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
    var title: String { self == .headphones ? "AirPods" : "模拟数据" }
}

extension CapturePhase {
    var title: String {
        switch self {
        case .idle: "待机"
        case .starting: "正在启动"
        case .waiting: "等待耳机"
        case .streaming: "正在采集"
        case .interrupted: "数据中断"
        case .permissionDenied: "权限不足"
        case .failed: "采集异常"
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
        case .notDetermined: "尚未请求"
        case .authorized: "已允许"
        case .denied: "已拒绝"
        case .restricted: "受系统限制"
        case .unknown: "未知"
        }
    }
}

extension MotionConnection {
    var title: String {
        switch self {
        case .unknown: "尚未确认"
        case .connected: "已连接"
        case .disconnected: "已断开"
        }
    }
}
