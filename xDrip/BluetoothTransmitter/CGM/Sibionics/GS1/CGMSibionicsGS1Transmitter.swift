// Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.

import Foundation
import CoreBluetooth
import os
import UIKit

/// read-only diagnostics for the peripheral detail screen and the trace file
struct SibionicsGS1Diagnostics: Equatable {
    var firmware: SibionicsGS1Firmware?
    var batteryPercent: Int?
    var lastIndex: Int?
    var lastRawMmol: Double?
    var lastPacketDate: Date?
    var unknownPacketCount: Int = 0
    var statusMessage: String = ""
}

/// pure back-off decision for re-retrieving the peripheral that the official app holds.
///
/// Every granted attempt reserves the next slot, so callers that fire in quick succession
/// (didDisconnect, connect timeout, the UI) can never produce a tight retrieve/connect loop.
/// Only a valid glucose packet resets the back-off.
struct SibionicsGS1ReconnectPolicy {

    let delays: [TimeInterval]

    private(set) var attempt = 0

    private(set) var nextAllowedAttempt = Date.distantPast

    init(delays: [TimeInterval] = ConstantsSibionicsGS1.reconnectDelays) {
        self.delays = delays.isEmpty ? [15] : delays
    }

    /// - returns: nil if an attempt is not allowed yet, otherwise the delay after which the next attempt is allowed
    mutating func requestAttempt(now: Date) -> TimeInterval? {
        guard now >= nextAllowedAttempt else { return nil }
        let delay = delays[min(attempt, delays.count - 1)]
        attempt += 1
        nextAllowedAttempt = now.addingTimeInterval(delay)
        return delay
    }

    mutating func reset() {
        attempt = 0
        nextAllowedAttempt = .distantPast
        pendingConnectOutstanding = false
    }

    /// what to do after a retrieveConnected attempt found nothing
    enum Recovery: Equatable {
        /// leave exactly one OS-level pending connect for the known peripheral, without stall timeout.
        /// iOS completes it when the official app re-establishes the shared link and wakes xDrip
        case pendingConnect
        /// a pending connect is already outstanding, do nothing
        case waitForPendingConnect
        /// no known peripheral: retry retrieveConnected after the back-off delay
        case retryWithBackoff
    }

    private(set) var pendingConnectOutstanding = false

    mutating func afterFailedAttempt(hasKnownPeripheral: Bool) -> Recovery {
        guard hasKnownPeripheral else { return .retryWithBackoff }
        if pendingConnectOutstanding { return .waitForPendingConnect }
        pendingConnectOutstanding = true
        return .pendingConnect
    }

    /// clears a stale pending-connect flag (flag true but the peripheral is not connecting). Returns true if cleared
    mutating func reconcilePendingConnect(peripheralIsConnecting: Bool) -> Bool {
        guard pendingConnectOutstanding, !peripheralIsConnecting else { return false }
        pendingConnectOutstanding = false
        return true
    }

    /// to be called when the pending connect completes, fails, or could not be issued
    mutating func pendingConnectEnded() {
        pendingConnectOutstanding = false
    }

}

/// pure watchdog decision, see spec 6.2
enum SibionicsGS1Watchdog {

    enum Action: Equatable {
        case none
        /// setNotifyValue(false) then setNotifyValue(true) on FF31
        case resubscribe
        /// release xDrip's own connection request and go back to back-off retrieval
        case release
    }

    static func action(secondsWithoutGlucose: TimeInterval, alreadyResubscribed: Bool) -> Action {
        if secondsWithoutGlucose >= ConstantsSibionicsGS1.releaseAfterSeconds {
            return .release
        }
        if secondsWithoutGlucose >= ConstantsSibionicsGS1.resubscribeAfterSeconds && !alreadyResubscribed {
            return .resubscribe
        }
        return .none
    }

}

private final class SibionicsGS1BackgroundTask {
    private let lock = NSLock()
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        let newIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Sibionics GS1 retrieve",
            expirationHandler: { [weak self] in self?.end() }
        )
        lock.lock()
        identifier = newIdentifier
        lock.unlock()
    }

    func end() {
        lock.lock()
        let identifierToEnd = identifier
        identifier = .invalid
        lock.unlock()
        guard identifierToEnd != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifierToEnd)
    }
}

