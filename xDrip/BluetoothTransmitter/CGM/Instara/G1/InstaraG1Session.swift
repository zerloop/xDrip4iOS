// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import Foundation

/// one glucose reading produced by the session
struct InstaraG1Reading: Equatable {
    let seq: Int
    let timeStamp: Date
    /// value as sent by the sensor
    let rawMmol: Double
    /// value to store, possibly clamped
    let mgDl: Double
    /// true if mgDl is a clamped value
    let clamped: Bool
}

/// a realtime packet that may belong to a new sensor, waiting for a second consistent packet
struct InstaraG1Suspect: Codable, Equatable {
    let seq: Int
    /// receive time of the packet
    let at: Date
    /// sensor start derived from the packet: at - seq * interval. Informational (logs, diagnostics), not used for confirmation
    let derivedStart: Date?
    /// value of the packet, emitted if the new session is confirmed
    let rawMmol: Double
}

/// a realtime packet whose sequence number is too far ahead for the time elapsed since the reference. Never a new sensor
struct InstaraG1JumpCandidate: Codable, Equatable {
    let seq: Int
    /// receive time of the packet
    let at: Date
    /// value of the packet, emitted if a following packet re-anchors the reference
    let rawMmol: Double
}

/// persistent (by the caller) state of the G1 session
struct InstaraG1SessionState: Codable, Equatable {
    /// highest realtime sequence number of the current session
    var lastSeq: Int?
    /// reference for history time stamps: sequence number and receive time of the newest realtime packet
    var refSeq: Int?
    var refDate: Date?
    /// refDate - refSeq * interval
    var sensorStart: Date?
    /// interval announced by the sensor (0x0A), minutes, only if valid
    var intervalFromSensor: Int?
    /// measured seconds per sequence step of consecutive realtime packets, most recent last
    var intervalSamples: [Double] = []
    /// emitted sequence numbers and their time stamps, limited to the sensor life
    var seenSeqs: [Int: Date] = [:]
    var suspect: InstaraG1Suspect?
    /// a realtime packet too fast after the reference (seq jumped ahead), waiting for a second packet to re-anchor
    var jumpCandidate: InstaraG1JumpCandidate?
    /// set by a SEQ-REANCHOR: sequence numbers no longer count from the sensor start, so sensorStart is not re-derived any more in this session
    var sensorStartLocked: Bool = false
}

struct InstaraG1SessionResult {
    /// oldest first
    let readings: [InstaraG1Reading]
    /// set when a first or a confirmed new sensor session was detected
    let newSensorStart: Date?
    let log: [String]
}

/// pure session logic: interval, time stamps, de-duplication, clamping, new sensor detection. No CoreBluetooth, no persistence
enum InstaraG1Session {

    /// a recalculated time stamp of an already emitted sequence number that differs more than this is logged as CLOCK-MISMATCH
    static let clockMismatchToleranceSeconds: TimeInterval = 120

    /// interval in minutes: measured median (at least 2 samples) > announced by the sensor > default
    static func intervalMinutes(_ state: InstaraG1SessionState) -> Int {
        measuredIntervalMinutes(state) ?? state.intervalFromSensor ?? ConstantsInstaraG1.defaultIntervalMinutes
    }

    static func process(_ packet: InstaraG1Packet, state: inout InstaraG1SessionState, receivedAt: Date) -> InstaraG1SessionResult {

        var context = Context()

        prune(&state, receivedAt: receivedAt)

        switch packet {
        case let .realtime(seq, mmol):
            processRealtime(seq: seq, mmol: mmol, state: &state, receivedAt: receivedAt, context: &context)
        case let .history(startSeq, _, mmolValues):
            processHistory(startSeq: startSeq, values: mmolValues, state: &state, receivedAt: receivedAt, context: &context)
        case let .interval(minutes):
            processInterval(minutes: minutes, state: &state, context: &context)
        case .historyHeader, .battery, .handshake, .unlisted, .invalid:
            break
        }

        return InstaraG1SessionResult(readings: context.readings.sorted { $0.timeStamp < $1.timeStamp }, newSensorStart: context.newSensorStart, log: context.log)
    }

    // MARK: - private

    private struct Context {
        var readings = [InstaraG1Reading]()
        var newSensorStart: Date?
        var log = [String]()
    }

    private enum Value {
        case dropped
        case valid(mgDl: Double, clamped: Bool)
    }

    /// a re-derived sensor start that moves more than this is reported as newSensorStart (R23)
    private static let sensorStartCorrectionThreshold: TimeInterval = 30 * 60

    private static func epoch(_ date: Date?) -> String {
        guard let date = date else { return "nil" }
        return String(Int(date.timeIntervalSince1970))
    }

