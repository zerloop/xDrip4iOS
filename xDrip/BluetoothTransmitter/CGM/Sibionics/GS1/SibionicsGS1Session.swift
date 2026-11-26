// Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.

import Foundation

/// persistent (by the caller) state of the GS1 session
struct SibionicsGS1SessionState: Equatable {
    /// highest record index received in the current sensor session, -1 if none
    var lastReceivedIndex: Int
    var sensorStartDate: Date?
    /// time stamp of the newest emitted record
    var lastReadingDate: Date?
}

struct SibionicsGS1SessionResult {
    let newRecords: [SibionicsGS1Record]
    /// set when a first or a new sensor session was detected
    let newSensorStartDate: Date?
    let skipped: [(record: SibionicsGS1Record, reason: String)]
}

/// pure session logic: de-duplication, new sensor detection, time handling. No CoreBluetooth, no persistence
enum SibionicsGS1Session {

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

            if record.index <= state.lastReceivedIndex {

                if let lastReadingDate = state.lastReadingDate, record.timeStamp > lastReadingDate {
                    // index went back while time moved on: new sensor
                    state.lastReceivedIndex = -1
                    state.sensorStartDate = nil
                    state.lastReadingDate = nil
                    isFirstSession = true
                } else {
                    skipped.append((record: record, reason: "duplicate"))
                    continue
                }

            }

            if state.sensorStartDate == nil {
                let start = record.timeStamp.addingTimeInterval(-Double(record.index) * 60)
                state.sensorStartDate = start
                newSensorStartDate = start
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
