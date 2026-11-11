// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import Foundation

enum PTP {
    static let port: UInt16 = 15740
    static let ok: UInt16 = 0x2001
    static let openSession: UInt16 = 0x1002
    static let closeSession: UInt16 = 0x1003
    static let getDeviceInfo: UInt16 = 0x1001
    static let getStorageIDs: UInt16 = 0x1004
    static let getObjectHandles: UInt16 = 0x1007
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let sonyOperation = UInt16(0x9280)
    static let sonyOperationResult = UInt16(0x9281)
    static let association: UInt16 = 0x3001
    static let jpeg: UInt16 = 0x3801

    static let initCommand: UInt32 = 1
    static let initAck: UInt32 = 2
    static let initEvent: UInt32 = 3
    static let initEventAck: UInt32 = 4
    static let initFail: UInt32 = 5
    static let command: UInt32 = 6
    static let response: UInt32 = 7
    static let startData: UInt32 = 9
    static let data: UInt32 = 10
    static let endData: UInt32 = 12
    static let ping: UInt32 = 13
    static let pong: UInt32 = 14
}

struct PTPResponse: Equatable {
    var code: UInt16
    var transaction: UInt32
    var parameters: [UInt32]
}

struct CameraObject: Equatable {
    var handle: UInt32
    var storageID: UInt32
    var format: UInt16
    var byteSize: UInt32
    var name: String
    var isFolder: Bool
}

struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ value: [UInt8]) { data.append(contentsOf: value) }
}

func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

/// Identity PlayMemories Home registers: eight zero bytes, `FF FF`, then the computer's MAC address.
func playMemoriesGUID(mac: [UInt8]) -> [UInt8]? {
    guard mac.count == 6 else { return nil }
    if mac.allSatisfy({ $0 == 0 }) || mac.allSatisfy({ $0 == 0xff }) { return nil }
    return [UInt8](repeating: 0, count: 8) + [0xff, 0xff] + mac
}

