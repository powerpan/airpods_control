import SwiftUI
import MotionCore

@MainActor
struct MotionValuesView: View {
    let motion: ProcessedMotion?
    let isPaused: Bool
    let smoothingEnabled: Bool
    let isStreaming: Bool
    let isSimulated: Bool

    private var processedTitle: String {
        let reference = motion?.isCalibrated == true ? "參考姿態下" : "未校準"
        return "\(reference) · \(smoothingEnabled ? "已平滑" : "未平滑")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("姿態角").font(.headline)
                        Spacer()
                        if isPaused {
                            Text("凍結幀").foregroundStyle(.orange)
                        } else if !isStreaming, motion != nil {
                            Text("最後一幀 · 非實時").foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                        GridRow {
                            Text("角度（°）").foregroundStyle(.secondary)
                            columnHeader("Yaw")
                            columnHeader("Pitch")
                            columnHeader("Roll")
                        }
                        angleRow(isSimulated ? "模擬原始姿態" : "API 原始姿態", angles: motion?.raw.attitude)
                        angleRow(processedTitle, angles: motion?.displayAngles)
                    }
                    Text("處理角按 Z-X-Y 分解（Yaw Z / Pitch X / Roll Y）；多軸旋轉時不保證與 API 歐拉角逐項相同。數值不是絕對朝向或位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            HStack(alignment: .top, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("運動向量").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                Text(isSimulated ? "模擬原始數據" : "API 原始數據").font(.caption).foregroundStyle(.secondary)
                                columnHeader("X")
                                columnHeader("Y")
                                columnHeader("Z")
                            }
                            vectorRow("角速度 · rad/s", vector: motion?.raw.rotationRate)
                            vectorRow("用戶加速度 · g", vector: motion?.raw.userAcceleration)
                            vectorRow("重力 · g", vector: motion?.raw.gravity)
                        }
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                Text(smoothingEnabled ? "平滑向量" : "處理向量（未平滑）").font(.caption).foregroundStyle(.secondary)
                                columnHeader("X")
                                columnHeader("Y")
                                columnHeader("Z")
                            }
                            vectorRow("角速度 · rad/s", vector: motion?.smoothedRotationRate)
                            vectorRow("用戶加速度 · g", vector: motion?.smoothedUserAcceleration)
                        }
                    }
                    .padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("四元數與時間戳").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            quaternionRow("x", motion?.raw.quaternion.x)
                            quaternionRow("y", motion?.raw.quaternion.y)
                            quaternionRow("z", motion?.raw.quaternion.z)
                            quaternionRow("w", motion?.raw.quaternion.w)
                        }
                        Divider()
                        Text("採樣時間戳（啓動後秒數）")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(DisplayFormatting.number(motion?.raw.timestamp, digits: 4))
                            .monospacedDigit().textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 280)
            }
        }
    }

    private func columnHeader(_ label: String) -> some View {
        Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func angleRow(_ label: String, angles: AttitudeAngles?) -> some View {
        GridRow {
            Text(label).font(.callout).frame(minWidth: 180, alignment: .leading)
            angleValue(angles?.yaw)
            angleValue(angles?.pitch)
            angleValue(angles?.roll)
        }
    }

    private func angleValue(_ value: Double?) -> some View {
        Text(DisplayFormatting.degrees(value))
            .font(.system(.title2, design: .monospaced).weight(.medium))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
    }

    private func vectorRow(_ label: String, vector: Vector3?) -> some View {
        GridRow {
            Text(label).font(.callout).frame(minWidth: 120, alignment: .leading)
            vectorValue(vector?.x)
            vectorValue(vector?.y)
            vectorValue(vector?.z)
        }
    }

    private func vectorValue(_ value: Double?) -> some View {
        Text(DisplayFormatting.number(value))
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .textSelection(.enabled)
    }

    private func quaternionRow(_ label: String, _ value: Double?) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(DisplayFormatting.number(value, digits: 5))
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}
