// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import Foundation

public struct ReceiveResult: Equatable {
    public var cameraName: String
    public var saved: Int
    public var skipped: Int
    public var moviesLeft: Int
}

public enum ReceiveError: Error, LocalizedError {
    case notFound
    case rejected
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The camera did not open a connection. On the camera choose Menu, Network, Send to Computer, then the memory card."
        case .rejected:
            return "The camera refused this Mac. Press Set this Mac, plug the camera in with USB, and leave the cable in until the camera accepts this Mac."
        case .message(let text):
            return text
        }
    }
}

public enum CameraSession {
    public static func receive(
        manualIP: String?,
        guidOverride: [UInt8]?,
        destination: URL,
        waitSeconds: TimeInterval = 90,
        isCancelled: @escaping () -> Bool,
        log: @escaping (String) -> Void,
        progress: @escaping (String) -> Void
    ) throws -> ReceiveResult {
        guard let host = CameraFinder.waitForCamera(
            manualIP: manualIP,
            waitSeconds: waitSeconds,
            isCancelled: isCancelled,
            log: log
        ) else {
            if isCancelled() { throw ReceiveError.message("Stopped.") }
            throw ReceiveError.notFound
        }
        log("Camera is at \(host). Connecting.")
        let guids = candidateGUIDs(override: guidOverride)
        let deadline = Date().addingTimeInterval(20)
        var lastError: Error = ReceiveError.rejected
        for guid in guids {
            while Date() < deadline {
                if isCancelled() { throw ReceiveError.message("Stopped.") }
                do {
                    let link = try PTPLink(host: host, guid: guid, hostName: computerName(), log: log)
                    defer { link.close() }
                    log("Connected to \(link.cameraName.isEmpty ? "the camera" : link.cameraName).")
                    let result = try download(link: link, destination: destination, isCancelled: isCancelled, log: log, progress: progress)
                    link.noteFinished()
                    return result
                } catch SocketError.notListening {
                    lastError = SocketError.notListening
                    Thread.sleep(forTimeInterval: 0.5)
                } catch SocketError.rejected {
                    log("The camera refused identity \(formatGUID(guid)).")
                    lastError = ReceiveError.rejected
                    break
                }
            }
        }
        throw lastError
    }

    /// Only the Wi-Fi address is registered on the camera. Trying every adapter
    /// makes the body restart "Connecting…" for each one.
    static func candidateGUIDs(override: [UInt8]?) -> [[UInt8]] {
        var guids: [[UInt8]] = []
        if let override, override.count == 16 { guids.append(override) }
        let wifiNames = wifiInterfaceNames()
        let all = hardwareAddresses()
        let wifi = all.filter { wifiNames.contains($0.name) }
        for address in (wifi.isEmpty ? all : wifi).sorted(by: { $0.name < $1.name }) {
            if let guid = playMemoriesGUID(mac: address.mac), !guids.contains(guid) {
                guids.append(guid)
            }
        }
        return guids
    }
}

private final class PTPLink {
    let cameraName: String
    private let command: TCPSocket
    private let events: TCPSocket
    private let log: (String) -> Void
    private var transaction: UInt32 = 0
    private let eventQueue = DispatchQueue(label: "ptp-events")
    private var eventRunning = true
    private var sessionOpen = false
    private var accepted = false
    private var endSessionOnClose = false

