import Charts
import SwiftUI

@MainActor
struct AttitudeChartView: View {
    let points: [AttitudeChartPoint]
    let isCalibrated: Bool

    private var latestTimestamp: Double { points.last?.timestamp ?? 10 }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("姿態變化").font(.headline)
                    Spacer()
                    Text("最近 10 秒 · \(isCalibrated ? "相對姿態" : "未校準姿態") · 顯示約 10 Hz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Chart(points) { point in
                    LineMark(
                        x: .value("時間", point.timestamp),
                        y: .value("角度", point.degrees),
                        series: .value("連續片段", point.series)
                    )
                    .foregroundStyle(by: .value("軸", point.axis))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.7))
                }
                .chartForegroundStyleScale(["Yaw": Color.blue, "Pitch": Color.orange, "Roll": Color.purple])
                .chartXScale(domain: (latestTimestamp - 10)...latestTimestamp)
                .chartYScale(domain: -180...180)
                .chartYAxis {
                    AxisMarks(values: [-180, -90, 0, 90, 180]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let angle = value.as(Int.self) { Text("\(angle)°") }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let time = value.as(Double.self) {
                                Text("\(Int((time - latestTimestamp).rounded()))s")
                            }
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 170)
                .overlay {
                    if points.isEmpty {
                        Text("開始採集後顯示曲線").foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Yaw、Pitch、Roll 最近十秒的處理姿態角曲線")
            }
            .padding(8)
        }
    }
}
