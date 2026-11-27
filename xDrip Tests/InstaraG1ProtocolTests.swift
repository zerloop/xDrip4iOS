// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import XCTest
@testable import xdrip

final class InstaraG1ProtocolTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_100_000)

    func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testCrc8MaximCheckValue() { XCTAssertEqual(InstaraG1Protocol.crc8(Data("123456789".utf8)), 0xA1) }
    func testRealtime0x10() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa10040120004863")), .realtime(seq: 288, mmol: 7.2)) }
    func testRealtime0x01() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa01040121004b46")), .realtime(seq: 289, mmol: 7.5)) }
    func testHistoryFrame() {
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa3008011e00050046004734")), .history(startSeq: 286, durationField: 5, mmolValues: [7.0, 7.1]))
    }
    func testBatteryHandshakeInterval() {
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa20015541")), .battery(percent: 85))
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aaf0021234d7")), .handshake(hardware: 0x12, software: 0x34))
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa0a02000520")), .interval(minutes: 5))
    }
    func testUnlistedKeepsPayload() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa600101ca")), .unlisted(cmd: 0x60, payload: hex("01"))) }
    func testBadCrcHeaderAndLengthAreInvalid() {
        for f in ["55aa10040120004800", "56aa10040120004863", "55aa100501200048", "55aa"] {
            guard case .invalid = InstaraG1Protocol.parse(frame: hex(f)) else { return XCTFail(f) }
        }
    }
    func testHistoryWithOddValueBytesIsInvalid() {
        guard case .invalid = InstaraG1Protocol.parse(frame: hex("55aa3007011e000500460074")) else { return XCTFail() }
    }
    func testAssemblerTwoFramesInOneNotification() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("55aa10040120004863" + "55aa20015541"), now: t0), [.realtime(seq: 288, mmol: 7.2), .battery(percent: 85)])
    }
    func testAssemblerFrameSplitAcrossNotifications() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("55aa100401"), now: t0), [])
        XCTAssertEqual(a.feed(hex("20004863"), now: t0.addingTimeInterval(0.5)), [.realtime(seq: 288, mmol: 7.2)])
    }
    func testAssemblerDropsStaleFragment() {
        var a = InstaraG1FrameAssembler()
        _ = a.feed(hex("55aa100401"), now: t0)
        XCTAssertEqual(a.feed(hex("55aa20015541"), now: t0.addingTimeInterval(3)), [.battery(percent: 85)])
    }
    func testAssemblerSkipsGarbageBeforeHeader() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("0102" + "55aa20015541"), now: t0), [.battery(percent: 85)])
    }
}
