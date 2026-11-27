//
//  BluetoothPeripheralDisplayStatusTests.swift
//  xdripTests
//

import XCTest
import CoreBluetooth
@testable import xdrip

/// Generic heartbeat policy tests need no sensor and never alter the app's real preferences.
final class GenericHeartbeatSubscriptionTests: XCTestCase {
    private func channel(_ uuid: String, _ properties: CBCharacteristicProperties = .notify, service: String = "1234") -> GenericHeartbeatChannel {
        GenericHeartbeatChannel(service: service, characteristic: uuid, properties: properties)
    }

    func testCapabilityFilteringAndDeterministicRanking() {
        // Standard measurements win over arbitrary notify channels, then indication-only channels.
        let candidates = [channel("3333", .indicate), channel("1111"), channel("2AA7"), channel("2222", .read), channel("2A19", [.read, .notify], service: "180F")]
        let expected = ["1234/2AA7", "1234/1111", "1234/3333"]
        XCTAssertEqual(GenericHeartbeatChannel.ordered(candidates).map(\.id), expected)
        XCTAssertEqual(GenericHeartbeatChannel.ordered(candidates.reversed()).map(\.id), expected)
    }

    func testDuplicateUUIDPairsAreExcluded() {
        // A UUID pair must identify one physical characteristic, even in All mode.
        XCTAssertTrue(GenericHeartbeatChannel.ordered([channel("2222"), channel("2222")]).isEmpty)
    }

    func testAutomaticFallbackRequiresExplicitFailureAndStopsAfterSuccess() {
        // Silence leaves the first request pending; only its explicit failure opens the next candidate.
        var state = GenericHeartbeatSubscriptions()
        XCTAssertEqual(state.next(["a", "b"], mode: .automatic), ["a"])
        XCTAssertTrue(state.next(["a", "b"], mode: .automatic).isEmpty)
        XCTAssertEqual(state.outcome, "pending")
        XCTAssertTrue(state.complete("a", success: false))
        XCTAssertEqual(state.next(["a", "b"], mode: .automatic), ["b"])
        // A duplicate failure must not abandon the channel currently awaiting confirmation.
        XCTAssertFalse(state.complete("a", success: false))
        XCTAssertTrue(state.complete("b", success: true))
        XCTAssertTrue(state.next(["a", "b", "c"], mode: .automatic).isEmpty)
        XCTAssertEqual(state.outcome, "subscribed")
    }

    func testExhaustionAndSessionResetAreBounded() {
        // Exhausted candidates stay exhausted for this connection, without a retry loop.
        var state = GenericHeartbeatSubscriptions()
        XCTAssertEqual(state.next(["a"], mode: .automatic), ["a"])
        state.complete("a", success: false)
        XCTAssertTrue(state.next(["a"], mode: .automatic).isEmpty)
        XCTAssertEqual(state.outcome, "failed")
        // A new connection discards the old pending confirmations before discovery resumes.
        state = GenericHeartbeatSubscriptions()
        XCTAssertFalse(state.complete("a", success: true))
        XCTAssertEqual(state.next(["a"], mode: .automatic), ["a"])
    }

    func testCompatibilityModeRequestsEachSupportedChannelOnlyOnce() {
        // All may request multiple channels, but repeated discovery must not request them again.
        var state = GenericHeartbeatSubscriptions()
        XCTAssertEqual(state.next(["a", "b"], mode: .all), ["a", "b"])
        state.complete("a", success: true)
        XCTAssertTrue(state.next(["a", "b"], mode: .all).isEmpty)
        state.complete("b", success: false)
        XCTAssertEqual(state.subscribed, ["a"])
    }

