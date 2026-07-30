@preconcurrency import CoreBluetooth
import Foundation
import UIKit

enum ConnectionState: Equatable {
    case unavailable, searching, connecting, preparing, ready, disconnected, failed(String)
}

enum MeasurementState: Equatable {
    case idle, checkingBattery, measuring(Int, Int), waiting(Int, Int, Int), failed(String)
}

enum ControlCommand: Equatable {
    case start, cancel
    var data: Data { Data([0xF1, self == .start ? 0x01 : 0x02]) }
}

struct ControlWriteTracker {
    private var commands: [ControlCommand] = []

    mutating func enqueue(_ command: ControlCommand) {
        commands.append(command)
    }

    mutating func next() -> ControlCommand? {
        guard !commands.isEmpty else { return nil }
        return commands.removeFirst()
    }

    mutating func removeAll() {
        commands.removeAll()
    }
}

@MainActor
final class BPClient: NSObject, ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .searching
    @Published private(set) var measurementState: MeasurementState = .idle
    @Published private(set) var lastReading: BPReading?
    @Published private(set) var liveReading: BPReading?
    @Published private(set) var batteryLevelPct: Int?
    @Published private(set) var batteryStatusLine = "Battery: unavailable"
    @Published var readingCount = 1
    @Published var delayBetweenRuns: Double = 30
    var onFinalReading: ((BPReading, Bool) -> Void)?

    var isConnected: Bool { connectionState == .preparing || connectionState == .ready }
    var canMeasure: Bool { connectionState == .ready && measurementState == .idle }
    var isMeasuring: Bool {
        switch measurementState { case .idle, .failed: false; default: true }
    }
    var status: String {
        switch measurementState {
        case .checkingBattery: return "Checking battery…"
        case let .measuring(n, total): return total == 1 ? "Measuring…" : "Measuring (reading \(n) of \(total))…"
        case let .waiting(done, total, seconds): return "Reading \(done) of \(total) complete — next in \(seconds)s…"
        case let .failed(message): return message
        case .idle: break
        }
        switch connectionState {
        case .unavailable: return "Bluetooth unavailable"
        case .searching: return "Searching for device…"
        case .connecting: return "Connecting…"
        case .preparing: return "Connected — preparing…"
        case .ready: return "Connected — ready"
        case .disconnected: return "Disconnected"
        case let .failed(message): return message
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var measurementChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var notificationReady = false

    private let bpsService = CBUUID(string: "1810")
    private let measurement = CBUUID(string: "2A35")
    private let control = CBUUID(string: "583CB5B3-875D-40ED-9098-C39EB0C1983D")
    private let batteryService = CBUUID(string: "180F")
    private let battery = CBUUID(string: "2A19")

    private var connectionID = UUID()
    private var sessionID = UUID()
    private var readings: [BPReading] = []
    private var controlWrites = ControlWriteTracker()
    private var guestSession = false
    private var sessionReadingCount = 1
    private var waitingForBattery = false
    private var connectTask: DispatchWorkItem?
    private var finalizeTask: DispatchWorkItem?
    private var watchdogTask: DispatchWorkItem?
    private var countdownTask: DispatchWorkItem?
    private var batteryFallbackTask: DispatchWorkItem?

    private var screenshotState: String? {
#if DEBUG
        ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--screenshot-state=") })?
            .replacingOccurrences(of: "--screenshot-state=", with: "")
#else
        nil
#endif
    }

    override init() {
        super.init()
        if let screenshotState {
            connectionState = .ready
            batteryLevelPct = 84
            batteryStatusLine = "Battery: 84%"
            readingCount = 3
            switch screenshotState {
            case "measuring":
                measurementState = .measuring(2, 3)
                liveReading = BPReading(sys: 120, dia: 70)
            case "result", "guidance":
                lastReading = BPReading(sys: 120, dia: 70, map: 87, hr: 60)
            default:
                break
            }
            return
        }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startConnect(timeout: TimeInterval = 30) {
        if screenshotState != nil { return }
        guard central.state == .poweredOn else { connectionState = .unavailable; return }
        let previousPeripheral = peripheral
        endSession(sendCancel: false, result: .idle, keepReading: true)
        if let previousPeripheral {
            central.cancelPeripheralConnection(previousPeripheral)
        }
        clearDevice()
        connectionID = UUID()
        let id = connectionID
        connectionState = .searching
        central.scanForPeripherals(withServices: [bpsService])
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.connectionID == id, self.connectionState != .ready else { return }
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.clearDevice()
            self.connectionState = .failed("Connection timed out. Check the cuff is awake and nearby.")
        }
        connectTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: task)
    }

    func refreshBattery() {
        if screenshotState != nil { return }
        guard UIApplication.shared.applicationState == .active, let peripheral, let batteryChar else { return }
        peripheral.readValue(for: batteryChar)
    }

    func startMeasurement(guest: Bool = false) {
        guard canMeasure else { return }
        readingCount = min(max(readingCount, 1), 3)
        sessionReadingCount = Self.sessionReadingCount(configuredCount: readingCount, guest: guest)
        readings.removeAll()
        lastReading = nil
        guestSession = guest
        sessionID = UUID()
        waitingForBattery = true
        measurementState = .checkingBattery
        UIApplication.shared.isIdleTimerDisabled = true
        refreshBattery()

        let id = sessionID
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == id, self.waitingForBattery else { return }
            self.waitingForBattery = false
            if self.batteryChar == nil { self.batteryStatusLine = "Battery: unavailable (measurement can continue)" }
            self.beginRun(1)
        }
        batteryFallbackTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }

    func cancelMeasurement() { endSession(sendCancel: true, result: .idle, keepReading: true) }
    func isValidReading(_ reading: BPReading) -> Bool { reading.isStructurallyValid }

    private func beginRun(_ number: Int) {
        guard let peripheral, let controlChar, connectionState == .ready else {
            endSession(sendCancel: false, result: .failed("Cuff is no longer ready. Reconnect and try again."), keepReading: true)
            return
        }
        if let level = batteryLevelPct, level <= 10 {
            endSession(sendCancel: false, result: .failed("Battery critical (\(level)%). Replace batteries before measuring."), keepReading: true)
            return
        }
        measurementState = .measuring(number, sessionReadingCount)
        write(.start, characteristic: controlChar, peripheral: peripheral)
        armWatchdog()
    }

    private func write(_ command: ControlCommand, characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withResponse { controlWrites.enqueue(command) }
        peripheral.writeValue(command.data, for: characteristic, type: type)
    }

    private func armWatchdog() {
        watchdogTask?.cancel()
        let id = sessionID
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == id, self.isMeasuring else { return }
            self.endSession(sendCancel: true, result: .failed("No completed reading was received. Check cuff fit, battery and pairing, then try again."), keepReading: true)
        }
        watchdogTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: task)
    }

    private func receive(_ reading: BPReading) {
        guard Self.acceptsMeasurement(in: measurementState) else { return }
        liveReading = reading
        finalizeTask?.cancel()
        let id = sessionID
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionID == id,
                  Self.acceptsMeasurement(in: self.measurementState) else { return }
            self.finalize(reading)
        }
        finalizeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func finalize(_ reading: BPReading) {
        guard reading.isComplete else { return }
        guard reading.isStructurallyValid else {
            endSession(sendCancel: false, result: .failed("The cuff reported an incomplete or inconsistent result. It was not saved; please try again."), keepReading: true)
            return
        }
        watchdogTask?.cancel()
        readings.append(reading)
        if readings.count < sessionReadingCount { scheduleNextRun(); return }
        guard let result = BPReading.average(readings) else {
            endSession(sendCancel: false, result: .failed("The reading set could not be averaged. Please try again."), keepReading: true)
            return
        }
        lastReading = result
        let wasGuest = guestSession
        endSession(sendCancel: false, result: .idle, keepReading: true)
        onFinalReading?(result, wasGuest)
        refreshBattery()
    }

    private func scheduleNextRun() {
        let id = sessionID
        let done = readings.count
        var seconds = Int(min(max(delayBetweenRuns, 15), 60))
        measurementState = .waiting(done, sessionReadingCount, seconds)
        func tick() {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.sessionID == id, self.isMeasuring else { return }
                seconds -= 1
                if seconds > 0 {
                    self.measurementState = .waiting(done, self.sessionReadingCount, seconds)
                    tick()
                } else {
                    self.beginRun(done + 1)
                }
            }
            countdownTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
        }
        tick()
    }

    private func endSession(sendCancel: Bool, result: MeasurementState, keepReading: Bool) {
        sessionID = UUID()
        [finalizeTask, watchdogTask, countdownTask, batteryFallbackTask].forEach { $0?.cancel() }
        finalizeTask = nil; watchdogTask = nil; countdownTask = nil; batteryFallbackTask = nil
        waitingForBattery = false
        if sendCancel, let peripheral, let controlChar {
            write(.cancel, characteristic: controlChar, peripheral: peripheral)
        }
        readings.removeAll()
        guestSession = false
        liveReading = nil
        if !keepReading { lastReading = nil }
        measurementState = result
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func clearDevice() {
        connectTask?.cancel(); connectTask = nil
        measurementChar = nil; controlChar = nil; batteryChar = nil
        controlWrites.removeAll()
        notificationReady = false; peripheral = nil
        batteryLevelPct = nil; batteryStatusLine = "Battery: unavailable"
    }

    private func updateReadiness() {
        guard measurementChar != nil, controlChar != nil, notificationReady else { return }
        connectTask?.cancel(); connectTask = nil
        connectionState = .ready
    }

    private func updateBattery(_ level: Int) {
        guard (0...100).contains(level) else { return }
        batteryLevelPct = level
        batteryStatusLine = level <= 10 ? "Battery: \(level)% (Critical)" :
            level <= 20 ? "Battery: \(level)% (Low)" : "Battery: \(level)%"
        if waitingForBattery {
            waitingForBattery = false
            batteryFallbackTask?.cancel(); batteryFallbackTask = nil
            beginRun(1)
        }
    }

    static func isPairingATTError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let pairingCodes: Set<Int> = [0x05, 0x08, 0x0C, 0x0F]
        return nsError.domain == CBATTErrorDomain && pairingCodes.contains(nsError.code)
    }

    static func acceptsMeasurement(in state: MeasurementState) -> Bool {
        if case .measuring = state { return true }
        return false
    }

    static func sessionReadingCount(configuredCount: Int, guest: Bool) -> Int {
        guest ? 1 : min(max(configuredCount, 1), 3)
    }

    private func recoveryMessage(_ error: Error) -> String {
        if Self.isPairingATTError(error) {
            return "Pairing needs attention. Reset the cuff through its LED pinhole, forget QardioArm in iPhone Bluetooth settings if listed, then reconnect here."
        }
        return "Cuff command failed: \(error.localizedDescription)"
    }
}

