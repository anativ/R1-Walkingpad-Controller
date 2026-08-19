import Combine
import CoreBluetooth
import Foundation
import os

public enum PadConnectionState: Equatable, Sendable {
    case bluetoothUnavailable(String)
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    /// The scan ran its full window without seeing a belt. A terminal state, not a spinner.
    case notFound

    public var label: String {
        switch self {
        case .bluetoothUnavailable(let why): return why
        case .idle: return "Not connected"
        case .scanning: return "Searching for belt…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name): return name
        case .notFound: return "No belt found"
        }
    }

    /// Extra guidance shown under the status line, when there is something useful to say.
    public var hint: String? {
        switch self {
        case .notFound:
            return "Turn the belt on and leave it in standby (not off), keep it within a few metres, then try again."
        case .bluetoothUnavailable:
            return "Enable Bluetooth for WalkingPad in System Settings › Privacy & Security › Bluetooth."
        default:
            return nil
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting: return true
        default: return false
        }
    }
}

/// Owns the CoreBluetooth session with the belt.
///
/// All CoreBluetooth callbacks are delivered on the main queue, so every property here is
/// touched from the main thread only and is safe to bind straight into SwiftUI.
public final class PadController: NSObject, ObservableObject {
    // MARK: BLE identifiers (KingSmith WalkingPad)
    public static let serviceUUID = CBUUID(string: "0000FE00-0000-1000-8000-00805F9B34FB")
    public static let notifyUUID = CBUUID(string: "0000FE01-0000-1000-8000-00805F9B34FB")
    public static let writeUUID = CBUUID(string: "0000FE02-0000-1000-8000-00805F9B34FB")

    /// The belt drops commands that arrive too close together.
    private static let minimumCommandSpacing: TimeInterval = 0.7
    private static let statusPollInterval: TimeInterval = 1.0
    /// If the service-filtered scan finds nothing, fall back to matching on name.
    private static let broadScanFallbackDelay: TimeInterval = 6.0
    /// Total time to look for a belt before reporting that none was found.
    private static let scanBudget: TimeInterval = 15.0
    /// Time allowed to go from "belt discovered" to "ready to accept commands".
    private static let connectBudget: TimeInterval = 12.0
    /// How long to wait for the belt to echo back a speed we asked for.
    private static let speedConfirmBudget: TimeInterval = 4.0

