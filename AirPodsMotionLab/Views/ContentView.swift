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
                Text("此页用于观察运动数据。隐私保护和颈部活动可从“功能”或菜单栏打开。")
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
                Picker("数据来源", selection: Binding(
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
                Button(action: store.start) { Label("开始", systemImage: "play.fill") }
                    .disabled(!store.canStart)
                    .help("开始采集（⌘R）")
                Button(action: store.stop) { Label("停止", systemImage: "stop.fill") }
                    .disabled(!store.canStop)
                    .help("停止传感器采集（⌘.）")
                Button(action: store.toggleDisplayPause) {
                    Label(store.isDisplayPaused ? "恢复显示" : "暂停显示",
                          systemImage: store.isDisplayPaused ? "play.rectangle" : "pause.rectangle")
                }
                .help("只冻结数值与曲线，采集和订阅继续运行（⇧⌘P）")
                Button(action: store.calibrate) { Label("校准", systemImage: "scope") }
                    .disabled(!store.canCalibrate)
                    .help("将最新采集姿态设为参考（⌘K）")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("运动数据调试").font(.largeTitle.weight(.semibold))
                Text("\(store.snapshot.source.title) · 实时采集与姿态校准")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Label(store.snapshot.phase.title, systemImage: "circle.fill")
                    .foregroundStyle(store.snapshot.phase.color)
                Toggle("姿态与向量平滑", isOn: Binding(
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
            notice("当前为合成数据，不代表 AirPods 实测结果。", symbol: "waveform.path", color: .blue)
        }
        if store.isDisplayPaused {
            notice("显示已冻结；采集、校准及数据订阅仍继续。上方状态和收帧时间保持更新。", symbol: "pause.circle", color: .orange)
        }
        if let message = store.snapshot.message {
            notice(message, symbol: "info.circle", color: .secondary)
        }
        if let error = store.snapshot.lastError {
            notice("最近异常：\(error)", symbol: "exclamationmark.triangle", color: .orange)
        }
        if store.snapshot.availability.authorization == .denied || store.snapshot.availability.authorization == .restricted {
            notice("请检查系统设置 → 隐私与安全性 → 运动与健身中的应用权限，允许后重新开始采集。", symbol: "lock", color: .orange)
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
