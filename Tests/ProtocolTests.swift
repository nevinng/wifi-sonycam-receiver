// Copyright (c) 2026 Nevin Ng
// SPDX-License-Identifier: MIT

import XCTest
@testable import SonyReceiveCore

final class ProtocolTests: XCTestCase {
    func testRegistrationPayloadCarriesTheNameAndIdentity() {
        let guid: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0x5c, 0xe9, 0x1e, 0x8d, 0x28, 0x99]
        let payload = registrationPayload(name: "nng-mbp", guid: guid)
        XCTAssertEqual(payload.count, 8192)
        XCTAssertEqual(Array(payload[0..<5]), [0x25, 0x01, 0x00, 0x00, 0x08])
        XCTAssertEqual(payload[16], 0)
        let name = [UInt8]("nng-mbp".utf8)
        for (index, byte) in name.enumerated() {
            XCTAssertEqual(payload[17 + index * 2], byte)
            XCTAssertEqual(payload[18 + index * 2], 0)
        }
        XCTAssertEqual(payload[17 + name.count * 2], 0)
        XCTAssertEqual(Array(payload[177..<181]), [0x10, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(payload[181..<197]), guid)
        XCTAssertEqual(payload[197], 0)
        XCTAssertEqual(payload[8191], 0)
    }

    func testPlayMemoriesIdentityUsesTheMacAddress() {
        let guid = playMemoriesGUID(mac: [0xbc, 0x24, 0x11, 0x60, 0xf7, 0x64])
        XCTAssertEqual(
            guid,
            [0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xbc, 0x24, 0x11, 0x60, 0xf7, 0x64]
        )
        XCTAssertNil(playMemoriesGUID(mac: [0, 0, 0, 0, 0, 0]))
    }

    func testGUIDTextRoundTrip() {
        let text = "00:00:00:00:00:00:00:00:ff:ff:aa:bb:cc:dd:ee:ff"
        let bytes = parseGUID(text)
        XCTAssertEqual(bytes?.count, 16)
        XCTAssertEqual(bytes.map(formatGUID), text)
    }

    func testSonyAnnouncementRecognizesTheTransferService() {
        let packet = """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        NT: urn:microsoft-com:service:MtpNullService:1\r
        LOCATION: http://192.168.1.50:1900/DeviceDescription.xml\r
        SERVER: FedoraCore/2 UPnP/1.0 MINT-X/1.8.1\r
        """
        XCTAssertTrue(isSonyTransferAnnouncement(packet))
        XCTAssertEqual(locationIPv4(in: packet), "192.168.1.50")
        XCTAssertEqual(
            cameraAddress(sender: "192.168.1.50", text: packet, local: ["192.168.1.24"]),
            "192.168.1.50"
        )
        XCTAssertNil(cameraAddress(sender: "192.168.1.24", text: "NOTIFY\r\nLOCATION: http://192.168.1.24:1900/a.xml\r\n", local: ["192.168.1.24"]))
        let router = "HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nLOCATION: http://192.168.1.1:1900/gatedesc.xml\r\n"
        XCTAssertFalse(isSonyTransferAnnouncement(router))
        XCTAssertFalse(isPrivateIPv4("8.8.8.8"))
        XCTAssertTrue(isPrivateIPv4("172.16.4.2"))
        XCTAssertFalse(isPrivateIPv4("172.32.0.1"))
    }