    func testPerDevicePersistenceDefaultsAndRemoval() throws {
        // Isolate storage and clean up even when an assertion fails.
        let suite = "GenericHeartbeatTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GenericHeartbeatSettings.load("one", defaults: defaults), GenericHeartbeatSettings())
        var settings = GenericHeartbeatSettings()
        // Decode the old experimental format without reviving manual or battery controls.
        defaults.set(Data(#"{"mode":"selected","characteristic":"1234/2AA7","readBattery":false}"#.utf8), forKey: "genericHeartbeat.ONE")
        settings.mode = .automatic
        XCTAssertEqual(GenericHeartbeatSettings.load("ONE", defaults: defaults), settings)
        XCTAssertEqual(GenericHeartbeatSettings.load("one", defaults: defaults), settings)
        // Saving the simplified format must round-trip the existing Single choice.
        settings.save("one", defaults: defaults)
        XCTAssertEqual(GenericHeartbeatSettings.load("ONE", defaults: defaults), settings)
        XCTAssertEqual(GenericHeartbeatSettings.load("two", defaults: defaults), GenericHeartbeatSettings())
        GenericHeartbeatSettings.remove("one", defaults: defaults)
        XCTAssertEqual(GenericHeartbeatSettings.load("one", defaults: defaults), GenericHeartbeatSettings())
        defaults.set(Data("invalid".utf8), forKey: "genericHeartbeat.ONE")
        XCTAssertEqual(GenericHeartbeatSettings.load("one", defaults: defaults), GenericHeartbeatSettings())
    }

    func testSimplifiedPickerContainsOnlyCompatibleAndAutomaticModes() {
        // The persisted automatic value represents Single; no hidden third mode remains.
        XCTAssertEqual(GenericHeartbeatSettings.Mode.allCases, [.all, .automatic])
    }

    func testSupportLabelsMatchTheTwoSubscriptionChoices() {
        // Keep support files readable without renaming the persisted automatic preference.
        XCTAssertEqual(GenericHeartbeatSettings.Mode.automatic.rawValue, "automatic")
        XCTAssertEqual(GenericHeartbeatSettings.Mode.automatic.logDescription, "Single")
        XCTAssertEqual(GenericHeartbeatSettings.Mode.all.logDescription, "All")
    }

    func testUnexpectedStateChangesDoNotCompletePendingRequests() {
        var state = GenericHeartbeatSubscriptions()
        XCTAssertEqual(state.next(["a", "b"], mode: .automatic), ["a"])
        // An unsolicited channel may become active, but must not consume the pending request.
        state.observe("b", isNotifying: true)
        XCTAssertEqual(state.pending, ["a"])
        XCTAssertEqual(state.subscribed, ["b"])
        XCTAssertFalse(state.complete("b", success: false))
        state.observe("b", isNotifying: false)
        XCTAssertTrue(state.subscribed.isEmpty)
        XCTAssertEqual(state.pending, ["a"])
        XCTAssertTrue(state.next(["a", "b"], mode: .automatic).isEmpty)
    }
}

final class BluetoothPeripheralDisplayStatusTests: XCTestCase {
    func testConnectedTakesPrecedenceOverEveryOtherInput() {
        XCTAssertEqual(status(isConnected: true), .connected)
    }

    func testExplicitNewDeviceDiscoveryTakesPrecedenceOverInactiveState() {
        XCTAssertEqual(status(isDiscovering: true), .discovering)
    }

    func testDisabledPeripheralIsNotScanning() {
        XCTAssertEqual(status(), .notScanning)
    }

    func testEnabledPeripheralConnectsUntilFirstSuccess() {
        XCTAssertEqual(status(isEnabled: true), .connecting)
    }

    func testPreviouslyConnectedIntermittentDexcomWaitsForNextReading() {
        XCTAssertEqual(
            status(isEnabled: true, hasConnected: true, isIntermittent: true),
            .waitingForNextReading
        )
    }

    func testRelaunchedIntermittentDexcomRetainsWaitingState() {
        XCTAssertEqual(
            status(isEnabled: true, hasConnected: true, isIntermittent: true),
            .waitingForNextReading
        )
    }

    func testHealthyDexcomWaitingShowsElapsedTimer() {
        XCTAssertTrue(BluetoothPeripheralDisplayStatus.waitingForNextReading.showsElapsedTime)
        XCTAssertFalse(BluetoothPeripheralDisplayStatus.connected.showsElapsedTime)
        XCTAssertFalse(BluetoothPeripheralDisplayStatus.notScanning.showsElapsedTime)
    }

    func testManualReactivationReturnsToConnectingUntilAnotherSuccess() {
        XCTAssertEqual(
            status(isEnabled: true, hasConnected: false, isIntermittent: true),
            .connecting
        )
    }

    func testPreviouslyConnectedContinuousPeripheralIsReconnecting() {
        XCTAssertEqual(
            status(isEnabled: true, hasConnected: true, isIntermittent: false),
            .reconnecting
        )
    }

    func testOnlyDirectAndHeartbeatDexcomTypesUseIntermittentPresentation() {
        XCTAssertTrue(BluetoothPeripheralType.DexcomType.usesIntermittentConnection)
        XCTAssertTrue(BluetoothPeripheralType.DexcomG7Type.usesIntermittentConnection)
        XCTAssertTrue(BluetoothPeripheralType.DexcomG7HeartBeatType.usesIntermittentConnection)

        XCTAssertFalse(BluetoothPeripheralType.Libre2Type.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.MiaoMiaoType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.BubbleType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.Libre3HeartBeatType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.OmniPodHeartBeatType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.MedtrumTouchCareNanoType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.SibionicsGS1Type.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.InstaraG1Type.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.M5StackType.usesIntermittentConnection)
        XCTAssertFalse(BluetoothPeripheralType.M5StickCType.usesIntermittentConnection)
    }

    func testNewPeripheralPersistsFalseActivationSuccessByDefault() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let dexcom = DexcomG5(
            address: "test-dexcom",
            name: "Dexcom",
            alias: nil,
            nsManagedObjectContext: coreDataManager.mainManagedObjectContext
        )

        XCTAssertTrue(dexcom.blePeripheral.shouldconnect)
        XCTAssertFalse(dexcom.blePeripheral.hasConnectedSinceActivation)

        coreDataManager.saveChanges()
        let objectID = dexcom.blePeripheral.objectID
        coreDataManager.mainManagedObjectContext.reset()

        let restored = try XCTUnwrap(
            coreDataManager.mainManagedObjectContext.existingObject(with: objectID) as? BLEPeripheral
        )
        XCTAssertFalse(restored.hasConnectedSinceActivation)
    }

    func testManagerRecordsDirectAndHeartbeatSuccessAndResetsOnlyOnActivationChange() {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = ConnectionStatusCGMDelegateStub()
        var presentationRefreshCount = 0
        let manager = BluetoothPeripheralManager(
            coreDataManager: coreDataManager,
            cgmTransmitterDelegate: delegate,
            messageHandler: { _, _ in },
            heartBeatFunction: nil,
            cgmTransmitterInfoChanged: {},
            connectionPresentationChanged: { presentationRefreshCount += 1 }
        )
        let context = coreDataManager.mainManagedObjectContext
        let g6 = DexcomG5(address: "test-g6", name: "Dexcom", alias: nil, nsManagedObjectContext: context)
        let g7 = DexcomG7(address: "test-g7", name: "Dexcom", alias: nil, nsManagedObjectContext: context)
        let heartbeat = DexcomG7HeartBeat(address: "test-heartbeat", name: "Dexcom", alias: nil, nsManagedObjectContext: context)

        manager.recordSuccessfulConnection(for: g6)
        manager.recordSuccessfulConnection(for: g7)
        manager.recordSuccessfulConnection(for: heartbeat)

        XCTAssertTrue(g6.blePeripheral.hasConnectedSinceActivation)
        XCTAssertTrue(g7.blePeripheral.hasConnectedSinceActivation)
        XCTAssertTrue(heartbeat.blePeripheral.hasConnectedSinceActivation)

        manager.recordDisconnection(for: g6)
        XCTAssertTrue(g6.blePeripheral.hasConnectedSinceActivation)
        manager.setConnectionEnabled(false, for: g6)
        XCTAssertFalse(g6.blePeripheral.hasConnectedSinceActivation)
        manager.setConnectionEnabled(true, for: g6)
        XCTAssertFalse(g6.blePeripheral.hasConnectedSinceActivation)
        XCTAssertEqual(presentationRefreshCount, 6)
    }

    func testManualDisconnectPreservesG6AndG7TransmitterSensorMetadata() {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = ConnectionStatusCGMDelegateStub()
        let manager = BluetoothPeripheralManager(
            coreDataManager: coreDataManager,
            cgmTransmitterDelegate: delegate,
            messageHandler: { _, _ in },
            heartBeatFunction: nil,
            cgmTransmitterInfoChanged: {}
        )
        let context = coreDataManager.mainManagedObjectContext
        let g6 = DexcomG5(address: "test-g6", name: "Dexcom", alias: nil, nsManagedObjectContext: context)
        let g7 = DexcomG7(address: "test-g7", name: "Dexcom", alias: nil, nsManagedObjectContext: context)
        let sensorStartDate = Date(timeIntervalSince1970: 1_800_000_000)
        g6.sensorStartDate = sensorStartDate
        g7.sensorStartDate = sensorStartDate

        manager.setConnectionEnabled(false, for: g6)
        manager.setConnectionEnabled(false, for: g7)

        XCTAssertEqual(g6.sensorStartDate, sensorStartDate)
        XCTAssertEqual(g7.sensorStartDate, sensorStartDate)
    }

    private func status(
        isConnected: Bool = false,
        isEnabled: Bool = false,
        hasConnected: Bool = false,
        isIntermittent: Bool = false,
        isDiscovering: Bool = false
    ) -> BluetoothPeripheralDisplayStatus {
        BluetoothPeripheralDisplayStatus(
            isConnected: isConnected,
            isEnabled: isEnabled,
            hasConnectedSinceActivation: hasConnected,
            usesIntermittentConnection: isIntermittent,
            isDiscoveringNewPeripheral: isDiscovering
        )
    }
}

final class StandardBluetoothBatteryLevelTests: XCTestCase {
    func testParsesValidStandardBatteryPercentages() {
        // EmaLink/OrangeLink-compatible Battery Service values include both boundary percentages.
        XCTAssertEqual(StandardBluetoothBatteryLevel.percentage(from: Data([0])), 0)
        XCTAssertEqual(StandardBluetoothBatteryLevel.percentage(from: Data([57])), 57)
        XCTAssertEqual(StandardBluetoothBatteryLevel.percentage(from: Data([100])), 100)
    }

