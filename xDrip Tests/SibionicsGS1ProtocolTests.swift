import XCTest
@testable import xdrip

final class SibionicsGS1ProtocolTests: XCTestCase {
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

    func testRC4StandardVector() {
        XCTAssertEqual(SibionicsGS1Protocol.rc4(key: Array("Key".utf8), data: Data("Plaintext".utf8)), hex("bbf316e8d940af0ad3"))
    }
    func testEncryptedV120GlucoseBatch() {
        let p = SibionicsGS1Protocol.classify(hex("3cff6dbd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afaf3"), receivedAt: t0)
        guard case let .records(fw, recs, reindex) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(fw, .v120); XCTAssertEqual(reindex, 0); XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].index, 100); XCTAssertEqual(recs[0].timeStamp, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(recs[0].rawMmol, 7.2, accuracy: 1e-9); XCTAssertEqual(recs[0].temperatureC, 36.5, accuracy: 1e-9)
        XCTAssertEqual(recs[1].index, 101); XCTAssertEqual(recs[1].timeStamp, Date(timeIntervalSince1970: 1_795_000_060))
        XCTAssertEqual(recs[1].rawMmol, 7.5, accuracy: 1e-9)
        XCTAssertEqual(recs[0].glucoseLevelRaw, 7.2 * 18.0182 * 1000, accuracy: 1e-6)
    }
    func testEncryptedAck() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("23f66ed9f2"), receivedAt: t0), .ack(cmd: 0x01, status: 1, aux: 0))
    }
    func testAuthTriggerDecryptsToBypassAck() {   // 23F76FD9F4 -> 04 00 00 00 FC
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("23f76fd9f4"), receivedAt: t0), .ack(cmd: 0x00, status: 0, aux: 0))
    }
    func testPlainBypassPacketIsNotDecrypted() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("04000000fc"), receivedAt: t0), .ack(cmd: 0x00, status: 0, aux: 0))
    }
    func testLegacyPlainBigEndianRecord() {
        // index 50, temp 36.8, electric 1234, value 6.8, status 0, unreceived 2, addtime 0
        let p = SibionicsGS1Protocol.classify(hex("aa5509010032017004d2004400000002000038"), receivedAt: t0)
        guard case let .records(fw, recs, reindex) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(fw, .legacy); XCTAssertNil(reindex)
        XCTAssertEqual(recs.first?.index, 50); XCTAssertEqual(recs.first!.rawMmol, 6.8, accuracy: 1e-9)
        XCTAssertEqual(recs.first!.temperatureC, 36.8, accuracy: 1e-9)
        XCTAssertEqual(recs.first?.timeStamp, t0.addingTimeInterval(-120))  // offtime = addtime - unreceived*60 = -120
    }
    func testLegacyFutureOffsetIsClampedToReceivedAt() {
        // same record, unreceived 0, addtime 30 -> offtime > 0 -> time = receivedAt (process.cpp "infuture")
        let p = SibionicsGS1Protocol.classify(hex("aa5509010032017004d2004400000000001e1c"), receivedAt: t0)
        guard case let .records(_, recs, _) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(recs.first?.timeStamp, t0)
    }
    func testUnknownDataCommandIsPreserved() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("21b56e72c59c08"), receivedAt: t0), .unknownData(cmd: 0x42, decrypted: hex("064201abcdef50")))
    }
    func testBadChecksumIsInvalid() {
        var d = hex("3cff6dbd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afaf3"); d[d.count-1] ^= 0xFF
        guard case .invalid = SibionicsGS1Protocol.classify(d, receivedAt: t0) else { return XCTFail() }
    }
    func testRecordCountExceedingLengthIsInvalid() {
        // decrypted: len 0x1b, cmd 08, status 5 (5 records declared, 2 records of data), valid checksum
        guard case .invalid = SibionicsGS1Protocol.classify(hex("3cff6abd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afafe"), receivedAt: t0) else { return XCTFail() }
    }
    func testEmptyAndOneBytePacketsAreInvalid() {
        for d in [Data(), Data([0x01])] { guard case .invalid = SibionicsGS1Protocol.classify(d, receivedAt: t0) else { return XCTFail() } }
    }
    func testOutOfRangeRecordIsFlagged() {
        func r(_ v: Double) -> SibionicsGS1Record { SibionicsGS1Record(index: 1, timeStamp: t0, temperatureC: 36, rawMmol: v, dump: 0, extra: 0) }
        XCTAssertFalse(r(0.5).isInValidRange); XCTAssertFalse(r(31.0).isInValidRange)
        XCTAssertTrue(r(1.8).isInValidRange);  XCTAssertTrue(r(30.0).isInValidRange)
    }
    func testComparisonLineFormat() {
        let r = SibionicsGS1Record(index: 100, timeStamp: Date(timeIntervalSince1970: 1_795_000_000), temperatureC: 36.5, rawMmol: 7.2, dump: 0, extra: 0)
        XCTAssertEqual(SibionicsGS1Protocol.comparisonLine(r, calibratedMgDl: nil), "SIBCMP;1795000000000;100;7.2;36.5;-")
        XCTAssertEqual(SibionicsGS1Protocol.comparisonLine(r, calibratedMgDl: 131.4), "SIBCMP;1795000000000;100;7.2;36.5;131")
    }
}