    init(host: String, guid: [UInt8], hostName: String, log: @escaping (String) -> Void) throws {
        let command = try TCPSocket.connect(host: host, port: PTP.port, timeout: 8)
        do {
            try command.writeAll(initCommandPacket(guid: guid, hostName: hostName))
        } catch {
            command.abort()
            throw error
        }
        log("Asked the camera to accept \(hostName).")
        let ack: (type: UInt32, payload: Data)
        do {
            ack = try command.readPacket(within: 8)
        } catch SocketError.timeout {
            command.abort()
            throw SocketError.protocolError("The camera is still on Connecting. Leave Send to Computer, open it again, and press Receive once.")
        } catch {
            command.abort()
            throw error
        }
        if ack.type == PTP.initFail {
            command.abort()
            throw SocketError.rejected
        }
        guard ack.type == PTP.initAck, let parsed = parseInitAck(ack.payload) else {
            command.abort()
            throw SocketError.protocolError("The camera sent an unexpected greeting.")
        }
        log("The camera answered.")
        // The event port can refuse the first try while the body is still
        // switching from the greeting to the session. Only a refused connect
        // is retried. A second accepted connection restarts Connecting.
        var events: TCPSocket?
        var eventError: Error = SocketError.notListening
        for attempt in 0..<5 {
            do {
                events = try TCPSocket.connect(host: host, port: PTP.port, timeout: 8)
                break
            } catch SocketError.notListening {
                eventError = SocketError.notListening
                if attempt < 4 { Thread.sleep(forTimeInterval: 0.2) }
            } catch {
                command.abort()
                throw error
            }
        }
        guard let events else {
            command.abort()
            throw eventError
        }
        do {
            try events.writeAll(eventRequestPacket(connection: parsed.connection))
            let eventAck = try events.readPacket(within: 8)
            guard eventAck.type == PTP.initEventAck else {
                events.abort()
                command.abort()
                throw SocketError.protocolError("The camera did not open the event connection.")
            }
        } catch {
            events.abort()
            command.abort()
            throw error
        }
        self.command = command
        self.events = events
        self.log = log
        self.cameraName = parsed.name
        self.accepted = true
        eventQueue.async { [weak self] in self?.drainEvents() }
    }

    func noteFinished() {
        endSessionOnClose = true
    }

    func close() {
        eventRunning = false
        if sessionOpen && endSessionOnClose {
            sessionOpen = false
            command.setReadTimeout(2)
            tellCameraTheSaveFinished()
            do {
                _ = try call(opcode: PTP.closeSession, parameters: [])
                events.close()
                command.close()
                return
            } catch {
                // The camera already dropped the link, usually because it powered off.
            }
        }
        // A reset after the camera has accepted this Mac leaves Send to Computer
        // and returns the body to shooting. Shut the sockets down without one.
        if accepted {
            events.close()
            command.close()
            return
        }
        events.abort()
        command.abort()
    }

    func prepare() throws {
        log("Opening a session.")
        let (_, opened) = try call(opcode: PTP.openSession, parameters: [1])
        guard opened.code == PTP.ok else {
            throw SocketError.protocolError("The camera declined the session (\(hex(opened.code))).")
        }
        sessionOpen = true
        log("Opened a session on the camera.")
        _ = try call(opcode: PTP.getDeviceInfo, parameters: [])
        log("Read the camera description.")
        log("Asking the camera to send photos.")
        let sony = try sendSonyConnect()
        guard sony.code == PTP.ok else {
            throw SocketError.protocolError("The camera did not accept the transfer handshake (\(hex(sony.code))).")
        }
        _ = try call(opcode: PTP.sonyOperationResult, parameters: [4])
        log("The camera is ready to send photos.")
    }

    func storageIDs() throws -> [UInt32] {
        let (payload, answer) = try call(opcode: PTP.getStorageIDs, parameters: [])
        guard answer.code == PTP.ok else {
            throw SocketError.protocolError("The camera did not list its memory cards (\(hex(answer.code))).")
        }
        return parseIDArray(payload)
    }

