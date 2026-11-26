import XCTest
@testable import xdrip

final class SibionicsGS1SessionTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_795_100_000)

    private func record(_ index: Int, _ ts: Date, mmol: Double = 6.0) -> SibionicsGS1Record {
        SibionicsGS1Record(index: index, timeStamp: ts, temperatureC: 32.0, rawMmol: mmol, dump: 0, extra: 0)
    }

    private func freshState() -> SibionicsGS1SessionState {
        SibionicsGS1SessionState(lastReceivedIndex: -1, sensorStartDate: nil, lastReadingDate: nil, lastRecordDate: nil)
    }

    func testFirstBatchSetsSensorStart() {
        var state = freshState()
        let t = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(100, t)], state: &state, now: now)
        XCTAssertEqual(result.newRecords.count, 1)
        XCTAssertEqual(state.sensorStartDate, t.addingTimeInterval(-6000))
        XCTAssertEqual(result.newSensorStartDate, t.addingTimeInterval(-6000))
        XCTAssertEqual(state.lastReceivedIndex, 100)
        XCTAssertEqual(state.lastReadingDate, t)
    }

    func testDuplicateBatchIsIgnored() {
        var state = freshState()
        let batch = [record(10, now.addingTimeInterval(-120)), record(11, now.addingTimeInterval(-60))]
        _ = SibionicsGS1Session.process(batch, state: &state, now: now)
        let second = SibionicsGS1Session.process(batch, state: &state, now: now)
        XCTAssertTrue(second.newRecords.isEmpty)
        XCTAssertNil(second.newSensorStartDate)
        XCTAssertEqual(second.skipped.count, 2)
        XCTAssertEqual(second.skipped.first?.reason, "duplicate")
    }

    func testIndexResetWithNewerTimeStartsNewSession() {
        let old = now.addingTimeInterval(-3600)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 500, sensorStartDate: old.addingTimeInterval(-30000), lastReadingDate: old, lastRecordDate: old)
        let ts = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(3, ts)], state: &state, now: now)
        XCTAssertEqual(result.newSensorStartDate, ts.addingTimeInterval(-180))
        XCTAssertEqual(state.sensorStartDate, ts.addingTimeInterval(-180))
        XCTAssertEqual(result.newRecords.count, 1)
        XCTAssertEqual(state.lastReceivedIndex, 3)
    }

    func testIndexBackwardsWithOlderTimeIsSkipped() {
        let last = now.addingTimeInterval(-60)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 500, sensorStartDate: last.addingTimeInterval(-30000), lastReadingDate: last, lastRecordDate: last)
        let result = SibionicsGS1Session.process([record(3, last.addingTimeInterval(-3600))], state: &state, now: now)
        XCTAssertTrue(result.newRecords.isEmpty)
        XCTAssertNil(result.newSensorStartDate)
        XCTAssertEqual(result.skipped.first?.reason, "duplicate")
        XCTAssertEqual(state.lastReceivedIndex, 500)
    }

    func testFutureTimestampIsClampedToNow() {
        var state = freshState()
        let result = SibionicsGS1Session.process([record(5, now.addingTimeInterval(600))], state: &state, now: now)
        XCTAssertEqual(result.newRecords.count, 1)
        XCTAssertEqual(result.newRecords.first?.timeStamp, now)
        XCTAssertEqual(state.lastReadingDate, now)
    }

    func testBackfillLimitSixHours() {
        var state = freshState()
        let old = record(1, now.addingTimeInterval(-7 * 3600))
        let ok = record(2, now.addingTimeInterval(-5 * 3600))
        let result = SibionicsGS1Session.process([old, ok], state: &state, now: now)
        XCTAssertEqual(result.newRecords.map { $0.index }, [2])
        XCTAssertEqual(result.skipped.map { $0.reason }, ["backfill-limit"])
        XCTAssertEqual(state.lastReceivedIndex, 2)
    }

    func testOutOfRangeAdvancesIndexButIsNotEmitted() {
        var state = freshState()
        let t = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(7, t, mmol: 0.5)], state: &state, now: now)
        XCTAssertTrue(result.newRecords.isEmpty)
        XCTAssertEqual(result.skipped.first?.reason, "out-of-range")
        XCTAssertEqual(state.lastReceivedIndex, 7)
        XCTAssertNil(state.lastReadingDate)
        XCTAssertEqual(state.lastRecordDate, t)
    }

    func testReplacedSensorAfterOnlyOutOfRangeRecordsStartsNewSession() {
        var state = freshState()
        let t0 = now.addingTimeInterval(-7200)
        _ = SibionicsGS1Session.process([record(499, t0, mmol: 0.5), record(500, t0.addingTimeInterval(60), mmol: 0.5)], state: &state, now: now)
        XCTAssertEqual(state.lastReceivedIndex, 500)
        XCTAssertNil(state.lastReadingDate)
        let ts = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(3, ts)], state: &state, now: now)
        XCTAssertEqual(result.newSensorStartDate, ts.addingTimeInterval(-180))
        XCTAssertEqual(result.newRecords.count, 1)
        XCTAssertEqual(state.sensorStartDate, ts.addingTimeInterval(-180))
    }

    func testResentFutureRecordIsDuplicateNotNewSession() {
        var state = freshState()
        let now1 = now
        let future = record(100, now1.addingTimeInterval(600))
        let first = SibionicsGS1Session.process([future], state: &state, now: now1)
        XCTAssertEqual(first.newRecords.count, 1)
        let second = SibionicsGS1Session.process([future], state: &state, now: now1.addingTimeInterval(120))
        XCTAssertNil(second.newSensorStartDate)
        XCTAssertTrue(second.newRecords.isEmpty)
        XCTAssertEqual(second.skipped.first?.reason, "duplicate")
    }

    func testEqualIndexWithNewerTimeIsDuplicate() {
        let last = now.addingTimeInterval(-600)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 50, sensorStartDate: last.addingTimeInterval(-3000), lastReadingDate: last, lastRecordDate: last)
        let result = SibionicsGS1Session.process([record(50, now.addingTimeInterval(-60))], state: &state, now: now)
        XCTAssertNil(result.newSensorStartDate)
        XCTAssertTrue(result.newRecords.isEmpty)
        XCTAssertEqual(result.skipped.first?.reason, "duplicate")
    }

    func testMidBatchNewSessionUsesResetState() {
        let old = now.addingTimeInterval(-3600)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 500, sensorStartDate: old.addingTimeInterval(-30000), lastReadingDate: old, lastRecordDate: old)
        let t3 = now.addingTimeInterval(-120)
        let t4 = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(4, t4), record(3, t3)], state: &state, now: now)
        XCTAssertEqual(result.newRecords.map { $0.index }, [3, 4])
        XCTAssertEqual(result.newSensorStartDate, t3.addingTimeInterval(-180))
        XCTAssertEqual(state.lastReceivedIndex, 4)
        XCTAssertEqual(state.lastReadingDate, t4)
    }

    func testUnorderedInputIsProcessedAscending() {
        var state = freshState()
        let r1 = record(1, now.addingTimeInterval(-120))
        let r2 = record(2, now.addingTimeInterval(-60))
        let result = SibionicsGS1Session.process([r2, r1], state: &state, now: now)
        XCTAssertEqual(result.newRecords.map { $0.index }, [1, 2])
    }
}
