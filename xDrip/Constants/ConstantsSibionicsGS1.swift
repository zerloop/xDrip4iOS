// Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.

import Foundation

/// constants for the Sibionics GS1 passive co-listener
enum ConstantsSibionicsGS1 {

    /// GS1 glucose service
    static let serviceUUID = "0000FF30-0000-1000-8000-00805F9B34FB"

    /// notify characteristic on which the sensor sends its packets (the sensor is only listened to, never written to)
    static let notifyCharacteristicUUID = "0000FF31-0000-1000-8000-00805F9B34FB"

    /// standard device information service
    static let deviceInformationServiceUUID = "180A"

    /// standard battery service
    static let batteryServiceUUID = "180F"

    /// standard battery level characteristic
    static let batteryLevelCharacteristicUUID = "2A19"

    /// RC4 key, 16 bytes, skip 0, key stream restarts for every packet
    static let rc4Key: [UInt8] = [
        0x01, 0x38, 0x0b, 0x9a, 0x00, 0x5b, 0x02, 0x5d,
        0xcd, 0x9e, 0xc3, 0x99, 0x09, 0x37, 0xaa, 0xe8
    ]

    /// mg/dL = mmol/L * mmolToMgDl
    static let mmolToMgDl = 18.0182

    /// lower limit of valid raw values, mmol/L
    static let minValidMmol = 1.8

    /// upper limit of valid raw values, mmol/L
    static let maxValidMmol = 30.0

    /// maximum age of records that will be backfilled on first connection
    static let maxBackfillSeconds: TimeInterval = 6 * 3600

    /// sensor life in days
    static let sensorLifeDays = 14.0

    /// warm-up time in minutes
    static let warmupMinutes = 60.0

    /// re-subscribe to the notify characteristic if no valid glucose packet was received for this long
    static let resubscribeAfterSeconds: TimeInterval = 300

    /// disconnect and re-retrieve the connected peripheral if no valid glucose packet was received for this long
    static let releaseAfterSeconds: TimeInterval = 900

    /// back-off delays (seconds) for re-retrieving connected peripherals
    static let reconnectDelays: [TimeInterval] = [5, 10, 15]

}
