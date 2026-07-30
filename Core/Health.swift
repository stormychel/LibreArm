import HealthKit

protocol HealthStore {
    func requestAuthorization(toShare typesToShare: Set<HKSampleType>, read typesToRead: Set<HKObjectType>) async throws
    func save(_ object: HKObject) async throws
}

extension HKHealthStore: HealthStore {}

enum HealthAuthorizationState: Equatable {
    case notRequested, requesting, ready, failed(String)
}

enum HealthSaveState: Equatable {
    case idle, saving, saved, partiallySaved(String), failed(String), skipped(String)
}

struct HealthSaveOutcome: Equatable {
    let bloodPressureSaved: Bool
    let heartRateSaved: Bool?
    let message: String
}

@MainActor
final class Health: ObservableObject {
    @Published private(set) var authorizationState: HealthAuthorizationState = .notRequested
    @Published private(set) var saveState: HealthSaveState = .idle
    private let store: HealthStore

    init(store: HealthStore = HKHealthStore()) {
        self.store = store
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot-state=result") {
            authorizationState = .ready
            saveState = .saved
        }
#endif
    }

    func resetSaveState() {
        saveState = .idle
    }

    func requestAuth() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--screenshot-state=") }) {
            authorizationState = .ready
            return
        }
#endif
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .failed("Apple Health is unavailable on this device.")
            return
        }
        authorizationState = .requesting
        let types: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]
        do {
            try await store.requestAuthorization(toShare: types, read: [])
            authorizationState = .ready
        } catch {
            authorizationState = .failed("Health access could not be requested: \(error.localizedDescription)")
        }
    }

    func save(_ reading: BPReading, date: Date = Date()) async -> HealthSaveOutcome {
        guard reading.isWithinSupportedSaveRange else {
            let message = "Not saved: this result is outside LibreArm’s supported save range. Please repeat the measurement."
            saveState = .skipped(message)
            return HealthSaveOutcome(bloodPressureSaved: false, heartRateSaved: nil, message: message)
        }

        saveState = .saving
        let mmHg = HKUnit.millimeterOfMercury()
        let systolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic)!
        let diastolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)!
        let correlationType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)!
        let systolic = HKQuantitySample(
            type: systolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: reading.sys),
            start: date,
            end: date
        )
        let diastolic = HKQuantitySample(
            type: diastolicType,
            quantity: HKQuantity(unit: mmHg, doubleValue: reading.dia),
            start: date,
            end: date
        )

        do {
            try await store.save(
                HKCorrelation(type: correlationType, start: date, end: date, objects: [systolic, diastolic])
            )
        } catch {
            let message = "Blood pressure was not saved. In Health, open your profile, Apps, LibreArm, then enable Blood Pressure."
            saveState = .failed(message)
            return HealthSaveOutcome(bloodPressureSaved: false, heartRateSaved: nil, message: message)
        }

        guard let bpm = reading.hr else {
            saveState = .saved
            return HealthSaveOutcome(bloodPressureSaved: true, heartRateSaved: nil, message: "Saved to Apple Health")
        }

        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let heartRate = HKQuantitySample(
            type: heartRateType,
            quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: bpm),
            start: date,
            end: date
        )
        do {
            try await store.save(heartRate)
            saveState = .saved
            return HealthSaveOutcome(bloodPressureSaved: true, heartRateSaved: true, message: "Saved to Apple Health")
        } catch {
            let message = "Blood pressure saved; heart rate was not saved. Check LibreArm’s Heart Rate access in Health."
            saveState = .partiallySaved(message)
            return HealthSaveOutcome(bloodPressureSaved: true, heartRateSaved: false, message: message)
        }
    }

    func record(
        _ reading: BPReading,
        guest: Bool,
        enabled: Bool,
        date: Date = Date()
    ) async -> HealthSaveOutcome {
        if guest {
            let message = "Guest measurement complete — not saved"
            saveState = .skipped(message)
            return HealthSaveOutcome(bloodPressureSaved: false, heartRateSaved: nil, message: message)
        }
        if !enabled {
            let message = "Measurement complete — Apple Health saving is off"
            saveState = .skipped(message)
            return HealthSaveOutcome(bloodPressureSaved: false, heartRateSaved: nil, message: message)
        }
        return await save(reading, date: date)
    }
}