    @Published public private(set) var state: PadConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            logger.notice("state: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)")
        }
    }

    /// Mirrors the in-app event log to unified logging, so a session can be inspected after the
    /// fact with:  log show --predicate 'subsystem == "io.nativ.walkingpad"' --last 5m
    private let logger = Logger(subsystem: "io.nativ.walkingpad", category: "ble")
    @Published public private(set) var status: PadStatus?
    @Published public private(set) var lastRecord: PadRecord?
    @Published public private(set) var rssi: Int?
    @Published public private(set) var log: [PadLogEntry] = []
    /// Speed we have asked for but not yet seen confirmed by the belt.
    @Published public private(set) var inFlightSpeedRaw: UInt8?

    public var onStatus: ((PadStatus) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    private var queue = CommandQueue()
    private var lastSendAt: Date?
    private var drainScheduled = false

    private var pollTimer: Timer?
    private var rssiTimer: Timer?
    private var broadScanTimer: Timer?
    private var scanDeadlineTimer: Timer?
    private var connectDeadlineTimer: Timer?
    private var speedConfirmTimer: Timer?
    private var wantsConnection = false
    private var isBroadScanning = false

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Connection lifecycle

    public func connect() {
        wantsConnection = true
        guard central.state == .poweredOn else {
            appendLog("Waiting for Bluetooth to power on", .info)
            return
        }
        guard !state.isConnected, peripheral == nil else { return }
        startScan(broad: false)
    }

    public func disconnect() {
        wantsConnection = false
        stopScan()
        stopTimers()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        writeCharacteristic = nil
        queue.removeAll()
        inFlightSpeedRaw = nil
        state = .idle
        appendLog("Disconnected", .info)
    }

    private func startScan(broad: Bool) {
        guard central.state == .poweredOn else { return }
        // A fresh scan (not the name-matching fallback) restarts the overall budget.
        if !broad { armScanDeadline() }
        isBroadScanning = broad
        state = .scanning
        let services: [CBUUID]? = broad ? nil : [PadController.serviceUUID]
        central.scanForPeripherals(withServices: services, options: nil)
        appendLog(broad ? "Scanning all BLE devices by name…" : "Scanning for WalkingPad service…", .info)

        broadScanTimer?.invalidate()
        if !broad {
            // Some belts advertise without the service UUID; widen the net if nothing shows up.
            broadScanTimer = Timer.scheduledTimer(
                withTimeInterval: PadController.broadScanFallbackDelay, repeats: false
            ) { [weak self] _ in
                guard let self, self.peripheral == nil, self.wantsConnection else { return }
                self.central.stopScan()
                self.startScan(broad: true)
            }
        }
    }

    private func stopScan() {
        broadScanTimer?.invalidate()
        broadScanTimer = nil
        scanDeadlineTimer?.invalidate()
        scanDeadlineTimer = nil
        if central.state == .poweredOn { central.stopScan() }
    }

    /// Scanning must not spin forever: without this the UI sits on a spinner with no way to
    /// tell "still looking" from "there is no belt here".
    private func armScanDeadline() {
        scanDeadlineTimer?.invalidate()
        scanDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: PadController.scanBudget, repeats: false
        ) { [weak self] _ in
            guard let self, self.peripheral == nil else { return }
            self.giveUpScanning()
        }
    }

    private func giveUpScanning() {
        stopScan()
        wantsConnection = false
        state = .notFound
        appendLog("No belt found after \(Int(PadController.scanBudget))s — is it powered on?", .warning)
    }

    /// Connecting needs its own deadline. `stopScan()` discards the scan budget the moment a belt
    /// is discovered, CoreBluetooth's `connect(_:options:)` never times out on its own, and a GATT
    /// discovery that yields no write characteristic simply never calls back — so without this the
    /// UI can sit on "Connecting…" forever.
    private func armConnectDeadline() {
        connectDeadlineTimer?.invalidate()
        connectDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: PadController.connectBudget, repeats: false
        ) { [weak self] _ in
            guard let self, self.writeCharacteristic == nil else { return }
            self.abandonConnectAttempt("Belt found but never became ready")
        }
    }

    /// The belt never acknowledges a speed it will not honour — below its minimum, above its own
    /// configured max, or while it is not running. Without a deadline `inFlightSpeedRaw` would stay
    /// set and the UI would show a "waiting for the belt" spinner that never clears.
    private func armSpeedConfirmDeadline() {
        speedConfirmTimer?.invalidate()
        speedConfirmTimer = Timer.scheduledTimer(
            withTimeInterval: PadController.speedConfirmBudget, repeats: false
        ) { [weak self] _ in
            guard let self, let pending = self.inFlightSpeedRaw else { return }
            self.inFlightSpeedRaw = nil
            self.appendLog(
                "Belt did not confirm \(String(format: "%.1f", Double(pending) / 10)) km/h — it may be "
                + "stopped, in automatic mode, or above the belt's own max speed",
                .warning
            )
        }
    }

    /// Tear down a half-finished connection and land in a terminal state the UI can explain.
    private func abandonConnectAttempt(_ why: String) {
        connectDeadlineTimer?.invalidate()
        connectDeadlineTimer = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnectionArtifacts()
        stopTimers()
        stopScan()
        wantsConnection = false
        state = .notFound
        appendLog("\(why) — giving up", .warning)
    }

    /// Everything that is only meaningful while a belt is attached.
    private func resetConnectionArtifacts() {
        peripheral = nil
        writeCharacteristic = nil
        queue.removeAll()
        inFlightSpeedRaw = nil
        speedConfirmTimer?.invalidate()
        speedConfirmTimer = nil
    }

    private func looksLikeBelt(name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return ["walkingpad", "kingsmith", "ksmith", "r1 pro", "r1pro"].contains { name.contains($0) }
    }

    // MARK: - Commands

    /// Queue a command, respecting the belt's minimum spacing.
    public func send(_ command: PadCommand) {
        guard state.isConnected || command.isStatusPoll else {
            appendLog("Ignored \(command) — not connected", .warning)
            return
        }
        if case .setSpeed(let raw) = command { inFlightSpeedRaw = raw }

        queue.enqueue(command)
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        guard !queue.isEmpty else { return }
        let elapsed = lastSendAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = max(0, PadController.minimumCommandSpacing - elapsed)
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.sendNext()
            self.scheduleDrain()
        }
    }

    /// Control commands always win over a queued status poll.
    private func sendNext() {
        guard let command = queue.dequeue(),
              let peripheral,
              let characteristic = writeCharacteristic else { return }

        let payload = Data(command.bytes)
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(payload, for: characteristic, type: type)
        lastSendAt = Date()
        if case .setSpeed = command { armSpeedConfirmDeadline() }
        if !command.isStatusPoll {
            appendLog("TX \(payload.map { String(format: "%02x", $0) }.joined(separator: " "))", .tx)
        }
    }

    // MARK: - Convenience API

    /// Speed in km/h. Clamped by the caller's configured ceiling.
    public func setSpeed(kph: Double) {
        let raw = UInt8(max(0, min(255, (kph * 10).rounded())))
        send(.setSpeed(raw))
    }

    public func stop() {
        // Speed 0 is the belt's stop command.
        send(.setSpeed(0))
    }

    /// Belt only accepts app speed changes in manual mode, and must be woken from standby.
    public func startWalking(at kph: Double) {
        send(.setMode(.manual))
        send(.start)
        setSpeed(kph: kph)
    }

    public func setMode(_ mode: PadMode) { send(.setMode(mode)) }

    public func requestHistory() { send(.askHistory) }

    public func setPreference(_ key: PadPreference, value: Int, type: UInt8 = 0) {
        send(.setPreference(key, type: type, value: value))
    }

    public func setTarget(_ target: PadTarget, value: Int) {
        send(.setPreference(.target, type: target.rawValue, value: value))
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: PadController.statusPollInterval, repeats: true
        ) { [weak self] _ in
            self?.send(.askStats)
        }
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        rssiTimer?.invalidate(); rssiTimer = nil
        connectDeadlineTimer?.invalidate(); connectDeadlineTimer = nil
        speedConfirmTimer?.invalidate(); speedConfirmTimer = nil
    }

    // MARK: - Logging

    public func appendLog(_ text: String, _ kind: PadLogEntry.Kind) {
        switch kind {
        case .warning: logger.warning("\(text, privacy: .public)")
        case .info: logger.notice("\(text, privacy: .public)")
        case .tx, .rx: logger.debug("\(text, privacy: .public)")
        }
        log.append(PadLogEntry(text: text, kind: kind, at: Date()))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    public func clearLog() { log.removeAll() }
}