    func objectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        let (payload, answer) = try call(opcode: PTP.getObjectHandles, parameters: [storage, 0, parent])
        guard answer.code == PTP.ok else {
            // A folder that cannot be listed is skipped. The card itself must answer.
            if parent != 0 && parent != 0xffff_ffff { return [] }
            throw SocketError.protocolError("The camera did not list its photos (\(hex(answer.code))).")
        }
        return parseIDArray(payload)
    }

    func objectInfo(handle: UInt32) throws -> CameraObject? {
        let (payload, answer) = try call(opcode: PTP.getObjectInfo, parameters: [handle])
        guard answer.code == PTP.ok else { return nil }
        return parseObjectInfo(payload, handle: handle)
    }

    func downloadObject(handle: UInt32, to url: URL, progress: (Int64, Int64) -> Void) throws {
        try transact(opcode: PTP.getObject, parameters: [handle])
        let start = try readCommand()
        if start.type == PTP.response {
            let answer = parseResponse(start.payload)
            throw SocketError.protocolError("The camera did not send \(url.lastPathComponent) (\(hex(answer.code))).")
        }
        guard start.type == PTP.startData, start.payload.count >= 8 else {
            throw SocketError.protocolError("The camera started \(url.lastPathComponent) in an unexpected way.")
        }
        let total = Int64(readU32(start.payload, 4))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        var output: FileHandle? = try FileHandle(forWritingTo: partial)
        defer { try? output?.close() }
        var received: Int64 = 0
        while received < total {
            let packet = try readCommand()
            guard packet.type == PTP.data || packet.type == PTP.endData, packet.payload.count >= 4 else {
                throw SocketError.protocolError("The photo download was interrupted.")
            }
            let chunk = packet.payload.dropFirst(4)
            if !chunk.isEmpty { try output?.write(contentsOf: Data(chunk)) }
            received += Int64(chunk.count)
            progress(received, total)
        }
        try output?.close()
        output = nil
        let answer = try response()
        guard answer.code == PTP.ok else {
            try? FileManager.default.removeItem(at: partial)
            throw SocketError.protocolError("The camera reported an error after \(url.lastPathComponent) (\(hex(answer.code))).")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    private func transact(opcode: UInt16, parameters: [UInt32], sendingData: Bool = false) throws {
        let packet = commandPacket(
            opcode: opcode,
            transaction: transaction,
            parameters: parameters,
            sendingData: sendingData
        )
        transaction += 1
        try command.writeAll(packet)
    }

    private func sendSonyConnect() throws -> PTPResponse {
        try sendSonyPackets(sonyConnectPackets(transaction: transaction))
    }

    /// Command 5 is sent only here, after the photos are saved. The same command
    /// with the older packet layout made this body ask for USB setup again.
    private func tellCameraTheSaveFinished() {
        log("Telling the camera the save is finished.")
        do {
            let answer = try sendSonyPackets(sonyPowerOffPackets(transaction: transaction))
            if answer.code == PTP.ok {
                log("The camera accepted the finished save.")
            } else {
                log("The camera answered \(hex(answer.code)) after the finished save.")
            }
        } catch {
            log("The camera closed the connection after the save.")
        }
    }

    private func sendSonyPackets(_ packets: [Data]) throws -> PTPResponse {
        transaction += 1
        for packet in packets {
            try command.writeAll(packet)
        }
        return try response()
    }

    private func call(opcode: UInt16, parameters: [UInt32]) throws -> (Data, PTPResponse) {
        try transact(opcode: opcode, parameters: parameters)
        let first = try readCommand()
        if first.type == PTP.response { return (Data(), parseResponse(first.payload)) }
        guard first.type == PTP.startData, first.payload.count >= 8 else {
            throw SocketError.protocolError("The camera's reply was packet \(first.type), not the expected data.")
        }
        let total = Int(readU32(first.payload, 4))
        var payload = Data()
        if total > 0 { payload.reserveCapacity(total) }
        while payload.count < total {
            let packet = try readCommand()
            guard packet.type == PTP.data || packet.type == PTP.endData, packet.payload.count >= 4 else {
                throw SocketError.protocolError("The camera's reply was cut short.")
            }
            payload.append(packet.payload.dropFirst(4))
        }
        return (payload, try response())
    }

    private func response() throws -> PTPResponse {
        while true {
            let packet = try readCommand()
            switch packet.type {
            case PTP.response:
                return parseResponse(packet.payload)
            case PTP.startData, PTP.data, PTP.endData:
                continue
            default:
                throw SocketError.protocolError("Expected a response from the camera (packet \(packet.type)).")
            }
        }
    }

    private func readCommand() throws -> (type: UInt32, payload: Data) {
        while true {
            let packet = try command.readPacket()
            if packet.type == PTP.ping {
                var pong = ByteWriter()
                pong.u32(8)
                pong.u32(PTP.pong)
                try command.writeAll(pong.data)
                continue
            }
            return packet
        }
    }

    private func drainEvents() {
        events.setReadTimeout(2)
        while eventRunning {
            guard let packet = try? events.readPacket() else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if packet.type == PTP.ping {
                var pong = ByteWriter()
                pong.u32(8)
                pong.u32(PTP.pong)
                try? events.writeAll(pong.data)
            }
        }
    }
}

private func download(
    link: PTPLink,
    destination: URL,
    isCancelled: () -> Bool,
    log: (String) -> Void,
    progress: (String) -> Void
) throws -> ReceiveResult {
    try link.prepare()
    let storages = try link.storageIDs()
    if storages.isEmpty { throw ReceiveError.message("The camera reported no memory card.") }
    log("Found \(storages.count) memory card\(storages.count == 1 ? "" : "s").")
    var saved = 0
    var skipped = 0
    var movies = 0
    var seen = Set<UInt32>()
    for (index, storage) in storages.enumerated() {
        if isCancelled() { throw ReceiveError.message("Stopped.") }
        let cardFolder = storages.count > 1 ? "Card \(index + 1)" : nil
        // Parent 0 is the whole card. 0xFFFFFFFF is only the top folder, which on this
        // body is DCIM and contains no photos of its own.
        let handles: [UInt32]
        do {
            let wholeCard = try link.objectHandles(storage: storage, parent: 0)
            if wholeCard.isEmpty {
                log("The full card list was empty. Checking the top folder.")
                handles = try link.objectHandles(storage: storage, parent: 0xffff_ffff)
            } else {
                handles = wholeCard
            }
        } catch {
            log("The full card list was refused. Checking the top folder.")
            handles = try link.objectHandles(storage: storage, parent: 0xffff_ffff)
        }
        log("The camera offered \(handles.count) item\(handles.count == 1 ? "" : "s").")
        try collect(
            handles,
            storage: storage,
            cardFolder: cardFolder,
            depth: 0,
            seen: &seen,
            saved: &saved,
            skipped: &skipped,
            movies: &movies,
            link: link,
            destination: destination,
            isCancelled: isCancelled,
            log: log,
            progress: progress
        )
    }
    if saved == 0 && skipped == 0 && movies == 0 {
        log("The camera did not offer any photos.")
    } else if saved == 0 && skipped > 0 {
        log("\(skipped) photo\(skipped == 1 ? " is" : "s are") already in the folder.")
    }
    progress(saved == 0 ? "No new photos." : "Saved \(saved) photo\(saved == 1 ? "" : "s").")
    return ReceiveResult(cameraName: link.cameraName, saved: saved, skipped: skipped, moviesLeft: movies)
}

private func collect(
    _ handles: [UInt32],
    storage: UInt32,
    cardFolder: String?,
    depth: Int,
    seen: inout Set<UInt32>,
    saved: inout Int,
    skipped: inout Int,
    movies: inout Int,
    link: PTPLink,
    destination: URL,
    isCancelled: () -> Bool,
    log: (String) -> Void,
    progress: (String) -> Void
) throws {
    if depth > 8 { return }
    for handle in handles {
        if isCancelled() { throw ReceiveError.message("Stopped.") }
        if !seen.insert(handle).inserted { continue }
        guard let object = try link.objectInfo(handle: handle) else { continue }
        if object.isFolder {
            let folderName = object.name.isEmpty ? "a folder" : object.name
            log("Opening \(folderName).")
            let children = try link.objectHandles(storage: storage, parent: handle)
            try collect(
                children,
                storage: storage,
                cardFolder: cardFolder,
                depth: depth + 1,
                seen: &seen,
                saved: &saved,
                skipped: &skipped,
                movies: &movies,
                link: link,
                destination: destination,
                isCancelled: isCancelled,
                log: log,
                progress: progress
            )
            continue
        }
        let ext = ((object.name as NSString).pathExtension).lowercased()
        if ["mp4", "mov", "mts", "m2ts", "mpg"].contains(ext) {
            movies += 1
            continue
        }
        guard let name = saveName(for: object) else { continue }
        let url = photoFileURL(name: name, cardFolder: cardFolder, destination: destination)
        if alreadySaved(url, expected: object.byteSize) {
            skipped += 1
            continue
        }
        progress("Saving \(name)")
        log("Saving \(name)")
        try link.downloadObject(handle: handle, to: url) { received, total in
            let percent = total > 0 ? Int(received * 100 / total) : 0
            progress("Saving \(name)  \(percent)%")
        }
        saved += 1
    }
}

private func alreadySaved(_ url: URL, expected: UInt32) -> Bool {
    guard expected > 0, expected != 0xffff_ffff else { return false }
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else { return false }
    return size == Int(expected)
}

func computerName() -> String {
    let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let trimmed = raw.split(separator: ".").first.map(String.init) ?? "Mac"
    return trimmed.isEmpty ? "Mac" : trimmed
}

private func wifiInterfaceNames() -> Set<String> {
    let output = shell("/usr/sbin/networksetup", ["-listallhardwareports"])
    var names: Set<String> = []
    var previous = ""
    for line in output.split(separator: "\n").map(String.init) {
        if previous.contains("Wi-Fi") || previous.contains("AirPort"), line.hasPrefix("Device:") {
            names.insert(line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces))
        }
        previous = line
    }
    return names
}

private func shell(_ launch: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

private func hex(_ code: UInt16) -> String { String(format: "0x%04x", code) }