    private static func measuredIntervalMinutes(_ state: InstaraG1SessionState) -> Int? {
        let samples = state.intervalSamples.sorted()
        guard samples.count >= 2 else { return nil }
        let middle = samples.count / 2
        let median = samples.count % 2 == 0 ? (samples[middle - 1] + samples[middle]) / 2 : samples[middle]
        return Int((median / 60).rounded())
    }

    private static func intervalSeconds(_ state: InstaraG1SessionState) -> TimeInterval {
        TimeInterval(intervalMinutes(state) * 60)
    }

    /// classifies a raw value, logs drops and clamps
    private static func classify(_ mmol: Double, seq: Int, context: inout Context) -> Value {
        if mmol <= 0 || mmol > ConstantsInstaraG1.maxPlausibleMmol {
            context.log.append("OUT-OF-RANGE;seq=\(seq);mmol=\(mmol);action=dropped")
            return .dropped
        }
        if mmol < ConstantsInstaraG1.minValidMmol {
            context.log.append("OUT-OF-RANGE;seq=\(seq);mmol=\(mmol);action=clamped;mgDl=\(ConstantsInstaraG1.clampLowMgDl)")
            return .valid(mgDl: ConstantsInstaraG1.clampLowMgDl, clamped: true)
        }
        if mmol > ConstantsInstaraG1.maxValidMmol {
            context.log.append("OUT-OF-RANGE;seq=\(seq);mmol=\(mmol);action=clamped;mgDl=\(ConstantsInstaraG1.clampHighMgDl)")
            return .valid(mgDl: ConstantsInstaraG1.clampHighMgDl, clamped: true)
        }
        return .valid(mgDl: mmol * ConstantsBloodGlucose.mmollToMgdl, clamped: false)
    }

    /// emits a reading unless the sequence number was emitted before
    private static func emit(seq: Int, at timeStamp: Date, mmol: Double, mgDl: Double, clamped: Bool, state: inout InstaraG1SessionState, context: inout Context) {
        if let stored = state.seenSeqs[seq] {
            if abs(timeStamp.timeIntervalSince(stored)) > clockMismatchToleranceSeconds {
                context.log.append("CLOCK-MISMATCH;seq=\(seq);stored=\(epoch(stored));calculated=\(epoch(timeStamp))")
            }
            return
        }
        state.seenSeqs[seq] = timeStamp
        context.readings.append(InstaraG1Reading(seq: seq, timeStamp: timeStamp, rawMmol: mmol, mgDl: mgDl, clamped: clamped))
    }

    private static func prune(_ state: inout InstaraG1SessionState, receivedAt: Date) {
        let limit = receivedAt.addingTimeInterval(-ConstantsInstaraG1.sensorLifeDays * 86400)
        state.seenSeqs = state.seenSeqs.filter { $0.value >= limit }
    }

    /// true if Δt / Δseq of a forward step is a plausible reading interval
    private static func isPlausibleStep(deltaT: TimeInterval, deltaSeq: Int) -> Bool {
        guard deltaSeq > 0 else { return false }
        let step = deltaT / Double(deltaSeq)
        return step >= ConstantsInstaraG1.minPlausibleStepSeconds && step <= ConstantsInstaraG1.maxPlausibleStepSeconds
    }

    /// to be called after anything that may change the interval. sensorStart is re-derived only when the interval first becomes measured; later changes are logged
    private static func intervalMayHaveChanged(from previous: Int, wasMeasured: Bool, announced: Bool, state: inout InstaraG1SessionState, context: inout Context) {
        let current = intervalMinutes(state)
        let isMeasured = measuredIntervalMinutes(state) != nil
        if !wasMeasured, isMeasured, !state.sensorStartLocked, let refSeq = state.refSeq, let refDate = state.refDate {
            let previousStart = state.sensorStart
            let rederivedStart = refDate.addingTimeInterval(-Double(refSeq) * intervalSeconds(state))
            state.sensorStart = rederivedStart
            context.log.append("SENSOR-START;reason=interval-measured;interval=\(current);sensorStart=\(epoch(state.sensorStart))")
            // R23: a large correction is reported like a new start, so xDrip's active sensor (and the verification
            // bound to it) follows the session start the mismatch check compares with
            if let previousStart, abs(rederivedStart.timeIntervalSince(previousStart)) > sensorStartCorrectionThreshold {
                context.newSensorStart = rederivedStart
                context.log.append("SENSOR-START-CORRECTED;from=\(epoch(previousStart));to=\(epoch(rederivedStart))")
            }
        } else if current != previous {
            context.log.append("INTERVAL-CHANGE;from=\(previous);to=\(current)")
        }
        if current != previous || announced, let measured = measuredIntervalMinutes(state), let fromSensor = state.intervalFromSensor, measured != fromSensor {
            context.log.append("INTERVAL-MISMATCH;measured=\(measured);sensor=\(fromSensor);used=\(measured)")
        }
    }

