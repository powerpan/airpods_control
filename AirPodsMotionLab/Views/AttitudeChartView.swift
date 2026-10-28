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
                    Text("姿态变化").font(.headline)
                    Spacer()
                    Text("最近 10 秒 · \(isCalibrated ? "相对姿态" : "未校准姿态") · 显示约 10 Hz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Chart(points) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("角度", point.degrees),
                        series: .value("连续片段", point.series)
                    )
                    .foregroundStyle(by: .value("轴", point.axis))
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
                        Text("开始采集后显示曲线").foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Yaw、Pitch、Roll 最近十秒的处理姿态角曲线")
            }
            .padding(8)
        }
    }
}