/// Passive co-listener for the Sibionics GS1 CGM.
///
/// The official Sibionics app owns the BLE session with the sensor (pairing, authentication and
/// every command). iOS multiplexes the link between apps: xDrip retrieves the peripheral that is
/// already connected to the system, subscribes to the FF31 notifications and decodes the packets
/// the official app requests. xDrip never writes anything to the sensor: all write paths of the
/// base class are overridden and blocked. A real scan is never started.
@objcMembers
class CGMSibionicsGS1Transmitter: BluetoothTransmitter, CGMTransmitter {

    private enum DefaultsKey {
        static let lastReceivedIndex = "sibionicsGS1.lastReceivedIndex"
        static let sensorStartDate = "sibionicsGS1.sensorStartDate"
        static let lastReadingDate = "sibionicsGS1.lastReadingDate"
        static let lastRecordDate = "sibionicsGS1.lastRecordDate"
    }

    // MARK: - status messages (user visible, localised in Texts_BluetoothPeripheralView)

    static let officialAppNotConnectedMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusOfficialAppNotConnected

    static let connectingMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusConnecting

    static let connectedWaitingMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusConnectedWaiting

    static let receivingMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusReceiving

    static let resubscribedMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusResubscribed

    static let releasedMessage = Texts_BluetoothPeripheralView.sibionicsGS1StatusReleased

    // MARK: - properties

    private let serviceCBUUID = CBUUID(string: ConstantsSibionicsGS1.serviceUUID)

    private let notifyCBUUID = CBUUID(string: ConstantsSibionicsGS1.notifyCharacteristicUUID)

    private let deviceInformationServiceCBUUID = CBUUID(string: ConstantsSibionicsGS1.deviceInformationServiceUUID)

    private let batteryLevelCBUUID = CBUUID(string: ConstantsSibionicsGS1.batteryLevelCharacteristicUUID)

    /// tolerance used to decide if the session start equals the active xDrip sensor start
    private let sensorSessionTolerance: TimeInterval = 10 * 60

    /// delay after which an issued pending connect is verified (the base issues it asynchronously)
    private let pendingConnectVerificationDelay: TimeInterval = 1

    /// interval of the watchdog tick while connected
    private let watchdogTickInterval: TimeInterval = 60