    func testSonyConnectPacketIsTheSendingHandshake() {
        let packets = sonyConnectPackets(transaction: 0x23).map { [UInt8]($0) }
        XCTAssertEqual(packets, [
            [0x16, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x92, 0x23, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00],
            [0x14, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x1e, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01],
            [0x0c, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00],
        ])
        let open = commandPacket(opcode: PTP.openSession, transaction: 0, parameters: [1], sendingData: false)
        XCTAssertEqual(readU32(open, 8), 1)
        XCTAssertEqual([UInt8](open), [0x16, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
    }

    func testSonyPowerOffPacketMatchesTheCapturedShutdown() {
        let packets = sonyPowerOffPackets(transaction: 0x02c7).map { [UInt8]($0) }
        XCTAssertEqual(packets, [
            [0x16, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x92, 0xc7, 0x02, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00],
            [0x14, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0xc7, 0x02, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x1c, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0xc7, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x0c, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0xc7, 0x02, 0x00, 0x00],
        ])
    }

    func testInitPacketCarriesNameAndVersion() {
        let guid = [UInt8](repeating: 0x11, count: 16)
        let packet = initCommandPacket(guid: guid, hostName: "Mac")
        XCTAssertEqual(packet.count, 36)
        XCTAssertEqual(readU32(packet, 0), 36)
        XCTAssertEqual(readU32(packet, 4), PTP.initCommand)
        XCTAssertEqual([UInt8](packet[8..<24]), guid)
        // "Mac" plus a terminator, then protocol version 1.0 as minor, major.
        XCTAssertEqual([UInt8](packet.suffix(4)), [0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual(readU16(packet, 24), UInt16(UnicodeScalar("M").value))
    }

    func testObjectInfoReadsTheFileName() {
        var header = Data(count: 52)
        header[4] = 0x01
        header[5] = 0x38 // JPEG 0x3801
        header[8] = 0x2a
        header[9] = 0x04 // size 1066
        var payload = header
        payload.append(ptpString("DSC00001.ARW"))
        let object = parseObjectInfo(payload, handle: 7)
        XCTAssertEqual(object?.name, "DSC00001.ARW")
        XCTAssertEqual(object?.byteSize, 1066)
        XCTAssertEqual(object?.isFolder, false)
        XCTAssertEqual(object.flatMap(saveName(for:)), "DSC00001.ARW")
    }

    func testFoldersAndMoviesAreNotPhotos() {
        var folder = Data(count: 52)
        folder[4] = 0x01
        folder[5] = 0x30 // association 0x3001
        folder.append(ptpString("100MSDCF"))
        XCTAssertEqual(parseObjectInfo(folder, handle: 1)?.isFolder, true)
        XCTAssertNil(parseObjectInfo(folder, handle: 1).flatMap(saveName(for:)))

        var movie = Data(count: 52)
        movie.append(ptpString("C0001.MP4"))
        XCTAssertNil(parseObjectInfo(movie, handle: 2).flatMap(saveName(for:)))
    }

    func testHomeNetworkListingSkipsThisMac() {
        let listed = hosts(onNetwork: "192.168.1.20", netmask: "255.255.255.0")
        XCTAssertEqual(listed.count, 253)
        XCTAssertFalse(listed.contains("192.168.1.20"))
        XCTAssertTrue(listed.contains("192.168.1.1"))
        XCTAssertFalse(listed.contains("192.168.1.0"))
        XCTAssertFalse(listed.contains("192.168.1.255"))
    }

    func testStorageList() {
        var writer = ByteWriter()
        writer.u32(2)
        writer.u32(0x0001_0001)
        writer.u32(0x0002_0001)
        XCTAssertEqual(parseIDArray(writer.data), [0x0001_0001, 0x0002_0001])
    }

    func testPhotoLandsInsideTheChosenFolder() throws {
        let root = URL(fileURLWithPath: "/tmp/a7-photos")
        let url = photoFileURL(name: "DSC00001.ARW", cardFolder: nil, destination: root)
        XCTAssertEqual(url.path, "/tmp/a7-photos/DSC00001.ARW")
        let slotted = photoFileURL(name: "../DSC00002.JPG", cardFolder: "Card 1", destination: root)
        XCTAssertEqual(slotted.path, "/tmp/a7-photos/Card 1/.._DSC00002.JPG")
    }
}

private func ptpString(_ text: String) -> Data {
    var writer = ByteWriter()
    let units = Array(text.utf16) + [0]
    writer.u8(UInt8(units.count))
    for unit in units { writer.u16(unit) }
    return writer.data
}
