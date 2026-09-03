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
    public var hint: String? { hint(for: nil) }

    /// The same guidance, naming the belt family being looked for. A Z1 owner whose app is still
    /// set to the classic family sees "No belt found" forever otherwise, with no clue why.
    public func hint(for family: PadFamily?) -> String? {
        let modelNote = family.map {
            " Looking for a \($0.label). Different model? Change it in Settings › General."
        } ?? ""
        switch self {
        case .notFound:
            return "Turn the belt on and leave it in standby (not off), keep it within a few metres, "
                + "then try again." + modelNote
        case .scanning:
            return family == nil ? nil : String(modelNote.dropFirst())
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
///
/// Everything protocol-specific lives in the `BeltDialect` chosen by `family`; this class only
/// knows how to scan, connect, keep deadlines, and pace the command queue.
public final class PadController: NSObject, ObservableObject {
    // MARK: BLE identifiers of the classic belt, kept for callers that still name them.
    public static let serviceUUID = ClassicDialect.serviceUUID
    public static let notifyUUID = ClassicDialect.notifyUUID
    public static let writeUUID = ClassicDialect.writeUUID

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
    /// How long a held speed waits for the belt to start moving (FTMS cold start).
    private static let startMovingBudget: TimeInterval = 15.0
    /// Once the belt reports movement, how long to let the motor settle before the speed target
    /// is written. The firmware drops the link if the two overlap; two seconds is comfortably clear.
    public static let startSettleDelay: TimeInterval = 2.0
    /// A belt that pushes status (FTMS) is expected to say something at least this often. Past it
    /// the link is treated as dead: otherwise a stalled stream would show a belt "running" forever.
    public static let staleStatusBudget: TimeInterval = 10.0

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
    /// Speed limits the belt itself reported, where the protocol offers them.
    @Published public private(set) var beltSpeedRange: FTMS.SpeedRange?
    /// The last speed written to the belt that it has not yet been seen running at. Unlike
    /// `inFlightSpeedRaw` this survives the belt's acknowledgement: an FTMS belt accepts a target
    /// at once and then ramps to it for several seconds, and a ceiling lowered during the ramp has
    /// to know where the belt is heading, not where it is.
    @Published public private(set) var targetSpeedRaw: UInt8?
    /// The app's speed ceiling in 0.1 km/h, applied once more at the wire.
    ///
    /// The app clamps before it asks, but a speed can wait in the queue, or be held for the
    /// motor, while the ceiling drops underneath it. Clamping at the last moment before the write
    /// is invariant 6; this is where that happens.
    public var speedCeilingRaw: UInt8 = UInt8(PadController.maxSafeSpeedKph * 10)

    /// Which generation of belt to look for. Changing it mid-connection starts over with the new
    /// protocol — a belt of one family is invisible to the other's scan.
    public var family: PadFamily {
        get { dialect.family }
        set {
            guard newValue != dialect.family else { return }
            // Changing the model right after "No belt found" is almost always the fix for it, so
            // that case starts a new search too rather than waiting for another click.
            let resume = wantsConnection || state == .notFound
            if state.isConnected || state.isBusy { disconnect() }
            dialect = makeDialect(for: newValue)
            appendLog("Belt model set to \(newValue.label)", .info)
            if resume { connect() }
        }
    }

    public var onStatus: ((PadStatus) -> Void)?

    private var dialect: BeltDialect = makeDialect(for: .default)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Every characteristic the dialect asked for, once discovered.
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServiceDiscoveries = 0
    private var isReady = false

    private var queue = CommandQueue()
    private var lastSendAt: Date?
    private var drainScheduled = false
    /// A speed target waiting for the belt to report movement (see `BeltDialect.holdsSpeedUntilBeltMoves`).
    private var heldSpeedRaw: UInt8?
    /// The settle delay in progress, once the belt has reported movement.
    private var heldSpeedRelease: DispatchWorkItem?

    private var pollTimer: Timer?
    private var rssiTimer: Timer?
    private var broadScanTimer: Timer?
    private var scanDeadlineTimer: Timer?
    private var connectDeadlineTimer: Timer?
    private var speedConfirmTimer: Timer?
    private var heldSpeedTimer: Timer?
    private var staleStatusTimer: Timer?
    private var readyAt: Date?
    private var setupWorkItem: DispatchWorkItem?
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
        resetConnectionArtifacts()
        state = .idle
        appendLog("Disconnected", .info)
    }

    private func startScan(broad: Bool) {
        guard central.state == .poweredOn else { return }
        // A fresh scan (not the name-matching fallback) restarts the overall budget.
        if !broad { armScanDeadline() }
        isBroadScanning = broad
        state = .scanning
        let services: [CBUUID]? = broad ? nil : dialect.scanServiceUUIDs
        central.scanForPeripherals(withServices: services, options: nil)
        appendLog(
            broad ? "Scanning all BLE devices by name…"
                  : "Scanning for a \(dialect.family.label) (\(dialect.family == .ftms ? "FTMS" : "WalkingPad") service)…",
            .info
        )

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
        appendLog(
            "No \(dialect.family.label) found after \(Int(PadController.scanBudget))s — is it powered on, "
            + "and is the belt model in Settings right?",
            .warning
        )
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
            guard let self, !self.isReady else { return }
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
                + "stopped, in automatic mode, or outside the belt's own speed range",
                .warning
            )
        }
    }

    /// A held speed is waiting on the motor. If the belt never starts, the wait has to end in a
    /// state the UI can explain, not a spinner.
    private func armHeldSpeedDeadline() {
        heldSpeedTimer?.invalidate()
        heldSpeedTimer = Timer.scheduledTimer(
            withTimeInterval: PadController.startMovingBudget, repeats: false
        ) { [weak self] _ in
            guard let self, let held = self.heldSpeedRaw else { return }
            self.heldSpeedRaw = nil
            self.inFlightSpeedRaw = nil
            self.appendLog(
                "Belt did not start moving within \(Int(PadController.startMovingBudget))s, so "
                + "\(String(format: "%.1f", Double(held) / 10)) km/h was not sent — check the safety key "
                + "and that the belt is awake",
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
        characteristics.removeAll()
        pendingServiceDiscoveries = 0
        isReady = false
        setupWorkItem?.cancel()
        setupWorkItem = nil
        queue.removeAll()
        inFlightSpeedRaw = nil
        targetSpeedRaw = nil
        dropHeldSpeed()
        beltSpeedRange = nil
        // A status from the previous connection must not vouch for the belt moving now: the
        // spin-up hold (invariant 8) reads it, and a stale "running" would let a speed through.
        status = nil
        speedConfirmTimer?.invalidate()
        speedConfirmTimer = nil
        heldSpeedTimer?.invalidate()
        heldSpeedTimer = nil
        dialect.resetConnectionState()
    }

    // MARK: - Commands

    /// Queue a command, respecting the belt's minimum spacing.
    public func send(_ command: PadCommand) {
        guard state.isConnected || command.isStatusPoll else {
            appendLog("Ignored \(command) — not connected", .warning)
            return
        }
        guard dialect.encode(command) != nil else {
            if !command.isStatusPoll {
                appendLog("\(describe(command)) is not available on a \(dialect.family.label)", .warning)
            }
            return
        }
        if case .setSpeed(let raw) = command { noteSpeedRequested(raw) }

        queue.enqueue(command)
        scheduleDrain()
    }

    /// Queue several frames that must reach the belt in order.
    public func send(batch: [PadCommand]) {
        guard state.isConnected else {
            appendLog("Ignored \(batch.count) commands — not connected", .warning)
            return
        }
        let batch = dialect.supported(batch)
        guard !batch.isEmpty else { return }
        if let speed = batch.compactMap({ command -> UInt8? in
            if case .setSpeed(let raw) = command { return raw }
            return nil
        }).last {
            noteSpeedRequested(speed)
        }
        queue.enqueue(batch: batch)
        scheduleDrain()
    }

    /// A newer speed supersedes anything still waiting for the motor.
    private func noteSpeedRequested(_ raw: UInt8) {
        inFlightSpeedRaw = raw
        dropHeldSpeed()
    }

    /// Forget a speed that was waiting for the motor, and any settle delay running for it.
    private func dropHeldSpeed() {
        heldSpeedRaw = nil
        heldSpeedTimer?.invalidate()
        heldSpeedTimer = nil
        heldSpeedRelease?.cancel()
        heldSpeedRelease = nil
    }

    private func describe(_ command: PadCommand) -> String {
        switch command {
        case .askStats: return "Status poll"
        case .setSpeed: return "Speed change"
        case .setMode(let mode): return "Mode \(mode.label)"
        case .start: return "Start"
        case .askHistory: return "Stored-session query"
        case .setPreference: return "Belt preference"
        }
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
        guard let command = queue.dequeue(), let peripheral else { return }

        if SpeedGate.shouldHold(
            command, beltIsMoving: status?.isMoving ?? false, dialectHolds: dialect.holdsSpeedUntilBeltMoves
        ), case .setSpeed(let raw) = command {
            heldSpeedRaw = raw
            armHeldSpeedDeadline()
            appendLog(
                "Holding \(String(format: "%.1f", Double(raw) / 10)) km/h until the belt is moving", .info
            )
            return
        }
        if case .setSpeed(0) = command, heldSpeedRaw != nil {
            // A stop cancels whatever speed was waiting to be applied.
            dropHeldSpeed()
        }

        var outgoing = command
        if case .setSpeed(let raw) = command {
            // The last clamp before the wire. The app already clamped when it asked, but the
            // ceiling may have dropped while this speed sat in the queue or waited for the motor.
            let limited = PadController.wireSpeed(raw, ceilingRaw: speedCeilingRaw, beltMaxKph: beltSpeedRange?.maxKph)
            if limited != raw {
                appendLog(String(format: "Clamped %.1f km/h to the %.1f km/h limit at the wire",
                                 Double(raw) / 10, Double(limited) / 10), .warning)
                outgoing = .setSpeed(limited)
                if inFlightSpeedRaw == raw { inFlightSpeedRaw = limited }
            }
            targetSpeedRaw = limited > 0 ? limited : nil
        }

        guard let write = dialect.encode(outgoing),
              let characteristic = characteristics[write.characteristic] else { return }
        if let preamble = dialect.preamble(for: outgoing),
           let preambleCharacteristic = characteristics[preamble.characteristic] {
            perform(preamble, on: peripheral, characteristic: preambleCharacteristic)
        }
        perform(write, on: peripheral, characteristic: characteristic)
        lastSendAt = Date()
        if case .setSpeed = outgoing { armSpeedConfirmDeadline() }
        if !outgoing.isStatusPoll {
            appendLog("TX \(write.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))", .tx)
        }
    }

    private func perform(_ write: BeltWrite, on peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(write.bytes), for: characteristic, type: type)
    }

    /// The belt started moving: give the motor a moment to settle, then release the speed that
    /// was waiting for it. A stop or a newer speed in the meantime cancels the release.
    private func releaseHeldSpeedIfMoving(_ status: PadStatus) {
        guard heldSpeedRaw != nil, status.isMoving, heldSpeedRelease == nil else { return }
        heldSpeedTimer?.invalidate()
        heldSpeedTimer = nil
        let release = DispatchWorkItem { [weak self] in
            guard let self, let held = self.heldSpeedRaw else { return }
            self.heldSpeedRelease = nil
            self.heldSpeedRaw = nil
            // The belt may have stopped again during the settle — the safety key, most likely.
            // A speed target must then not go out; the user can start again deliberately.
            guard self.status?.isMoving == true else {
                self.inFlightSpeedRaw = nil
                self.appendLog(
                    "Belt stopped before \(String(format: "%.1f", Double(held) / 10)) km/h could be sent — not sending it",
                    .warning
                )
                return
            }
            self.queue.enqueue(.setSpeed(held))
            self.scheduleDrain()
        }
        heldSpeedRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + PadController.startSettleDelay, execute: release)
    }

    private func clearInFlightSpeed() {
        inFlightSpeedRaw = nil
        speedConfirmTimer?.invalidate()
        speedConfirmTimer = nil
    }

    // MARK: - Convenience API

    /// The fastest speed this controller will ever ask the belt for, whatever the caller passes.
    ///
    /// The app clamps to the user's own (lower) ceiling first, but this is the floor of the
    /// safety story: a treadmill command must never escape a bounds check just because some other
    /// entry point — `padctl speed 20`, a future caller — forgot to clamp.
    public static let maxSafeSpeedKph: Double = 10.0

    /// Speed in km/h, clamped to `maxSafeSpeedKph`.
    public func setSpeed(kph: Double) {
        send(.setSpeed(PadController.rawSpeed(kph)))
    }

    /// km/h to the protocol's 0.1 km/h units, hard-clamped.
    public static func rawSpeed(_ kph: Double) -> UInt8 {
        let safe = min(max(0, kph), maxSafeSpeedKph)
        return UInt8(max(0, min(255, (safe * 10).rounded())))
    }

    /// The speed that may actually be written: the request, capped by the app's ceiling, the
    /// hard maximum, and the belt's own reported maximum where it gave one. Only ever lower.
    public static func wireSpeed(_ raw: UInt8, ceilingRaw: UInt8, beltMaxKph: Double?) -> UInt8 {
        var limit = min(ceilingRaw, rawSpeed(maxSafeSpeedKph))
        if let beltMaxKph, beltMaxKph.isFinite, beltMaxKph >= SpeedLimits.minRunningKph {
            limit = min(limit, rawSpeed(beltMaxKph))
        }
        return min(raw, limit)
    }

    public func stop() {
        // Speed 0 is the belt's stop command (the dialect turns it into whatever its belt needs).
        send(.setSpeed(0))
    }

    /// Belt only accepts app speed changes in manual mode, and must be woken from standby.
    ///
    /// The three frames go in as one batch so a second call cannot interleave and reorder them.
    /// A dialect without modes simply drops the first frame.
    public func startWalking(at kph: Double) {
        send(batch: [.setMode(.manual), .start, .setSpeed(PadController.rawSpeed(kph))])
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
        if dialect.pollsForStatus {
            pollTimer = Timer.scheduledTimer(
                withTimeInterval: PadController.statusPollInterval, repeats: true
            ) { [weak self] _ in
                self?.send(.askStats)
            }
        } else {
            // Nothing is asked for, so nothing would notice the stream stopping. Watch it.
            readyAt = Date()
            staleStatusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.checkStatusStream()
            }
        }
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    /// The pushed status stream went quiet: drop the link so the reconnect logic takes over,
    /// rather than leaving the last frame on screen as if it were live.
    private func checkStatusStream() {
        guard let peripheral, isReady else { return }
        // Only a stalled stream from a *moving* belt is dangerous — that is a belt shown running
        // when nobody knows. An idle belt that goes quiet is left alone, in case the firmware
        // simply stops notifying in standby; the reference material says it does not, but that
        // is unconfirmed on real hardware and a reconnect loop would be the worse mistake.
        guard status?.isMoving == true else { return }
        let last = status?.receivedAt ?? readyAt ?? Date()
        let silence = Date().timeIntervalSince(last)
        guard silence > PadController.staleStatusBudget else { return }
        appendLog("No status from the belt for \(Int(silence))s — reconnecting", .warning)
        staleStatusTimer?.invalidate()
        staleStatusTimer = nil
        central.cancelPeripheralConnection(peripheral)
    }

    private func stopTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        rssiTimer?.invalidate(); rssiTimer = nil
        connectDeadlineTimer?.invalidate(); connectDeadlineTimer = nil
        speedConfirmTimer?.invalidate(); speedConfirmTimer = nil
        staleStatusTimer?.invalidate(); staleStatusTimer = nil
        // A held speed is connection state, not a timer: `resetConnectionArtifacts` drops it.
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
        if isBroadScanning && !dialect.looksLikeBelt(name: name) { return }

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
        peripheral.discoverServices(dialect.serviceUUIDs)
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
        resetConnectionArtifacts()
        if wantsConnection {
            state = .scanning
            startScan(broad: false)
        } else if case .notFound = state {
            // We got here from abandonConnectAttempt/giveUpScanning, which already set the
            // explanatory terminal state. Overwriting it with a bare "Not connected" would erase
            // the reason the user needs to see.
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
        pendingServiceDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(dialect.characteristicUUIDs, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil else {
            abandonConnectAttempt("Characteristic discovery failed: \(error!.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        pendingServiceDiscoveries -= 1
        guard pendingServiceDiscoveries <= 0, !isReady else { return }

        let missing = dialect.requiredCharacteristicUUIDs.filter { characteristics[$0] == nil }
        guard missing.isEmpty else {
            // The device has the service but not the characteristic that drives the belt, so it
            // can never accept commands. Fail now rather than waiting out the connect budget.
            abandonConnectAttempt(
                "Device exposes no \(dialect.family.label) control characteristic "
                + "(\(missing.map(\.uuidString).joined(separator: ", ")))"
            )
            return
        }
        runSetup(dialect.setupSteps, on: peripheral)
    }

    /// Walk the dialect's bring-up sequence, honouring the pauses it asks for, and declare the
    /// link ready at the end. Cancelled wholesale if the peripheral goes away in the middle.
    private func runSetup(_ steps: [BeltSetupStep], on peripheral: CBPeripheral) {
        guard let step = steps.first else {
            finishSetup(peripheral)
            return
        }
        var pause: TimeInterval = 0
        switch step {
        case .subscribe(let uuid, let pauseAfter):
            if let characteristic = characteristics[uuid] {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            pause = pauseAfter
        case .read(let uuid):
            if let characteristic = characteristics[uuid] { peripheral.readValue(for: characteristic) }
        case .write(let write):
            if let characteristic = characteristics[write.characteristic] {
                perform(write, on: peripheral, characteristic: characteristic)
                lastSendAt = Date()
                appendLog("TX \(write.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))", .tx)
            }
        }
        let remaining = Array(steps.dropFirst())
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral === peripheral else { return }
            self.runSetup(remaining, on: peripheral)
        }
        setupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: item)
    }

    private func finishSetup(_ peripheral: CBPeripheral) {
        setupWorkItem = nil
        isReady = true
        connectDeadlineTimer?.invalidate()
        connectDeadlineTimer = nil
        state = .connected(peripheral.name ?? "WalkingPad")
        appendLog("Ready", .info)
        startTimers()
        if dialect.pollsForStatus { send(.askStats) }
        if dialect.family.supportsStoredSession { send(.askHistory) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            appendLog("Could not enable notifications on \(characteristic.uuid): \(error.localizedDescription)", .warning)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        for event in dialect.decode(characteristic: characteristic.uuid, bytes: bytes, now: Date()) {
            handle(event)
        }
    }

    private func handle(_ event: BeltEvent) {
        switch event {
        case .status(let s):
            if status == nil {
                // One line per connection proving data flows, and what the first frame looked like.
                appendLog("First status frame: \(s.hexDump)", .rx)
            }
            status = s
            if let want = inFlightSpeedRaw, s.speedRaw == want { clearInFlightSpeed() }
            if let target = targetSpeedRaw, s.speedRaw == target || !s.isMoving && target > 0 && heldSpeedRaw == nil && inFlightSpeedRaw == nil {
                // Reached it, or the belt stopped on its own with nothing further pending.
                targetSpeedRaw = nil
            }
            releaseHeldSpeedIfMoving(s)
            onStatus?(s)
        case .record(let r):
            lastRecord = r
            appendLog("Stored session: \(r.steps) steps, \(String(format: "%.2f", r.distanceKm)) km", .info)
        case .speedAccepted(let raw):
            if inFlightSpeedRaw == raw { clearInFlightSpeed() }
            // Whoever set it — this app or the physical remote — this is where the belt is now
            // heading, so the ceiling check must reason about it (and never about a stale one).
            targetSpeedRaw = raw > 0 ? raw : nil
        case .speedCommandAccepted:
            // The belt took the speed. If nothing newer is queued or held, that is the one we
            // are waiting on; the instantaneous speed will catch up as the motor ramps.
            let newerPending = heldSpeedRaw != nil
                || queue.pendingControl.contains { if case .setSpeed = $0 { return true }; return false }
            if !newerPending { clearInFlightSpeed() }
        case .speedRange(let range):
            beltSpeedRange = range
        case .note(let text, let isWarning):
            appendLog(text, isWarning ? .warning : .info)
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
