import CoreData
import XCTest
@testable import xdrip

final class SibionicsGS1TypePolicyTests: XCTestCase {

    func testSibionicsTypeIsBlockedFromAid() {
        XCTAssertEqual(CGMTransmitterType.sibionicsGS1.osAidSharingPolicy, .blocked)
    }

    func testSibionicsDisallowsExportAndAlarms() {
        XCTAssertFalse(CGMTransmitterType.sibionicsGS1.allowsGlucoseExport)
        XCTAssertFalse(CGMTransmitterType.sibionicsGS1.allowsGlucoseAlarms)
        XCTAssertTrue(CGMTransmitterType.dexcomG7.allowsGlucoseExport)
        XCTAssertTrue(CGMTransmitterType.dexcomG7.allowsGlucoseAlarms)

        for transmitter in CGMTransmitterType.allCases where transmitter != .sibionicsGS1 {
            XCTAssertTrue(transmitter.allowsGlucoseExport, transmitter.rawValue)
            XCTAssertTrue(transmitter.allowsGlucoseAlarms, transmitter.rawValue)
        }
    }

    func testSibionicsDetectsNewSensor() {
        let type = CGMTransmitterType.sibionicsGS1
        XCTAssertTrue(type.canDetectNewSensor())
        XCTAssertFalse(type.allowManualSensorStart())
        XCTAssertEqual(type.sensorType(), .Sibionics)
        XCTAssertEqual(type.detailedDescription(), "Sibionics GS1 (experimental, passive)")
    }

    func testSibionicsPeripheralTypeFlags() {
        let type = BluetoothPeripheralType.SibionicsGS1Type
        XCTAssertEqual(type.category(), .CGM)
        XCTAssertFalse(type.needsTransmitterId())
        XCTAssertFalse(type.canWebOOP())
        XCTAssertFalse(type.canUseNonFixedSlope())
        XCTAssertFalse(type.needsNFCScanToConnect())
        XCTAssertFalse(type.usesIntermittentConnection)
        XCTAssertEqual(type.bluetoothPeripheralDisplayTitle, "Sibionics GS1 (Deneysel, resmi uygulamayla)")
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(BluetoothPeripheralType.SibionicsGS1Type.rawValue, "Sibionics GS1")
        XCTAssertEqual(CGMTransmitterType.sibionicsGS1.rawValue, "Sibionics GS1")
        XCTAssertEqual(CGMSensorType.Sibionics.rawValue, "Sibionics")
    }

    func testCreateNewBluetoothPeripheralReturnsSibionicsGS1() throws {
        let context = try makeInMemoryContext()
        let peripheral = BluetoothPeripheralType.SibionicsGS1Type.createNewBluetoothPeripheral(
            withAddress: "AA:BB", withName: "GS1", nsManagedObjectContext: context)

        let gs1 = try XCTUnwrap(peripheral as? SibionicsGS1)
        XCTAssertEqual(gs1.bluetoothPeripheralType(), .SibionicsGS1Type)
        XCTAssertNil(gs1.firmware)
        XCTAssertTrue(gs1.blePeripheral.sibionicsGS1 === gs1)
        XCTAssertEqual(gs1.blePeripheral.address, "AA:BB")
    }

    func testModelV38SupportsLightweightMigrationFromV37() throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let previous = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v37.mom")))
        let current = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v38.mom")))
        XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: previous, destinationModel: current))

        let entity = try XCTUnwrap(current.entitiesByName["SibionicsGS1"])
        XCTAssertTrue(try XCTUnwrap(entity.attributesByName["firmware"]).isOptional)
        let toBLE = try XCTUnwrap(entity.relationshipsByName["blePeripheral"])
        XCTAssertEqual(toBLE.destinationEntity?.name, "BLEPeripheral")
        XCTAssertEqual(toBLE.inverseRelationship?.name, "sibionicsGS1")

        let fromBLE = try XCTUnwrap(current.entitiesByName["BLEPeripheral"]?.relationshipsByName["sibionicsGS1"])
        XCTAssertTrue(fromBLE.isOptional)
        XCTAssertEqual(fromBLE.deleteRule, .cascadeDeleteRule)
        XCTAssertEqual(fromBLE.destinationEntity?.name, "SibionicsGS1")
    }

    private func makeInMemoryContext() throws -> NSManagedObjectContext {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: directory.appendingPathComponent("xdrip v38.mom")))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
