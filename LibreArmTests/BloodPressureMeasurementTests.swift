import XCTest
import HealthKit
import CoreBluetooth
@testable import LibreArm

final class BloodPressureMeasurementTests: XCTestCase {
    func testParsesPulseAndIrregularStatus() throws {
        let reading = try BloodPressureMeasurementParser.parse(Data([
            0x14, 0x78, 0, 0x50, 0, 0x5D, 0, 0x48, 0, 0x04, 0
        ]))
        XCTAssertEqual(reading.sys, 120)
        XCTAssertEqual(reading.dia, 80)
        XCTAssertEqual(reading.map, 93)
        XCTAssertEqual(reading.hr, 72)
        XCTAssertTrue(reading.irregularPulseDetected)
    }

    func testConvertsKPaToMMHg() throws {
        let reading = try BloodPressureMeasurementParser.parse(
            Data([0x01, 0xA0, 0xF0, 0x2B, 0xE4, 0x7C, 0xF0])
        )
        XCTAssertEqual(reading.sys, 120.01, accuracy: 0.1)
        XCTAssertEqual(reading.dia, 80.03, accuracy: 0.1)
    }

    func testRejectsSpecialPressureValue() {
        XCTAssertThrowsError(
            try BloodPressureMeasurementParser.parse(Data([0, 0xFF, 0x07, 0x50, 0, 0x5D, 0]))
        ) { error in
            XCTAssertEqual(error as? BloodPressureParseError, .unavailablePressure)
        }
    }

    func testRejectsEveryReservedSFloatPressureValue() {
        for raw in [UInt16(0x07FE), 0x07FF, 0x0800, 0x0801, 0x0802] {
            let data = Data([0, UInt8(raw & 0xFF), UInt8(raw >> 8), 0x50, 0, 0x5D, 0])
            XCTAssertThrowsError(try BloodPressureMeasurementParser.parse(data))
        }
    }

    func testRejectsTruncatedOptionalField() {
        XCTAssertThrowsError(
            try BloodPressureMeasurementParser.parse(Data([0x10, 0x78, 0, 0x50, 0, 0x5D, 0, 0x04]))
        ) { error in
            XCTAssertEqual(error as? BloodPressureParseError, .truncatedOptionalField)
        }
    }

    func testAveragesAndPreservesIrregularFlag() throws {
        let result = try XCTUnwrap(BPReading.average([
            BPReading(sys: 120, dia: 80, map: 93, hr: 70),
            BPReading(sys: 130, dia: 90, map: 103, hr: 74, irregularPulseDetected: true)
        ]))
        XCTAssertEqual(result.sys, 125)
        XCTAssertEqual(result.dia, 85)
        XCTAssertEqual(result.map, 98)
        XCTAssertEqual(result.hr, 72)
        XCTAssertTrue(result.irregularPulseDetected)
    }