    func testRejectsMissingMalformedAndOutOfRangeBatteryValues() {
        XCTAssertNil(StandardBluetoothBatteryLevel.percentage(from: nil))
        XCTAssertNil(StandardBluetoothBatteryLevel.percentage(from: Data()))
        XCTAssertNil(StandardBluetoothBatteryLevel.percentage(from: Data([50, 51])))
        XCTAssertNil(StandardBluetoothBatteryLevel.percentage(from: Data([101])))
    }

    func testPresentationIsInvisibleUntilAValidLevelExists() {
        // Absence stays invisible for normal heartbeat users, while a genuine empty battery must
        // remain distinguishable from an unsupported EmaLink or OrangeLink battery service.
        XCTAssertNil(BluetoothBatteryLevelPresentation.detail(for: nil))
        XCTAssertNil(BluetoothBatteryLevelPresentation.detail(for: -1))
        XCTAssertNil(BluetoothBatteryLevelPresentation.detail(for: 101))
        XCTAssertEqual(BluetoothBatteryLevelPresentation.detail(for: 0), "0 %")
        XCTAssertEqual(BluetoothBatteryLevelPresentation.detail(for: 57), "57 %")
    }
}

private final class ConnectionStatusCGMDelegateStub: CGMTransmitterDelegate {
    func newSensorDetected(sensorStartDate: Date?) {}
    func sensorStopDetected() {}
    func sensorNotDetected() {}
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {}
    func errorOccurred(xDripError: XdripError) {}
}

/// App-wide wiring of the passive Sibionics GS1 co-listener: manager, add flow, warning and diagnostics.
final class SibionicsGS1WiringTests: XCTestCase {

