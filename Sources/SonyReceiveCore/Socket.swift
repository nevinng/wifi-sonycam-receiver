// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

enum SocketError: Error, LocalizedError {
    case failed(String)
    case notListening
    case timeout
    case closed
    case rejected
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .notListening: return "The camera is not accepting a connection yet. Stay on Send to Computer."
        case .timeout: return "The camera stopped answering."
        case .closed: return "The camera closed the connection."
        case .rejected: return "The camera refused this Mac."
        case .protocolError(let message): return message
        }
    }
}

/// One blocking TCP connection. All calls happen on the session's background task.
final class TCPSocket {
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { close() }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> TCPSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw SocketError.failed("Could not open a network socket.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw SocketError.failed("“\(host)” is not an IPv4 address.")
        }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected != 0 && errno != EINPROGRESS {
            let reason = errno
            Darwin.close(fd)
            if reason == ECONNREFUSED { throw SocketError.notListening }
            throw SocketError.failed("Could not reach \(host).")
        }
        if connected != 0 {
            var pollSlot = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let waited = poll(&pollSlot, 1, Int32(timeout * 1000))
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            if waited <= 0 || socketError != 0 {
                Darwin.close(fd)
                if waited == 0 || socketError == ECONNREFUSED || socketError == ETIMEDOUT {
                    throw SocketError.notListening
                }
                throw SocketError.failed("Could not reach \(host).")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        var time = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        return TCPSocket(fd: fd)
    }

    func setReadTimeout(_ seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if wrote > 0 {
                    sent += wrote
                    continue
                }
                if wrote < 0 && errno == EINTR { continue }
                throw wrote == 0 ? SocketError.closed : SocketError.failed("The camera stopped accepting data.")
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let read = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if read > 0 {
                got += read
                continue
            }
            if read < 0 && errno == EINTR { continue }
            if read < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT) {
                throw SocketError.timeout
            }
            throw read == 0 ? SocketError.closed : SocketError.failed("The camera stopped sending data.")
        }
        return data
    }

    func readPacket() throws -> (type: UInt32, payload: Data) {
        try readPacket(within: nil)
    }

    /// `within` waits with poll. The socket receive timeout does not always fire on macOS.
    func readPacket(within seconds: TimeInterval?) throws -> (type: UInt32, payload: Data) {
        let header = try readExactly(8, within: seconds)
        let length = Int(readU32(header, 0))
        let type = readU32(header, 4)
        guard length >= 8, length <= 16 * 1024 * 1024 else {
            throw SocketError.protocolError("The camera sent a packet of \(length) bytes.")
        }
        let payload = length == 8 ? Data() : try readExactly(length - 8, within: seconds)
        return (type, payload)
    }

    func close() {
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Drop the connection with a reset. A normal close leaves the camera in FIN_WAIT and on Connecting.
    func abort() {
        if fd >= 0 {
            var reset = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
            Darwin.close(fd)
            fd = -1
        }
    }

    private func readExactly(_ count: Int, within seconds: TimeInterval?) throws -> Data {
        if seconds == nil { return try readExactly(count) }
        let deadline = Date().addingTimeInterval(seconds ?? 0)
        var data = Data(count: count)
        var got = 0
        while got < count {
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { throw SocketError.timeout }
            var slot = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waited = poll(&slot, 1, Int32(remain * 1000))
            if waited == 0 { throw SocketError.timeout }
            if waited < 0 {
                if errno == EINTR { continue }
                throw SocketError.failed("The camera stopped sending data.")
            }
            let read = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return Darwin.read(fd, base.advanced(by: got), count - got)
            }
            if read > 0 {
                got += read
                continue
            }
            if read < 0 && errno == EINTR { continue }
            if read < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            throw read == 0 ? SocketError.closed : SocketError.failed("The camera stopped sending data.")
        }
        return data
    }
}

public func localIPv4Networks() -> [(name: String, ip: String, netmask: String)] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var results: [(String, String, String)] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
        let info = item.pointee
        cursor = info.ifa_next
        guard let address = info.ifa_addr, let mask = info.ifa_netmask else { continue }
        guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: info.ifa_name)
        if name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") { continue }
        var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var ipAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var maskAddress = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &ipAddress, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil,
              inet_ntop(AF_INET, &maskAddress, &maskBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: ipBuffer)
        let netmask = String(cString: maskBuffer)
        if ip.hasPrefix("169.254.") { continue }
        results.append((name, ip, netmask))
    }
    return results
}

func hardwareAddresses() -> [(name: String, mac: [UInt8])] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var results: [(String, [UInt8])] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
        let info = item.pointee
        cursor = info.ifa_next
        guard let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
        let name = String(cString: info.ifa_name)
        if name == "lo0" || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") { continue }
        let mac: [UInt8]? = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer in
            let link = pointer.pointee
            let length = Int(link.sdl_alen)
            guard length == 6 else { return nil }
            return withUnsafeBytes(of: link.sdl_data) { raw in
                let start = Int(link.sdl_nlen)
                guard start + 6 <= raw.count else { return nil }
                return [UInt8](raw[start..<(start + 6)])
            }
        }
        if let mac { results.append((name, mac)) }
    }
    return results
}