public func parseGUID(_ text: String) -> [UInt8]? {
    let cleaned = text.lowercased().filter { $0.isHexDigit }
    guard cleaned.count == 32 else { return nil }
    var bytes: [UInt8] = []
    var index = cleaned.startIndex
    for _ in 0..<16 {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

func formatGUID(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

func initCommandPacket(guid: [UInt8], hostName: String) -> Data {
    var writer = ByteWriter()
    writer.u32(0)
    writer.u32(PTP.initCommand)
    writer.bytes(guid.count == 16 ? guid : [UInt8](repeating: 0, count: 16))
    var units = Array(hostName.utf16.prefix(32))
    units.append(0)
    for unit in units { writer.u16(unit) }
    writer.u16(0) // protocol minor
    writer.u16(1) // protocol major
    var packet = writer.data
    let length = UInt32(packet.count)
    packet.replaceSubrange(0..<4, with: withUnsafeBytes(of: length.littleEndian) { Data($0) })
    return packet
}

func eventRequestPacket(connection: UInt32) -> Data {
    var writer = ByteWriter()
    writer.u32(12)
    writer.u32(PTP.initEvent)
    writer.u32(connection)
    return writer.data
}

func commandPacket(opcode: UInt16, transaction: UInt32, parameters: [UInt32], sendingData: Bool) -> Data {
    var writer = ByteWriter()
    let length = UInt32(18 + parameters.count * 4)
    writer.u32(length)
    writer.u32(PTP.command)
    writer.u32(sendingData ? 2 : 1)
    writer.u16(opcode)
    writer.u32(transaction)
    for parameter in parameters.prefix(5) { writer.u32(parameter) }
    return writer.data
}

/// Four packets for opcode 0x9280. Data phase is 0, the payload rides in a type-10
/// data packet, and the end packet is empty. A phase-2 command with the payload
/// inside the end packet leaves this A7III and it returns to shooting.
func sonyOperationPackets(transaction: UInt32, payload: Data) -> [Data] {
    var command = ByteWriter()
    command.u32(22)
    command.u32(PTP.command)
    command.u32(0)
    command.u16(PTP.sonyOperation)
    command.u32(transaction)
    command.u32(4)

    var start = ByteWriter()
    start.u32(20)
    start.u32(PTP.startData)
    start.u32(transaction)
    start.u32(UInt32(payload.count))
    start.u32(0)

    var data = ByteWriter()
    data.u32(UInt32(12 + payload.count))
    data.u32(PTP.data)
    data.u32(transaction)
    data.bytes([UInt8](payload))

    var end = ByteWriter()
    end.u32(12)
    end.u32(PTP.endData)
    end.u32(transaction)
    return [command.data, start.data, data.data, end.data]
}

/// Switches Send to Computer from “Connecting…” to “Sending…”.
func sonyConnectPackets(transaction: UInt32) -> [Data] {
    sonyOperationPackets(transaction: transaction, payload: sonyConnectPayload())
}

/// Tells the camera the computer has finished saving. Command 5 powers the body off,
/// which is what leaves the “Shuts down automatically after save” screen.
/// Send this only after a transfer has returned.
func sonyPowerOffPackets(transaction: UInt32) -> [Data] {
    sonyOperationPackets(transaction: transaction, payload: sonyPowerOffPayload())
}

func sonyConnectPayload() -> Data {
    var writer = ByteWriter()
    writer.u32(2)
    writer.u32(2)
    writer.u32(0)
    writer.u32(0)
    writer.u8(1)
    writer.u8(1)
    return writer.data
}

func sonyPowerOffPayload() -> Data {
    var writer = ByteWriter()
    writer.u32(0)
    writer.u32(5)
    writer.u32(0)
    writer.u32(0)
    return writer.data
}

func parseInitAck(_ payload: Data) -> (connection: UInt32, name: String)? {
    guard payload.count >= 20 else { return nil }
    let connection = readU32(payload, 0)
    let name = decodeUTF16(payload, offset: 20) ?? ""
    return (connection, name)
}

func parseResponse(_ payload: Data) -> PTPResponse {
    let code = readU16(payload, 0)
    let transaction = payload.count >= 6 ? readU32(payload, 2) : 0
    var parameters: [UInt32] = []
    var offset = 6
    while offset + 4 <= payload.count && parameters.count < 5 {
        parameters.append(readU32(payload, offset))
        offset += 4
    }
    return PTPResponse(code: code, transaction: transaction, parameters: parameters)
}

func parseIDArray(_ payload: Data) -> [UInt32] {
    guard payload.count >= 4 else { return [] }
    let count = Int(readU32(payload, 0))
    guard count >= 0, count < 100_000, payload.count >= 4 + count * 4 else { return [] }
    return (0..<count).map { readU32(payload, 4 + $0 * 4) }
}

func parseObjectInfo(_ payload: Data, handle: UInt32) -> CameraObject? {
    guard payload.count >= 52 else { return nil }
    let format = readU16(payload, 4)
    let association = readU16(payload, 42)
    var offset = 52
    let name = readPTPString(payload, offset: &offset) ?? ""
    let folder = format == PTP.association || association != 0
    return CameraObject(
        handle: handle,
        storageID: readU32(payload, 0),
        format: format,
        byteSize: readU32(payload, 8),
        name: name,
        isFolder: folder
    )
}

func saveName(for object: CameraObject) -> String? {
    if object.isFolder { return nil }
    let raw = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = (raw as NSString).lastPathComponent
    let ext = (base as NSString).pathExtension.lowercased()
    if photoExtensions.contains(ext) { return safePathComponent(base) }
    if movieExtensions.contains(ext) { return nil }
    if object.format == PTP.jpeg { return safePathComponent(base.isEmpty ? "DSC\(object.handle).JPG" : base) }
    return nil
}

func photoFileURL(name: String, cardFolder: String?, destination: URL) -> URL {
    var directory = destination
    if let cardFolder, !cardFolder.isEmpty {
        directory.appendPathComponent(safePathComponent(cardFolder), isDirectory: true)
    }
    return directory.appendingPathComponent(safePathComponent(name))
}

func hosts(onNetwork ip: String, netmask: String, limit: Int = 512) -> [String] {
    let address = ipv4Parts(ip)
    let mask = ipv4Parts(netmask)
    guard let address, let mask else { return [] }
    let prefix = mask.reduce(0) { count, byte -> Int in
        var value = byte
        var bits = 0
        for _ in 0..<8 {
            if value & 0x80 != 0 { bits += 1 } else { break }
            value <<= 1
        }
        return count + bits
    }
    guard prefix >= 16, prefix <= 30 else { return [] }
    let hostBits = 32 - prefix
    let count = (1 << hostBits) - 2
    guard count > 0, count <= limit else { return [] }
    let network = zip(address, mask).map { $0 & $1 }
    let base = (UInt32(network[0]) << 24) | (UInt32(network[1]) << 16) | (UInt32(network[2]) << 8) | UInt32(network[3])
    var results: [String] = []
    for host in 1...count {
        let ipValue = base &+ UInt32(host)
        let text = "\((ipValue >> 24) & 0xff).\((ipValue >> 16) & 0xff).\((ipValue >> 8) & 0xff).\(ipValue & 0xff)"
        if text != ip { results.append(text) }
    }
    return results
}

func safePathComponent(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let banned = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let cleaned = String(trimmed.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "photo" }
    return cleaned
}

private let photoExtensions: Set<String> = ["jpg", "jpeg", "arw", "hif", "heif", "png", "tif", "tiff"]
private let movieExtensions: Set<String> = ["mp4", "mov", "mts", "m2ts", "mpg"]

private func ipv4Parts(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4, text.split(separator: ".").count == 4 else { return nil }
    return parts
}

private func decodeUTF16(_ data: Data, offset: Int) -> String? {
    guard offset < data.count else { return nil }
    var units: [UInt16] = []
    var index = offset
    while index + 1 < data.count {
        let unit = readU16(data, index)
        index += 2
        if unit == 0 { break }
        units.append(unit)
    }
    return String(utf16CodeUnits: units, count: units.count)
}

private func readPTPString(_ data: Data, offset: inout Int) -> String? {
    guard offset < data.count else { return nil }
    let count = Int(data[offset])
    offset += 1
    if count == 0 { return "" }
    let byteCount = count * 2
    guard offset + byteCount <= data.count else { return nil }
    var units: [UInt16] = []
    for index in 0..<count {
        let unit = readU16(data, offset + index * 2)
        if unit != 0 { units.append(unit) }
    }
    offset += byteCount
    return String(utf16CodeUnits: units, count: units.count)
}
