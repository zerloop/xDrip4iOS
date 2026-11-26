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
    // MARK: - new sensor detected by derived start (final review item 2b)

    func testHigherIndexWithDifferentDerivedStartStartsNewSession() {
        // old sensor: index 100, started 10 days ago, last seen 2 days ago. After a long offline gap a
        // new sensor already has index 500 (> 100), its derived start differs by days
        let lastSeen = now.addingTimeInterval(-2 * 86400)
        let oldStart = now.addingTimeInterval(-10 * 86400)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 100, sensorStartDate: oldStart, lastReadingDate: lastSeen, lastRecordDate: lastSeen)
        let ts = now.addingTimeInterval(-60)
        let result = SibionicsGS1Session.process([record(500, ts)], state: &state, now: now)
        XCTAssertEqual(result.newSensorStartDate, ts.addingTimeInterval(-500 * 60))
        XCTAssertEqual(state.sensorStartDate, ts.addingTimeInterval(-500 * 60))
        XCTAssertEqual(state.rawSensorStartDate, ts.addingTimeInterval(-500 * 60))
        XCTAssertEqual(result.newRecords.map { $0.index }, [500])
        XCTAssertEqual(state.lastReceivedIndex, 500)
    }

    func testLongGapOnSameSensorKeepsSession() {
        let start = now.addingTimeInterval(-5 * 86400)
        let lastSeen = start.addingTimeInterval(100 * 60)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 100, sensorStartDate: start, lastReadingDate: lastSeen, lastRecordDate: lastSeen, rawSensorStartDate: start)
        // same sensor, index 5000 matches the start within seconds
        let ts = start.addingTimeInterval(5000 * 60 + 20)
        let result = SibionicsGS1Session.process([record(5000, ts)], state: &state, now: now)
        XCTAssertNil(result.newSensorStartDate)
        XCTAssertEqual(state.sensorStartDate, start)
        XCTAssertEqual(result.newRecords.map { $0.index }, [5000])
    }

    func testSensorClockAheadDoesNotStartNewSessionOnEveryPacket() {
        // sensor clock 3 hours ahead of the phone: every live record is clamped to now
        var state = freshState()
        let ahead: TimeInterval = 3 * 3600
        let first = SibionicsGS1Session.process([record(100, now.addingTimeInterval(ahead))], state: &state, now: now)
        XCTAssertNotNil(first.newSensorStartDate)
        for minute in 1...5 {
            let t = now.addingTimeInterval(Double(minute) * 60)
            let result = SibionicsGS1Session.process([record(100 + minute, t.addingTimeInterval(ahead))], state: &state, now: t)
            XCTAssertNil(result.newSensorStartDate, "minute \(minute)")
            XCTAssertEqual(result.newRecords.count, 1)
        }
    }

    func testStateWithoutRawStartIsMigratedWithoutNewSession() {
        // state persisted before rawSensorStartDate existed
        let start = now.addingTimeInterval(-6000)
        var state = SibionicsGS1SessionState(lastReceivedIndex: 99, sensorStartDate: start, lastReadingDate: now.addingTimeInterval(-120), lastRecordDate: now.addingTimeInterval(-120))
        let result = SibionicsGS1Session.process([record(100, now.addingTimeInterval(-60))], state: &state, now: now)
        XCTAssertNil(result.newSensorStartDate)
        XCTAssertEqual(result.newRecords.count, 1)
        XCTAssertNotNil(state.rawSensorStartDate)
    }
}
