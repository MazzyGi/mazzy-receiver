import XCTest
@testable import MazzyCore

final class VideoReassemblerTests: XCTestCase {
    /// Build a video fragment packet for an AU split into pieces.
    private func fragment(_ counter: UInt32, _ fragID: UInt8, _ fragCount: UInt8, payload: [UInt8]) -> Data {
        var d = Data()
        d.append(RelayProtocol.videoMagic)
        d.append(UInt8(counter >> 24 & 0xFF)); d.append(UInt8(counter >> 16 & 0xFF))
        d.append(UInt8(counter >> 8 & 0xFF)); d.append(UInt8(counter & 0xFF))
        d.append(fragID); d.append(fragCount)
        d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xFF))
        d.append(contentsOf: payload)
        return d
    }

    func testSingleFragmentAU() {
        let r = VideoReassembler()
        let payload: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67]
        let au = r.feed(packet: fragment(1, 0, 1, payload: payload))
        XCTAssertNotNil(au)
        XCTAssertEqual(au?.data, Data(payload))
        XCTAssertEqual(r.stats.accessUnits, 1)
        XCTAssertEqual(r.stats.lossRate, 0)
    }

    func testMultiFragmentInOrder() {
        let r = VideoReassembler()
        XCTAssertNil(r.feed(packet: fragment(7, 0, 3, payload: [1, 2, 3])))
        XCTAssertNil(r.feed(packet: fragment(7, 1, 3, payload: [4, 5])))
        let au = r.feed(packet: fragment(7, 2, 3, payload: [6]))
        XCTAssertNotNil(au)
        XCTAssertEqual(au?.data, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(au?.counter, 7)
    }

    func testMultiFragmentOutOfOrder() {
        let r = VideoReassembler()
        XCTAssertNil(r.feed(packet: fragment(9, 2, 3, payload: [6])))
        XCTAssertNil(r.feed(packet: fragment(9, 0, 3, payload: [1, 2])))
        let au = r.feed(packet: fragment(9, 1, 3, payload: [4, 5]))
        XCTAssertNotNil(au)
        XCTAssertEqual(au?.data, Data([1, 2, 4, 5, 6]))
    }

    func testDuplicateFragmentIgnored() {
        let r = VideoReassembler()
        XCTAssertNil(r.feed(packet: fragment(3, 0, 2, payload: [1])))
        XCTAssertNil(r.feed(packet: fragment(3, 0, 2, payload: [1]))) // dup
        XCTAssertEqual(r.stats.fragmentsDropped, 1)
        let au = r.feed(packet: fragment(3, 1, 2, payload: [2]))
        XCTAssertEqual(au?.data, Data([1, 2]))
    }

    func testMissingFragmentDeliveredIncomplete() {
        let r = VideoReassembler(deliverIncomplete: true)
        XCTAssertNil(r.feed(packet: fragment(1, 0, 3, payload: [1, 2])))
        // skip fragment 1 entirely; a much later AU forces eviction of AU 1
        _ = r.feed(packet: fragment(100, 0, 1, payload: [9]))
        let evicted = r.drainEviction()
        XCTAssertNotNil(evicted)
        XCTAssertEqual(evicted?.missingFragments, 2)
        // stitched payload keeps received fragments in order
        XCTAssertEqual(evicted?.data, Data([1, 2]))
        XCTAssertEqual(r.stats.accessUnitsCorrupt, 1)
        XCTAssertGreaterThan(r.stats.lossRate, 0)
    }

    func testBadMagicDropped() {
        let r = VideoReassembler()
        var bad = Data([0xC3, 0, 0, 0, 1, 0, 1, 0, 4, 1, 2, 3, 4])
        bad[0] = 0x99
        XCTAssertNil(r.feed(packet: bad))
        XCTAssertEqual(r.stats.fragmentsDropped, 1)
    }

    func testShortPacketDropped() {
        let r = VideoReassembler()
        XCTAssertNil(r.feed(packet: Data([0xC1, 1, 2])))
        XCTAssertEqual(r.stats.fragmentsDropped, 1)
    }

    func testHeaderRejectsBadFragID() {
        // fragID >= fragCount must be rejected
        let pkt = Data([RelayProtocol.videoMagic, 0, 0, 0, 1, 5, 3, 0, 1, 0xFF])
        XCTAssertNil(FragmentHeader(packet: pkt))
    }
}

final class H264ParserTests: XCTestCase {
    private let sc3: [UInt8] = [0x00, 0x00, 0x01]
    private let sc4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    private func nal(_ type: UInt8, body: [UInt8] = [0x11, 0x22]) -> [UInt8] {
        sc4 + [type] + body
    }

    func testSplitCount() {
        let buf = Data(nal(7) + nal(8) + nal(5, body: Array(repeating: 0x33, count: 16)))
        let nals = H264Parser.splitNALs(buf)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(nals[0].type, 7)
        XCTAssertEqual(nals[1].type, 8)
        XCTAssertEqual(nals[2].type, 5)
        // exact header positions (all NALs here use 4-byte start codes):
        // NAL1 = 4+[67]+[11,22] (7B) -> hdr=4; NAL2 starts at 7 -> hdr=11;
        // NAL3 starts at 14 -> hdr=18
        XCTAssertEqual(nals[0].headerIndex, 4)
        XCTAssertEqual(nals[1].headerIndex, 11)
        XCTAssertEqual(nals[2].headerIndex, 18)
    }