    /// the manager holds its CGM delegate weakly
    private let cgmDelegate = ConnectionStatusCGMDelegateStub()

    private func makeManager(_ coreDataManager: CoreDataManager) -> BluetoothPeripheralManager {
        BluetoothPeripheralManager(
            coreDataManager: coreDataManager,
            cgmTransmitterDelegate: cgmDelegate,
            messageHandler: { _, _ in },
            heartBeatFunction: nil,
            cgmTransmitterInfoChanged: {}
        )
    }

    func testAddFlowCreatesThePassiveSibionicsTransmitter() {
        let manager = makeManager(CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName))

        let transmitter = manager.createNewTransmitter(type: .SibionicsGS1Type, transmitterId: nil, dexcomG6BluetoothSlot: .defaultSlot, bluetoothTransmitterDelegate: nil)
        defer { transmitter.prepareForRelease() }

        XCTAssertTrue(transmitter is CGMSibionicsGS1Transmitter)
        XCTAssertEqual(manager.getTransmitterType(for: transmitter), .SibionicsGS1Type)
    }

    func testStoredSibionicsPeripheralGetsItsTransmitter() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let gs1 = SibionicsGS1(address: "test-gs1", name: "GS1", alias: nil, nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        // disabled, so loading it does not select it as the app's CGM source
        gs1.blePeripheral.shouldconnect = false
        coreDataManager.saveChanges()

        let manager = makeManager(coreDataManager)
        XCTAssertNil(manager.getBluetoothTransmitter(for: gs1, createANewOneIfNecesssary: false))

        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: gs1, createANewOneIfNecesssary: true))
        defer { transmitter.prepareForRelease() }

        XCTAssertTrue(transmitter is CGMSibionicsGS1Transmitter)
        XCTAssertEqual(transmitter.deviceAddress, "test-gs1")
    }

    func testAddFlowKeepsWaitingForTheOfficialAppConnection() {
        // the passive transmitter never scans, it reports alreadyScanning/connecting while it retrieves with back-off
        for result: BluetoothTransmitter.startScanningResult in [.alreadyScanning, .connecting] {
            XCTAssertTrue(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .SibionicsGS1Type, scanningResult: result))
        }
        XCTAssertFalse(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .SibionicsGS1Type, scanningResult: .poweredOff))
        XCTAssertFalse(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .DexcomType, scanningResult: .alreadyScanning))
        XCTAssertTrue(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .Libre3Type, scanningResult: .connecting))
    }

    func testAddFlowFooterAsksToOpenTheOfficialApp() {
        XCTAssertEqual(
            BluetoothPeripheralDetailState.sibionicsGS1AddFlowFooter(type: .SibionicsGS1Type, hasPeripheral: false, isWaiting: true),
            "Resmi Sibionics uygulamasını açın ve sensörün bağlı olduğundan emin olun."
        )
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1AddFlowFooter(type: .SibionicsGS1Type, hasPeripheral: true, isWaiting: false))
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1AddFlowFooter(type: .Libre2Type, hasPeripheral: false, isWaiting: true))
    }

    func testTransmitterStatusTextsAreLocalised() {
        XCTAssertEqual(CGMSibionicsGS1Transmitter.officialAppNotConnectedMessage, Texts_BluetoothPeripheralView.sibionicsGS1StatusOfficialAppNotConnected)
        XCTAssertEqual(CGMSibionicsGS1Transmitter.receivingMessage, Texts_BluetoothPeripheralView.sibionicsGS1StatusReceiving)
    }

    func testExperimentalWarningTextMatchesTheSpec() {
        XCTAssertEqual(
            Texts_BluetoothPeripheralView.sibionicsGS1ExperimentalWarning,
            "Bu deneysel bir özelliktir. Değerler parmak ucu ile kalibre edilir ve resmi uygulamadan sapabilir. Tedavi kararlarınızı resmi uygulamaya göre verin. Resmi Sibionics uygulamasını kapatmayın."
        )
    }

    func testExperimentalWarningIsShownOnlyOnce() throws {
        let suite = "SibionicsGS1WiringTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(defaults.sibionicsGS1ExperimentalWarningAcknowledged)
        XCTAssertNotNil(BluetoothPeripheralDetailState.sibionicsGS1ExperimentalWarningNotice(type: .SibionicsGS1Type, defaults: defaults))
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1ExperimentalWarningNotice(type: .MedtrumTouchCareNanoType, defaults: defaults))

        defaults.sibionicsGS1ExperimentalWarningAcknowledged = true
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1ExperimentalWarningNotice(type: .SibionicsGS1Type, defaults: defaults))
    }

    func testSibionicsRuntimeStateIsNotPortableInBackups() {
        XCTAssertFalse(BackupService.isPortableSetting("sibionicsGS1.lastReceivedIndex"))
        XCTAssertFalse(BackupService.isPortableSetting("sibionicsGS1.sensorStartDate"))
        XCTAssertFalse(BackupService.isPortableSetting(UserDefaults.Key.sibionicsGS1ExperimentalWarningAcknowledged.rawValue))
    }

    func testDiagnosticsRowsAreReadOnlyAndOrdered() {
        var diagnostics = SibionicsGS1Diagnostics()
        diagnostics.firmware = .v120
        diagnostics.batteryPercent = 87
        diagnostics.lastIndex = 1234
        diagnostics.lastRawMmol = 6.4
        diagnostics.lastPacketDate = Date(timeIntervalSince1970: 1_800_000_000)
        diagnostics.unknownPacketCount = 3
        diagnostics.statusMessage = "Glikoz verisi alınıyor."

        let rows = SibionicsGS1DiagnosticsRows.make(diagnostics: diagnostics)

        XCTAssertEqual(rows.map(\.title), [
            "Bağlantı durumu", "Firmware", "Batarya", "Son indeks", "Son ham değer (kalibre edilmemiş)", "Son paket zamanı", "Bilinmeyen paket sayısı"
        ])
        XCTAssertEqual(rows[0].detail, "Glikoz verisi alınıyor.")
        XCTAssertEqual(rows[1].detail, "V120")
        XCTAssertEqual(rows[2].detail, "87 %")
        XCTAssertEqual(rows[3].detail, "1234")
        XCTAssertEqual(rows[4].detail, "6.4 mmol/L")
        XCTAssertEqual(rows[5].detail, Date(timeIntervalSince1970: 1_800_000_000).toStringInUserLocale(timeStyle: .medium, dateStyle: .short))
        XCTAssertEqual(rows[6].detail, "3")
    }

    func testDiagnosticsRowsWithoutDataStayEmpty() {
        var diagnostics = SibionicsGS1Diagnostics()
        diagnostics.firmware = .legacy

        let rows = SibionicsGS1DiagnosticsRows.make(diagnostics: diagnostics)

        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[1].detail, "Eski")
        XCTAssertNil(rows[2].detail)
        XCTAssertNil(rows[3].detail)
        XCTAssertNil(rows[4].detail)
        XCTAssertNil(rows[5].detail)
        XCTAssertEqual(rows[6].detail, "0")
    }
}

