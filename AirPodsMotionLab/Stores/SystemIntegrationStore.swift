import Carbon.HIToolbox
import Foundation
import Observation
import ServiceManagement

/// Background-utility integration: the login item that keeps the shield
/// running after sign-in, and the system-wide "shield now" shortcut.
@MainActor
@Observable
final class SystemIntegrationStore {
    private(set) var loginItemStatus: SMAppService.Status
    private(set) var loginItemError: String?
    private(set) var shieldHotKeyEnabled: Bool
    private(set) var shieldHotKeyRegistered = false
    private(set) var shieldHotKeyError: String?
    @ObservationIgnored private var hotKey: GlobalHotKey?

    init() {
        loginItemStatus = SMAppService.mainApp.status
        shieldHotKeyEnabled = UserDefaults.standard.object(forKey: "shortcut.shield.enabled.v1") as? Bool ?? true
    }

    var shieldHotKeyTitle: String { GlobalHotKey.Shortcut.shieldNow.title }

    func activate(showShield: @escaping @MainActor () -> Void) {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(.shieldNow, action: showShield)
        if shieldHotKeyEnabled { registerHotKey() }
        refreshLoginItem()
    }

    func shutdown() {
        hotKey?.unregister()
        shieldHotKeyRegistered = false
    }

    // MARK: Login item

    var launchAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    var loginItemStatusText: String {
        switch loginItemStatus {
        case .enabled: "已加入登入項目：登入 macOS 後自動在菜單欄啟動。"
        case .requiresApproval: "等待批准：請在「系統設定 → 一般 → 登入項目」允許本應用，否則登入後不會啟動。"
        case .notRegistered: "未加入登入項目。應用沒有運行時，隱私保護不會生效。"
        case .notFound: "系統找不到本應用的登入項目。請將應用放到「應用程式」資料夾後再試。"
        @unknown default: "登入項目狀態未知。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "\(enabled ? "無法加入登入項目" : "無法移除登入項目")：\(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    /// The user can change the login item in System Settings at any time.
    func refreshLoginItem() { loginItemStatus = SMAppService.mainApp.status }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Shortcut

    var shieldHotKeyStatusText: String {
        if let shieldHotKeyError { return shieldHotKeyError }
        return shieldHotKeyRegistered
            ? "在任何應用中按 \(shieldHotKeyTitle) 立即遮擋所有屏幕，不需要輔助功能權限。"
            : "全局快捷鍵已關閉；菜單打開時仍可按 \(shieldHotKeyTitle)。"
    }

    func setShieldHotKeyEnabled(_ enabled: Bool) {
        shieldHotKeyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "shortcut.shield.enabled.v1")
        if enabled {
            registerHotKey()
        } else {
            hotKey?.unregister()
            shieldHotKeyRegistered = false
            shieldHotKeyError = nil
        }
    }

    private func registerHotKey() {
        guard let hotKey else { return }
        let status = hotKey.register()
        shieldHotKeyRegistered = hotKey.isRegistered
        switch status {
        case noErr: shieldHotKeyError = nil
        case OSStatus(eventHotKeyExistsErr): shieldHotKeyError = "\(shieldHotKeyTitle) 已被其他應用或系統快捷鍵佔用，全局快捷鍵未啟用。"
        default: shieldHotKeyError = "無法註冊全局快捷鍵 \(shieldHotKeyTitle)（錯誤 \(status)）。"
        }
    }
}