    private static func processInterval(minutes: Int, state: inout InstaraG1SessionState, context: inout Context) {
        guard ConstantsInstaraG1.validIntervalRange.contains(minutes) else {
            context.log.append("INTERVAL-INVALID;minutes=\(minutes)")
            return
        }
        let previous = intervalMinutes(state)
        let wasMeasured = measuredIntervalMinutes(state) != nil
        state.intervalFromSensor = minutes
        intervalMayHaveChanged(from: previous, wasMeasured: wasMeasured, announced: true, state: &state, context: &context)
    }

    private static func processHistory(startSeq: Int, values: [Double], state: inout InstaraG1SessionState, receivedAt: Date, context: inout Context) {
        guard let refSeq = state.refSeq, let refDate = state.refDate else {
            context.log.append("HISTORY-NO-REF;startSeq=\(startSeq);count=\(values.count)")
            return
        }
        let interval = intervalSeconds(state)
        let oldestAllowed = receivedAt.addingTimeInterval(-ConstantsInstaraG1.sensorLifeDays * 86400)

        for (i, mmol) in values.enumerated() {
            let seq = startSeq + i
            let timeStamp = refDate.addingTimeInterval(-Double(refSeq - seq) * interval)
            if timeStamp > receivedAt {
                context.log.append("HISTORY-FUTURE;seq=\(seq);t=\(epoch(timeStamp))")
                continue
            }
            if timeStamp < oldestAllowed {
                context.log.append("HISTORY-TOO-OLD;seq=\(seq);t=\(epoch(timeStamp))")
                continue
            }
            guard case let .valid(mgDl, clamped) = classify(mmol, seq: seq, context: &context) else { continue }
            emit(seq: seq, at: timeStamp, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
        }
    }

    /// starts a session from a realtime packet on an empty state
    private static func startSession(seq: Int, receivedAt: Date, state: inout InstaraG1SessionState) {
        state.lastSeq = seq
        state.refSeq = seq
        state.refDate = receivedAt
        state.sensorStart = receivedAt.addingTimeInterval(-Double(seq) * intervalSeconds(state))
    }

    /// adds a Δt/Δseq sample if it is within the valid interval range
    private static func addSample(deltaT: TimeInterval, deltaSeq: Int, state: inout InstaraG1SessionState, context: inout Context) {
        guard deltaSeq > 0, deltaT > 0 else { return }
        let sample = deltaT / Double(deltaSeq)
        guard ConstantsInstaraG1.validIntervalRange.contains(Int((sample / 60).rounded())) else {
            context.log.append("INTERVAL-SAMPLE-DISCARDED;seconds=\(sample)")
            return
        }
        state.intervalSamples.append(sample)
        if state.intervalSamples.count > ConstantsInstaraG1.intervalSampleCount {
            state.intervalSamples.removeFirst(state.intervalSamples.count - ConstantsInstaraG1.intervalSampleCount)
        }
    }

    private static func processRealtime(seq: Int, mmol: Double, state: inout InstaraG1SessionState, receivedAt: Date, context: inout Context) {

        // dropped values do not change the session
        guard case let .valid(mgDl, clamped) = classify(mmol, seq: seq, context: &context) else { return }

        // first packet ever
        guard let lastSeq = state.lastSeq, let refSeq = state.refSeq, let refDate = state.refDate else {
            startSession(seq: seq, receivedAt: receivedAt, state: &state)
            context.newSensorStart = state.sensorStart
            context.log.append("SESSION-START;seq=\(seq);sensorStart=\(epoch(state.sensorStart))")
            emit(seq: seq, at: receivedAt, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
            return
        }

        let derivedStart = receivedAt.addingTimeInterval(-Double(seq) * intervalSeconds(state))

        // candidate rules, always against the current (old) session
        let seqDrop = seq < lastSeq - ConstantsInstaraG1.newSensorSeqDrop
        let stepFromRef = seq > lastSeq ? receivedAt.timeIntervalSince(refDate) / Double(seq - refSeq) : nil
        // too fast forward is never a new sensor, see jumpCandidate
        let tooFast = stepFromRef.map { $0 < ConstantsInstaraG1.minPlausibleStepSeconds } ?? false
        let tooSlow = stepFromRef.map { $0 > ConstantsInstaraG1.maxPlausibleStepSeconds } ?? false
        let isCandidate = seqDrop || tooSlow

        if let suspect = state.suspect {

            if isCandidate, seq > suspect.seq, isPlausibleStep(deltaT: receivedAt.timeIntervalSince(suspect.at), deltaSeq: seq - suspect.seq) {
                // confirmed: new session from the confirming pair; the announced interval is kept
                let intervalFromSensor = state.intervalFromSensor
                state = InstaraG1SessionState()
                state.intervalFromSensor = intervalFromSensor
                addSample(deltaT: receivedAt.timeIntervalSince(suspect.at), deltaSeq: seq - suspect.seq, state: &state, context: &context)
                startSession(seq: seq, receivedAt: receivedAt, state: &state)
                context.newSensorStart = state.sensorStart
                context.log.append("SESSION-NEW;suspectSeq=\(suspect.seq);seq=\(seq);sensorStart=\(epoch(state.sensorStart))")
                if case let .valid(suspectMgDl, suspectClamped) = classify(suspect.rawMmol, seq: suspect.seq, context: &context) {
                    emit(seq: suspect.seq, at: suspect.at, mmol: suspect.rawMmol, mgDl: suspectMgDl, clamped: suspectClamped, state: &state, context: &context)
                }
                emit(seq: seq, at: receivedAt, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
                return
            }

            // not confirmed: the suspect was an outlier, its reading is dropped
            state.suspect = nil
            context.log.append("SESSION-SUSPECT-CLEARED;suspectSeq=\(suspect.seq);seq=\(seq)")
        }

        if tooFast {
            if let jump = state.jumpCandidate, isPlausibleStep(deltaT: receivedAt.timeIntervalSince(jump.at), deltaSeq: seq - jump.seq) {
                // the sequence number really jumped: same session, new reference
                state.jumpCandidate = nil
                let previousInterval = intervalMinutes(state)
                let wasMeasured = measuredIntervalMinutes(state) != nil
                addSample(deltaT: receivedAt.timeIntervalSince(jump.at), deltaSeq: seq - jump.seq, state: &state, context: &context)
                state.lastSeq = seq
                state.refSeq = seq
                state.refDate = receivedAt
                state.sensorStartLocked = true
                context.log.append("SEQ-REANCHOR;fromSeq=\(refSeq);jumpSeq=\(jump.seq);seq=\(seq)")
                intervalMayHaveChanged(from: previousInterval, wasMeasured: wasMeasured, announced: false, state: &state, context: &context)
                if case let .valid(jumpMgDl, jumpClamped) = classify(jump.rawMmol, seq: jump.seq, context: &context) {
                    emit(seq: jump.seq, at: jump.at, mmol: jump.rawMmol, mgDl: jumpMgDl, clamped: jumpClamped, state: &state, context: &context)
                }
                emit(seq: seq, at: receivedAt, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
                return
            }
            state.jumpCandidate = InstaraG1JumpCandidate(seq: seq, at: receivedAt, rawMmol: mmol)
            context.log.append("SEQ-JUMP;seq=\(seq);refSeq=\(refSeq);refDate=\(epoch(refDate));step=\(stepFromRef ?? 0)")
            return
        }

        if let jump = state.jumpCandidate {
            // a normal packet: the jump was an outlier, its reading is dropped
            state.jumpCandidate = nil
            context.log.append("SEQ-JUMP-CLEARED;jumpSeq=\(jump.seq);seq=\(seq)")
        }

        if isCandidate {
            state.suspect = InstaraG1Suspect(seq: seq, at: receivedAt, derivedStart: derivedStart, rawMmol: mmol)
            context.log.append("SESSION-SUSPECT;seq=\(seq);lastSeq=\(lastSeq);reason=\(seqDrop ? "seq-drop" : "slow-forward");refDate=\(epoch(refDate));derivedStart=\(epoch(derivedStart))")
            return
        }

        if seq <= lastSeq {
            // small step back or repeat: time from the reference, the reference stays
            guard state.seenSeqs[seq] == nil else { return }
            let timeStamp = refDate.addingTimeInterval(-Double(refSeq - seq) * intervalSeconds(state))
            if timeStamp > receivedAt {
                context.log.append("REALTIME-FUTURE;seq=\(seq);t=\(epoch(timeStamp))")
                return
            }
            emit(seq: seq, at: timeStamp, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
            return
        }

        // normal: newer realtime moves the reference
        let previousInterval = intervalMinutes(state)
        let wasMeasured = measuredIntervalMinutes(state) != nil
        addSample(deltaT: receivedAt.timeIntervalSince(refDate), deltaSeq: seq - refSeq, state: &state, context: &context)
        state.lastSeq = seq
        state.refSeq = seq
        state.refDate = receivedAt
        intervalMayHaveChanged(from: previousInterval, wasMeasured: wasMeasured, announced: false, state: &state, context: &context)
        emit(seq: seq, at: receivedAt, mmol: mmol, mgDl: mgDl, clamped: clamped, state: &state, context: &context)
    }
}
