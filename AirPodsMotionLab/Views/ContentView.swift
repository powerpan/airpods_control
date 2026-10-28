import SwiftUI
import MotionRuntime

@MainActor
struct ContentView: View {
    @Bindable var store: MotionStore
    var features: InteractionStore? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                StatusPanel(snapshot: store.snapshot, refreshedUptime: store.refreshedUptime)
                notices
                MotionValuesView(motion: store.displayedMotion, isPaused: store.isDisplayPaused,
                                 smoothingEnabled: store.displayedSmoothingEnabled,
                                 isStreaming: store.snapshot.phase == .streaming,
                                 isSimulated: store.snapshot.source == .simulation)
                AttitudeChartView(points: store.chartPoints, isCalibrated: store.displayedMotion?.isCalibrated ?? false)
                Text("此頁用於觀察運動數據。隱私保護和頸部活動可從“功能”或菜單欄打開。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 900, minHeight: 740)
        .toolbar {
            if let features {
                ToolbarItem { FeatureToolbarMenu(motion: store, features: features) }
            }
            ToolbarItemGroup(placement: .automatic) {
                Picker("數據來源", selection: Binding(
                    get: { store.snapshot.source },
                    set: { store.selectSource($0) }
                )) {
                    ForEach(MotionSourceKind.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .frame(width: 160)
                .disabled(store.snapshot.isRequested || store.isBusy)
                Divider()
                Button(action: store.start) { Label("開始", systemImage: "play.fill") }
                    .disabled(!store.canStart)
                    .help("開始採集（⌘R）")
                Button(action: store.stop) { Label("停止", systemImage: "stop.fill") }
                    .disabled(!store.canStop)
                    .help("停止傳感器採集（⌘.）")
                Button(action: store.toggleDisplayPause) {
                    Label(store.isDisplayPaused ? "恢復顯示" : "暫停顯示",
                          systemImage: store.isDisplayPaused ? "play.rectangle" : "pause.rectangle")
                }
                .help("只凍結數值與曲線，採集和訂閱繼續運行（⌥⌘P）")
                Button(action: store.calibrate) { Label("校準", systemImage: "scope") }
                    .disabled(!store.canCalibrate)
                    .help("將最新採集姿態設為參考（⌘K）")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("運動數據調試").font(.largeTitle.weight(.semibold))
                Text("\(store.snapshot.source.title) · 實時採集與姿態校準")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Label(store.snapshot.phase.title, systemImage: "circle.fill")
                    .foregroundStyle(store.snapshot.phase.color)
                Toggle("姿態與向量平滑", isOn: Binding(
                    get: { store.snapshot.smoothingEnabled },
                    set: { store.setSmoothing($0) }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if store.snapshot.source == .simulation {
            notice("當前為合成數據，不代表 AirPods 實測結果。", symbol: "waveform.path", color: .blue)
        }
        if store.isDisplayPaused {
            notice("顯示已凍結；採集、校準及數據訂閱仍繼續。上方狀態和收幀時間保持更新。", symbol: "pause.circle", color: .orange)
        }
        if let message = store.snapshot.message {
            notice(message, symbol: "info.circle", color: .secondary)
        }
        if let error = store.snapshot.lastError {
            notice("最近異常：\(error)", symbol: "exclamationmark.triangle", color: .orange)
        }
        if store.snapshot.availability.authorization == .denied || store.snapshot.availability.authorization == .restricted {
            notice("請檢查系統設置 → 隱私與安全性 → 運動與健身中的應用權限，允許後重新開始採集。", symbol: "lock", color: .orange)
        }
        if let message = store.snapshot.calibrationMessage ?? store.localMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func notice(_ message: String, symbol: String, color: Color) -> some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
