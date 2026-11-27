// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import Foundation

/// constants for the Instara G1 passive co-listener
enum ConstantsInstaraG1 {

    /// G1 service
    static let serviceUUID = "8653000A-43E6-47B7-9CB0-5FC21D4AE340"

    /// notify characteristic on which the sensor sends its frames (the sensor is only listened to, never written to)
    static let notifyCharacteristicUUID = "8653000B-43E6-47B7-9CB0-5FC21D4AE340"

    /// write characteristic, recognised but never used
    static let writeCharacteristicUUID = "8653000C-43E6-47B7-9CB0-5FC21D4AE340"

    /// lower limit of valid values, mmol/L
    static let minValidMmol = 2.0

    /// upper limit of valid values, mmol/L
    static let maxValidMmol = 26.0

    /// values above this are implausible and dropped, mmol/L
    static let maxPlausibleMmol = 40.0

    /// mg/dL value used for readings below minValidMmol
    static let clampLowMgDl = 36.0

    /// mg/dL value used for readings between maxValidMmol and maxPlausibleMmol
    static let clampHighMgDl = 468.0

    /// reading interval used when nothing better is known, minutes
    static let defaultIntervalMinutes = 5

    /// accepted range of the interval announced by the sensor, minutes
    static let validIntervalRange = 1...15

    /// number of most recent sample pairs used to measure the reading interval
    static let intervalSampleCount = 6

    /// sensor life, days
    static let sensorLifeDays = 21.0

    /// warm-up time, minutes
    static let warmupMinutes = 15.0

    /// a sequence number drop of at least this much indicates a new sensor
    static let newSensorSeqDrop = 12

    /// sensor start is assumed this long before the first reading of a new sensor, seconds
    static let newSensorStartShift: TimeInterval = 1800

    /// a new sensor must be confirmed within this window, seconds
    static let newSensorConfirmWindow: TimeInterval = 600

    /// a partial frame older than this is dropped, seconds
    static let fragmentTimeout: TimeInterval = 2

    /// watchdog: renew the notification subscription after this many seconds without data
    static let resubscribeAfterSeconds = 900

    /// watchdog: release the connection after this many seconds without data
    static let releaseAfterSeconds = 1800

    /// delays between reconnect attempts, seconds
    static let reconnectDelays: [TimeInterval] = [5, 10, 15]
}
