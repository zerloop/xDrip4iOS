import XCTest
@testable import xdrip

final class SibionicsGS1SafetyGateTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private var savedIsMasterRaw: Any?
    private var savedTransmitterType: Any?
    private let isMasterKey = UserDefaults.Key.isMaster.rawValue
    private let transmitterKey = UserDefaults.Key.transmitterTypeAsString.rawValue

    private let cursorKeys = [
        UserDefaults.Key.timeStampLatestLoopSharedBgReading.rawValue,
        UserDefaults.Key.timeStampLatestNSUploadedBgReadingToNightscout.rawValue,
        UserDefaults.Key.timeStampLatestHealthKitStoreBgReading.rawValue,
        UserDefaults.Key.timeStampLatestDexcomShareUploadedBgReading.rawValue,
        UserDefaults.Key.glucoseExportFloorTimeStamp.rawValue
    ]
    private var savedCursors = [String: Any]()

    override func setUp() {
        super.setUp()
        savedIsMasterRaw = defaults.object(forKey: isMasterKey)
        savedTransmitterType = defaults.object(forKey: transmitterKey)
        savedCursors = [:]
        for key in cursorKeys {
            savedCursors[key] = defaults.object(forKey: key)
        }
    }

    override func tearDown() {
        restore(savedIsMasterRaw, forKey: isMasterKey)
        restore(savedTransmitterType, forKey: transmitterKey)
        for key in cursorKeys {
            restore(savedCursors[key], forKey: key)
        }
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testExportBlockedForSibionicsMaster() {
        defaults.isMaster = true
        defaults.set(CGMTransmitterType.sibionicsGS1.rawValue, forKey: transmitterKey)
        XCTAssertFalse(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertFalse(defaults.activeSourceAllowsGlucoseAlarms)
    }

    func testExportAllowedForFollower() {
        defaults.isMaster = false
        defaults.set(CGMTransmitterType.sibionicsGS1.rawValue, forKey: transmitterKey)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseAlarms)
    }

    func testOnlyGlucoseValueAlarmsAreBlocked() {
        let blocked: Set<AlertKind> = [.verylow, .low, .high, .veryhigh, .fastdrop, .fastrise]
        for kind in AlertKind.allCases {
            XCTAssertEqual(AlertManager.alertIsPermitted(kind, sourceAllowsAlarms: false), !blocked.contains(kind), "\(kind)")
        }
        for kind in [AlertKind.missedreading, .notlooping, .calibration, .batterylow, .phonebatterylow, .sensorTransmitterFailure, .dexcomG5BatteryLow, .dexcomG7BatteryLow, .sensorEndingSoon, .sensorExpectedExpiry] {
            XCTAssertTrue(AlertManager.alertIsPermitted(kind, sourceAllowsAlarms: false), "\(kind)")
        }
    }

    func testAlarmsAllowedForOtherSources() {
        for kind in AlertKind.allCases {
            XCTAssertTrue(AlertManager.alertIsPermitted(kind, sourceAllowsAlarms: true), "\(kind)")
        }
        defaults.isMaster = true
        defaults.set(CGMTransmitterType.dexcomG7.rawValue, forKey: transmitterKey)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseAlarms)
    }

    func testUnconfiguredMasterIsAllowed() {
        defaults.isMaster = true
        defaults.removeObject(forKey: transmitterKey)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseAlarms)
    }
    // MARK: - backlog after a source switch (final review item 1)

    private let threeDaysAgo = Date(timeIntervalSinceNow: -3 * 86400)

    private func setAllCursors(_ date: Date) {
        defaults.timeStampLatestLoopSharedBgReading = date
        defaults.timeStampLatestNightscoutUploadedBgReading = date
        defaults.timeStampLatestHealthKitStoreBgReading = date
        defaults.timeStampLatestDexcomShareUploadedBgReading = date
        defaults.removeObject(forKey: UserDefaults.Key.glucoseExportFloorTimeStamp.rawValue)
    }

    private func assertAllCursors(atLeast date: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestLoopSharedBgReading ?? .distantPast, date, "loop", file: file, line: line)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestNightscoutUploadedBgReading ?? .distantPast, date, "nightscout", file: file, line: line)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestHealthKitStoreBgReading ?? .distantPast, date, "healthkit", file: file, line: line)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestDexcomShareUploadedBgReading ?? .distantPast, date, "dexcom share", file: file, line: line)
        XCTAssertGreaterThanOrEqual(defaults.glucoseExportFloorTimeStamp ?? .distantPast, date, "floor", file: file, line: line)
    }

    private func startAsSibionicsMaster() {
        defaults.isMaster = true
        defaults.set(CGMTransmitterType.sibionicsGS1.rawValue, forKey: transmitterKey)
        setAllCursors(threeDaysAgo)
    }

    func testSwitchFromSibionicsToDexcomG7AdvancesAllExportCursors() {
        startAsSibionicsMaster()
        let switchTime = Date()
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.dexcomG7.rawValue
        assertAllCursors(atLeast: switchTime)
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseExport)
    }

    func testSwitchFromSibionicsMasterToFollowerAdvancesAllExportCursors() {
        startAsSibionicsMaster()
        let switchTime = Date()
        defaults.isMaster = false
        assertAllCursors(atLeast: switchTime)
    }

    func testRemovingSibionicsTypeAdvancesAllExportCursors() {
        startAsSibionicsMaster()
        let switchTime = Date()
        defaults.cgmTransmitterTypeAsString = nil
        assertAllCursors(atLeast: switchTime)
    }

    func testSwitchBetweenAllowedSourcesKeepsCursors() {
        defaults.isMaster = true
        defaults.set(CGMTransmitterType.dexcomG7.rawValue, forKey: transmitterKey)
        setAllCursors(threeDaysAgo)
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.Libre3.rawValue
        defaults.isMaster = false
        XCTAssertEqual(defaults.timeStampLatestNightscoutUploadedBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestLoopSharedBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestHealthKitStoreBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestDexcomShareUploadedBgReading, threeDaysAgo)
        XCTAssertNil(defaults.glucoseExportFloorTimeStamp)
    }

    func testFollowerToSibionicsMasterKeepsCursors() {
        defaults.isMaster = false
        defaults.set(CGMTransmitterType.sibionicsGS1.rawValue, forKey: transmitterKey)
        setAllCursors(threeDaysAgo)
        defaults.isMaster = true
        XCTAssertEqual(defaults.timeStampLatestNightscoutUploadedBgReading, threeDaysAgo)
    }

    func testAdvanceNeverMovesCursorsBackwards() {
        let future = Date(timeIntervalSinceNow: 3600)
        setAllCursors(future)
        defaults.advanceGlucoseExportCursors(to: Date())
        XCTAssertEqual(defaults.timeStampLatestNightscoutUploadedBgReading, future)
        XCTAssertEqual(defaults.timeStampLatestLoopSharedBgReading, future)
        XCTAssertEqual(defaults.timeStampLatestHealthKitStoreBgReading, future)
        XCTAssertEqual(defaults.timeStampLatestDexcomShareUploadedBgReading, future)
    }

    func testLoopLookBackNeverReachesBeforeExportFloor() {
        let latestShared = Date(timeIntervalSince1970: 1_795_000_000)
        // without floor: the usual 30 minute look-back
        XCTAssertEqual(LoopManager.shareFromDate(latestShared: latestShared, exportFloor: nil), latestShared.addingTimeInterval(-1800))
        // readings of the blocked source before the switch must never reach the OS-AID app
        XCTAssertEqual(LoopManager.shareFromDate(latestShared: latestShared, exportFloor: latestShared), latestShared)
        XCTAssertEqual(LoopManager.shareFromDate(latestShared: latestShared, exportFloor: latestShared.addingTimeInterval(-7200)), latestShared.addingTimeInterval(-1800))
    }
}
