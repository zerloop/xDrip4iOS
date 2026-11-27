// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import XCTest
@testable import xdrip

final class InstaraG1SessionTests: XCTestCase {

    let t0 = Date(timeIntervalSince1970: 1_795_100_000)

    private func realtime(_ seq: Int, _ at: Date, mmol: Double = 7.2, _ state: inout InstaraG1SessionState) -> InstaraG1SessionResult {
        InstaraG1Session.process(.realtime(seq: seq, mmol: mmol), state: &state, receivedAt: at)
    }

    private func logContains(_ result: InstaraG1SessionResult, _ tag: String) -> Bool {
        result.log.contains { $0.hasPrefix(tag) }
    }

    func testFirstRealtimeSetsStartWithDefaultInterval() {
        var state = InstaraG1SessionState()
        let result = realtime(288, t0, &state)
        XCTAssertEqual(state.sensorStart, t0.addingTimeInterval(-288 * 300))
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.seq, 288)
        XCTAssertEqual(result.readings.first?.timeStamp, t0)
        XCTAssertEqual(state.lastSeq, 288)
        XCTAssertEqual(state.refSeq, 288)
        XCTAssertEqual(state.refDate, t0)
    }

    func testMeasuredIntervalWinsOverSensorField() {
        var state = InstaraG1SessionState()
        _ = realtime(10, t0, &state)
        _ = realtime(11, t0.addingTimeInterval(60), &state)
        _ = realtime(12, t0.addingTimeInterval(120), &state)
        let result = InstaraG1Session.process(.interval(minutes: 5), state: &state, receivedAt: t0.addingTimeInterval(130))
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 1)
        XCTAssertEqual(state.intervalFromSensor, 5)
        XCTAssertTrue(logContains(result, "INTERVAL-MISMATCH"), "\(result.log)")
    }

    func testMeasuredIntervalRederivesStartWithoutFalseSuspect() {
        var state = InstaraG1SessionState()
        for i in 0..<6 {
            let result = realtime(10 + i, t0.addingTimeInterval(Double(i) * 60), &state)
            XCTAssertEqual(result.readings.count, 1, "seq \(10 + i)")
            XCTAssertFalse(logContains(result, "SESSION-SUSPECT"), "\(result.log)")
        }
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 1)
        XCTAssertEqual(state.sensorStart, t0.addingTimeInterval(300 - 15 * 60))
        XCTAssertNil(state.suspect)
    }

    func testSensorIntervalUsedWhenNotMeasured() {
        var state = InstaraG1SessionState()
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 5)
        let result = InstaraG1Session.process(.interval(minutes: 3), state: &state, receivedAt: t0)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 3)
    }

    func testSensorIntervalOutsideRangeIsIgnored() {
        var state = InstaraG1SessionState()
        _ = InstaraG1Session.process(.interval(minutes: 0), state: &state, receivedAt: t0)
        _ = InstaraG1Session.process(.interval(minutes: 16), state: &state, receivedAt: t0)
        XCTAssertNil(state.intervalFromSensor)
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 5)
    }

    func testMeasuredSampleOutsideRangeIsDiscarded() {
        var state = InstaraG1SessionState()
        _ = realtime(10, t0, &state)
        // 20 s per sequence rounds to 0 minutes
        _ = realtime(11, t0.addingTimeInterval(20), &state)
        _ = realtime(12, t0.addingTimeInterval(40), &state)
        // 20 minutes per sequence is above 15
        _ = realtime(13, t0.addingTimeInterval(40 + 1200), &state)
        XCTAssertTrue(state.intervalSamples.isEmpty, "\(state.intervalSamples)")
        XCTAssertEqual(InstaraG1Session.intervalMinutes(state), 5)
    }

    func testHistoryTimestampsFromReference() {
        var state = InstaraG1SessionState()
        _ = realtime(288, t0, &state)
        let result = InstaraG1Session.process(.history(startSeq: 286, durationField: 5, mmolValues: [7.0, 7.1]), state: &state, receivedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(result.readings.count, 2)
        XCTAssertEqual(result.readings[0].seq, 286)
        XCTAssertEqual(result.readings[0].timeStamp, t0.addingTimeInterval(-600))
        XCTAssertEqual(result.readings[0].mgDl, 7.0 * ConstantsBloodGlucose.mmollToMgdl, accuracy: 0.0001)
        XCTAssertEqual(result.readings[0].rawMmol, 7.0)
        XCTAssertFalse(result.readings[0].clamped)
        XCTAssertEqual(result.readings[1].seq, 287)
        XCTAssertEqual(result.readings[1].timeStamp, t0.addingTimeInterval(-300))
        XCTAssertEqual(result.readings[1].mgDl, 7.1 * ConstantsBloodGlucose.mmollToMgdl, accuracy: 0.0001)
    }

    func testHistoryInTheFutureIsDropped() {
        var state = InstaraG1SessionState()
        _ = realtime(288, t0, &state)
        // seq 290 would be t0 + 600, after receivedAt
        let result = InstaraG1Session.process(.history(startSeq: 288, durationField: 5, mmolValues: [7.2, 7.3, 7.4]), state: &state, receivedAt: t0.addingTimeInterval(10))
        XCTAssertEqual(result.readings.map { $0.seq }, [])
        XCTAssertNil(state.seenSeqs[290])
    }

    func testHistoryWithoutReferenceIsDropped() {
        var state = InstaraG1SessionState()
        let result = InstaraG1Session.process(.history(startSeq: 286, durationField: 5, mmolValues: [7.0, 7.1]), state: &state, receivedAt: t0)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertTrue(logContains(result, "HISTORY-NO-REF"), "\(result.log)")
        XCTAssertTrue(state.seenSeqs.isEmpty)
    }

    func testDuplicateSeqIsNotEmittedTwice() {
        var state = InstaraG1SessionState()
        _ = realtime(288, t0, &state)
        let history = InstaraG1Packet.history(startSeq: 286, durationField: 5, mmolValues: [7.0, 7.1])
        let first = InstaraG1Session.process(history, state: &state, receivedAt: t0.addingTimeInterval(5))
        let second = InstaraG1Session.process(history, state: &state, receivedAt: t0.addingTimeInterval(10))
        XCTAssertEqual(first.readings.count, 2)
        XCTAssertTrue(second.readings.isEmpty)
        XCTAssertFalse(logContains(second, "CLOCK-MISMATCH"))
        // the realtime itself is not emitted again either
        XCTAssertTrue(realtime(288, t0.addingTimeInterval(20), &state).readings.isEmpty)
    }

    func testClockMismatchIsLoggedNotApplied() {
        var state = InstaraG1SessionState()
        _ = realtime(288, t0, &state)
        let tA = t0.addingTimeInterval(-300)
        let first = InstaraG1Session.process(.history(startSeq: 287, durationField: 5, mmolValues: [7.0]), state: &state, receivedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(first.readings.first?.timeStamp, tA)
        // next realtime arrives 10 minutes late, which moves the reference
        _ = realtime(289, t0.addingTimeInterval(300 + 600), &state)
        let second = InstaraG1Session.process(.history(startSeq: 287, durationField: 5, mmolValues: [7.0]), state: &state, receivedAt: t0.addingTimeInterval(905))
        XCTAssertTrue(second.readings.isEmpty)
        XCTAssertTrue(logContains(second, "CLOCK-MISMATCH"), "\(second.log)")
        XCTAssertEqual(state.seenSeqs[287], tA)
    }

    func testLowBelowRangeIsClampedTo36() {
        var state = InstaraG1SessionState()
        let result = realtime(10, t0, mmol: 1.9, &state)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertEqual(result.readings.first?.mgDl, 36)
        XCTAssertEqual(result.readings.first?.rawMmol, 1.9)
        XCTAssertEqual(result.readings.first?.clamped, true)
        XCTAssertTrue(logContains(result, "OUT-OF-RANGE"), "\(result.log)")
        XCTAssertNotNil(state.seenSeqs[10])
    }

    func testHighAboveRangeIsClampedTo468() {
        var state = InstaraG1SessionState()
        let result = realtime(10, t0, mmol: 27.0, &state)
        XCTAssertEqual(result.readings.first?.mgDl, 468)
        XCTAssertEqual(result.readings.first?.clamped, true)
        XCTAssertTrue(logContains(result, "OUT-OF-RANGE"))
        // the upper limits themselves
        XCTAssertEqual(realtime(11, t0.addingTimeInterval(300), mmol: 26.0, &state).readings.first?.clamped, false)
        XCTAssertEqual(realtime(12, t0.addingTimeInterval(600), mmol: 40.0, &state).readings.first?.mgDl, 468)
    }

    func testZeroAndAbsurdAreDropped() {
        var state = InstaraG1SessionState()
        let zero = realtime(10, t0, mmol: 0, &state)
        let absurd = realtime(11, t0.addingTimeInterval(300), mmol: 50.1, &state)
        XCTAssertTrue(zero.readings.isEmpty)
        XCTAssertTrue(absurd.readings.isEmpty)
        XCTAssertTrue(logContains(zero, "OUT-OF-RANGE"))
        XCTAssertTrue(logContains(absurd, "OUT-OF-RANGE"))
        XCTAssertTrue(state.seenSeqs.isEmpty)
        // values inside a history frame too
        _ = realtime(288, t0.addingTimeInterval(600), &state)
        let history = InstaraG1Session.process(.history(startSeq: 286, durationField: 5, mmolValues: [0, 50.1]), state: &state, receivedAt: t0.addingTimeInterval(605))
        XCTAssertTrue(history.readings.isEmpty)
        XCTAssertEqual(history.log.filter { $0.hasPrefix("OUT-OF-RANGE") }.count, 2)
    }

    func testSingleLowerSequenceDoesNotStartNewSession() {
        var state = InstaraG1SessionState()
        _ = realtime(500, t0, &state)
        let suspect = realtime(3, t0.addingTimeInterval(300), &state)
        XCTAssertTrue(suspect.readings.isEmpty)
        XCTAssertNil(suspect.newSensorStart)
        XCTAssertTrue(logContains(suspect, "SESSION-SUSPECT"), "\(suspect.log)")
        XCTAssertEqual(state.suspect?.seq, 3)
        XCTAssertEqual(state.lastSeq, 500)

        let normal = realtime(501, t0.addingTimeInterval(300), &state)
        XCTAssertEqual(normal.readings.map { $0.seq }, [501])
        XCTAssertNil(normal.newSensorStart)
        XCTAssertNil(state.suspect)
        XCTAssertEqual(state.lastSeq, 501)
    }

    func testTwoConsistentLowerSequencesStartNewSession() {
        var state = InstaraG1SessionState()
        _ = realtime(500, t0.addingTimeInterval(-3000), &state)
        let first = realtime(3, t0, mmol: 6.0, &state)
        XCTAssertTrue(first.readings.isEmpty)
        let second = realtime(4, t0.addingTimeInterval(300), mmol: 6.1, &state)
        XCTAssertEqual(second.newSensorStart, t0.addingTimeInterval(300 - 4 * 300))
        XCTAssertEqual(second.readings.map { $0.seq }, [3, 4])
        XCTAssertEqual(second.readings[0].timeStamp, t0)
        XCTAssertEqual(second.readings[0].rawMmol, 6.0)
        XCTAssertEqual(second.readings[1].timeStamp, t0.addingTimeInterval(300))
        XCTAssertEqual(state.lastSeq, 4)
        XCTAssertEqual(state.sensorStart, second.newSensorStart)
        XCTAssertNil(state.suspect)
        XCTAssertEqual(Set(state.seenSeqs.keys), [3, 4])
    }

    func testInconsistentSecondLowerSequenceDoesNotStartNewSession() {
        var state = InstaraG1SessionState()
        _ = realtime(500, t0.addingTimeInterval(-3000), &state)
        _ = realtime(3, t0, &state)
        // lower again, but its derived start is an hour away from the suspect's
        let second = realtime(4, t0.addingTimeInterval(3900), &state)
        XCTAssertNil(second.newSensorStart)
        XCTAssertTrue(second.readings.isEmpty)
        XCTAssertEqual(state.suspect?.seq, 4)
        XCTAssertEqual(state.lastSeq, 500)
    }

    func testSmallBackwardSequenceUsesReferenceTimeAndKeepsReference() {
        var state = InstaraG1SessionState()
        _ = realtime(500, t0, &state)
        let back = realtime(495, t0.addingTimeInterval(30), &state)
        XCTAssertEqual(back.readings.map { $0.seq }, [495])
        XCTAssertEqual(back.readings.first?.timeStamp, t0.addingTimeInterval(-5 * 300))
        XCTAssertNil(state.suspect)
        XCTAssertEqual(state.refSeq, 500)
        XCTAssertEqual(state.refDate, t0)
        XCTAssertEqual(state.lastSeq, 500)
        // seen ones are dropped silently
        let again = realtime(495, t0.addingTimeInterval(60), &state)
        XCTAssertTrue(again.readings.isEmpty)
        XCTAssertTrue(again.log.isEmpty, "\(again.log)")
    }

    func testStartShiftNeedsMeasuredInterval() {
        var state = InstaraG1SessionState()
        _ = realtime(100, t0, &state)
        // two hours later only one sequence step: derived start shifts by almost two hours
        let result = realtime(101, t0.addingTimeInterval(7200), &state)
        XCTAssertFalse(logContains(result, "SESSION-SUSPECT"), "\(result.log)")
        XCTAssertNil(state.suspect)
        XCTAssertEqual(result.readings.map { $0.seq }, [101])
    }

    func testStartShiftWithMeasuredIntervalIsSuspect() {
        var state = InstaraG1SessionState()
        _ = realtime(100, t0, &state)
        _ = realtime(101, t0.addingTimeInterval(300), &state)
        _ = realtime(102, t0.addingTimeInterval(600), &state)
        XCTAssertEqual(state.intervalSamples.count, 2)
        // one step, but one hour later
        let result = realtime(103, t0.addingTimeInterval(600 + 3600), &state)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertTrue(logContains(result, "SESSION-SUSPECT"), "\(result.log)")
        XCTAssertEqual(state.suspect?.seq, 103)
    }

    func testOldSeenSeqsArePruned() {
        var state = InstaraG1SessionState()
        _ = realtime(10, t0, &state)
        state.seenSeqs[1] = t0.addingTimeInterval(-22 * 86400)
        _ = realtime(11, t0.addingTimeInterval(300), &state)
        XCTAssertNil(state.seenSeqs[1])
        XCTAssertNotNil(state.seenSeqs[10])
    }

    func testOtherPacketsProduceNoReadings() {
        var state = InstaraG1SessionState()
        _ = realtime(10, t0, &state)
        let before = state
        for packet: InstaraG1Packet in [.battery(percent: 80), .handshake(hardware: 1, software: 2), .historyHeader(frameCount: 3), .unlisted(cmd: 0x60, payload: Data([1])), .invalid(reason: "CRC-FAIL", raw: Data())] {
            XCTAssertTrue(InstaraG1Session.process(packet, state: &state, receivedAt: t0.addingTimeInterval(10)).readings.isEmpty)
        }
        XCTAssertEqual(state, before)
    }

    func testStateIsCodable() throws {
        var state = InstaraG1SessionState()
        _ = realtime(500, t0, &state)
        _ = realtime(3, t0.addingTimeInterval(300), &state)
        let decoded = try JSONDecoder().decode(InstaraG1SessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertNotNil(decoded.suspect)
    }
}
