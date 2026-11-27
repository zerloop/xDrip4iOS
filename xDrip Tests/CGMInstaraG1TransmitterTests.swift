import XCTest
import CoreBluetooth
@testable import xdrip

final class CGMInstaraG1TransmitterTests: XCTestCase {

    private let sessionStateKey = "instaraG1.sessionState"

    private let intervalMinutesKey = "instaraG1.intervalMinutes"

    /// realtime frame from the brief: seq 288 (0x0120), 7.2 mmol/L (0x0048)
    private let realtime288 = "55aa10040120004863"

    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    private var bluetoothDelegate: FakeBluetoothTransmitterDelegate!
    private var cgmDelegate: FakeCGMTransmitterDelegate!
    private var transmitter: CGMInstaraG1Transmitter!

    override func setUp() {
        super.setUp()
        clearDefaults()
        bluetoothDelegate = FakeBluetoothTransmitterDelegate()
        cgmDelegate = FakeCGMTransmitterDelegate()
        transmitter = CGMInstaraG1Transmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: cgmDelegate)
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
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: sessionStateKey)
        defaults.removeObject(forKey: intervalMinutesKey)
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1ExportVerified.rawValue)
        defaults.removeObject(forKey: UserDefaults.Key.instaraG1VerifiedSensorStart.rawValue)
    }

    // MARK: - helpers

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

    /// builds a valid frame 55 AA | cmd | len | payload | crc8
    private func frame(cmd: UInt8, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x55, 0xAA, cmd, UInt8(payload.count)]
        bytes.append(contentsOf: payload)
        bytes.append(InstaraG1Protocol.crc8(Data(bytes)))
        return Data(bytes)
    }

    private func realtime(seq: Int, tenthMmol: Int) -> Data {
        frame(cmd: 0x10, payload: [UInt8(seq >> 8), UInt8(seq & 0xFF), UInt8(tenthMmol >> 8), UInt8(tenthMmol & 0xFF)])
    }

    private func persist(_ state: InstaraG1SessionState) {
        UserDefaults.standard.set(try! JSONEncoder().encode(state), forKey: sessionStateKey)
    }

    private func storedState() -> InstaraG1SessionState? {
        guard let data = UserDefaults.standard.data(forKey: sessionStateKey) else { return nil }
        return try? JSONDecoder().decode(InstaraG1SessionState.self, from: data)
    }

    /// state of a running session whose last realtime was seq at refDate, 5 minute interval
    private func runningState(lastSeq: Int, refDate: Date) -> InstaraG1SessionState {
        var state = InstaraG1SessionState()
        state.lastSeq = lastSeq
        state.refSeq = lastSeq
        state.refDate = refDate
        state.sensorStart = refDate.addingTimeInterval(-Double(lastSeq) * 300)
        state.seenSeqs = [lastSeq: refDate]
        return state
    }

    private func spinMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - tests from the brief

    func testWriteIsBlocked() {
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), type: .withoutResponse))
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), type: .withResponse))

        let characteristic = CBMutableCharacteristic(type: CBUUID(string: ConstantsInstaraG1.writeCharacteristicUUID), properties: [.write], value: nil, permissions: [.writeable])
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), characteristicToWriteTo: characteristic, type: .withResponse))
        XCTAssertFalse(transmitter.writeDataToPeripheral(data: Data([1]), characteristicToWriteTo: characteristic, type: .withoutResponse, logPayload: false))

        XCTAssertEqual(transmitter.blockedWriteCount, 4)
    }

    func testTypeAndLimits() {
        XCTAssertEqual(transmitter.cgmTransmitterType(), .instaraG1)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 21)
        XCTAssertEqual(transmitter.sensorWarmupDurationInMinutes(), 15)
        XCTAssertEqual(transmitter.getCBUUID_Service(), "8653000A-43E6-47B7-9CB0-5FC21D4AE340")
        XCTAssertEqual(transmitter.getCBUUID_Receive(), "8653000B-43E6-47B7-9CB0-5FC21D4AE340")
        XCTAssertFalse(transmitter.isWebOOPEnabled())
        XCTAssertFalse(transmitter.isNonFixedSlopeEnabled())
        XCTAssertFalse(transmitter.needsSensorStartTime())
    }

    func testNoConnectedPeripheralSchedulesBackoffNotTightLoop() {
        // the simulator has no system-connected 8653000A peripheral
        let result = transmitter.startScanning()

        XCTAssertNotEqual(result, .success, "no real scan may be started and no peripheral can be connected")
        XCTAssertFalse(transmitter.isScanning())
        XCTAssertEqual(transmitter.diagnostics.statusMessage, CGMInstaraG1Transmitter.officialAppNotConnectedMessage)
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)

        _ = transmitter.startScanning()
        _ = transmitter.startScanning()
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)

        // the scheduled retry does not fire within 1 second (first back-off is 5 s)
        spinMainRunLoop(1.0)
        XCTAssertEqual(transmitter.retrieveConnectedAttemptCount, 1)
        XCTAssertFalse(transmitter.isScanning())
    }

    func testRealtimeIsDeliveredOnce() {
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }

        transmitter.handleNotification(hex(realtime288), now: t0)
        transmitter.handleNotification(hex(realtime288), now: t0.addingTimeInterval(1))

        wait(for: [delivered], timeout: 2)
        spinMainRunLoop(0.3)

        let all = cgmDelegate.received.flatMap { $0 }
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.timeStamp, t0)
        XCTAssertEqual(all.first?.glucoseLevelRaw ?? 0, 7.2 * ConstantsBloodGlucose.mmollToMgdl, accuracy: 1e-9)

        XCTAssertEqual(transmitter.diagnostics.lastSeq, 288)
        XCTAssertEqual(transmitter.diagnostics.lastRawMmol ?? 0, 7.2, accuracy: 1e-9)
        XCTAssertEqual(transmitter.diagnostics.lastPacketDate, t0.addingTimeInterval(1))
        XCTAssertEqual(transmitter.diagnostics.statusMessage, CGMInstaraG1Transmitter.receivingMessage)
        XCTAssertEqual(storedState()?.lastSeq, 288)
    }

    func testNewSensorRevokesVerification() {
        let state = runningState(lastSeq: 500, refDate: t0.addingTimeInterval(-300))
        persist(state)
        UserDefaults.standard.setInstaraG1Verified(true, sensorStart: state.sensorStart, reason: "test")
        XCTAssertTrue(UserDefaults.standard.instaraG1ExportVerified)

        transmitter.handleNotification(realtime(seq: 3, tenthMmol: 60), now: t0)
        transmitter.handleNotification(realtime(seq: 4, tenthMmol: 61), now: t0.addingTimeInterval(300))
        spinMainRunLoop(0.3)

        XCTAssertEqual(cgmDelegate.newSensorStartDates.count, 1)
        XCTAssertNotNil(cgmDelegate.newSensorStartDates.first ?? nil)
        XCTAssertFalse(UserDefaults.standard.instaraG1ExportVerified)
        XCTAssertNil(UserDefaults.standard.instaraG1VerifiedSensorStart)
        XCTAssertEqual(storedState()?.lastSeq, 4)
    }

    func testSensorMismatchRevokesVerification() {
        // a running session (no new session on the next packet) whose start is about t0 - 1 day,
        // but the verification belongs to a sensor started at t0 - 10 days
        persist(runningState(lastSeq: 287, refDate: t0.addingTimeInterval(-300)))
        UserDefaults.standard.setInstaraG1Verified(true, sensorStart: t0.addingTimeInterval(-10 * 86400), reason: "test")
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }

        transmitter.handleNotification(hex(realtime288), now: t0)

        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(cgmDelegate.newSensorStartDates.isEmpty, "the revocation must come from the mismatch check, not from a new session")
        XCTAssertFalse(UserDefaults.standard.instaraG1ExportVerified)
    }

    // MARK: - additional tests

    func testMatchingSensorKeepsVerification() {
        let state = runningState(lastSeq: 287, refDate: t0.addingTimeInterval(-300))
        persist(state)
        UserDefaults.standard.setInstaraG1Verified(true, sensorStart: state.sensorStart!.addingTimeInterval(20 * 60), reason: "test")
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }

        transmitter.handleNotification(hex(realtime288), now: t0)

        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(UserDefaults.standard.instaraG1ExportVerified)
    }

    func testUndecodableSessionStateFallsBackToFreshState() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: sessionStateKey)
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }

        transmitter.handleNotification(hex(realtime288), now: t0)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(cgmDelegate.received.flatMap { $0 }.count, 1)
        XCTAssertEqual(cgmDelegate.newSensorStartDates.count, 1, "a fresh state starts a session")
        XCTAssertEqual(storedState()?.lastSeq, 288, "the fresh state replaces the undecodable one")
    }

    func testStateIsRestoredAcrossInstances() {
        let delivered = expectation(description: "glucose delivered")
        cgmDelegate.onInfoReceived = { delivered.fulfill() }
        transmitter.handleNotification(hex(realtime288), now: t0)
        wait(for: [delivered], timeout: 2)

        let secondDelegate = FakeCGMTransmitterDelegate()
        let second = CGMInstaraG1Transmitter(address: nil, name: nil, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: secondDelegate)
        second.handleNotification(hex(realtime288), now: t0.addingTimeInterval(60))
        spinMainRunLoop(0.3)
        XCTAssertTrue(secondDelegate.received.flatMap { $0 }.isEmpty)
        XCTAssertTrue(secondDelegate.newSensorStartDates.isEmpty)
        second.prepareForRelease()
    }

    func testIntervalPacketUpdatesIntervalDefault() {
        XCTAssertEqual(UserDefaults.standard.instaraG1IntervalMinutes, 5, "default")

        transmitter.handleNotification(frame(cmd: 0x0A, payload: [0x00, 0x01]), now: t0)

        XCTAssertEqual(UserDefaults.standard.instaraG1IntervalMinutes, 1)
        XCTAssertEqual(transmitter.diagnostics.intervalMinutes, 1)
    }

    func testBatteryHandshakeUnlistedAndInvalidUpdateDiagnosticsOnly() {
        transmitter.handleNotification(frame(cmd: 0x20, payload: [0x4B]), now: t0)
        transmitter.handleNotification(frame(cmd: 0xF0, payload: [0x01, 0x02]), now: t0)
        transmitter.handleNotification(frame(cmd: 0x07, payload: [0x01]), now: t0)
        transmitter.handleNotification(hex("55aa10040120004800"), now: t0)   // CRC-FAIL
        spinMainRunLoop(0.2)

        let diagnostics = transmitter.diagnostics
        XCTAssertEqual(diagnostics.batteryPercent, 75)
        XCTAssertEqual(diagnostics.firmware, "HW 1 / SW 2")
        XCTAssertEqual(diagnostics.unlistedPacketCount, 1)
        XCTAssertEqual(diagnostics.invalidPacketCount, 1)
        XCTAssertTrue(cgmDelegate.received.isEmpty)
        XCTAssertNil(storedState(), "packets without glucose do not create a session")
    }

    func testHandshakeFirmwareIsReportedOnceToTheFirmwareDelegate() {
        let firmwareDelegate = FakeInstaraG1FirmwareDelegate()
        transmitter.cGMInstaraG1TransmitterDelegate = firmwareDelegate

        transmitter.handleNotification(frame(cmd: 0xF0, payload: [0x01, 0x02]), now: t0)
        transmitter.handleNotification(frame(cmd: 0xF0, payload: [0x01, 0x02]), now: t0)
        spinMainRunLoop(0.2)
        XCTAssertEqual(firmwareDelegate.firmwares, ["HW 1 / SW 2"], "an unchanged handshake is not saved again")

        transmitter.handleNotification(frame(cmd: 0xF0, payload: [0x01, 0x03]), now: t0)
        spinMainRunLoop(0.2)
        XCTAssertEqual(firmwareDelegate.firmwares, ["HW 1 / SW 2", "HW 1 / SW 3"])
    }

    func testReconnectPolicyBacksOff5_10_15() {
        var policy = InstaraG1ReconnectPolicy(delays: [5, 10, 15])

        XCTAssertEqual(policy.requestAttempt(now: t0), 5)
        XCTAssertNil(policy.requestAttempt(now: t0.addingTimeInterval(4.9)))
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(5)), 10)
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(15)), 15)
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(30)), 15)

        policy.reset()
        XCTAssertEqual(policy.requestAttempt(now: t0.addingTimeInterval(31)), 5)
    }

    func testOnePendingConnectAndTenMinuteSuppression() {
        var policy = InstaraG1ReconnectPolicy(delays: [5, 10, 15])
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true, now: t0), .pendingConnect)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true, now: t0), .waitForPendingConnect)
        policy.pendingConnectEnded()

        policy.pendingConnectLinkEnded(receivedGlucose: false, now: t0)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true, now: t0.addingTimeInterval(599)), .retryWithBackoff)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: true, now: t0.addingTimeInterval(601)), .pendingConnect)
        XCTAssertEqual(policy.afterFailedAttempt(hasKnownPeripheral: false, now: t0), .retryWithBackoff)
    }

    func testStallTimeoutIsDisabledOnlyWhilePendingConnectIsOutstanding() {
        XCTAssertTrue(transmitter.shouldTimeoutStalledConnectionSetup())
        transmitter.enterPendingConnectStateForTesting()
        XCTAssertFalse(transmitter.shouldTimeoutStalledConnectionSetup())
        transmitter.disconnect()
        XCTAssertTrue(transmitter.shouldTimeoutStalledConnectionSetup())
    }

    func testWatchdogResubscribesAt900AndReleasesAt1800() {
        XCTAssertEqual(InstaraG1Watchdog.action(secondsWithoutGlucose: 899, alreadyResubscribed: false), .none)
        XCTAssertEqual(InstaraG1Watchdog.action(secondsWithoutGlucose: 900, alreadyResubscribed: false), .resubscribe)
        XCTAssertEqual(InstaraG1Watchdog.action(secondsWithoutGlucose: 1200, alreadyResubscribed: true), .none)
        XCTAssertEqual(InstaraG1Watchdog.action(secondsWithoutGlucose: 1800, alreadyResubscribed: true), .release)
        XCTAssertEqual(InstaraG1Watchdog.action(secondsWithoutGlucose: 1800, alreadyResubscribed: false), .release)
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

private final class FakeInstaraG1FirmwareDelegate: CGMInstaraG1TransmitterDelegate {
    private(set) var firmwares: [String] = []
    func received(firmware: String, from cGMInstaraG1Transmitter: CGMInstaraG1Transmitter) {
        XCTAssertTrue(Thread.isMainThread)
        firmwares.append(firmware)
    }
}
