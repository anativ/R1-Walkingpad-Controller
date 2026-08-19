import Charts
import SwiftUI
import WalkingPadKit

/// Speed over the current session.
struct SpeedChartView: View {
    let samples: [SpeedSample]
    let unit: DistanceUnit
    let ceiling: Double

    var body: some View {
        if samples.count < 2 {
            Text("Speed history appears once the belt is moving.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            Chart(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("Speed", unit.speed(fromKph: sample.speedKph))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", sample.elapsed),
                    y: .value("Speed", unit.speed(fromKph: sample.speedKph))
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: 0...max(1, unit.speed(fromKph: ceiling)))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Int.self) {
                            Text(Metrics.formatDuration(seconds))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let speed = value.as(Double.self) {
                            Text(String(format: "%.0f", speed))
                        }
                    }
                }
            }
            .frame(height: 140)
        }
    }
}