extension BPClient: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            endSession(sendCancel: false, result: .idle, keepReading: true)
            clearDevice()
            connectionState = .unavailable
            return
        }
        if connectionState == .unavailable { startConnect() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectionState == .searching else { return }
        central.stopScan(); connectionState = .connecting
        peripheral = p; p.delegate = self; central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p == peripheral else { return }
        connectionState = .preparing
        p.discoverServices([bpsService, batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        clearDevice()
        connectionState = .failed(error.map { "Connection failed: \($0.localizedDescription)" } ?? "Connection failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        endSession(sendCancel: false, result: .idle, keepReading: true)
        clearDevice(); connectionState = .disconnected
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p == peripheral else { return }
        if let error { connectionState = .failed("Service discovery failed: \(error.localizedDescription)"); return }
        for service in p.services ?? [] {
            if service.uuid == bpsService { p.discoverCharacteristics([measurement, control], for: service) }
            if service.uuid == batteryService { p.discoverCharacteristics([battery], for: service) }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p == peripheral else { return }
        if let error { connectionState = .failed("Device setup failed: \(error.localizedDescription)"); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == measurement {
                measurementChar = characteristic; p.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == control {
                controlChar = characteristic
            } else if characteristic.uuid == battery {
                batteryChar = characteristic; refreshBattery()
            }
        }
        updateReadiness()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral, connectionState == .preparing, characteristic.uuid == measurement else { return }
        if let error {
            central.cancelPeripheralConnection(p)
            clearDevice()
            connectionState = .failed(recoveryMessage(error))
            return
        }
        notificationReady = characteristic.isNotifying
        updateReadiness()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral, characteristic.uuid == control else { return }
        let command = controlWrites.next()
        guard let error else { return }
        if command == .start {
            endSession(sendCancel: false, result: .failed(recoveryMessage(error)), keepReading: true)
        } else {
            measurementState = .failed("The cuff may not have stopped cleanly. Reconnect before measuring again.")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p == peripheral else { return }
        if let error {
            if characteristic.uuid == measurement {
                endSession(sendCancel: false, result: .failed("Reading failed: \(error.localizedDescription)"), keepReading: true)
            } else {
                batteryStatusLine = "Battery: unavailable (measurement can continue)"
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == battery, let level = data.first {
            updateBattery(Int(level))
        } else if characteristic.uuid == measurement {
            do { receive(try BloodPressureMeasurementParser.parse(data)) }
            catch {
                endSession(sendCancel: false, result: .failed("The cuff sent an incomplete result. It was not saved; check fit and battery, then try again."), keepReading: false)
            }
        }
    }
}
