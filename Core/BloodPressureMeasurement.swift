import Foundation

struct BPReading: Equatable {
    let sys: Double
    let dia: Double
    let map: Double?
    let hr: Double?
    let irregularPulseDetected: Bool

    init(
        sys: Double,
        dia: Double,
        map: Double? = nil,
        hr: Double? = nil,
        irregularPulseDetected: Bool = false
    ) {
        self.sys = sys
        self.dia = dia
        self.map = map
        self.hr = hr
        self.irregularPulseDetected = irregularPulseDetected
    }

    var isComplete: Bool {
        sys.isFinite && dia.isFinite && sys > 0 && dia > 0
    }

    var isStructurallyValid: Bool {
        isComplete && sys > dia
    }

    var isWithinSupportedSaveRange: Bool {
        isStructurallyValid &&
            (40...260).contains(sys) &&
            (20...200).contains(dia) &&
            hr.map { $0.isFinite && (20...220).contains($0) } != false
    }

    static func average(_ readings: [BPReading]) -> BPReading? {
        guard !readings.isEmpty, readings.allSatisfy(\.isStructurallyValid) else { return nil }
        let count = Double(readings.count)
        let maps = readings.compactMap(\.map).filter(\.isFinite)
        let heartRates = readings.compactMap(\.hr).filter(\.isFinite)
        return BPReading(
            sys: readings.map(\.sys).reduce(0, +) / count,
            dia: readings.map(\.dia).reduce(0, +) / count,
            map: maps.isEmpty ? nil : maps.reduce(0, +) / Double(maps.count),
            hr: heartRates.isEmpty ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
            irregularPulseDetected: readings.contains(where: \.irregularPulseDetected)
        )
    }
}

enum BloodPressureParseError: Error, Equatable {
    case tooShort
    case truncatedOptionalField
    case unsupportedReservedFlags
    case unavailablePressure
}

enum BloodPressureMeasurementParser {
    private static let kPaToMMHg = 7.500_615_758_456_563

    static func parse(_ data: Data) throws -> BPReading {
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { throw BloodPressureParseError.tooShort }

        let flags = bytes[0]
        guard flags & 0b1110_0000 == 0 else {
            throw BloodPressureParseError.unsupportedReservedFlags
        }

        guard
            let rawSystolic = decodeSFloat(bytes[1], bytes[2]),
            let rawDiastolic = decodeSFloat(bytes[3], bytes[4])
        else {
            throw BloodPressureParseError.unavailablePressure
        }
        let rawMAP = decodeSFloat(bytes[5], bytes[6])
        let multiplier = flags & 0x01 == 0 ? 1.0 : kPaToMMHg

        var index = 7
        if flags & 0x02 != 0 {
            guard bytes.count >= index + 7 else { throw BloodPressureParseError.truncatedOptionalField }
            index += 7
        }

        var heartRate: Double?
        if flags & 0x04 != 0 {
            guard bytes.count >= index + 2 else { throw BloodPressureParseError.truncatedOptionalField }
            heartRate = decodeSFloat(bytes[index], bytes[index + 1])
            index += 2
        }

        if flags & 0x08 != 0 {
            guard bytes.count >= index + 1 else { throw BloodPressureParseError.truncatedOptionalField }
            index += 1
        }

        var irregularPulseDetected = false
        if flags & 0x10 != 0 {
            guard bytes.count >= index + 2 else { throw BloodPressureParseError.truncatedOptionalField }
            let measurementStatus = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            irregularPulseDetected = measurementStatus & 0x0004 != 0
            index += 2
        }

        guard index == bytes.count else {
            throw BloodPressureParseError.truncatedOptionalField
        }

        return BPReading(
            sys: rawSystolic * multiplier,
            dia: rawDiastolic * multiplier,
            map: rawMAP.map { $0 * multiplier },
            hr: heartRate,
            irregularPulseDetected: irregularPulseDetected
        )
    }

    static func decodeSFloat(_ lowByte: UInt8, _ highByte: UInt8) -> Double? {
        let raw = UInt16(lowByte) | (UInt16(highByte) << 8)
        let mantissaBits = raw & 0x0FFF

        // IEEE 11073-20601 reserved special values: +Inf, NaN, NRes, Reserved, -Inf.
        if [0x07FE, 0x07FF, 0x0800, 0x0801, 0x0802].contains(mantissaBits) {
            return nil
        }

        let mantissa = mantissaBits >= 0x0800
            ? Int(mantissaBits) - 0x1000
            : Int(mantissaBits)
        let exponentBits = Int((raw >> 12) & 0x000F)
        let exponent = exponentBits >= 8 ? exponentBits - 16 : exponentBits
        return Double(mantissa) * pow(10, Double(exponent))
    }
}

enum HomeBloodPressureGuide: String, CaseIterable {
    case belowThreshold = "Below raised threshold"
    case raised = "Raised"
    case high = "High"
    case severe = "Severe range"

    static func classification(systolic: Double, diastolic: Double) -> Self {
        if systolic >= 180 || diastolic >= 120 { return .severe }
        if systolic >= 150 || diastolic >= 95 { return .high }
        if systolic >= 135 || diastolic >= 85 { return .raised }
        return .belowThreshold
    }
}