/// App-wide wiring of the passive Instara G1 co-listener: manager, add flow, warning, diagnostics and Loop interval.
final class InstaraG1WiringTests: XCTestCase {

    /// the manager holds its CGM delegate weakly
    private let cgmDelegate = ConnectionStatusCGMDelegateStub()

    private func makeManager(_ coreDataManager: CoreDataManager) -> BluetoothPeripheralManager {
        BluetoothPeripheralManager(
            coreDataManager: coreDataManager,
            cgmTransmitterDelegate: cgmDelegate,
            messageHandler: { _, _ in },
            heartBeatFunction: nil,
            cgmTransmitterInfoChanged: {}
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "InstaraG1WiringTests." + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testAddFlowCreatesThePassiveInstaraTransmitter() {
        let manager = makeManager(CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName))

        let transmitter = manager.createNewTransmitter(type: .InstaraG1Type, transmitterId: nil, dexcomG6BluetoothSlot: .defaultSlot, bluetoothTransmitterDelegate: nil)
        defer { transmitter.prepareForRelease() }

        XCTAssertTrue(transmitter is CGMInstaraG1Transmitter)
        XCTAssertEqual(manager.getTransmitterType(for: transmitter), .InstaraG1Type)
    }

    func testHandshakeFirmwareIsSavedOnTheCoreDataObject() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let g1 = InstaraG1(address: "test-g1", name: "Instara", alias: nil, nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        // disabled, so loading it does not select it as the app's CGM source
        g1.blePeripheral.shouldconnect = false
        coreDataManager.saveChanges()

        let manager = makeManager(coreDataManager)
        let transmitter = try XCTUnwrap(manager.getBluetoothTransmitter(for: g1, createANewOneIfNecesssary: true) as? CGMInstaraG1Transmitter)
        defer { transmitter.prepareForRelease() }

        manager.received(firmware: "HW 1.0 / SW 2.3", from: transmitter)

        XCTAssertEqual(g1.firmware, "HW 1.0 / SW 2.3")
    }

    func testRemovingTheDeviceTurnsTheVerificationOff() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let g1 = InstaraG1(address: "test-g1-remove", name: "Instara", alias: nil, nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        g1.blePeripheral.shouldconnect = false
        coreDataManager.saveChanges()
        let manager = makeManager(coreDataManager)

        let wasVerified = UserDefaults.standard.instaraG1ExportVerified
        let previousSensorStart = UserDefaults.standard.instaraG1VerifiedSensorStart
        defer { UserDefaults.standard.setInstaraG1Verified(wasVerified, sensorStart: previousSensorStart, reason: "test-restore") }
        UserDefaults.standard.setInstaraG1Verified(true, sensorStart: Date(timeIntervalSince1970: 1_800_000_000), reason: "test")
        XCTAssertTrue(UserDefaults.standard.instaraG1ExportVerified)

        manager.deleteBluetoothPeripheral(bluetoothPeripheral: g1)

        XCTAssertFalse(UserDefaults.standard.instaraG1ExportVerified)
        XCTAssertNil(UserDefaults.standard.instaraG1VerifiedSensorStart)
    }

    func testAddFlowKeepsWaitingForTheOfficialAppConnection() {
        for result: BluetoothTransmitter.startScanningResult in [.alreadyScanning, .connecting] {
            XCTAssertTrue(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .InstaraG1Type, scanningResult: result))
        }
        XCTAssertFalse(BluetoothPeripheralDetailState.keepsWaitingForNewPeripheral(type: .InstaraG1Type, scanningResult: .poweredOff))
    }

