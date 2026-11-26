import XCTest
import CoreBluetooth
@testable import xdrip

final class CGMSibionicsGS1TransmitterTests: XCTestCase {

    private let defaultsKeys = [
        "sibionicsGS1.lastReceivedIndex",
        "sibionicsGS1.sensorStartDate",
        "sibionicsGS1.lastReadingDate",
        "sibionicsGS1.lastRecordDate"
    ]

    /// encrypted V120 batch from SibionicsGS1ProtocolTests: index 100 (7.2 mmol/L, t=1_795_000_000) and 101 (7.5 mmol/L, t=1_795_000_060)
    private let encryptedGlucoseBatch = "3cff6dbd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afaf3"

    private var bluetoothDelegate: FakeBluetoothTransmitterDelegate!
    private var cgmDelegate: FakeCGMTransmitterDelegate!
    private var transmitter: CGMSibionicsGS1Transmitter!

    override func setUp() {
        super.setUp()
        clearDefaults()
        bluetoothDelegate = FakeBluetoothTransmitterDelegate()
        cgmDelegate = FakeCGMTransmitterDelegate()
        transmitter = CGMSibionicsGS1Transmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: cgmDelegate)
    }

    override func tearDown() {
        transmitter.prepareForRelease()
        transmitter = nil
        cgmDelegate = nil
        bluetoothDelegate = nil
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        for key in defaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func spinMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - tests

    func testWriteIsBlocked() {
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), type: .withoutResponse))
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), type: .withResponse))

        let characteristic = CBMutableCharacteristic(type: CBUUID(string: "FF32"), properties: [.write], value: nil, permissions: [.writeable])
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), characteristicToWriteTo: characteristic, type: .withResponse))
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), characteristicToWriteTo: characteristic, type: .withoutResponse, logPayload: false))

        XCTAssertEqual(transmitter.blockedWriteCount, 4)
    }

    func testTypeAndLimits() {
        XCTAssertEqual(transmitter.cgmTransmitterType(), .sibionicsGS1)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 14)
        XCTAssertEqual(transmitter.sensorWarmupDurationInMinutes(), 60)
        XCTAssertEqual(transmitter.getCBUUID_Service(), "0000FF30-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), "0000FF31-0000-1000-8000-00805F9B34FB")
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        XCTAssertFalse(transmitter.needsSensorStartTime())
    }

    func testNoConnectedPeripheralSchedulesBackoffNotTightLoop() {
        // the simulator has no system-connected FF30 peripheral
        let result = transmitter.startScanning()

        XCTAssertNotEqual(result, .success, "no real scan may be started and no peripheral can be connected")
        XCTAssertFalse(transmitter.isScanning())
        XCTAssertEqual(transmitter.diagnostics.statusMessage, CGMSibionicsGS1Transmitter.officialAppNotConnectedMessage)
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)

        // calling again immediately (as didDisconnect, connect timeout or the UI do) must not re-attempt
        _ = transmitter.startScanning()
        _ = transmitter.startScanning()
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)

        // and the scheduled retry does not fire within 1 second (first back-off is 5 s)
        spinMainRunLoop(1.0)
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)
        XCTAssertFalse(transmitter.isScanning())
    }

    func testReconnectPolicyBacksOff5_10_15() {
        var policy = SibionicsGS1ReconnectPolicy(delays: [5, 10, 15])
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)

        XCTAssertEqual(policy.requestAttempt(now: t0), 5)
        XCTAssertNil(policy.requestAttempt(now: t0))
        XCTAssertNil(policy.requestAttempt(now: t0.addingTimeInterval(4.9)))
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(5)), 10)
        XCTAssertNil(policy.requestAttempt(now: t0.addingTimeInterval(14.9)))
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(15)), 15)
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(30)), 15, "delay stays at the last value")

        policy.reset()
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(31)), 5)
    }

    func testFailedAttemptWithKnownPeripheralLeavesOnePendingConnect() {
        var policy = SibionicsGS1ReconnectPolicy(delays: [5, 10, 15])
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)

        XCTAssertEqual(policy.requestAttempt(now: t0), 5)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true), .pendingConnect)
        XCTAssertTrue(policy.pendingConnectOutstanding)

        // not repeated while pending
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(5)), 10)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true), .waitForPendingConnect)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true), .waitForPendingConnect)

        // once the pending connect ended (didConnect / didFail / didDisconnect / Bluetooth off), a new one may be issued
        policy.pendingConnectEnded()
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true), .pendingConnect)
    }

    func testFailedAttemptWithoutKnownPeripheralRetriesWithBackoff() {
        var policy = SibionicsGS1ReconnectPolicy(delays: [5, 10, 15])
        let t0 = Date(timeIntervalSince1970: 1_795_000_000)

        XCTAssertEqual(policy.requestAttempt(now: t0), 5)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: false), .retryWithBackoff)
        XCTAssertFalse(policy.pendingConnectOutstanding)
        XCTAssertNil(policy.requestAttempt(now: t0.addingTimeInterval(1)), "back-off still applies")
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(5)), 10)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: false), .retryWithBackoff)
    }

    func testStallTimeoutIsDisabledOnlyWhilePendingConnectIsOutstanding() {
        XCTAssertTrue(transmitter.shouldTimeoutStalledConnectionSetup())

        transmitter.enterPendingConnectStateForTesting()
        XCTAssertTrue(transmitter.isPendingConnectOutstanding)
        XCTAssertFalse(transmitter.shouldTimeoutStalledConnectionSetup(), "the pending connect must not be cancelled by the stall timeout")

        // disconnect() ends xDrip's own connect request, so the pending state must end too
        transmitter.disconnect()
        XCTAssertFalse(transmitter.isPendingConnectOutstanding)
        XCTAssertTrue(transmitter.shouldTimeoutStalledConnectionSetup())
    }

    func testPolicyReconcileClearsStalePendingConnect() {
        var policy = SibionicsGS1ReconnectPolicy(delays: [5, 10, 15])
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true), .pendingConnect)

        XCTAssertFalse(policy.reconcilePendingConnect(peripheralIsConnecting: true), "a real pending connect is kept")
        XCTAssertTrue(policy.pendingConnectOutstanding)

        XCTAssertTrue(policy.reconcilePendingConnect(peripheralIsConnecting: false), "stale flag is cleared")
        XCTAssertFalse(policy.pendingConnectOutstanding)
        XCTAssertFalse(policy.reconcilePendingConnect(peripheralIsConnecting: false))
    }

    func testStalePendingConnectFlagIsClearedAndRetryScheduledInSuppressedPath() {
        // consume the first back-off slot (no peripheral in the simulator)
        _ = transmitter.startScanning()
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)

        // stale state: flag true, no real pending connect, no retry scheduled
        transmitter.cancelScheduledRetryForTesting()
        transmitter.enterPendingConnectStateForTesting()
        XCTAssertFalse(transmitter.isRetryScheduled)

        // back-off suppresses the attempt, but the stale flag must be cleared and a retry scheduled
        _ = transmitter.startScanning()
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1, "still no immediate re-attempt")
        XCTAssertFalse(transmitter.isPendingConnectOutstanding)
        XCTAssertTrue(transmitter.isRetryScheduled)
    }

    func testStalePendingConnectFlagIsClearedInAllowedAttemptPath() {
        transmitter.enterPendingConnectStateForTesting()
        XCTAssertTrue(transmitter.isPendingConnectOutstanding)

        _ = transmitter.startScanning()
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)
        XCTAssertFalse(transmitter.isPendingConnectOutstanding)
        XCTAssertTrue(transmitter.isRetryScheduled)
    }

    func testWatchdogResubscribesAt5MinutesAndReleasesAt15() {
        XCTAssertEqual(SibionicsGS1Watchdog.action(secondsWithoutGlucose: 299, alreadyResubscribed: false), .none)
        XCTAssertEqual(SibionicsGS1Watchdog.action(secondsWithoutGlucose: 300, alreadyResubscribed: false), .resubscribe)
        XCTAssertEqual(SibionicsGS1Watchdog.action(secondsWithoutGlucose: 600, alreadyResubscribed: true), .none, "only one resubscribe per silence period")
        XCTAssertEqual(SibionicsGS1Watchdog.action(secondsWithoutGlucose: 900, alreadyResubscribed: true), .release)
        XCTAssertEqual(SibionicsGS1Watchdog.action(secondsWithoutGlucose: 900, alreadyResubscribed: false), .release)
    }

    func testRecordsAreDeliveredOnceViaDelegate() {
        let now = Date(timeIntervalSince1970: 1_795_000_120)
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }

        transmitter.handleNotification(hex(encryptedGlucoseBatch), now: now)
        transmitter.handleNotification(hex(encryptedGlucoseBatch), now: now)

        wait(for: [delivered], timeout: 2)
        spinMainRunLoop(0.3)

        let all = cgmDelegate.received.flatMap { $0 }
        XCTAssertEqual(all.count, 2)
        // newest first
        XCTAssertEqual(all.first?.timeStamp, Date(timeIntervalSince1970: 1_795_000_060))
        XCTAssertEqual(all.first?.glucoseLevelRaw ?? 0, 7.5 * 18.0182 * 1000, accuracy: 1e-6)
        XCTAssertEqual(all.last?.timeStamp, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(all.last?.glucoseLevelRaw ?? 0, 7.2 * 18.0182 * 1000, accuracy: 1e-6)

        // the session state is persisted with all fields
        XCTAssertEqual(UserDefaults.standard.object(forKey: "sibionicsGS1.lastReceivedIndex") as? Int, 101)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "sibionicsGS1.sensorStartDate") as? Date)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "sibionicsGS1.lastReadingDate") as? Date, Date(timeIntervalSince1970: 1_795_000_060))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "sibionicsGS1.lastRecordDate") as? Date, Date(timeIntervalSince1970: 1_795_000_060))

        XCTAssertEqual(transmitter.diagnostics.lastIndex, 101)
        XCTAssertEqual(transmitter.diagnostics.lastRawMmol ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(transmitter.diagnostics.firmware, .v120)
        XCTAssertEqual(transmitter.diagnostics.lastPacketDate, now)
    }

    func testStateIsRestoredFromDefaultsAcrossInstances() {
        let now = Date(timeIntervalSince1970: 1_795_000_120)
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }
        transmitter.handleNotification(hex(encryptedGlucoseBatch), now: now)
        wait(for: [delivered], timeout: 2)

        // a new instance (app restart) must not deliver the same records again nor see a new sensor
        let secondDelegate = FakeCGMTransmitterDelegate()
        let second = CGMSibionicsGS1Transmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: secondDelegate)
        second.handleNotification(hex(encryptedGlucoseBatch), now: now.addingTimeInterval(60))
        spinMainRunLoop(0.3)
        XCTAssertTrue(secondDelegate.received.flatMap { $0 }.isEmpty)
        XCTAssertTrue(secondDelegate.newSensorStartDates.isEmpty)
        second.prepareForRelease()
    }

    func testMalformedPacketsDoNotCrashAndAreCounted() {
        transmitter.handleNotification(Data(), now: Date())
        transmitter.handleNotification(Data([0x01]), now: Date())
        transmitter.handleNotification(hex("21b56e72c59c08"), now: Date())   // unknown data cmd 0x42
        transmitter.handleNotification(hex("23f66ed9f2"), now: Date())       // ack
        spinMainRunLoop(0.2)

        XCTAssertEqual(transmitter.diagnostics.unknownPacketCount, 1)
        XCTAssertTrue(cgmDelegate.received.isEmpty)
    }

}

// MARK: - fakes

private final class FakeCGMTransmitterDelegate: CGMTransmitterDelegate {
    var received = [[GlucoseData]]()
    var newSensorStartDates = [Date?]()
    var onInfoReceived: (() -> Void)?

    func newSensorDetected(sensorStartDate: Date?) { newSensorStartDates.append(sensorStartDate) }
    func sensorStopDetected() {}
    func sensorNotDetected() {}
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {
        received.append(glucoseData)
        onInfoReceived?()
    }
    func errorOccurred(xDripError: XdripError) {}
}

private final class FakeBluetoothTransmitterDelegate: BluetoothTransmitterDelegate {
    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) {}
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) {}
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) {}
    func successfullyPaired() {}
    func pairingFailed() {}
    func error(message: String) {}
    func heartBeat() {}
}
