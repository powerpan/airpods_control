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
        guard let hertz = snapshot.latest?.measuredFrequency else { return "測量中" }
        return DisplayFormatting.number(hertz, digits: 1) + " Hz"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    statusItem("運動數據可用", snapshot.availability.isAvailable ? "是" : "否")
                    statusItem("運動權限", snapshot.source == .simulation ? "模擬無需權限" : snapshot.availability.authorization.title)
                    statusItem("連接狀態", snapshot.source == .simulation ? "模擬數據源" : snapshot.availability.connection.title)
                    statusItem("實際更新頻率", frequency)
                }
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    statusItem("最近收幀時間", DisplayFormatting.receipt(snapshot.lastReceivedAt))
                    statusItem("距最近一幀", age)
                    statusItem("已接受 / 已拒絕", "\(snapshot.acceptedCount) / \(snapshot.rejectedCount)")
                    statusItem("連續性重置 / 緩衝丟棄", "\(snapshot.discontinuityCount) / \(snapshot.ingressDroppedCount + snapshot.subscriberDroppedCount)")
                        .help("中斷：數據連續性重置。緩衝丟棄：輸入 \(snapshot.ingressDroppedCount)，訂閱者 \(snapshot.subscriberDroppedCount)。")
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
