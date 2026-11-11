// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// Finds the A7III after Send to Computer opens PTP/IP on port 15740.
enum CameraFinder {
    static func waitForCamera(
        manualIP: String?,
        waitSeconds: TimeInterval,
        isCancelled: @escaping () -> Bool,
        log: (String) -> Void
    ) -> String? {
        let trimmed = manualIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // A bare connect to port 15740 starts the camera's Connecting screen.
            // The transfer itself is the only connection this address needs.
            return trimmed
        }

        let networks = preferredNetworks()
        let local = Set(networks.map(\.ip))
        if networks.isEmpty {
            log("This Mac has no IPv4 address. Join the same Wi-Fi as the camera.")
        } else {
            let described = networks.map { "\($0.ip) (\($0.netmask))" }.joined(separator: ", ")
            log("Watching \(described). On the camera, choose Send to Computer.")
        }
        let announced = SSDPListener()
        if !announced.start(interfaces: networks.map(\.ip)) {
            log("Could not listen for camera announcements on UDP port 1900. Quit any other copy of Photo WiFi Receiver and try again.")
        }
        defer { announced.stop() }

        var sony: [String] = []
        var notedNetwork = false
        let deadline = Date().addingTimeInterval(waitSeconds)
        var lastSearch = Date.distantPast
        while Date() < deadline {
            if isCancelled() { return nil }
            for packet in announced.takePackets() {
                if isSonyTransferAnnouncement(packet.text) {
                    guard let ip = cameraAddress(sender: packet.sender, text: packet.text, local: local) else { continue }
                    if !sony.contains(ip) {
                        sony.insert(ip, at: 0)
                        log("The camera announced itself at \(ip).")
                    }
                } else if !notedNetwork && isPrivateIPv4(packet.sender) && !local.contains(packet.sender) {
                    notedNetwork = true
                    log("This Mac can see other devices. Waiting for the camera to announce Send to Computer.")
                }
            }
            if let found = sony.first { return found }
            if Date().timeIntervalSince(lastSearch) > 2 {
                announced.search()
                lastSearch = Date()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }
}

public struct CameraWatch: Equatable, Sendable {
    public var status: String
    public var address: String?
    public var searching: Bool

    public init(status: String, address: String?, searching: Bool) {
        self.status = status
        self.address = address
        self.searching = searching
    }
}

/// Watches the LAN continuously so the window can show the camera before a transfer starts.
public final class CameraMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var watch = CameraWatch(status: "Looking for the camera.", address: nil, searching: true)
    private var running = false
    private var generation = 0
    private var worker: Thread?
    private var listener: SSDPListener?
    private var exitGate: DispatchSemaphore?

    public init() {}

    public func read() -> CameraWatch {
        lock.lock()
        defer { lock.unlock() }
        return watch
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        stop()
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        generation += 1
        let token = generation
        running = true
        exitGate = gate
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.loop(token: token, onChange: onChange)
            gate.signal()
        }
        thread.name = "camera-monitor"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let gate = exitGate
        let worker = self.worker
        lock.unlock()
        listener?.stop()
        if wasRunning, Thread.current != worker {
            _ = gate?.wait(timeout: .now() + 2)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == token
    }

    private func publish(_ next: CameraWatch, onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        let changed = watch != next
        watch = next
        lock.unlock()
        if changed { onChange() }
    }

