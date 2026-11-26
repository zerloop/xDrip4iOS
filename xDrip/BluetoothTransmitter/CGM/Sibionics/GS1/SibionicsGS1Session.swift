// Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.

import Foundation

/// persistent (by the caller) state of the GS1 session
struct SibionicsGS1SessionState: Equatable {
    /// highest record index received in the current sensor session, -1 if none
    var lastReceivedIndex: Int
    var sensorStartDate: Date?
    /// time stamp of the newest emitted record
    var lastReadingDate: Date?
    /// raw (unclamped) time stamp of the newest record processed in any way (emitted or skipped)
    var lastRecordDate: Date? = nil
    /// session start derived from the raw (unclamped) sensor time: raw time stamp - index * 60.
    /// Constant for one sensor even if the sensor clock is ahead of the phone, used to detect a sensor change
    var rawSensorStartDate: Date? = nil
}

struct SibionicsGS1SessionResult {
    let newRecords: [SibionicsGS1Record]
    /// set when a first or a new sensor session was detected
    let newSensorStartDate: Date?
    let skipped: [(record: SibionicsGS1Record, reason: String)]
}

/// pure session logic: de-duplication, new sensor detection, time handling. No CoreBluetooth, no persistence
enum SibionicsGS1Session {

    /// a derived session start that differs more than this from the stored one is a new sensor
    static let newSessionStartToleranceSeconds: TimeInterval = 30 * 60

    static func process(_ records: [SibionicsGS1Record], state: inout SibionicsGS1SessionState, now: Date) -> SibionicsGS1SessionResult {

        var newRecords = [SibionicsGS1Record]()
        var skipped = [(record: SibionicsGS1Record, reason: String)]()
        var newSensorStartDate: Date?

        // the backfill limit applies to the first session only
        var isFirstSession = state.lastReceivedIndex == -1

        for original in records.sorted(by: { $0.index < $1.index }) {

            // sensor clock may be ahead of the phone
            var record = original
            if record.timeStamp > now {
                record = SibionicsGS1Record(index: original.index, timeStamp: now, temperatureC: original.temperatureC, rawMmol: original.rawMmol, dump: original.dump, extra: original.extra)
            }

            // raw session start of this record, independent of the index direction
            let derivedRawStart = original.timeStamp.addingTimeInterval(-Double(original.index) * 60)

            let timeMovedOn = state.lastRecordDate == nil || original.timeStamp > state.lastRecordDate!

            if state.lastReceivedIndex != -1, timeMovedOn,
               let storedStart = state.rawSensorStartDate ?? state.sensorStartDate,
               abs(derivedRawStart.timeIntervalSince(storedStart)) > newSessionStartToleranceSeconds {

                // derived start differs: new sensor, also when its index is already higher (long offline gap)
                state.lastReceivedIndex = -1
                state.sensorStartDate = nil
                state.lastReadingDate = nil
                state.rawSensorStartDate = nil
                isFirstSession = true

            } else if original.index == state.lastReceivedIndex {

                skipped.append((record: record, reason: "duplicate"))
                continue

            } else if original.index < state.lastReceivedIndex {

                // index went back while (raw) time moved on: new sensor
                if timeMovedOn {
                    state.lastReceivedIndex = -1
                    state.sensorStartDate = nil
                    state.lastReadingDate = nil
                    state.rawSensorStartDate = nil
                    isFirstSession = true
                } else {
                    skipped.append((record: record, reason: "duplicate"))
                    continue
                }

            }

            if let lastRecordDate = state.lastRecordDate, state.lastReceivedIndex != -1, lastRecordDate > original.timeStamp {
                // keep the newest raw time stamp
            } else {
                state.lastRecordDate = original.timeStamp
            }

            if state.sensorStartDate == nil {
                let start = record.timeStamp.addingTimeInterval(-Double(record.index) * 60)
                state.sensorStartDate = start
                newSensorStartDate = start
            }

            // also migrates a state persisted before rawSensorStartDate existed
            if state.rawSensorStartDate == nil {
                state.rawSensorStartDate = derivedRawStart
            }

            state.lastReceivedIndex = record.index

            if isFirstSession && record.timeStamp < now.addingTimeInterval(-ConstantsSibionicsGS1.maxBackfillSeconds) {
                skipped.append((record: record, reason: "backfill-limit"))
                continue
            }

            if !record.isInValidRange {
                skipped.append((record: record, reason: "out-of-range"))
                continue
            }

            state.lastReadingDate = record.timeStamp
            newRecords.append(record)

        }

        return SibionicsGS1SessionResult(newRecords: newRecords, newSensorStartDate: newSensorStartDate, skipped: skipped)

    }

}