    func testThreeByteStartCodes() {
        let buf = Data(sc3 + [0x41] + [1, 2])
        let nals = H264Parser.splitNALs(buf)
        XCTAssertEqual(nals.count, 1)
        XCTAssertEqual(nals[0].type, 1)
    }

    func testIsIDRAndSPS() {
        let idr = Data(nal(7) + nal(8) + nal(5))
        let pframe = Data(nal(1))
        XCTAssertTrue(H264Parser.isIDR(idr))
        XCTAssertTrue(H264Parser.containsSPS(idr))
        XCTAssertFalse(H264Parser.isIDR(pframe))
        XCTAssertFalse(H264Parser.containsSPS(pframe))
    }

    func testExtractSPSPPS() {
        let buf = Data(nal(7) + nal(8) + nal(5, body: [0xAA]))
        let got = H264Parser.extractSPSPPS(buf)
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.sps, Data(nal(7)))
        XCTAssertEqual(got?.pps, Data(nal(8)))
        XCTAssertNil(H264Parser.extractSPSPPS(Data(nal(7))))
    }

    func testAnnexBToAVCC() {
        // helper emits the raw type byte as the NAL header (nal_ref_idc=0)
        let raw = nal(1, body: [0x0A]) + nal(5, body: [0x0B])
        let buf = Data(raw)
        let nals = H264Parser.splitNALs(buf)
        let avcc = H264Parser.annexBToAVCC(buf)
        let u8 = [UInt8](avcc)
        XCTAssertEqual(nals.map(\.type), [1, 5])
        // two NALs -> 4-byte length prefix + 2-byte body each
        XCTAssertEqual(u8.count, (4 + 2) * 2)
        // first length prefix is 2 (big endian)
        XCTAssertEqual(u8[0], 0); XCTAssertEqual(u8[1], 0)
        XCTAssertEqual(u8[2], 0); XCTAssertEqual(u8[3], 2)
        // first NAL body = header byte 0x01 + 0x0A
        XCTAssertEqual(u8[4], 0x01)
        XCTAssertEqual(u8[5], 0x0A)
        // second NAL: length 2, header 0x05
        XCTAssertEqual(u8[7], 2)
        XCTAssertEqual(u8[8], 0x05)
        XCTAssertEqual(u8[9], 0x0B)
    }
}

final class ControlProtocolTests: XCTestCase {
    func testCtrlMessageJSON() {
        let s = ControlProtocol.ctrlMessage(buttons: 5, lx: -3, ly: 0, rx: 0, ry: 127, l2: 0, r2: 255)
        let obj = try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "ctrl")
        XCTAssertEqual(obj["buttons"] as? Int, 5)
        XCTAssertEqual(obj["ly"] as? Int, 0)
        XCTAssertEqual(obj["r2"] as? Int, 255)
    }

    func testLineBufferSplitsLines() {
        let lb = ControlProtocol.LineBuffer()
        let a = lb.feed(Data("{\"type\":\"a\"}\n{\"type\"".utf8))
        XCTAssertEqual(a, ["{\"type\":\"a\"}"])
        let b = lb.feed(Data(":\"b\"}\n".utf8))
        XCTAssertEqual(b, ["{\"type\":\"b\"}"])
    }

    func testLineBufferIgnoresEmptyLines() {
        let lb = ControlProtocol.LineBuffer()
        let lines = lb.feed(Data("\n\n{\"type\":\"x\"}\n\n".utf8))
        XCTAssertEqual(lines, ["{\"type\":\"x\"}"])
    }

    func testProbeMessage() {
        XCTAssertEqual(ControlProtocol.probeMessage(videoPort: 50012, audioPort: 50012), "PROBE1 50012 50012")
    }
}

final class BitrateMeterTests: XCTestCase {
    func testRateOverWindow() {
        let m = BitrateMeter(windowSeconds: 10)
        m.add(bytes: 1250, at: 0)   // 1s worth of pacing
        m.add(bytes: 1250, at: 1)
        XCTAssertEqual(m.bitsPerSecond, 20000, accuracy: 1000)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(BitrateMeter().bitsPerSecond, 0)
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        let c = ReceiverConfig()
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("cfg-\(UUID().uuidString).json")
        c.save(to: path)
        let loaded = ReceiverConfig.load(path: path)
        XCTAssertEqual(loaded.host, c.host)
        XCTAssertEqual(loaded.tcpPort, c.tcpPort)
        XCTAssertEqual(loaded.deliverIncompleteAUs, c.deliverIncompleteAUs)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testCorruptFileFallsBackToDefaults() {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("bad-\(UUID().uuidString).json")
        try? "not json".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        let loaded = ReceiverConfig.load(path: path)
        XCTAssertEqual(loaded.host, ReceiverConfig().host)
    }
}