    private func loop(token: Int, onChange: @escaping @Sendable () -> Void) {
        let started = Date()
        let listener = SSDPListener()
        self.listener = listener
        let networks = preferredNetworks()
        let local = Set(networks.map(\.ip))
        let whereWeAre = networks.map(\.ip).joined(separator: ", ")
        if !listener.start(interfaces: networks.map(\.ip)) {
            publish(CameraWatch(
                status: "Photo WiFi Receiver could not listen for the camera because UDP port 1900 is already in use. Quit the other copy and open this one again.",
                address: nil,
                searching: false
            ), onChange: onChange)
            return
        }
        defer { listener.stop() }

        var sonyIP: String?
        var sonyName: String?
        var lastSearch = Date.distantPast
        var heardNetwork = false
        var checkedGateway = false
        var gatewayReachable = true

        while isCurrent(token) {
            for packet in listener.takePackets() {
                let fromUs = local.contains(packet.sender)
                if isSonyTransferAnnouncement(packet.text) {
                    guard let ip = cameraAddress(sender: packet.sender, text: packet.text, local: local) else { continue }
                    heardNetwork = true
                    if sonyIP != ip {
                        sonyIP = ip
                        sonyName = nil
                        if let location = locationURL(in: packet.text) {
                            sonyName = sonyFriendlyName(at: location)
                        }
                    }
                } else if !fromUs && isPrivateIPv4(packet.sender) {
                    heardNetwork = true
                }
            }

            if let ip = sonyIP {
                // Do not connect to port 15740 from the watcher. That connection
                // starts Connecting… and resetting it sends the body back to shooting.
                let name = sonyName ?? "Sony camera"
                publish(CameraWatch(
                    status: "\(name) at \(ip). Press Receive photos.",
                    address: ip,
                    searching: false
                ), onChange: onChange)
            } else {
                if !checkedGateway && Date().timeIntervalSince(started) > 3 {
                    checkedGateway = true
                    if let gateway = defaultIPv4Gateway() {
                        if tcpProbe(host: gateway, port: 80, timeout: 0.6) == .unreachable {
                            gatewayReachable = false
                        }
                    }
                }
                publish(CameraWatch(
                    status: searchingStatus(
                        networks: whereWeAre,
                        heardNetwork: heardNetwork,
                        gatewayReachable: gatewayReachable,
                        waited: Date().timeIntervalSince(started)
                    ),
                    address: nil,
                    searching: !networks.isEmpty && (gatewayReachable || !checkedGateway)
                ), onChange: onChange)
            }

            if Date().timeIntervalSince(lastSearch) > 2 {
                listener.search()
                lastSearch = Date()
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
    }
}

/// The transfer service the body announces while Send to Computer is on screen.
func isSonyTransferAnnouncement(_ text: String) -> Bool {
    let folded = text.lowercased()
    if folded.contains("mtpnullservice") { return true }
    if folded.contains("microsoft-com:device:mtp") { return true }
    if folded.contains("mint-x") { return true }
    return false
}

func locationIPv4(in text: String) -> String? {
    guard let url = locationURL(in: text), let host = URL(string: url)?.host else { return nil }
    let parts = host.split(separator: ".")
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
    return host
}

func locationURL(in text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("location:") else { continue }
        let value = trimmed.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") else { return nil }
        return value
    }
    return nil
}

func isPrivateIPv4(_ ip: String) -> Bool {
    if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") { return true }
    let parts = ip.split(separator: ".")
    if parts.count == 4, parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) { return true }
    return false
}

func cameraAddress(sender: String, text: String, local: Set<String>) -> String? {
    if let located = locationIPv4(in: text), isPrivateIPv4(located), !local.contains(located) {
        return located
    }
    if isPrivateIPv4(sender), !local.contains(sender) { return sender }
    return nil
}

private func searchingStatus(networks: String, heardNetwork: Bool, gatewayReachable: Bool, waited: TimeInterval) -> String {
    if networks.isEmpty {
        return "This Mac has no IPv4 address. Join the same Wi-Fi network as the camera."
    }
    if waited > 3 && !heardNetwork && !gatewayReachable {
        return "This Mac cannot reach other devices on the network. Allow Photo WiFi Receiver in System Settings → Privacy & Security → Local Network, then open the app again."
    }
    if heardNetwork || (waited > 8 && gatewayReachable) {
        return "This Mac is on \(networks). The camera has not announced itself. On the camera, choose Menu → Network → Send to Computer and stay on that screen. The camera announces itself only from that screen."
    }
    return "Looking for the camera on \(networks). On the camera, choose Menu → Network → Send to Computer and stay on that screen."
}

private func preferredNetworks() -> [(name: String, ip: String, netmask: String)] {
    let networks = localIPv4Networks()
    let preferred = defaultRouteInterface()
    return networks.sorted { lhs, rhs in
        if lhs.name == preferred { return true }
        if rhs.name == preferred { return false }
        return lhs.name < rhs.name
    }
}

private func defaultRouteText() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/route")
    process.arguments = ["-n", "get", "default"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

private func defaultRouteInterface() -> String? {
    for line in defaultRouteText().split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first, first.hasPrefix("interface"), let value = parts.last else { continue }
        return value
    }
    return nil
}

private func defaultIPv4Gateway() -> String? {
    for line in defaultRouteText().split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first, first.hasPrefix("gateway"), let value = parts.last else { continue }
        let octets = value.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) { return value }
    }
    return nil
}

