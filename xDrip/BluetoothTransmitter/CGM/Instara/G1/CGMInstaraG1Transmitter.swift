// Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.

import Foundation
import CoreBluetooth
import os
import UIKit

/// read-only diagnostics for the peripheral detail screen and the trace file
struct InstaraG1Diagnostics: Equatable {
    /// hardware / software version from the handshake (0xF0)
    var firmware: String?
    var batteryPercent: Int?
    /// sequence number of the latest realtime packet
    var lastSeq: Int?
    /// value of the latest realtime packet as sent by the sensor
    var lastRawMmol: Double?
    /// latest decodable packet
    var lastPacketDate: Date?
    /// InstaraG1Session.intervalMinutes of the current session state
    var intervalMinutes: Int = ConstantsInstaraG1.defaultIntervalMinutes
    var unlistedPacketCount: Int = 0
    var invalidPacketCount: Int = 0
    var statusMessage: String = ""
}

/// pure back-off decision for re-retrieving the peripheral that the official Instara app holds.
///
/// Every granted attempt reserves the next slot, so callers that fire in quick succession
/// (didDisconnect, connect timeout, the UI) can never produce a tight retrieve/connect loop.
/// Only a glucose packet resets the back-off.
struct InstaraG1ReconnectPolicy {

    let delays: [TimeInterval]

    private(set) var attempt = 0

    private(set) var nextAllowedAttempt = Date.distantPast

    init(delays: [TimeInterval] = ConstantsInstaraG1.reconnectDelays) {
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
        pendingConnectSuppressedUntil = .distantPast
    }

    /// what to do after a retrieveConnected attempt found nothing
    enum Recovery: Equatable {
        /// leave exactly one OS-level pending connect for the known peripheral, without stall timeout
        case pendingConnect
        /// a pending connect is already outstanding, do nothing
        case waitForPendingConnect
        /// no known peripheral (or pending connects suppressed): retry retrieveConnected after the back-off delay
        case retryWithBackoff
    }

    private(set) var pendingConnectOutstanding = false

    /// how long pending connects stay suppressed after a link created by xDrip's pending connect ended without glucose
    static let pendingConnectSuppression: TimeInterval = 10 * 60

    private(set) var pendingConnectSuppressedUntil = Date.distantPast

    mutating func afterFailedAttempt(hasKnownPeripheral: Bool, now: Date = Date()) -> Recovery {
        guard hasKnownPeripheral else { return .retryWithBackoff }
        if pendingConnectOutstanding { return .waitForPendingConnect }
        if now < pendingConnectSuppressedUntil { return .retryWithBackoff }
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

    /// to be called when a link created by xDrip's pending connect ends. Without glucose the official app was most likely absent
    mutating func pendingConnectLinkEnded(receivedGlucose: Bool, now: Date) {
        guard !receivedGlucose else { return }
        pendingConnectSuppressedUntil = now.addingTimeInterval(Self.pendingConnectSuppression)
    }

}

/// pure watchdog decision: resubscribe after 900 s, release after 1800 s without glucose
enum InstaraG1Watchdog {

    enum Action: Equatable {
        case none
        /// setNotifyValue(false) then setNotifyValue(true) on 8653000B
        case resubscribe
        /// release xDrip's own connection request and go back to back-off retrieval
        case release
    }

    static func action(secondsWithoutGlucose: TimeInterval, alreadyResubscribed: Bool) -> Action {
        if secondsWithoutGlucose >= TimeInterval(ConstantsInstaraG1.releaseAfterSeconds) {
            return .release
        }
        if secondsWithoutGlucose >= TimeInterval(ConstantsInstaraG1.resubscribeAfterSeconds) && !alreadyResubscribed {
            return .resubscribe
        }
        return .none
    }

}

private final class InstaraG1BackgroundTask {
    private let lock = NSLock()
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        let newIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Instara G1 retrieve",
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

/// Passive co-listener for the Instara G1 CGM.
///
/// The official Instara app owns the BLE session with the sensor. xDrip retrieves the peripheral that
/// is already connected to the system, subscribes to the 8653000B notifications and decodes the frames.
/// xDrip never writes anything to the sensor: all write paths of the base class are overridden and
/// blocked. A real scan is never started.
@objcMembers
class CGMInstaraG1Transmitter: BluetoothTransmitter, CGMTransmitter {