    private(set) weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMSibionicsGS1)

    /// protects all mutable state below. Never held while calling into the base class, because
    /// several base methods synchronously enter the Core Bluetooth queue.
    private let stateLock = NSLock()

    private var diagnosticsStorage = SibionicsGS1Diagnostics()

    private var reconnectPolicy = SibionicsGS1ReconnectPolicy()

    private var retryPending = false

    /// invalidates a scheduled retry
    private var retryGeneration = 0

    private var retryBackgroundTask: SibionicsGS1BackgroundTask?

    private var retrieveAttempts = 0

    private var blockedWrites = 0

    private var isReleased = false

    private var lastCentralState: CBManagerState?

    /// central from the latest Core Bluetooth callback, used to check that the system still knows the stored peripheral
    private weak var lastCentral: CBCentralManager?

    private weak var restoredPeripheral: CBPeripheral?

    private var notifyCharacteristic: CBCharacteristic?

    /// characteristics already read on the current connection (180A, 2A19 are read only once)
    private var readCharacteristicUUIDs = Set<CBUUID>()

    private var watchdogGeneration = 0

    /// last valid glucose packet, or the moment of connection if none yet
    private var watchdogReferenceDate = Date()

    private var resubscribedSinceReference = false

    // MARK: - test / diagnostics accessors

    var diagnostics: SibionicsGS1Diagnostics {
        withStateLock { diagnosticsStorage }
    }

    /// number of retrieveConnected attempts that were actually performed
    var retrieveConnectedAttemptCount: Int {
        withStateLock { retrieveAttempts }
    }

    /// number of write attempts that were blocked
    var blockedWriteCount: Int {
        withStateLock { blockedWrites }
    }

    var isPendingConnectOutstanding: Bool {
        withStateLock { reconnectPolicy.pendingConnectOutstanding }
    }

    var isRetryScheduled: Bool {
        withStateLock { retryPending }
    }

    /// test seam: puts the policy in the pending-connect state without a real connect (= a stale flag)
    func enterPendingConnectStateForTesting() {
        withStateLock { _ = reconnectPolicy.afterFailedAttempt(hasKnownPeripheral: true) }
    }

    /// test seam: drops a scheduled retry, as if none had been scheduled
    func cancelScheduledRetryForTesting() {
        withStateLock {
            retryGeneration += 1
            retryPending = false
        }
    }

    // MARK: - Initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {

        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // receive and write UUID are both FF31: the write characteristic is never used, every write path is blocked below
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [
                CBUUID(string: ConstantsSibionicsGS1.serviceUUID),
                CBUUID(string: ConstantsSibionicsGS1.deviceInformationServiceUUID),
                CBUUID(string: ConstantsSibionicsGS1.batteryServiceUUID)
            ],
            CBUUID_ReceiveCharacteristic: ConstantsSibionicsGS1.notifyCharacteristicUUID,
            CBUUID_WriteCharacteristic: ConstantsSibionicsGS1.notifyCharacteristicUUID,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )

        updateDiagnostics { $0.statusMessage = Self.officialAppNotConnectedMessage }
    }

    // MARK: - write blocking (the sensor is never written to)

    override func writeDataToPeripheral(data: Data, type: CBCharacteristicWriteType) -> Bool {
        blockWrite(data: data, characteristic: nil)
    }

    override func writeDataToPeripheral(data: Data, characteristicToWriteTo: CBCharacteristic, type: CBCharacteristicWriteType) -> Bool {
        blockWrite(data: data, characteristic: characteristicToWriteTo)
    }

    override func writeDataToPeripheral(data: Data, characteristicToWriteTo: CBCharacteristic, type: CBCharacteristicWriteType, logPayload: Bool) -> Bool {
        blockWrite(data: data, characteristic: characteristicToWriteTo)
    }

    private func blockWrite(data: Data, characteristic: CBCharacteristic?) -> Bool {
        withStateLock { blockedWrites += 1 }
        trace("BLOCKED WRITE to %{public}@, %{public}@ bytes, hex = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, characteristic?.uuid.uuidString ?? "write characteristic", data.count.description, data.hexEncodedString())
        return false
    }

    // MARK: - connection (passive: retrieveConnected only, never a real scan)

    /// does not scan. Tries to retrieve the peripheral that the official app holds, with back-off
    override func startScanning() -> BluetoothTransmitter.startScanningResult {
        switch getConnectionStatus() {
        case .connected:
            return .alreadyConnected
        case .connecting:
            return .connecting
        default:
            return attemptRetrieveConnected(trigger: "startScanning")
        }
    }

    /// base reconnects immediately with central.connect, here it goes through the back-off
    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        withStateLock { lastCentral = central }
        _ = attemptRetrieveConnected(trigger: "didDisconnect")
    }

    /// external connect requests (manager at launch, detail screen) go through the same path:
    /// retrieveConnected with back-off, then one pending connect for the known peripheral
    override func connect() {
        runOnCentralQueue { [weak self] in
            guard let self else { return }
            switch self.getConnectionStatus() {
            case .connected, .connecting:
                return
            default:
                _ = self.attemptRetrieveConnected(trigger: "connect")
            }
        }
    }

    /// the stall timeout applies to connection setup after didConnect, never to the outstanding
    /// pending connect: that one must stay with iOS until the official app's link comes back
    override func shouldTimeoutStalledConnectionSetup() -> Bool {
        !withStateLock { reconnectPolicy.pendingConnectOutstanding }
    }

    override func centralManagerDidUpdateState(_ central: CBCentralManager) {
        withStateLock {
            lastCentralState = central.state
            lastCentral = central
            // iOS drops pending connects when Bluetooth is not powered on
            if central.state != .poweredOn { reconnectPolicy.pendingConnectEnded() }
        }

        trace("in centralManagerDidUpdateState, new state is %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, central.state.toString())

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bluetoothTransmitterDelegate?.deviceDidUpdateBluetoothState(state: central.state, bluetoothTransmitter: self)
        }

        guard central.state == .poweredOn else { return }

        if getConnectionStatus() == .connected, let restored = withStateLock({ restoredPeripheral }) {
            // restoration can report a connected peripheral before Bluetooth is powered on: redo setup now
            trace("restored peripheral is connected, restarting service discovery", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info)
            restored.delegate = self
            centralManager(central, didConnect: restored)
            return
        }

        if getConnectionStatus() == .connecting || getConnectionStatus() == .connected {
            return
        }

        // base would call central.connect for the stored identifier. Only retrieveConnected is used here
        _ = attemptRetrieveConnected(trigger: "poweredOn")
    }

    override func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        super.centralManager(central, willRestoreState: dict)

        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first,
              deviceAddress == nil || restored.identifier.uuidString == deviceAddress else { return }
        withStateLock {
            restoredPeripheral = restored
            lastCentral = central
        }
    }

    /// base retries central.connect immediately, which could loop. Use the back-off instead
    override func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectionTimer()
        withStateLock {
            lastCentral = central
            reconnectPolicy.pendingConnectEnded()
        }
        trace("in didFailToConnect, error = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, error?.localizedDescription ?? "none")
        _ = attemptRetrieveConnected(trigger: "didFailToConnect")
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        withStateLock {
            lastCentral = central
            // clear before super, so the base arms the setup timeout for this connection
            reconnectPolicy.pendingConnectEnded()
            restoredPeripheral = peripheral
            readCharacteristicUUIDs.removeAll()
            notifyCharacteristic = nil
            diagnosticsStorage.statusMessage = Self.connectedWaitingMessage
        }
        trace("connected to peripheral name = %{public}@, id = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, peripheral.name ?? "<unnamed>", peripheral.identifier.uuidString)

        super.centralManager(central, didConnect: peripheral)

        startWatchdog()
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        withStateLock {
            watchdogGeneration += 1
            notifyCharacteristic = nil
            restoredPeripheral = peripheral
            lastCentral = central
            reconnectPolicy.pendingConnectEnded()
        }
        trace("disconnected, error = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, error?.localizedDescription ?? "none")

        // base calls reconnectAfterDisconnect or startScanning, both are overridden and go through the back-off
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    /// performs a retrieveConnected attempt if the back-off allows it, otherwise makes sure a retry is scheduled
    private func attemptRetrieveConnected(trigger: String) -> BluetoothTransmitter.startScanningResult {

        let now = Date()

        reconcileStalePendingConnect()

        let (delay, centralState, released): (TimeInterval?, CBManagerState?, Bool) = withStateLock {
            guard !isReleased else { return (nil, lastCentralState, true) }
            let delay = reconnectPolicy.requestAttempt(now: now)
            if delay != nil {
                retrieveAttempts += 1
            }
            return (delay, lastCentralState, false)
        }

        if released { return .other(reason: "released") }

        guard delay != nil else {
            trace("retrieveConnected suppressed by back-off, trigger = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .debug, trigger)
            scheduleRetryIfNeeded()
            return result(for: centralState)
        }

        var found = false
        if centralState == .poweredOn {
            // after the first connection only the stored peripheral is accepted
            found = retrieveConnectedPeripheral(withServiceUUIDs: [serviceCBUUID], allowFallback: deviceAddress == nil)
        }

        trace("retrieveConnected attempt %{public}@, trigger = %{public}@, central state = %{public}@, found = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, retrieveConnectedAttemptCount.description, trigger, centralState?.toString() ?? "not yet known", found.description)

        if found {
            updateDiagnostics { $0.statusMessage = Self.connectingMessage }
            return .connecting
        }

        updateDiagnostics { $0.statusMessage = Self.officialAppNotConnectedMessage }

        let hasKnownPeripheral = centralState == .poweredOn && systemKnowsStoredPeripheral()
        reconcileStalePendingConnect()
        let recovery: SibionicsGS1ReconnectPolicy.Recovery = withStateLock {
            reconnectPolicy.afterFailedAttempt(hasKnownPeripheral: hasKnownPeripheral)
        }

        switch recovery {
        case .pendingConnect:
            if issuePendingConnect() {
                return .connecting
            }
            withStateLock { reconnectPolicy.pendingConnectEnded() }
            scheduleRetryIfNeeded()
        case .waitForPendingConnect:
            trace("pending connect already outstanding, trigger = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .debug, trigger)
            return .connecting
        case .retryWithBackoff:
            scheduleRetryIfNeeded()
        }
        return result(for: centralState)
    }

    /// true if a peripheral was stored and the system still knows its identifier
    private func systemKnowsStoredPeripheral() -> Bool {
        guard let deviceAddress, let identifier = UUID(uuidString: deviceAddress),
              let central = withStateLock({ lastCentral }), central.state == .poweredOn else { return false }
        return !central.retrievePeripherals(withIdentifiers: [identifier]).isEmpty
    }

    /// leaves exactly one OS-level connect request for the stored peripheral, without stall timeout
    /// (shouldTimeoutStalledConnectionSetup is false while it is outstanding). No write and no scan:
    /// iOS completes it when the official app re-establishes the shared link and then wakes xDrip
    private func issuePendingConnect() -> Bool {
        switch getConnectionStatus() {
        case .connecting, .connected:
            // already pending or connected: never issue a duplicate connect
            return true
        case .disconnecting:
            return false
        default:
            trace("PENDING CONNECT for stored peripheral %{public}@, no timeout", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, deviceAddress ?? "-")
            // base connect: retrievePeripherals(withIdentifiers:) then central.connect, keeps the base peripheral reference.
            // It runs asynchronously on the Core Bluetooth queue, so verify afterwards that a connect was really issued
            super.connect()
            runOnCentralQueue(after: pendingConnectVerificationDelay) { [weak self] in
                self?.verifyPendingConnectIssued()
            }
            return true
        }
    }

    /// if the base could not issue the connect (identifier unknown, no central), clear the flag and fall back to the back-off
    private func verifyPendingConnectIssued() {
        guard withStateLock({ !isReleased && reconnectPolicy.pendingConnectOutstanding }) else { return }
        if reconcileStalePendingConnect() {
            trace("PENDING CONNECT was not issued, falling back to back-off retrieveConnected", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error)
            scheduleRetryIfNeeded()
        }
    }

    /// clears the pending-connect flag if the peripheral is not actually connecting. Returns true if cleared
    @discardableResult
    private func reconcileStalePendingConnect() -> Bool {
        let status = getConnectionStatus()
        let isConnecting = status == .connecting || status == .connected
        let cleared: Bool = withStateLock { reconnectPolicy.reconcilePendingConnect(peripheralIsConnecting: isConnecting) }
        if cleared {
            trace("stale pending connect flag cleared, peripheral state = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, status.map { String(describing: $0.rawValue) } ?? "none")
        }
        return cleared
    }

    /// own disconnect: xDrip's connect request (pending or not) ends here, didDisconnect may not follow for a pending one
    override func disconnect() {
        withStateLock { reconnectPolicy.pendingConnectEnded() }
        super.disconnect()
    }

    private func result(for centralState: CBManagerState?) -> BluetoothTransmitter.startScanningResult {
        switch centralState {
        case .poweredOff:
            return .poweredOff
        case .unauthorized:
            return .unauthorized
        default:
            // "looking for the official app's connection", a retry is scheduled
            return .alreadyScanning
        }
    }

    private func scheduleRetryIfNeeded() {

        // a stale pending-connect flag must never block the retry (also in the back-off suppressed path)
        reconcileStalePendingConnect()

        let delay: TimeInterval? = withStateLock {
            guard !retryPending, !isReleased, !reconnectPolicy.pendingConnectOutstanding else { return nil }
            retryPending = true
            return max(0.5, reconnectPolicy.nextAllowedAttempt.timeIntervalSinceNow)
        }

        guard let delay else { return }

        let generation = withStateLock { retryGeneration }

        let backgroundTask: SibionicsGS1BackgroundTask? = UserDefaults.standard.appInForeGround ? nil : SibionicsGS1BackgroundTask()
        backgroundTask?.begin()
        withStateLock {
            retryBackgroundTask?.end()
            retryBackgroundTask = backgroundTask
        }

        trace("scheduling retrieveConnected retry in %{public}@ seconds", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, String(format: "%.1f", delay))

        runOnCentralQueue(after: delay) { [weak self] in
            guard let self else {
                backgroundTask?.end()
                return
            }
            let released: Bool = self.withStateLock {
                guard self.retryGeneration == generation else { return true }
                self.retryPending = false
                if self.retryBackgroundTask === backgroundTask {
                    self.retryBackgroundTask = nil
                }
                return self.isReleased
            }
            defer { backgroundTask?.end() }

            guard !released else { return }

            switch self.getConnectionStatus() {
            case .connected, .connecting:
                return
            default:
                _ = self.attemptRetrieveConnected(trigger: "back-off retry")
            }
        }
    }

    // MARK: - watchdog

    private func startWatchdog() {
        let generation: Int = withStateLock {
            watchdogGeneration += 1
            watchdogReferenceDate = Date()
            resubscribedSinceReference = false
            return watchdogGeneration
        }
        scheduleWatchdogTick(generation: generation)
    }

    private func scheduleWatchdogTick(generation: Int) {
        runOnCentralQueue(after: watchdogTickInterval) { [weak self] in
            self?.watchdogTick(generation: generation)
        }
    }

    private func watchdogTick(generation: Int) {

        let (action, characteristic, elapsed): (SibionicsGS1Watchdog.Action?, CBCharacteristic?, TimeInterval) = withStateLock {
            guard !isReleased, watchdogGeneration == generation else { return (nil, nil, 0) }
            let elapsed = Date().timeIntervalSince(watchdogReferenceDate)
            let action = SibionicsGS1Watchdog.action(secondsWithoutGlucose: elapsed, alreadyResubscribed: resubscribedSinceReference)
            if action == .resubscribe { resubscribedSinceReference = true }
            if action == .release { watchdogGeneration += 1 }
            return (action, notifyCharacteristic, elapsed)
        }

        guard let action else { return }

        guard getConnectionStatus() == .connected else { return }

        switch action {

        case .none:
            break

        case .resubscribe:
            trace("watchdog: no valid glucose packet for %{public}@ seconds, re-subscribing to FF31", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, Int(elapsed).description)
            updateDiagnostics { $0.statusMessage = Self.resubscribedMessage }
            if let characteristic {
                setNotifyValue(false, for: characteristic)
                setNotifyValue(true, for: characteristic)
            }

        case .release:
            trace("watchdog: no valid glucose packet for %{public}@ seconds, releasing own connection and retrieving again", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, Int(elapsed).description)
            updateDiagnostics { $0.statusMessage = Self.releasedMessage }
            // base disconnect unsubscribes FF31 first, then cancels only xDrip's own connection request.
            // didDisconnect then goes through reconnectAfterDisconnect, i.e. the back-off retrieve
            disconnect()
            return

        }

        scheduleWatchdogTick(generation: generation)
    }

    // MARK: - discovery and notifications

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {

        // base subscribes FF31 (the receive characteristic) with setNotifyValue(true)
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {

            trace("discovered characteristic %{public}@ in service %{public}@, properties = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, characteristic.uuid.uuidString, service.uuid.uuidString, Self.describe(characteristic.properties))

            if characteristic.uuid == notifyCBUUID {
                withStateLock { notifyCharacteristic = characteristic }
                continue
            }

            let shouldRead = (service.uuid == deviceInformationServiceCBUUID || characteristic.uuid == batteryLevelCBUUID) && characteristic.properties.contains(.read)

            if shouldRead {
                let firstTime: Bool = withStateLock { readCharacteristicUUIDs.insert(characteristic.uuid).inserted }
                if firstTime {
                    readValueForCharacteristic(for: characteristic)
                }
            }
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)

        guard characteristic.uuid == notifyCBUUID else { return }
        trace("FF31 notifications enabled = %{public}@, error = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, characteristic.isNotifying.description, error?.localizedDescription ?? "none")
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)

        guard error == nil, let value = characteristic.value else { return }

        if characteristic.uuid == notifyCBUUID {
            handleNotification(value, now: Date())
            return
        }

        if characteristic.uuid == batteryLevelCBUUID {
            if let percent = StandardBluetoothBatteryLevel.percentage(from: value) {
                updateDiagnostics { $0.batteryPercent = percent }
                trace("battery level = %{public}@ percent", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, percent.description)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.bluetoothTransmitterDelegate?.didUpdateBatteryLevel(percent, bluetoothTransmitter: self)
                }
            } else {
                trace("invalid battery level, hex = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, value.hexEncodedString())
            }
            return
        }

        if characteristic.service?.uuid == deviceInformationServiceCBUUID {
            let text = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
            trace("device information %{public}@ = %{public}@ (hex %{public}@)", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, characteristic.uuid.uuidString, text, value.hexEncodedString())
            return
        }

        trace("value for characteristic %{public}@, hex = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, characteristic.uuid.uuidString, value.hexEncodedString())
    }

    // MARK: - packet handling

    /// processes one FF31 notification. Called by didUpdateValueFor, internal for tests
    func handleNotification(_ data: Data, now: Date) {

        trace("FF31 raw = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, data.hexEncodedString())

        let packet = SibionicsGS1Protocol.classify(data, receivedAt: now)

        switch packet {

        case .records(let firmware, let records, let reindex):
            handleRecords(firmware: firmware, records: records, reindex: reindex, now: now)

        case .ack(let cmd, let status, let aux):
            trace("ACK cmd = %{public}@, status = %{public}@, aux = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, String(format: "0x%02X", cmd), status.description, aux.description)

        case .unknownData(let cmd, let decrypted):
            updateDiagnostics { $0.unknownPacketCount += 1 }
            trace("UNKNOWN-DATA cmd = %{public}@, decrypted = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, String(format: "0x%02X", cmd), decrypted.hexEncodedString())

        case .invalid(let raw, let decrypted):
            trace("INVALID raw = %{public}@, decrypted = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .error, raw.hexEncodedString(), decrypted.hexEncodedString())

        }
    }

    private func handleRecords(firmware: SibionicsGS1Firmware, records: [SibionicsGS1Record], reindex: Int?, now: Date) {

        trace("glucose packet, firmware = %{public}@, records = %{public}@, reindex = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, String(describing: firmware), records.count.description, reindex?.description ?? "-")

        for record in records {
            trace("record index = %{public}@, itime = %{public}@, temp = %{public}@, raw mmol/L = %{public}@, dump = %{public}@, extra = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, record.index.description, Int(record.timeStamp.timeIntervalSince1970).description, record.temperatureC.description, record.rawMmol.description, record.dump.description, record.extra.description)
            // fixed format comparison line, for every record including the ones that are skipped
            trace("%{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, SibionicsGS1Protocol.comparisonLine(record, calibratedMgDl: nil))
        }

        var state = loadSessionState()
        let result = SibionicsGS1Session.process(records, state: &state, now: now)
        saveSessionState(state)

        for skipped in result.skipped {
            trace("record index %{public}@ not delivered, reason = %{public}@", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, skipped.record.index.description, skipped.reason)
        }

        let newest = records.max(by: { $0.index < $1.index })

        // any decodable glucose packet proves that the stream is alive: feed the watchdog and reset the back-off
        let batteryPercent: Int? = withStateLock {
            diagnosticsStorage.firmware = firmware
            diagnosticsStorage.lastPacketDate = now
            if let newest {
                diagnosticsStorage.lastIndex = newest.index
                diagnosticsStorage.lastRawMmol = newest.rawMmol
            }
            diagnosticsStorage.statusMessage = Self.receivingMessage
            watchdogReferenceDate = Date()
            resubscribedSinceReference = false
            reconnectPolicy.reset()
            return diagnosticsStorage.batteryPercent
        }

        let newSensorStartDate = result.newSensorStartDate

        // newest first, as expected by CGMTransmitterDelegate
        var glucoseData = result.newRecords
            .sorted(by: { $0.timeStamp > $1.timeStamp })
            .map { GlucoseData(timeStamp: $0.timeStamp, glucoseLevelRaw: $0.glucoseLevelRaw) }

        guard !glucoseData.isEmpty || newSensorStartDate != nil else { return }

        let sensorAge: TimeInterval? = state.sensorStartDate.map { start in
            max(0, (glucoseData.first?.timeStamp ?? now).timeIntervalSince(start))
        }

        let batteryInfo: TransmitterBatteryInfo? = batteryPercent.map { .percentage(percentage: $0) }

        trace("delivering %{public}@ new reading(s), sensor age = %{public}@ s", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, glucoseData.count.description, sensorAge.map { Int($0).description } ?? "-")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // a new session only replaces an existing xDrip sensor if its start really differs.
            // Without an active sensor, the sensorAge passed below starts one.
            if let newSensorStartDate,
               let activeSensorStartDate = UserDefaults.standard.activeSensorStartDate,
               abs(activeSensorStartDate.timeIntervalSince(newSensorStartDate)) > self.sensorSessionTolerance {
                trace("new sensor session detected, start = %{public}@", log: self.log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info, newSensorStartDate.description(with: .current))
                self.cgmTransmitterDelegate?.newSensorDetected(sensorStartDate: newSensorStartDate)
            }

            if !glucoseData.isEmpty {
                self.cgmTransmitterDelegate?.cgmTransmitterInfoReceived(glucoseData: &glucoseData, transmitterBatteryInfo: batteryInfo, sensorAge: sensorAge)
            }
        }
    }

    // MARK: - session state persistence

    private func loadSessionState() -> SibionicsGS1SessionState {
        let defaults = UserDefaults.standard
        return SibionicsGS1SessionState(
            lastReceivedIndex: defaults.object(forKey: DefaultsKey.lastReceivedIndex) as? Int ?? -1,
            sensorStartDate: defaults.object(forKey: DefaultsKey.sensorStartDate) as? Date,
            lastReadingDate: defaults.object(forKey: DefaultsKey.lastReadingDate) as? Date,
            lastRecordDate: defaults.object(forKey: DefaultsKey.lastRecordDate) as? Date
        )
    }

    private func saveSessionState(_ state: SibionicsGS1SessionState) {
        let defaults = UserDefaults.standard
        defaults.set(state.lastReceivedIndex, forKey: DefaultsKey.lastReceivedIndex)
        Self.set(state.sensorStartDate, forKey: DefaultsKey.sensorStartDate, in: defaults)
        Self.set(state.lastReadingDate, forKey: DefaultsKey.lastReadingDate, in: defaults)
        Self.set(state.lastRecordDate, forKey: DefaultsKey.lastRecordDate, in: defaults)
    }

    private static func set(_ date: Date?, forKey key: String, in defaults: UserDefaults) {
        if let date {
            defaults.set(date, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - release

    override func prepareForRelease() {
        let characteristic: CBCharacteristic? = withStateLock {
            isReleased = true
            watchdogGeneration += 1
            retryGeneration += 1
            reconnectPolicy.pendingConnectEnded()
            retryBackgroundTask?.end()
            retryBackgroundTask = nil
            let characteristic = notifyCharacteristic
            notifyCharacteristic = nil
            return characteristic
        }

        // release the FF31 subscription before the base clears the delegates (both run in order on the Core Bluetooth queue)
        if let characteristic, getConnectionStatus() == .connected {
            trace("in prepareForRelease, unsubscribing FF31", log: log, category: ConstantsLog.categoryCGMSibionicsGS1, type: .info)
            setNotifyValue(false, for: characteristic)
        }

        super.prepareForRelease()
    }

    // MARK: - helpers

    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func updateDiagnostics(_ block: (inout SibionicsGS1Diagnostics) -> Void) {
        withStateLock { block(&diagnosticsStorage) }
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        var names = [String]()
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType {
        return .sibionicsGS1
    }

    func maxSensorAgeInDays() -> Double? {
        return ConstantsSibionicsGS1.sensorLifeDays
    }

    func sensorWarmupDurationInMinutes() -> Double? {
        return ConstantsSibionicsGS1.warmupMinutes
    }

    func getCBUUID_Service() -> String { return ConstantsSibionicsGS1.serviceUUID }

    func getCBUUID_Receive() -> String { return ConstantsSibionicsGS1.notifyCharacteristicUUID }

    /// the official app owns the sensor lifecycle, the start is inferred from the packets
    func needsSensorStartTime() -> Bool { return false }

    /// raw values, calibrated by xDrip with Libre1Calibrator
    func isWebOOPEnabled() -> Bool { return false }

    func isNonFixedSlopeEnabled() -> Bool { return false }

}
