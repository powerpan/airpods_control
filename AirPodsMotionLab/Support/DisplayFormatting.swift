import Foundation
import SwiftUI
import MotionRuntime

enum DisplayFormatting {
    static func number(_ value: Double?, digits: Int = 3) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func degrees(_ radians: Double?) -> String {
        guard let radians else { return "—" }
        return number(radians * 180 / .pi, digits: 1) + "°"
    }

    static func receipt(_ date: Date?) -> String {
        guard let date else { return "尚未收到" }
        return date.formatted(date: .omitted, time: .standard)
    }
}

extension MotionSourceKind {
    var title: String { self == .headphones ? "AirPods" : "模擬數據" }
}

extension CapturePhase {
    var title: String {
        switch self {
        case .idle: "待機"
        case .starting: "正在啓動"
        case .waiting: "等待耳機"
        case .streaming: "正在採集"
        case .interrupted: "數據中斷"
        case .permissionDenied: "權限不足"
        case .failed: "採集異常"
        case .stopped: "已停止"
        }
    }

    var color: Color {
        switch self {
        case .streaming: .green
        case .failed, .permissionDenied: .red
        case .waiting, .interrupted, .starting: .orange
        case .idle, .stopped: .secondary
        }
    }
}

extension MotionAuthorization {
    var title: String {
        switch self {
        case .notDetermined: "尚未請求"
        case .authorized: "已允許"
        case .denied: "已拒絕"
        case .restricted: "受系統限制"
        case .unknown: "未知"
        }
    }
}

extension MotionConnection {
    var title: String {
        switch self {
        case .unknown: "尚未確認"
        case .connected: "已連接"
        case .disconnected: "已斷開"
        }
    }
}