    func testSevereReadingRemainsValid() {
        let reading = BPReading(sys: 240, dia: 130)
        XCTAssertTrue(reading.isStructurallyValid)
        XCTAssertTrue(reading.isWithinSupportedSaveRange)
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 240, diastolic: 130), .severe)
    }

    func testUnsupportedReadingIsDisplayedButNotSaveEligible() {
        let reading = BPReading(sys: 280, dia: 130)
        XCTAssertTrue(reading.isStructurallyValid)
        XCTAssertFalse(reading.isWithinSupportedSaveRange)
    }

    func testRejectsSystolicNotGreaterThanDiastolic() {
        XCTAssertFalse(BPReading(sys: 80, dia: 90).isStructurallyValid)
        XCTAssertFalse(BPReading(sys: 90, dia: 90).isWithinSupportedSaveRange)
    }

    func testAverageAllowsMissingOptionalHeartRate() throws {
        let result = try XCTUnwrap(BPReading.average([
            BPReading(sys: 120, dia: 80, hr: 70),
            BPReading(sys: 130, dia: 90)
        ]))
        XCTAssertEqual(result.hr, 70)
    }

    func testNICEHomeGuideBoundaries() {
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 134, diastolic: 84), .belowThreshold)
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 135, diastolic: 84), .raised)
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 149, diastolic: 95), .high)
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 180, diastolic: 80), .severe)
        XCTAssertEqual(HomeBloodPressureGuide.classification(systolic: 120, diastolic: 120), .severe)
    }

    @MainActor
    func testPairingRecoveryUsesATTErrorCodesNotLocalisedText() {
        XCTAssertTrue(BPClient.isPairingATTError(NSError(domain: CBATTErrorDomain, code: 0x05)))
        XCTAssertTrue(BPClient.isPairingATTError(NSError(domain: CBATTErrorDomain, code: 0x0F)))
        XCTAssertFalse(BPClient.isPairingATTError(NSError(domain: CBATTErrorDomain, code: 0x06)))
        XCTAssertFalse(BPClient.isPairingATTError(NSError(domain: "Unrelated", code: 0x05)))
    }

    func testControlWriteTrackerPreservesStartCancelAcknowledgementOrder() {
        var tracker = ControlWriteTracker()
        tracker.enqueue(.start)
        tracker.enqueue(.cancel)
        XCTAssertEqual(tracker.next(), .start)
        XCTAssertEqual(tracker.next(), .cancel)
        XCTAssertNil(tracker.next())
    }

    @MainActor
    func testMeasurementNotificationsAreAcceptedOnlyDuringActiveRun() {
        XCTAssertTrue(BPClient.acceptsMeasurement(in: .measuring(1, 3)))
        XCTAssertFalse(BPClient.acceptsMeasurement(in: .waiting(1, 3, 30)))
        XCTAssertFalse(BPClient.acceptsMeasurement(in: .checkingBattery))
        XCTAssertFalse(BPClient.acceptsMeasurement(in: .idle))
    }

    @MainActor
    func testGuestSessionAlwaysUsesOneReadingWithoutChangingOwnerCount() {
        XCTAssertEqual(BPClient.sessionReadingCount(configuredCount: 3, guest: true), 1)
        XCTAssertEqual(BPClient.sessionReadingCount(configuredCount: 3, guest: false), 3)
    }
}

@MainActor
final class HealthTests: XCTestCase {
    func testResetSaveStateClearsPreviousOutcome() async {
        let health = Health(store: FakeHealthStore())
        _ = await health.record(BPReading(sys: 120, dia: 80), guest: true, enabled: true)
        XCTAssertNotEqual(health.saveState, .idle)
        health.resetSaveState()
        XCTAssertEqual(health.saveState, .idle)
    }

    func testGuestMeasurementNeverCallsHealthStore() async {
        let store = FakeHealthStore()
        let health = Health(store: store)
        let outcome = await health.record(BPReading(sys: 120, dia: 80), guest: true, enabled: true)
        XCTAssertFalse(outcome.bloodPressureSaved)
        XCTAssertEqual(store.savedObjects.count, 0)
    }

    func testBloodPressureUsesCorrelationAndHeartRateIsSeparate() async {
        let store = FakeHealthStore()
        let health = Health(store: store)
        let outcome = await health.save(BPReading(sys: 120, dia: 80, hr: 72))
        XCTAssertTrue(outcome.bloodPressureSaved)
        XCTAssertEqual(outcome.heartRateSaved, true)
        XCTAssertEqual(store.savedObjects.count, 2)
        XCTAssertTrue(store.savedObjects[0] is HKCorrelation)
        XCTAssertTrue(store.savedObjects[1] is HKQuantitySample)
    }

    func testHeartRateFailureDoesNotLoseSavedBloodPressure() async {
        let store = FakeHealthStore(failAtSaveIndex: 1)
        let health = Health(store: store)
        let outcome = await health.save(BPReading(sys: 120, dia: 80, hr: 72))
        XCTAssertTrue(outcome.bloodPressureSaved)
        XCTAssertEqual(outcome.heartRateSaved, false)
    }
}

private final class FakeHealthStore: HealthStore {
    private(set) var savedObjects: [HKObject] = []
    private let failAtSaveIndex: Int?

    init(failAtSaveIndex: Int? = nil) {
        self.failAtSaveIndex = failAtSaveIndex
    }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}

    func save(_ object: HKObject) async throws {
        if savedObjects.count == failAtSaveIndex {
            throw NSError(domain: "HealthTests", code: 1)
        }
        savedObjects.append(object)
    }
}
