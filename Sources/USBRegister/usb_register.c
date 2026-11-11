// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

#include "usb_register.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <string.h>
#include <unistd.h>

/* Opens the A7III mass-storage interface before the kernel disk driver
   takes it, then sends the PlayMemories host record. No seize, no
   reenumerate, and no eject. LUN 2 is the setup unit that accepted
   this record. */

typedef struct Watch {
    const uint8_t *payload;
    int (*is_cancelled)(void *);
    void (*log_line)(const char *, void *);
    void *context;
    int accepted;
} Watch;

static int cancelled(Watch *watch) {
    return watch->is_cancelled && watch->is_cancelled(watch->context);
}

static void log_line(Watch *watch, const char *line) {
    if (watch->log_line && line) watch->log_line(line, watch->context);
}

/* 1 = mass-storage interface, 0 = a different interface, -1 = not ready. */
static int interface_kind(io_service_t service) {
    CFTypeRef vendor = IORegistryEntryCreateCFProperty(service, CFSTR("idVendor"), kCFAllocatorDefault, 0);
    CFTypeRef product = IORegistryEntryCreateCFProperty(service, CFSTR("idProduct"), kCFAllocatorDefault, 0);
    CFTypeRef class_value = IORegistryEntryCreateCFProperty(service, CFSTR("bInterfaceClass"), kCFAllocatorDefault, 0);
    int vid = 0, pid = 0, class_id = -1;
    if (vendor) CFNumberGetValue(vendor, kCFNumberIntType, &vid);
    if (product) CFNumberGetValue(product, kCFNumberIntType, &pid);
    if (class_value) CFNumberGetValue(class_value, kCFNumberIntType, &class_id);
    if (vendor) CFRelease(vendor);
    if (product) CFRelease(product);
    if (class_value) CFRelease(class_value);
    if (vid != 0x054c || pid != 0x0c01) return 0;
    if (class_id < 0) return -1;
    return class_id == 0x08 ? 1 : 0;
}

/* 0 accepted, 1 driver owns the port, 2 not this camera, 3 try again. */
static int send_record(io_service_t service, Watch *watch) {
    int kind = interface_kind(service);
    if (kind == 0) return 2;
    if (kind < 0) return 3;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || !plugin) return kr == kIOReturnExclusiveAccess ? 1 : 3;

    IOUSBInterfaceInterface700 **intf = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID700), (LPVOID *)&intf);
    (*plugin)->Release(plugin);
    if (hr || !intf) return 3;

    kr = (*intf)->USBInterfaceOpen(intf);
    if (kr != kIOReturnSuccess) {
        (*intf)->Release(intf);
        return kr == kIOReturnExclusiveAccess ? 1 : 3;
    }

    UInt8 pipes = 0, pipe_in = 0, pipe_out = 0;
    (*intf)->GetNumEndpoints(intf, &pipes);
    for (UInt8 pipe = 1; pipe <= pipes; pipe++) {
        UInt8 direction = 0, number = 0, transfer = 0, interval = 0;
        UInt16 packet = 0;
        kr = (*intf)->GetPipeProperties(intf, pipe, &direction, &number, &transfer, &packet, &interval);
        if (kr != kIOReturnSuccess || transfer != kUSBBulk) continue;
        if (direction == kUSBIn && !pipe_in) pipe_in = pipe;
        if (direction == kUSBOut && !pipe_out) pipe_out = pipe;
    }
    int result = 3;
    if (pipe_in && pipe_out) {
        uint8_t cbw[31];
        memset(cbw, 0, sizeof(cbw));
        cbw[0] = 'U'; cbw[1] = 'S'; cbw[2] = 'B'; cbw[3] = 'C';
        uint32_t tag = 1;
        uint32_t length = 8192;
        memcpy(cbw + 4, &tag, 4);
        memcpy(cbw + 8, &length, 4);
        cbw[13] = 2;
        cbw[14] = 9;
        const uint8_t cdb[9] = {0x7a, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
        memcpy(cbw + 15, cdb, 9);
        uint8_t payload[8192];
        memcpy(payload, watch->payload, sizeof(payload));
        kr = (*intf)->WritePipeTO(intf, pipe_out, cbw, 31, 2000, 5000);
        if (kr == kIOReturnSuccess)
            kr = (*intf)->WritePipeTO(intf, pipe_out, payload, 8192, 2000, 5000);
        uint8_t csw[13];
        UInt32 got = sizeof(csw);
        if (kr == kIOReturnSuccess) {
            kr = (*intf)->ReadPipeTO(intf, pipe_in, csw, &got, 2000, 5000);
            if (kr != kIOReturnSuccess) {
                (*intf)->ClearPipeStallBothEnds(intf, pipe_in);
                got = sizeof(csw);
                kr = (*intf)->ReadPipeTO(intf, pipe_in, csw, &got, 2000, 5000);
            }
        }
        if (kr == kIOReturnSuccess && got == 13 &&
            csw[0] == 'U' && csw[1] == 'S' && csw[2] == 'B' && csw[3] == 'S' && csw[12] == 0) {
            result = 0;
        }
    }
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    return result;
}

static void consume(void *refcon, io_iterator_t iterator) {
    Watch *watch = refcon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (watch->accepted || cancelled(watch)) {
            IOObjectRelease(service);
            continue;
        }
        int result = 3;
        for (int attempt = 0; attempt < 8 && !cancelled(watch); attempt++) {
            result = send_record(service, watch);
            if (result == 0 || result == 1 || result == 2) break;
        }
        IOObjectRelease(service);
        if (result == 0) {
            watch->accepted = 1;
            log_line(watch, "The camera accepted this Mac.");
        } else if (result == 1) {
            log_line(watch, "The USB port is busy. Unplug the cable and plug it in again.");
        } else if (result == 3) {
            log_line(watch, "The camera did not accept this Mac. Unplug the cable and plug it in again.");
        }
    }
}

int usb_register_watch(
    const uint8_t *payload,
    int (*is_cancelled)(void *context),
    void (*log_line_fn)(const char *line, void *context),
    void *context)
{
    if (!payload) return 2;
    Watch watch = {
        .payload = payload,
        .is_cancelled = is_cancelled,
        .log_line = log_line_fn,
        .context = context,
        .accepted = 0
    };

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) return 2;
    CFRunLoopAddSource(
        CFRunLoopGetCurrent(),
        IONotificationPortGetRunLoopSource(port),
        kCFRunLoopDefaultMode);

    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostInterface");
    int vid = 0x054c;
    int pid = 0x0c01;
    CFNumberRef vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef product = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(properties, CFSTR("idVendor"), vendor);
    CFDictionarySetValue(properties, CFSTR("idProduct"), product);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), properties);
    CFRelease(vendor);
    CFRelease(product);
    CFRelease(properties);

    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceAddMatchingNotification(
        port, kIOFirstPublishNotification, matching, consume, &watch, &iterator);
    if (kr != KERN_SUCCESS) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
        IONotificationPortDestroy(port);
        return 2;
    }

    consume(&watch, iterator);
    while (!watch.accepted && !cancelled(&watch)) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, true);
    }

    IOObjectRelease(iterator);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    IONotificationPortDestroy(port);
    return watch.accepted ? 0 : 1;
}
