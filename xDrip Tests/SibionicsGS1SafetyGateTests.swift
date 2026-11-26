import XCTest
@testable import xdrip

final class SibionicsGS1SafetyGateTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private var savedIsMasterRaw: Any?
    private var savedTransmitterType: Any?
    private let isMasterKey = UserDefaults.Key.isMaster.rawValue
    private let transmitterKey = UserDefaults.Key.transmitterTypeAsString.rawValue

    override func setUp() {
        super.setUp()
        savedIsMasterRaw = defaults.object(forKey: isMasterKey)
        savedTransmitterType = defaults.object(forKey: transmitterKey)
    }

    override func tearDown() {
        restore(savedIsMasterRaw, forKey: isMasterKey)
        restore(savedTransmitterType, forKey: transmitterKey)
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
        let blocked: Set<AlertKind> = [.verylow, .low, .high, .veryhigh, .fastdrop, .fastrise, .notlooping]
        for kind in AlertKind.allCases {
            XCTAssertEqual(AlertManager.alertIsPermitted(kind, sourceAllowsAlarms: false), !blocked.contains(kind), "\(kind)")
        }
        for kind in [AlertKind.missedreading, .calibration, .batterylow, .phonebatterylow, .sensorTransmitterFailure, .dexcomG5BatteryLow, .dexcomG7BatteryLow, .sensorEndingSoon, .sensorExpectedExpiry] {
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
}
