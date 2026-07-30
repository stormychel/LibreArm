import SwiftUI

struct HypertensionGraphView: View {
    let systolic: Double?
    let diastolic: Double?
    let showsClassification: Bool

    @State private var showingGuidance = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--screenshot-state=guidance")
#else
        false
#endif
    }()

    private let systolicRange = 70.0...200.0
    private let diastolicRange = 40.0...130.0

    private var classification: HomeBloodPressureGuide? {
        guard let systolic, let diastolic else { return nil }
        return .classification(systolic: systolic, diastolic: diastolic)
    }

    private var isOutsidePlot: Bool {
        guard let systolic, let diastolic else { return false }
        return !systolicRange.contains(systolic) || !diastolicRange.contains(diastolic)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let plot = CGRect(x: 40, y: 4, width: max(geometry.size.width - 48, 1), height: max(geometry.size.height - 24, 1))
                ZStack(alignment: .topLeading) {
                    guideBackground(in: plot)
                    Path { path in
                        path.addRect(plot)
                    }
                    .stroke(.primary.opacity(0.7), lineWidth: 1)

                    if let systolic, let diastolic {
                        marker(systolic: systolic, diastolic: diastolic, in: plot)
                    }

                    Text("SYS (mmHg)")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(-90))
                        .position(x: 13, y: plot.midY)
                    Text("DIA (mmHg)")
                        .font(.caption2.bold())
                        .position(x: plot.midX, y: geometry.size.height - 5)
                }
            }
            .frame(height: 142)

            Button {
                showingGuidance = true
            } label: {
                HStack(spacing: 6) {
                    if showsClassification, let classification {
                        Image(systemName: symbol(for: classification))
                        Text(classification.rawValue)
                    } else if systolic != nil {
                        Image(systemName: "waveform.path.ecg")
                        Text("Measurement in progress")
                    } else {
                        Text("Home reading thresholds")
                    }
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.blue)
                    if showsClassification && isOutsidePlot {
                        Label("Outside chart", systemImage: "arrow.up.right")
                    }
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityHint("Shows the NICE home blood pressure guidance")
        }
        .sheet(isPresented: $showingGuidance) {
            ThresholdGuidanceView()
                .presentationDetents([.height(300)])
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func guideBackground(in plot: CGRect) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.65))
            .frame(width: plot.width, height: plot.height)
            .position(x: plot.midX, y: plot.midY)
        zoneRectangle(maxSystolic: 180, maxDiastolic: 120, color: .orange, in: plot)
        zoneRectangle(maxSystolic: 150, maxDiastolic: 95, color: .yellow, in: plot)
        zoneRectangle(maxSystolic: 135, maxDiastolic: 85, color: .green, in: plot)
    }

    private func zoneRectangle(maxSystolic: Double, maxDiastolic: Double, color: Color, in plot: CGRect) -> some View {
        let top = y(for: maxSystolic, in: plot)
        let right = x(for: maxDiastolic, in: plot)
        return Rectangle()
            .fill(color.opacity(0.65))
            .frame(width: max(right - plot.minX, 1), height: max(plot.maxY - top, 1))
            .position(x: (plot.minX + right) / 2, y: (top + plot.maxY) / 2)
    }

    private func marker(systolic: Double, diastolic: Double, in plot: CGRect) -> some View {
        let clampedSystolic = min(max(systolic, systolicRange.lowerBound), systolicRange.upperBound)
        let clampedDiastolic = min(max(diastolic, diastolicRange.lowerBound), diastolicRange.upperBound)
        return Image(systemName: showsClassification && isOutsidePlot ? "arrow.up.right.circle.fill" : "circle.inset.filled")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black)
            .shadow(radius: 2)
            .position(
                x: x(for: clampedDiastolic, in: plot),
                y: y(for: clampedSystolic, in: plot)
            )
            .accessibilityLabel("Blood pressure \(Int(systolic)) over \(Int(diastolic)) millimetres of mercury")
    }

    private func x(for value: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((value - diastolicRange.lowerBound) / (diastolicRange.upperBound - diastolicRange.lowerBound)) * plot.width
    }

    private func y(for value: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat((value - systolicRange.lowerBound) / (systolicRange.upperBound - systolicRange.lowerBound)) * plot.height
    }

    private func symbol(for classification: HomeBloodPressureGuide) -> String {
        switch classification {
        case .belowThreshold: "checkmark.circle"
        case .raised: "triangle"
        case .high: "exclamationmark.circle"
        case .severe: "exclamationmark.triangle.fill"
        }
    }
}

private struct ThresholdGuidanceView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Below raised: under 135/85", systemImage: "checkmark.circle")
                    Label("Raised: 135/85 or above", systemImage: "triangle")
                    Label("High: 150/95 or above", systemImage: "exclamationmark.circle")
                    Label("Severe: 180/120 or above", systemImage: "exclamationmark.triangle.fill")
                }

                Text("Guidance updated February 2026. A single reading does not diagnose hypertension. A severe-range reading needs prompt medical advice.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Blood Pressure Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    HypertensionGraphView(systolic: 120, diastolic: 70, showsClassification: true)
        .padding()
}
