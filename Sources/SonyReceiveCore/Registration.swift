// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import Foundation
import USBRegister

/// 8192-byte host record the A7III stores for Send to Computer.
/// The layout is the one the body accepted: magic, a UTF-16 name, then the 16-byte identity.
func registrationPayload(name: String, guid: [UInt8]) -> Data {
    var payload = Data(repeating: 0, count: 8192)
    payload.replaceSubrange(0..<5, with: [0x25, 0x01, 0x00, 0x00, 0x08])
    for (index, unit) in name.utf16.prefix(8).enumerated() {
        payload[17 + index * 2] = UInt8(unit & 0xff)
        payload[18 + index * 2] = UInt8((unit >> 8) & 0xff)
    }
    payload.replaceSubrange(177..<181, with: [0x10, 0x00, 0x00, 0x00])
    let identity = guid.count == 16 ? guid : [UInt8](repeating: 0, count: 16)
    payload.replaceSubrange(181..<197, with: identity)
    return payload
}

public enum USBRegistration {
    /// Watches for the camera on USB and writes this Mac's Send-to-Computer record.
    /// Returns when the camera accepts it. Throws if the watcher is stopped or cannot start.
    public static func watch(
        guidOverride: [UInt8]?,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void
    ) throws {
        guard let guid = CameraSession.candidateGUIDs(override: guidOverride).first, guid.count == 16 else {
            throw ReceiveError.message("This Mac has no hardware address to register.")
        }
        let payload = registrationPayload(name: computerName(), guid: guid)
        log("Saving \(formatGUID(guid)) for \(computerName()). Plug the camera in with USB.")
        let box = WatchBox(isCancelled: isCancelled, log: log)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<WatchBox>.fromOpaque(context).release() }
        let result = payload.withUnsafeBytes { raw -> Int32 in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            return usb_register_watch(bytes, watchIsCancelled, watchLog, context)
        }
        if result == 0 { return }
        if isCancelled() || result == 1 { throw ReceiveError.message("Stopped.") }
        throw ReceiveError.message("Could not watch for the camera over USB.")
    }
}

private final class WatchBox {
    let isCancelled: () -> Bool
    let log: (String) -> Void
    init(isCancelled: @escaping () -> Bool, log: @escaping (String) -> Void) {
        self.isCancelled = isCancelled
        self.log = log
    }
}

private let watchIsCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    let box = Unmanaged<WatchBox>.fromOpaque(context).takeUnretainedValue()
    return box.isCancelled() ? 1 : 0
}

private let watchLog: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { line, context in
    guard let line, let context else { return }
    let box = Unmanaged<WatchBox>.fromOpaque(context).takeUnretainedValue()
    box.log(String(cString: line))
}