    func testAddFlowFooterAsksToOpenTheOfficialApp() {
        XCTAssertEqual(
            BluetoothPeripheralDetailState.instaraG1AddFlowFooter(type: .InstaraG1Type, hasPeripheral: false, isWaiting: true),
            "Resmi Instara uygulamasını açın ve sensörün bağlı olduğundan emin olun."
        )
        XCTAssertNil(BluetoothPeripheralDetailState.instaraG1AddFlowFooter(type: .InstaraG1Type, hasPeripheral: true, isWaiting: false))
        XCTAssertNil(BluetoothPeripheralDetailState.instaraG1AddFlowFooter(type: .SibionicsGS1Type, hasPeripheral: false, isWaiting: true))
        // the Sibionics footer stays Sibionics only
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1AddFlowFooter(type: .InstaraG1Type, hasPeripheral: false, isWaiting: true))
    }

    func testExperimentalWarningTextMatchesTheBrief() {
        XCTAssertEqual(
            Texts_BluetoothPeripheralView.instaraG1ExperimentalWarning,
            "Instara-1 desteği deneyseldir. xDrip resmi Instara uygulamasının bağlantısını dinler; resmi uygulama açık ve sensöre bağlı kalmalıdır. Değerleri resmi uygulamayla karşılaştırıp doğrulayana kadar Loop, paylaşım ve glikoz alarmları kapalıdır."
        )
        XCTAssertFalse(Texts_BluetoothPeripheralView.instaraG1ExperimentalWarningTitle.isEmpty)
    }

    func testExperimentalWarningIsShownOnlyOnce() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(defaults.instaraG1ExperimentalWarningAcknowledged)
        let notice = try XCTUnwrap(BluetoothPeripheralDetailState.instaraG1ExperimentalWarningNotice(type: .InstaraG1Type, defaults: defaults))
        XCTAssertEqual(notice.message, Texts_BluetoothPeripheralView.instaraG1ExperimentalWarning)
        XCTAssertNil(BluetoothPeripheralDetailState.instaraG1ExperimentalWarningNotice(type: .SibionicsGS1Type, defaults: defaults))
        // acknowledging one passive source does not acknowledge the other
        XCTAssertNil(BluetoothPeripheralDetailState.sibionicsGS1ExperimentalWarningNotice(type: .InstaraG1Type, defaults: defaults))

        notice.onAcknowledge?()
        XCTAssertTrue(defaults.instaraG1ExperimentalWarningAcknowledged)
        XCTAssertFalse(defaults.sibionicsGS1ExperimentalWarningAcknowledged)
        XCTAssertNil(BluetoothPeripheralDetailState.instaraG1ExperimentalWarningNotice(type: .InstaraG1Type, defaults: defaults))
    }

    func testDiagnosticsRowsAreReadOnlyAndOrdered() {
        var diagnostics = InstaraG1Diagnostics()
        diagnostics.statusMessage = "Glikoz verisi alınıyor."
        diagnostics.firmware = "HW 1.0 / SW 2.3"
        diagnostics.batteryPercent = 87
        diagnostics.lastSeq = 1234
        diagnostics.lastRawMmol = 6.4
        diagnostics.intervalMinutes = 1
        diagnostics.lastPacketDate = Date(timeIntervalSince1970: 1_800_000_000)
        diagnostics.unlistedPacketCount = 3
        diagnostics.invalidPacketCount = 2

        let rows = InstaraG1DiagnosticsRows.make(diagnostics: diagnostics)

        XCTAssertEqual(rows.map(\.title), [
            "Bağlantı durumu", "Firmware", "Pil", "Son sıra no", "Son ham değer (mmol/L)", "Okuma aralığı", "Son paket zamanı", "Bilinmeyen/geçersiz paket"
        ])
        XCTAssertEqual(rows.map(\.detail), [
            "Glikoz verisi alınıyor.",
            "HW 1.0 / SW 2.3",
            "87 %",
            "1234",
            "6.4",
            "1 dk",
            Date(timeIntervalSince1970: 1_800_000_000).toStringInUserLocale(timeStyle: .medium, dateStyle: .short),
            "3 / 2"
        ])
    }

    func testDiagnosticsRowsWithoutDataStayEmpty() {
        let rows = InstaraG1DiagnosticsRows.make(diagnostics: InstaraG1Diagnostics())

        XCTAssertEqual(rows.count, 8)
        XCTAssertNil(rows[0].detail)
        XCTAssertNil(rows[1].detail)
        XCTAssertNil(rows[2].detail)
        XCTAssertNil(rows[3].detail)
        XCTAssertNil(rows[4].detail)
        XCTAssertEqual(rows[5].detail, "5 dk")
        XCTAssertNil(rows[6].detail)
        XCTAssertEqual(rows[7].detail, "0 / 0")
    }

    func testLoopExpectedIntervalFollowsTheReadingInterval() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // key absent: default 5 minutes
        XCTAssertEqual(XDripCGMMetadataBuilder.directExpectedInterval(.instaraG1, defaults: defaults), 300)

        defaults.instaraG1IntervalMinutes = 1
        XCTAssertEqual(XDripCGMMetadataBuilder.directExpectedInterval(.instaraG1, defaults: defaults), 60)

        // the other sources are unchanged
        XCTAssertEqual(XDripCGMMetadataBuilder.directExpectedInterval(.sibionicsGS1, defaults: defaults), 60)
        XCTAssertEqual(XDripCGMMetadataBuilder.directExpectedInterval(.dexcom, defaults: defaults), 300)
    }
}
