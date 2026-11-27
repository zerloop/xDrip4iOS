import CoreData
import XCTest
@testable import xdrip

final class InstaraG1TypePolicyTests: XCTestCase {

    private let defaults = UserDefaults.standard

    private let touchedKeys = [
        UserDefaults.Key.instaraG1ExportVerified.rawValue,
        UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue,
        UserDefaults.Key.timeStampLatestLoopSharedBgReading.rawValue,
        UserDefaults.Key.timeStampLatestNSUploadedBgReadingToNightscout.rawValue,
        UserDefaults.Key.timeStampLatestHealthKitStoreBgReading.rawValue,
        UserDefaults.Key.timeStampLatestDexcomShareUploadedBgReading.rawValue,
        UserDefaults.Key.glucoseExportFloorTimeStamp.rawValue
    ]
    private var savedValues = [String: Any]()

    override func setUp() {
        super.setUp()
        savedValues = [:]
        for key in touchedKeys {
            savedValues[key] = defaults.object(forKey: key)
        }
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1ExportVerified.rawValue)
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue)
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

    // MARK: - verification driven policy

    func testUnverifiedIsBlocked() {
        defaults.setInstaraG1Verified(false, sensorStart: nil, reason: "test")
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertEqual(CGMTransmitterType.instaraG1.osAidSharingPolicy, .blocked)
        XCTAssertFalse(CGMTransmitterType.instaraG1.allowsGlucoseExport)
        XCTAssertFalse(CGMTransmitterType.instaraG1.allowsGlucoseAlarms)
    }

    func testVerifiedIsAllowed() {
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        XCTAssertTrue(defaults.instaraG1ExportVerified)
        XCTAssertEqual(CGMTransmitterType.instaraG1.osAidSharingPolicy, .allowed)
        XCTAssertTrue(CGMTransmitterType.instaraG1.allowsGlucoseExport)
        XCTAssertTrue(CGMTransmitterType.instaraG1.allowsGlucoseAlarms)
    }

    func testSibionicsUnaffectedByInstaraToggle() {
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        XCTAssertEqual(CGMTransmitterType.sibionicsGS1.osAidSharingPolicy, .blocked)
        XCTAssertFalse(CGMTransmitterType.sibionicsGS1.allowsGlucoseExport)
        XCTAssertFalse(CGMTransmitterType.sibionicsGS1.allowsGlucoseAlarms)
    }

    func testVerifiedIsKVOObservable() {
        let changed = expectation(description: "KVO change for instaraG1ExportVerified")
        let observation = defaults.observe(\.instaraG1ExportVerified, options: [.new]) { _, change in
            if change.newValue == true {
                changed.fulfill()
            }
        }
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        wait(for: [changed], timeout: 1)
        observation.invalidate()
    }

    // MARK: - export cursors

    private func setAllCursors(_ date: Date) {
        defaults.timeStampLatestLoopSharedBgReading = date
        defaults.timeStampLatestNightscoutUploadedBgReading = date
        defaults.timeStampLatestHealthKitStoreBgReading = date
        defaults.timeStampLatestDexcomShareUploadedBgReading = date
        defaults.glucoseExportFloorTimeStamp = date
    }

    private func allCursors() -> [String: Date] {
        return [
            "loop": defaults.timeStampLatestLoopSharedBgReading ?? .distantPast,
            "nightscout": defaults.timeStampLatestNightscoutUploadedBgReading ?? .distantPast,
            "healthkit": defaults.timeStampLatestHealthKitStoreBgReading ?? .distantPast,
            "dexcom share": defaults.timeStampLatestDexcomShareUploadedBgReading ?? .distantPast,
            "floor": defaults.glucoseExportFloorTimeStamp ?? .distantPast
        ]
    }

    func testEnablingAdvancesExportCursors() {
        setAllCursors(.distantPast)

        let callTime = Date()
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        for (name, cursor) in allCursors() {
            XCTAssertGreaterThanOrEqual(cursor, callTime, name)
        }

        // on -> on must not advance the cursors again
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        setAllCursors(fixed)
        defaults.setInstaraG1Verified(true, sensorStart: nil, reason: "test")
        for (name, cursor) in allCursors() {
            XCTAssertEqual(cursor, fixed, name)
        }
    }

    func testDisablingClearsSensorBinding() {
        let sensorStart = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.setInstaraG1Verified(true, sensorStart: sensorStart, reason: "test")
        XCTAssertTrue(defaults.instaraG1ExportVerified)
        XCTAssertEqual(defaults.instaraG1VerifiedSensorStart, sensorStart)

        defaults.setInstaraG1Verified(false, sensorStart: sensorStart, reason: "test")
        XCTAssertFalse(defaults.instaraG1ExportVerified)
        XCTAssertNil(defaults.instaraG1VerifiedSensorStart)
    }

    // MARK: - backup

    func testInstaraKeysExcludedFromBackup() {
        XCTAssertFalse(BackupService.isPortableSetting("instaraG1ExportVerified"))
        XCTAssertFalse(BackupService.isPortableSetting("instaraG1VerifiedSensorStart"))
        XCTAssertFalse(BackupService.isPortableSetting("instaraG1ExperimentalWarningAcknowledged"))
        XCTAssertFalse(BackupService.isPortableSetting("instaraG1.lastSequenceNumber"))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.instaraG1ExportVerified.rawValue))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.instaraG1ExperimentalWarningAcknowledged.rawValue))
    }

    // MARK: - type

    func testRawValuesAreStable() {
        XCTAssertEqual(BluetoothPeripheralType.InstaraG1Type.rawValue, "Instara G1")
        XCTAssertEqual(CGMTransmitterType.instaraG1.rawValue, "Instara G1")
        XCTAssertEqual(CGMSensorType.Instara.rawValue, "Instara")
        XCTAssertEqual(UserDefaults.Key.instaraG1ExportVerified.rawValue, "instaraG1ExportVerified")
        XCTAssertEqual(UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue, "instaraG1VerifiedSensorStart")
    }

    func testTypeDetectsNewSensor() {
        let type = CGMTransmitterType.instaraG1
        XCTAssertEqual(type.sensorType(), .Instara)
        XCTAssertTrue(type.canDetectNewSensor())
        XCTAssertFalse(type.allowManualSensorStart())
        XCTAssertEqual(type.detailedDescription(), "Instara G1 (experimental, passive)")
    }

    func testPeripheralTypeFlags() {
        let type = BluetoothPeripheralType.InstaraG1Type
        XCTAssertEqual(type.category(), .CGM)
        XCTAssertFalse(type.needsTransmitterId())
        XCTAssertFalse(type.canWebOOP())
        XCTAssertFalse(type.canUseNonFixedSlope())
        XCTAssertFalse(type.needsNFCScanToConnect())
        XCTAssertFalse(type.usesIntermittentConnection)
        XCTAssertEqual(type.bluetoothPeripheralDisplayTitle, "Instara-1 / Perlanova (Deneysel, resmi uygulamayla)")
    }

    // MARK: - data model

    func testCreateNewBluetoothPeripheralReturnsInstaraG1() throws {
        let context = try makeInMemoryContext()
        let peripheral = BluetoothPeripheralType.InstaraG1Type.createNewBluetoothPeripheral(
            withAddress: "AA:BB", withName: "G1", nsManagedObjectContext: context)

        let g1 = try XCTUnwrap(peripheral as? InstaraG1)
        XCTAssertEqual(g1.bluetoothPeripheralType(), .InstaraG1Type)
        XCTAssertNil(g1.firmware)
        XCTAssertTrue(g1.blePeripheral.instaraG1 === g1)
        XCTAssertEqual(g1.blePeripheral.address, "AA:BB")
    }

    func testModelV39SupportsLightweightMigrationFromV38() throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let previous = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v38.mom")))
        let current = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v39.mom")))
        XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: previous, destinationModel: current))

        let entity = try XCTUnwrap(current.entitiesByName["InstaraG1"])
        XCTAssertTrue(try XCTUnwrap(entity.attributesByName["firmware"]).isOptional)
        let toBLE = try XCTUnwrap(entity.relationshipsByName["blePeripheral"])
        XCTAssertEqual(toBLE.destinationEntity?.name, "BLEPeripheral")
        XCTAssertEqual(toBLE.inverseRelationship?.name, "instaraG1")

        let fromBLE = try XCTUnwrap(current.entitiesByName["BLEPeripheral"]?.relationshipsByName["instaraG1"])
        XCTAssertTrue(fromBLE.isOptional)
        XCTAssertEqual(fromBLE.deleteRule, .cascadeDeleteRule)
        XCTAssertEqual(fromBLE.destinationEntity?.name, "InstaraG1")

        // Sibionics stays as it was in v38
        XCTAssertNotNil(current.entitiesByName["BLEPeripheral"]?.relationshipsByName["sibionicsGS1"])
    }

    private func makeInMemoryContext() throws -> NSManagedObjectContext {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v39.mom")))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