    private enum DefaultsKey {
        /// JSON encoded InstaraG1SessionState
        static let sessionState = "instaraG1.sessionState"
    }

    /// used as BLE name when the peripheral does not advertise one, so that it can be added
    static let fallbackName = "Instara G1"

    /// verification and session sensor start may differ this much before the verification is revoked
    static let sensorMismatchTolerance: TimeInterval = 30 * 60

    // MARK: - status messages (user visible, localised in Texts_BluetoothPeripheralView)

    static let officialAppNotConnectedMessage = Texts_BluetoothPeripheralView.instaraG1StatusOfficialAppNotConnected

    static let connectingMessage = Texts_BluetoothPeripheralView.instaraG1StatusConnecting

    static let connectedWaitingMessage = Texts_BluetoothPeripheralView.instaraG1StatusConnectedWaiting

    static let receivingMessage = Texts_BluetoothPeripheralView.instaraG1StatusReceiving

    static let resubscribedMessage = Texts_BluetoothPeripheralView.instaraG1StatusResubscribed

    static let releasedMessage = Texts_BluetoothPeripheralView.instaraG1StatusReleased

    // MARK: - properties

    private let serviceCBUUID = CBUUID(string: ConstantsInstaraG1.serviceUUID)

    private let notifyCBUUID = CBUUID(string: ConstantsInstaraG1.notifyCharacteristicUUID)

    /// delay after which an issued pending connect is verified (the base issues it asynchronously)
    private let pendingConnectVerificationDelay: TimeInterval = 1

    /// interval of the watchdog tick while connected
    private let watchdogTickInterval: TimeInterval = 60

    private(set) weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMInstaraG1)

    /// protects all mutable state below. Never held while calling into the base class, because
    /// several base methods synchronously enter the Core Bluetooth queue.
    private let stateLock = NSLock()

    private var diagnosticsStorage = InstaraG1Diagnostics()

    private var assembler = InstaraG1FrameAssembler()

    private var reconnectPolicy = InstaraG1ReconnectPolicy()

    private var retryPending = false

    /// invalidates a scheduled retry
    private var retryGeneration = 0

    private var retryBackgroundTask: InstaraG1BackgroundTask?

    private var retrieveAttempts = 0

    private var blockedWrites = 0

    private var isReleased = false

    private var lastCentralState: CBManagerState?

    /// central from the latest Core Bluetooth callback
    private weak var lastCentral: CBCentralManager?

    private weak var restoredPeripheral: CBPeripheral?

    private var notifyCharacteristic: CBCharacteristic?

    private var watchdogGeneration = 0

    /// last glucose packet, or the moment of connection if none yet
    private var watchdogReferenceDate = Date()

    private var resubscribedSinceReference = false

    /// origin of the next / current link, for the LINK-OWNER trace and the pending connect suppression
    private enum LinkOrigin {
        case unknown
        /// retrieveConnected found the peripheral already connected to the system (the official app holds it)
        case official
        /// xDrip's own pending connect
        case xdrip
    }

    private var nextLinkOrigin = LinkOrigin.unknown

    private var currentLinkOrigin = LinkOrigin.unknown

    private var glucoseOnCurrentLink = false

    // MARK: - test / diagnostics accessors