private func sonyFriendlyName(at location: String) -> String? {
    guard let url = URL(string: location), let host = url.host, isPrivateIPv4(host) else { return nil }
    let session = URLSession(configuration: .ephemeral)
    var request = URLRequest(url: url, timeoutInterval: 2)
    request.httpMethod = "GET"
    let wait = DispatchSemaphore(value: 0)
    var body = ""
    let task = session.dataTask(with: request) { data, _, _ in
        if let data { body = String(data: data, encoding: .utf8) ?? "" }
        wait.signal()
    }
    task.resume()
    _ = wait.wait(timeout: .now() + 3)
    task.cancel()
    session.invalidateAndCancel()
    guard body.lowercased().contains("sony") else { return nil }
    return xmlText("friendlyName", in: body)
}

private func xmlText(_ tag: String, in xml: String) -> String? {
    let open = "<\(tag)>"
    let close = "</\(tag)>"
    guard let start = xml.range(of: open), let end = xml.range(of: close, range: start.upperBound..<xml.endIndex) else { return nil }
    let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private enum TCPProbe { case open, refused, unreachable, timedOut }

private func tcpProbe(host: String, port: UInt16, timeout: TimeInterval) -> TCPProbe {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return .unreachable }
    // Reset the camera's half-open session instead of leaving it in FIN_WAIT.
    var reset = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .unreachable }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected == 0 { return .open }
    if errno != EINPROGRESS {
        return errno == ECONNREFUSED ? .refused : .unreachable
    }
    var pollSlot = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let waited = poll(&pollSlot, 1, Int32(max(timeout, 0) * 1000))
    if waited == 0 { return .timedOut }
    if waited < 0 { return .unreachable }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
    if socketError == 0 { return .open }
    if socketError == ECONNREFUSED { return .refused }
    if socketError == ETIMEDOUT { return .timedOut }
    return .unreachable
}

private struct SSDPPacket {
    var sender: String
    var text: String
}

/// Listens for the camera's UPnP announcement on the local network.
private final class SSDPListener {
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "ssdp-listener")
    private let lock = NSLock()
    private var packets: [SSDPPacket] = []
    private var running = false

    func start(interfaces: [String]) -> Bool {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return false }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var loopback: UInt8 = 0
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_LOOP, &loopback, socklen_t(MemoryLayout<UInt8>.size))
        var ttl: UInt8 = 2
        setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = UInt16(1900).bigEndian
        bindAddress.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &bindAddress) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            Darwin.close(socketFD)
            return false
        }
        let joined = joinGroup(socketFD, interfaces: interfaces)
        if !joined && interfaces.isEmpty == false {
            _ = joinGroup(socketFD, interfaces: [])
        }
        fd = socketFD
        running = true
        queue.async { [weak self] in self?.receiveLoop() }
        search()
        return true
    }

    func stop() {
        running = false
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    func takePackets() -> [SSDPPacket] {
        lock.lock()
        let copy = packets
        packets.removeAll()
        lock.unlock()
        return copy
    }

    func search() {
        let socketFD = fd
        guard socketFD >= 0 else { return }
        let targets = [
            "urn:microsoft-com:service:MtpNullService:1",
            "urn:microsoft-com:device:mtp:1",
            "ssdp:all",
        ]
        for target in targets {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n"
            let bytes = Array(message.utf8)
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(1900).bigEndian
            destination.sin_addr.s_addr = inet_addr("239.255.255.250")
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(socketFD, base, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func joinGroup(_ socketFD: Int32, interfaces: [String]) -> Bool {
        let targets = interfaces.isEmpty ? [INADDR_ANY] : interfaces.map { inet_addr($0) }
        var joined = false
        for interfaceAddress in targets where interfaceAddress != INADDR_NONE {
            var group = ip_mreq()
            group.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
            group.imr_interface.s_addr = interfaceAddress
            if setsockopt(socketFD, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                if !joined {
                    var iface = in_addr(s_addr: interfaceAddress)
                    setsockopt(socketFD, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
                }
                joined = true
            }
        }
        return joined
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    Darwin.recvfrom(fd, &buffer, buffer.count, 0, address, &length)
                }
            }
            if count <= 0 { continue }
            var address = sender.sin_addr
            var textBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &textBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: textBuffer)
            let text = String(bytes: buffer.prefix(count), encoding: .utf8) ?? ""
            guard !text.isEmpty else { continue }
            lock.lock()
            if packets.count > 64 { packets.removeFirst(packets.count - 64) }
            packets.append(SSDPPacket(sender: host, text: text))
            lock.unlock()
        }
    }
}
