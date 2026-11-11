// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

#ifndef USB_REGISTER_H
#define USB_REGISTER_H

#include <stdint.h>

/* Blocks until the ILCE-7M3 accepts `payload` (8192 bytes) on LUN 2,
   or until is_cancelled returns non-zero.
   0 accepted, 1 cancelled, 2 the watcher could not start. */
int usb_register_watch(
    const uint8_t *payload,
    int (*is_cancelled)(void *context),
    void (*log_line)(const char *line, void *context),
    void *context);

#endif
