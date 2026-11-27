import XCTest
@testable import xdrip

/// Safety gates of the Instara G1 verification toggle: nothing is exported, shared with OS-AID or alarmed on
/// glucose values until the user confirmed the values, and the toggle cannot be turned on without the confirmation.
final class InstaraG1SafetyGateTests: XCTestCase {

    private let defaults = UserDefaults.standard

    private let touchedKeys = [
        UserDefaults.Key.isMaster.rawValue,
        UserDefaults.Key.transmitterTypeAsString.rawValue,
        UserDefaults.Key.instaraG1ExportVerified.rawValue,
        UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue,
        UserDefaults.Key.timeStampLatestLoopSharedBgReading.rawValue,
        UserDefaults.Key.timeStampLatestNSUploadedBgReadingToNightscout.rawValue,
        UserDefaults.Key.timeStampLatestHealthKitStoreBgReading.rawValue,
        UserDefaults.Key.timeStampLatestDexcomShareUploadedBgReading.rawValue,
        UserDefaults.Key.glucoseExportFloorTimeStamp.rawValue
    ]
    private var savedValues = [String: Any]()

    private let threeDaysAgo = Date(timeIntervalSinceNow: -3 * 86400)
    private let sensorStart = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        savedValues = [:]
        for key in touchedKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1ExportVerified.rawValue)
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue)
        defaults.isMaster = true
        defaults.set(CGMTransmitterType.instaraG1.rawValue, forKey: UserDefaults.Key.transmitterTypeAsString.rawValue)
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = savedValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func setAllCursors(_ date: Date) {
        defaults.timeStampLatestLoopSharedBgReading = date
        defaults.timeStampLatestNightscoutUploadedBgReading = date
        defaults.timeStampLatestHealthKitStoreBgReading = date
        defaults.timeStampLatestDexcomShareUploadedBgReading = date
        defaults.removeObject(forKey: UserDefaults.Key.glucoseExportFloorTimeStamp.rawValue)
    }

    // MARK: - gates

    func testExportAndAidBlockedWhenUnverified() {
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertFalse(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertEqual(defaults.activeOSAidSharingPolicy, .blocked)
        XCTAssertFalse(defaults.canConfigureOSAidSharing)
    }

    func testExportAndAidAllowedWhenVerified() {
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseExport)
        XCTAssertEqual(defaults.activeOSAidSharingPolicy, .allowed)
        XCTAssertTrue(defaults.canConfigureOSAidSharing)
    }

    func testValueAlarmsBlockedWhenUnverifiedButMissedReadingAllowed() {
        XCTAssertFalse(defaults.activeSourceAllowsGlucoseAlarms)
        for kind in AlertKind.allCases {
            XCTAssertEqual(
                AlertManager.alertIsPermitted(kind, sourceAllowsAlarms: defaults.activeSourceAllowsGlucoseAlarms),
                !AlertManager.glucoseValueAlertKinds.contains(kind),
                "\(kind)"
            )
        }
        XCTAssertTrue(AlertManager.alertIsPermitted(.missedreading, sourceAllowsAlarms: defaults.activeSourceAllowsGlucoseAlarms))
    }

    func testVeryLowAllowedWhenVerified() {
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        XCTAssertTrue(defaults.activeSourceAllowsGlucoseAlarms)
        XCTAssertTrue(AlertManager.alertIsPermitted(.verylow, sourceAllowsAlarms: defaults.activeSourceAllowsGlucoseAlarms))
    }

    // MARK: - export cursors

    func testEnablingAdvancesExportCursorsSoBacklogIsNotExported() {
        setAllCursors(threeDaysAgo)
        // a reading stored while the toggle was off
        let backlogReadingTime = Date(timeIntervalSinceNow: -60)
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        XCTAssertLessThan(backlogReadingTime, defaults.timeStampLatestNightscoutUploadedBgReading ?? .distantPast)
        XCTAssertLessThan(backlogReadingTime, defaults.timeStampLatestHealthKitStoreBgReading ?? .distantPast)
        XCTAssertLessThan(backlogReadingTime, defaults.timeStampLatestLoopSharedBgReading ?? .distantPast)
        XCTAssertLessThan(backlogReadingTime, defaults.timeStampLatestDexcomShareUploadedBgReading ?? .distantPast)
    }

    func testLeavingUnverifiedInstaraForOtherSourceAdvancesCursors() {
        setAllCursors(threeDaysAgo)
        let switchTime = Date()
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.dexcomG7.rawValue
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestNightscoutUploadedBgReading ?? .distantPast, switchTime)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestHealthKitStoreBgReading ?? .distantPast, switchTime)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestLoopSharedBgReading ?? .distantPast, switchTime)
        XCTAssertGreaterThanOrEqual(defaults.timeStampLatestDexcomShareUploadedBgReading ?? .distantPast, switchTime)
        XCTAssertGreaterThanOrEqual(defaults.glucoseExportFloorTimeStamp ?? .distantPast, switchTime)
    }

    func testLeavingVerifiedInstaraDoesNotAdvanceCursors() {
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        setAllCursors(threeDaysAgo)
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.dexcomG7.rawValue
        XCTAssertEqual(defaults.timeStampLatestNightscoutUploadedBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestHealthKitStoreBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestLoopSharedBgReading, threeDaysAgo)
        XCTAssertEqual(defaults.timeStampLatestDexcomShareUploadedBgReading, threeDaysAgo)
        XCTAssertNil(defaults.glucoseExportFloorTimeStamp)
    }

    // MARK: - restore check

    func testVerificationForOtherSensorIsRevokedOnRestore() {
        let t = sensorStart
        XCTAssertFalse(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: t, activeSensorStart: t.addingTimeInterval(2 * 3600)))
        XCTAssertTrue(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: t, activeSensorStart: t.addingTimeInterval(10 * 60)))
        XCTAssertTrue(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: t, activeSensorStart: t.addingTimeInterval(-30 * 60)))
        XCTAssertFalse(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: t, activeSensorStart: t.addingTimeInterval(30 * 60 + 1)))
        XCTAssertFalse(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: nil, activeSensorStart: t))
        XCTAssertFalse(RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: t, activeSensorStart: nil))
    }

    // MARK: - KVO

    func testToggleChangeNotifiesKVO() {
        let observer = KeyPathObserver()
        defaults.addObserver(observer, forKeyPath: UserDefaults.Key.instaraG1ExportVerified.rawValue, options: .new, context: nil)
        defer { defaults.removeObserver(observer, forKeyPath: UserDefaults.Key.instaraG1ExportVerified.rawValue) }

        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        XCTAssertEqual(observer.changeCount, 1)
        defaults.setInstaraG1Verified(false, sensorStart: nil, reason: "test")
        XCTAssertEqual(observer.changeCount, 2)

        let typed = expectation(description: "typed KVO change")
        let observation = defaults.observe(\.instaraG1ExportVerified, options: [.new]) { _, change in
            if change.newValue == true { typed.fulfill() }
        }
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        wait(for: [typed], timeout: 1)
        observation.invalidate()
    }

    // MARK: - setter binding

    func testOnToOnWithNilSensorStartKeepsBinding() {
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        XCTAssertTrue(defaults.instaraG1ExportVerified)
        XCTAssertEqual(defaults.instaraG1VerifiedSensorStart, sensorStart)

        // an explicit new start on on→on still replaces the binding
        let other = sensorStart.addingTimeInterval(600)
        defaults.setInstaraG1Verified(true, sensorStart: other, reason: "test")
        XCTAssertEqual(defaults.instaraG1VerifiedSensorStart, other)
    }

    // MARK: - toggle needs the confirmation

    func testTurningOnRequiresConfirmation() throws {
        var refreshCount = 0
        let alert = InstaraG1VerificationToggle.handleChange(to: true, activeSensorStart: sensorStart, defaults: defaults) { refreshCount += 1 }

        // nothing changes before the user confirms
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertFalse(defaults.activeSourceAllowsGlucoseExport)

        let confirmation = try XCTUnwrap(alert)
        XCTAssertEqual(confirmation.title, Texts_BluetoothPeripheralView.instaraG1VerificationConfirmTitle)
        XCTAssertEqual(confirmation.message, "Bu sensörün değerlerini resmi Instara uygulamasıyla karşılaştırdım ve tutarlı buldum. Değerler Loop'ta insülin dozlamasında kullanılacak. Yeni sensörde bu onay sıfırlanır.")
        XCTAssertEqual(confirmation.primaryButtonTitle, Texts_BluetoothPeripheralView.instaraG1VerificationConfirm)
        XCTAssertEqual(confirmation.secondaryButtonTitle, Texts_BluetoothPeripheralView.instaraG1VerificationCancel)

        confirmation.primaryAction?()
        XCTAssertTrue(defaults.instaraG1ExportVerified)
        XCTAssertEqual(defaults.instaraG1VerifiedSensorStart, sensorStart)
        XCTAssertGreaterThan(refreshCount, 0)
    }

    func testCancellingConfirmationKeepsToggleOff() {
        var refreshCount = 0
        let alert = InstaraG1VerificationToggle.handleChange(to: true, activeSensorStart: sensorStart, defaults: defaults) { refreshCount += 1 }
        alert?.secondaryAction?()
        XCTAssertNotNil(alert)
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertNil(defaults.instaraG1VerifiedSensorStart)
        // the switch is redrawn as off
        XCTAssertGreaterThan(refreshCount, 0)
    }

    func testTurningOnWithoutActiveSensorIsImpossible() {
        let alert = InstaraG1VerificationToggle.handleChange(to: true, activeSensorStart: nil, defaults: defaults) {}
        XCTAssertNil(alert)
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertFalse(InstaraG1VerificationToggle.isEnabled(activeSensorStart: nil))
        XCTAssertEqual(InstaraG1VerificationToggle.footer(activeSensorStart: nil), Texts_BluetoothPeripheralView.instaraG1VerificationNeedsSensorData)
        XCTAssertTrue(InstaraG1VerificationToggle.isEnabled(activeSensorStart: sensorStart))
    }

    func testTurningOffNeedsNoConfirmation() {
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        let alert = InstaraG1VerificationToggle.handleChange(to: false, activeSensorStart: sensorStart, defaults: defaults) {}
        XCTAssertNil(alert)
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertNil(defaults.instaraG1VerifiedSensorStart)
    }

    func testToggleTexts() {
        XCTAssertEqual(Texts_BluetoothPeripheralView.instaraG1VerificationToggle, "Değerleri doğruladım — Loop ve paylaşımı aç")
        XCTAssertEqual(Texts_BluetoothPeripheralView.instaraG1VerificationConfirmTitle, "Değerleri doğruladınız mı?")
        XCTAssertEqual(Texts_BluetoothPeripheralView.instaraG1VerificationConfirm, "Onaylıyorum")
        XCTAssertEqual(Texts_BluetoothPeripheralView.instaraG1VerificationCancel, "Vazgeç")
        XCTAssertEqual(Texts_BluetoothPeripheralView.instaraG1VerificationNeedsSensorData, "Önce sensör verisi gelmeli")
    }
}

private final class KeyPathObserver: NSObject {
    private(set) var changeCount = 0

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changeCount += 1
    }
}