    private(set) var diagnostics: InstaraG1Diagnostics {
        get { withStateLock { diagnosticsStorage } }
        set { withStateLock { diagnosticsStorage = newValue } }
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

    // MARK: - Initialization

    init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {

        var newAddressAndName: BluetoothTransmitter.DeviceAddressAndName = .notYetConnected(expectedName: nil)
        if let address = address {
            newAddressAndName = .alreadyConnectedBefore(address: address, name: name)
        }

        self.cgmTransmitterDelegate = cGMTransmitterDelegate

        // the write characteristic is recognised, but never used: every write path is blocked below
        super.init(
            addressAndName: newAddressAndName,
            CBUUID_Advertisement: nil,
            servicesCBUUIDs: [CBUUID(string: ConstantsInstaraG1.serviceUUID)],
            CBUUID_ReceiveCharacteristic: ConstantsInstaraG1.notifyCharacteristicUUID,
            CBUUID_WriteCharacteristic: ConstantsInstaraG1.writeCharacteristicUUID,
            bluetoothTransmitterDelegate: bluetoothTransmitterDelegate
        )

        let intervalMinutes = UserDefaults.standard.instaraG1IntervalMinutes
        updateDiagnostics {
            $0.statusMessage = Self.officialAppNotConnectedMessage
            $0.intervalMinutes = intervalMinutes
        }
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
        trace("BLOCKED WRITE to %{public}@, %{public}@ bytes, hex = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, characteristic?.uuid.uuidString ?? "write characteristic", data.count.description, data.hexEncodedString())
        return false
    }

    // MARK: - connection (passive: retrieveConnected only, never a real scan)

    /// a G1 without BLE name would otherwise never be added (the manager requires a name)
    override func fallbackDeviceName() -> String? {
        Self.fallbackName
    }

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

    /// external connect requests (manager at launch, detail screen) go through the same path
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

    /// the stall timeout never cancels the outstanding pending connect
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

        trace("in centralManagerDidUpdateState, new state is %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, central.state.toString())

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bluetoothTransmitterDelegate?.deviceDidUpdateBluetoothState(state: central.state, bluetoothTransmitter: self)
        }

        guard central.state == .poweredOn else { return }

        if getConnectionStatus() == .connected, let restored = withStateLock({ restoredPeripheral }) {
            // restoration can report a connected peripheral before Bluetooth is powered on: redo setup now
            trace("restored peripheral is connected, restarting service discovery", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info)
            restored.delegate = self
            centralManager(central, didConnect: restored)
            return
        }

        if getConnectionStatus() == .connecting || getConnectionStatus() == .connected {
            return
        }

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
        trace("in didFailToConnect, error = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, error?.localizedDescription ?? "none")
        _ = attemptRetrieveConnected(trigger: "didFailToConnect")
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let origin: LinkOrigin = withStateLock {
            lastCentral = central
            currentLinkOrigin = nextLinkOrigin
            nextLinkOrigin = .unknown
            glucoseOnCurrentLink = false
            // clear before super, so the base arms the setup timeout for this connection
            reconnectPolicy.pendingConnectEnded()
            restoredPeripheral = peripheral
            notifyCharacteristic = nil
            // a partial frame of a previous link never completes
            assembler = InstaraG1FrameAssembler()
            diagnosticsStorage.statusMessage = Self.connectedWaitingMessage
            return currentLinkOrigin
        }
        trace("connected to peripheral name = %{public}@, id = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, peripheral.name ?? "<unnamed>", peripheral.identifier.uuidString)
        trace("LINK-OWNER %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, Self.describe(origin))

        super.centralManager(central, didConnect: peripheral)

        startWatchdog()
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let suppressed: Bool = withStateLock {
            watchdogGeneration += 1
            notifyCharacteristic = nil
            restoredPeripheral = peripheral
            lastCentral = central
            reconnectPolicy.pendingConnectEnded()
            let suppress = currentLinkOrigin == .xdrip && !glucoseOnCurrentLink
            if currentLinkOrigin == .xdrip {
                reconnectPolicy.pendingConnectLinkEnded(receivedGlucose: glucoseOnCurrentLink, now: Date())
            }
            currentLinkOrigin = .unknown
            glucoseOnCurrentLink = false
            return suppress
        }
        trace("disconnected, error = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, error?.localizedDescription ?? "none")
        if suppressed {
            trace("link created by xDrip's pending connect ended without glucose (official app absent?), no pending connect for %{public}@ s, retrieveConnected back-off continues", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, Int(InstaraG1ReconnectPolicy.pendingConnectSuppression).description)
        }

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
            trace("retrieveConnected suppressed by back-off, trigger = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .debug, trigger)
            scheduleRetryIfNeeded()
            return result(for: centralState)
        }

        var found = false
        if centralState == .poweredOn {
            logConnectedServicePeripherals()
            // set before the connect is issued: didConnect can arrive before retrieveConnectedPeripheral returns
            let previousOrigin: LinkOrigin = withStateLock {
                let previous = nextLinkOrigin
                nextLinkOrigin = .official
                return previous
            }
            // after the first connection only the stored peripheral is accepted
            found = retrieveConnectedPeripheral(withServiceUUIDs: [serviceCBUUID], allowFallback: deviceAddress == nil)
            if !found {
                withStateLock { if nextLinkOrigin == .official { nextLinkOrigin = previousOrigin } }
            }
        }

        trace("retrieveConnected attempt %{public}@, trigger = %{public}@, central state = %{public}@, found = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, retrieveConnectedAttemptCount.description, trigger, centralState?.toString() ?? "not yet known", found.description)

        if found {
            updateDiagnostics { $0.statusMessage = Self.connectingMessage }
            return .connecting
        }

        updateDiagnostics { $0.statusMessage = Self.officialAppNotConnectedMessage }

        let hasKnownPeripheral = centralState == .poweredOn && systemKnowsStoredPeripheral()
        reconcileStalePendingConnect()
        let recovery: InstaraG1ReconnectPolicy.Recovery = withStateLock {
            reconnectPolicy.afterFailedAttempt(hasKnownPeripheral: hasKnownPeripheral, now: now)
        }

        switch recovery {
        case .pendingConnect:
            if issuePendingConnect() {
                return .connecting
            }
            withStateLock { reconnectPolicy.pendingConnectEnded() }
            scheduleRetryIfNeeded()
        case .waitForPendingConnect:
            trace("pending connect already outstanding, trigger = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .debug, trigger)
            return .connecting
        case .retryWithBackoff:
            scheduleRetryIfNeeded()
        }
        return result(for: centralState)
    }

    /// triage: every system-connected 8653000A peripheral (more than one sensor nearby, or none), logging only
    private func logConnectedServicePeripherals() {
        guard let central = withStateLock({ lastCentral }), central.state == .poweredOn else {
            trace("8653000A connected peripherals: central not known", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info)
            return
        }
        let peripherals = central.retrieveConnectedPeripherals(withServices: [serviceCBUUID])
        let list = peripherals.map { "\($0.name ?? "<unnamed>")/\($0.identifier.uuidString)" }.joined(separator: ", ")
        trace("8653000A connected peripherals: count = %{public}@, [%{public}@], stored = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, peripherals.count.description, list, deviceAddress ?? "-")
    }

    /// true if a peripheral was stored and the system still knows its identifier
    private func systemKnowsStoredPeripheral() -> Bool {
        guard let deviceAddress, let identifier = UUID(uuidString: deviceAddress),
              let central = withStateLock({ lastCentral }), central.state == .poweredOn else { return false }
        return !central.retrievePeripherals(withIdentifiers: [identifier]).isEmpty
    }

    /// leaves exactly one OS-level connect request for the stored peripheral, without stall timeout.
    /// No write and no scan: iOS completes it when the official app re-establishes the shared link
    private func issuePendingConnect() -> Bool {
        switch getConnectionStatus() {
        case .connecting, .connected:
            return true
        case .disconnecting:
            return false
        default:
            trace("PENDING CONNECT for stored peripheral %{public}@, no timeout", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, deviceAddress ?? "-")
            withStateLock { nextLinkOrigin = .xdrip }
            // base connect runs asynchronously on the Core Bluetooth queue, verify afterwards that it was really issued
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
            trace("PENDING CONNECT was not issued, falling back to back-off retrieveConnected", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error)
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
            trace("stale pending connect flag cleared, peripheral state = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, status.map { String(describing: $0.rawValue) } ?? "none")
        }
        return cleared
    }

    /// own disconnect: xDrip's connect request (pending or not) ends here
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

        // a stale pending-connect flag must never block the retry
        reconcileStalePendingConnect()

        let delay: TimeInterval? = withStateLock {
            guard !retryPending, !isReleased, !reconnectPolicy.pendingConnectOutstanding else { return nil }
            retryPending = true
            return max(0.5, reconnectPolicy.nextAllowedAttempt.timeIntervalSinceNow)
        }

        guard let delay else { return }

        let generation = withStateLock { retryGeneration }

        let backgroundTask: InstaraG1BackgroundTask? = UserDefaults.standard.appInForeGround ? nil : InstaraG1BackgroundTask()
        backgroundTask?.begin()
        withStateLock {
            retryBackgroundTask?.end()
            retryBackgroundTask = backgroundTask
        }

        trace("scheduling retrieveConnected retry in %{public}@ seconds", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, String(format: "%.1f", delay))

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

        let (action, characteristic, elapsed): (InstaraG1Watchdog.Action?, CBCharacteristic?, TimeInterval) = withStateLock {
            guard !isReleased, watchdogGeneration == generation else { return (nil, nil, 0) }
            let elapsed = Date().timeIntervalSince(watchdogReferenceDate)
            let action = InstaraG1Watchdog.action(secondsWithoutGlucose: elapsed, alreadyResubscribed: resubscribedSinceReference)
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
            trace("watchdog: no glucose packet for %{public}@ seconds, re-subscribing to 8653000B", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, Int(elapsed).description)
            updateDiagnostics { $0.statusMessage = Self.resubscribedMessage }
            if let characteristic {
                setNotifyValue(false, for: characteristic)
                setNotifyValue(true, for: characteristic)
            }

        case .release:
            trace("watchdog: no glucose packet for %{public}@ seconds, releasing own connection and retrieving again", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, Int(elapsed).description)
            updateDiagnostics { $0.statusMessage = Self.releasedMessage }
            // base disconnect unsubscribes first, then cancels only xDrip's own connection request.
            // didDisconnect then goes through reconnectAfterDisconnect, i.e. the back-off retrieve
            disconnect()
            return

        }

        scheduleWatchdogTick(generation: generation)
    }

    // MARK: - discovery and notifications

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {

        // base subscribes 8653000B (the receive characteristic) with setNotifyValue(true)
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            trace("discovered characteristic %{public}@ in service %{public}@, properties = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, characteristic.uuid.uuidString, service.uuid.uuidString, Self.describe(characteristic.properties))
            if characteristic.uuid == notifyCBUUID {
                withStateLock { notifyCharacteristic = characteristic }
            }
        }
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)

        guard characteristic.uuid == notifyCBUUID else { return }
        trace("8653000B notifications enabled = %{public}@, error = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, characteristic.isNotifying.description, error?.localizedDescription ?? "none")
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        super.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)

        guard error == nil, let value = characteristic.value else { return }

        if characteristic.uuid == notifyCBUUID {
            handleNotification(value, now: Date())
            return
        }

        trace("value for characteristic %{public}@, hex = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, characteristic.uuid.uuidString, value.hexEncodedString())
    }

    // MARK: - packet handling

    /// processes one 8653000B notification. Called by didUpdateValueFor, internal for tests
    func handleNotification(_ data: Data, now: Date) {

        trace("8653000B raw = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, data.hexEncodedString())

        let packets: [InstaraG1Packet] = withStateLock { assembler.feed(data, now: now) }

        for packet in packets {
            trace("%{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, InstaraG1Protocol.logLine(packet))
            handlePacket(packet, now: now)
        }
    }

    private func handlePacket(_ packet: InstaraG1Packet, now: Date) {

        switch packet {

        case .realtime, .history, .interval:
            handleSessionPacket(packet, now: now)

        case .battery(let percent):
            updateDiagnostics {
                $0.batteryPercent = percent
                $0.lastPacketDate = now
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bluetoothTransmitterDelegate?.didUpdateBatteryLevel(percent, bluetoothTransmitter: self)
            }

        case .handshake(let hardware, let software):
            updateDiagnostics {
                $0.firmware = "HW \(hardware) / SW \(software)"
                $0.lastPacketDate = now
            }

        case .historyHeader:
            updateDiagnostics { $0.lastPacketDate = now }

        case .unlisted:
            updateDiagnostics {
                $0.unlistedPacketCount += 1
                $0.lastPacketDate = now
            }

        case .invalid:
            updateDiagnostics { $0.invalidPacketCount += 1 }

        }
    }

    private func handleSessionPacket(_ packet: InstaraG1Packet, now: Date) {

        let previousState = loadSessionState()
        var state = previousState
        let result = InstaraG1Session.process(packet, state: &state, receivedAt: now)

        for line in result.log {
            trace("%{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, line)
        }

        // seenSeqs can hold thousands of entries: only encode when something changed
        if state != previousState {
            saveSessionState(state)
        }

        let intervalMinutes = InstaraG1Session.intervalMinutes(state)
        if UserDefaults.standard.instaraG1IntervalMinutes != intervalMinutes {
            UserDefaults.standard.instaraG1IntervalMinutes = intervalMinutes
        }

        let isGlucosePacket: Bool
        switch packet {
        case .realtime, .history: isGlucosePacket = true
        default: isGlucosePacket = false
        }

        // any glucose packet proves that the stream is alive: feed the watchdog and reset the back-off
        let batteryPercent: Int? = withStateLock {
            diagnosticsStorage.lastPacketDate = now
            diagnosticsStorage.intervalMinutes = intervalMinutes
            if case let .realtime(seq, mmol) = packet {
                diagnosticsStorage.lastSeq = seq
                diagnosticsStorage.lastRawMmol = mmol
            }
            if isGlucosePacket {
                diagnosticsStorage.statusMessage = Self.receivingMessage
                watchdogReferenceDate = Date()
                resubscribedSinceReference = false
                reconnectPolicy.reset()
                glucoseOnCurrentLink = true
            }
            return diagnosticsStorage.batteryPercent
        }

        let readings = result.readings
        let newSensorStart = result.newSensorStart
        let sessionSensorStart = state.sensorStart

        guard !readings.isEmpty || newSensorStart != nil else { return }

        // newest first, as expected by CGMTransmitterDelegate. glucoseLevelRaw is mg/dL, NoCalibrator is used
        let newestFirst = readings.sorted { $0.timeStamp > $1.timeStamp }
        var glucoseData = newestFirst.map { GlucoseData(timeStamp: $0.timeStamp, glucoseLevelRaw: $0.mgDl) }

        let sensorAge: TimeInterval? = sessionSensorStart.map { start in
            max(0, (glucoseData.first?.timeStamp ?? now).timeIntervalSince(start))
        }

        let batteryInfo: TransmitterBatteryInfo? = batteryPercent.map { .percentage(percentage: $0) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let newSensorStart {
                trace("new sensor session detected, start = %{public}@", log: self.log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, newSensorStart.description(with: .current))
                // revoke first: nothing triggered by the new sensor may see an old verification
                UserDefaults.standard.setInstaraG1Verified(false, sensorStart: nil, reason: "new-sensor")
                self.cgmTransmitterDelegate?.newSensorDetected(sensorStartDate: newSensorStart)
            }

            // checked before every delivery: a verification belongs to one sensor
            Self.revokeVerificationIfSensorMismatch(sessionSensorStart: sessionSensorStart, log: self.log)

            guard !glucoseData.isEmpty else { return }

            let verified = UserDefaults.standard.instaraG1ExportVerified
            for reading in newestFirst {
                trace("INSTARA-RDG;%{public}@;%{public}@;%{public}@;%{public}@;%{public}@", log: self.log, category: ConstantsLog.categoryCGMInstaraG1, type: .info, reading.seq.description, reading.rawMmol.description, reading.mgDl.description, reading.clamped.description, verified.description)
            }

            self.cgmTransmitterDelegate?.cgmTransmitterInfoReceived(glucoseData: &glucoseData, transmitterBatteryInfo: batteryInfo, sensorAge: sensorAge)
        }
    }

    /// turns the verification off when it belongs to another sensor than the current session.
    /// Uses the stored (possibly locked) session start, never a start recomputed from the reference
    private static func revokeVerificationIfSensorMismatch(sessionSensorStart: Date?, log: OSLog) {
        let defaults = UserDefaults.standard
        guard defaults.instaraG1ExportVerified,
              let sessionSensorStart,
              let verifiedSensorStart = defaults.instaraG1VerifiedSensorStart else { return }
        guard abs(sessionSensorStart.timeIntervalSince(verifiedSensorStart)) > sensorMismatchTolerance else { return }
        trace("sensor mismatch, session start = %{public}@, verified start = %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, sessionSensorStart.description(with: .current), verifiedSensorStart.description(with: .current))
        defaults.setInstaraG1Verified(false, sensorStart: nil, reason: "sensor-mismatch")
    }

    // MARK: - session state persistence

    /// decoded on every session packet, so that several instances (temporary scan transmitter, restart) share the state
    private func loadSessionState() -> InstaraG1SessionState {
        guard let stored = UserDefaults.standard.object(forKey: DefaultsKey.sessionState) else {
            return InstaraG1SessionState()
        }
        guard let data = stored as? Data else {
            trace("session state is not data, starting from a fresh state", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error)
            return InstaraG1SessionState()
        }
        do {
            return try JSONDecoder().decode(InstaraG1SessionState.self, from: data)
        } catch {
            trace("session state could not be decoded (%{public}@), starting from a fresh state", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, error.localizedDescription)
            return InstaraG1SessionState()
        }
    }

    private func saveSessionState(_ state: InstaraG1SessionState) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: DefaultsKey.sessionState)
        } catch {
            trace("session state could not be encoded: %{public}@", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .error, error.localizedDescription)
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

        // release the subscription before the base clears the delegates (both run in order on the Core Bluetooth queue)
        if let characteristic, getConnectionStatus() == .connected {
            trace("in prepareForRelease, unsubscribing 8653000B", log: log, category: ConstantsLog.categoryCGMInstaraG1, type: .info)
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

    private func updateDiagnostics(_ block: (inout InstaraG1Diagnostics) -> Void) {
        withStateLock { block(&diagnosticsStorage) }
    }

    private static func describe(_ origin: LinkOrigin) -> String {
        switch origin {
        case .official: return "official (peripheral was already system-connected)"
        case .xdrip: return "xdrip (own pending connect)"
        case .unknown: return "unknown (restored or external connect)"
        }
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
        return .instaraG1
    }

    func maxSensorAgeInDays() -> Double? {
        return ConstantsInstaraG1.sensorLifeDays
    }

    func sensorWarmupDurationInMinutes() -> Double? {
        return ConstantsInstaraG1.warmupMinutes
    }

    func getCBUUID_Service() -> String { return ConstantsInstaraG1.serviceUUID }

    func getCBUUID_Receive() -> String { return ConstantsInstaraG1.notifyCharacteristicUUID }

    /// the official app owns the sensor lifecycle, the start is inferred from the packets
    func needsSensorStartTime() -> Bool { return false }

    /// mmol/L computed by the sensor, not calibrated (NoCalibrator)
    func isWebOOPEnabled() -> Bool { return false }

    func isNonFixedSlopeEnabled() -> Bool { return false }

}
