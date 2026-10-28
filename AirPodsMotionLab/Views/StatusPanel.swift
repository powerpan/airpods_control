import SwiftUI
import MotionRuntime

@MainActor
struct StatusPanel: View {
    let snapshot: SessionSnapshot
    let refreshedUptime: TimeInterval

    private var age: String {
        guard let received = snapshot.lastReceivedUptime else { return "—" }
        return DisplayFormatting.number(max(0, refreshedUptime - received), digits: 1) + " 秒前"
    }

    private var frequency: String {
        guard snapshot.phase == .streaming else { return "—" }
        guard let hertz = snapshot.latest?.measuredFrequency else { return "测量中" }
        return DisplayFormatting.number(hertz, digits: 1) + " Hz"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    statusItem("运动数据可用", snapshot.availability.isAvailable ? "是" : "否")
                    statusItem("运动权限", snapshot.source == .simulation ? "模拟无需权限" : snapshot.availability.authorization.title)
                    statusItem("连接状态", snapshot.source == .simulation ? "模拟数据源" : snapshot.availability.connection.title)
                    statusItem("实际更新频率", frequency)
                }
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    statusItem("最近收帧时间", DisplayFormatting.receipt(snapshot.lastReceivedAt))
                    statusItem("距最近一帧", age)
                    statusItem("已接受 / 已拒绝", "\(snapshot.acceptedCount) / \(snapshot.rejectedCount)")
                    statusItem("连续性重置 / 缓冲丢弃", "\(snapshot.discontinuityCount) / \(snapshot.ingressDroppedCount + snapshot.subscriberDroppedCount)")
                        .help("中断：数据连续性重置。缓冲丢弃：输入 \(snapshot.ingressDroppedCount)，订阅者 \(snapshot.subscriberDroppedCount)。")
                }
            }
            .padding(8)
        }
    }

    private func statusItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit().textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