// MARK: - CBCentralManagerDelegate

extension PadController: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("Bluetooth ready", .info)
            if wantsConnection { startScan(broad: false) }
        case .poweredOff:
            handleBluetoothUnavailable("Bluetooth is off")
        case .unauthorized:
            handleBluetoothUnavailable("Bluetooth permission denied — allow it in System Settings › Privacy & Security › Bluetooth")
        case .unsupported:
            handleBluetoothUnavailable("Bluetooth LE unsupported on this Mac")
        default:
            handleBluetoothUnavailable("Bluetooth unavailable")
        }
    }

    /// Dropping below `.poweredOn` invalidates every CBPeripheral we hold, and CoreBluetooth does
    /// not promise a disconnect callback for it. Without this teardown the stale `peripheral`
    /// reference silently defeats the scan-budget and broad-scan guards (both test
    /// `peripheral == nil`), so a Bluetooth off/on cycle left the UI scanning forever.
    private func handleBluetoothUnavailable(_ reason: String) {
        stopTimers()
        broadScanTimer?.invalidate(); broadScanTimer = nil
        scanDeadlineTimer?.invalidate(); scanDeadlineTimer = nil
        resetConnectionArtifacts()
        isBroadScanning = false
        state = .bluetoothUnavailable(reason)
        appendLog(reason, .warning)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName
        if isBroadScanning && !looksLikeBelt(name: name) { return }

        appendLog("Found \(name ?? peripheral.identifier.uuidString) (\(RSSI) dBm)", .info)
        stopScan()
        self.rssi = RSSI.intValue
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(name ?? "WalkingPad")
        armConnectDeadline()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog("Connected, discovering services", .info)
        peripheral.discoverServices([PadController.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        appendLog("Connect failed: \(error?.localizedDescription ?? "unknown")", .warning)
        self.peripheral = nil
        if wantsConnection { startScan(broad: false) }
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        appendLog("Belt disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")", .warning)
        stopTimers()
        self.peripheral = nil
        writeCharacteristic = nil
        queue.removeAll()
        inFlightSpeedRaw = nil
        if wantsConnection {
            state = .scanning
            startScan(broad: false)
        } else {
            state = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PadController: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            abandonConnectAttempt("Service discovery failed\(error.map { ": \($0.localizedDescription)" } ?? "")")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(
                [PadController.notifyUUID, PadController.writeUUID], for: service
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            abandonConnectAttempt("Characteristic discovery failed\(error.map { ": \($0.localizedDescription)" } ?? "")")
            return
        }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case PadController.notifyUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case PadController.writeUUID:
                writeCharacteristic = characteristic
            default:
                break
            }
        }
        if writeCharacteristic != nil {
            connectDeadlineTimer?.invalidate()
            connectDeadlineTimer = nil
            state = .connected(peripheral.name ?? "WalkingPad")
            appendLog("Ready", .info)
            startTimers()
            send(.askStats)
            send(.askHistory)
        } else if service.uuid == PadController.serviceUUID {
            // The belt's own service is present but has no write characteristic, so this device
            // can never accept commands. Fail now rather than waiting out the connect budget.
            abandonConnectAttempt("Device exposes no WalkingPad write characteristic")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        switch PadFrame(data: bytes) {
        case .status(let s):
            status = s
            if let want = inFlightSpeedRaw, s.speedRaw == want {
                inFlightSpeedRaw = nil
                speedConfirmTimer?.invalidate()
                speedConfirmTimer = nil
            }
            onStatus?(s)
        case .record(let r):
            lastRecord = r
            appendLog("Stored session: \(r.steps) steps, \(String(format: "%.2f", r.distanceKm)) km", .info)
        case .unknown(let bytes):
            appendLog("RX \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))", .rx)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        rssi = RSSI.intValue
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            appendLog("Write failed: \(error.localizedDescription)", .warning)
        }
    }
}

public struct PadLogEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case info, warning, tx, rx }
    public let id = UUID()
    public let text: String
    public let kind: Kind
    public let at: Date
}
