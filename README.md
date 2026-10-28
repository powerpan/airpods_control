# AirPods Motion Lab

一個僅在 macOS 本機運行的 AirPods 頭部運動應用。保留原有運動數據調試界面，在同一條採集流水線上加入 **Privacy Shield 隱私遮擋** 和 **Neck Exercise 頸部活動**。使用 Swift 6、SwiftUI、Core Motion、Swift Charts；沒有第三方依賴、網絡服務或手機端。

## 構建與運行

- Apple Silicon Mac，macOS 14 或更新版本。耳機 API 的最低版本是 macOS 14；工程當前明確構建 arm64。
- Xcode 26 或更新版本（需要原生玻璃效果 API 的 SDK，舊版 macOS 在運行時使用材質回退）。最低系統版本尚未實機驗證。
- 打開 `AirPodsMotionLab.xcodeproj`，選擇 **AirPodsMotionLab → My Mac**，按 ⌘R。
- 使用本地 ad-hoc 簽名，不需要開發者賬號。未啓用 App Sandbox，不申請網絡、輔助功能、藍牙掃描或 Apple Events 權限。

也可以在工程目錄運行：

```sh
./script/build_and_run.sh                    # 構建並啓動；已開啓自動隱私檢測時會開始採集
./script/build_and_run.sh --simulate         # 啓動後自動採集合成數據
./script/build_and_run.sh --verify --simulate
./script/build_and_run.sh --build-only
./script/test.sh
```

構建產物在 `build/DerivedData/Build/Products/Debug/AirPodsMotionLab.app`。腳本會先停止此前運行的本應用，再構建啓動；支持 `--debug`（LLDB）、`--logs` / `--telemetry`（系統進程日誌）。日誌位於被 Git 忽略的 `build/`，運動樣本只保存在有界內存緩衝中。

關閉調試或活動窗口後，應用繼續留在菜單欄。菜單欄可查看採集狀態、切換自動隱私保護、立即遮擋、啓動活動、打開設置或重新打開調試窗口。真正退出請選 **退出 AirPods Motion Lab**；退出會停止採集並移除覆蓋窗口。功能設置保存在本機，姿態參考不跨啓動保存，重新啓動後需重新校準。

## Privacy Shield

1. 連接並佩戴 AirPods，在菜單欄開啓 **自動隱私保護**。應用會複用現有採集會話。
2. 正常看向工作屏幕，選擇 **校準屏幕中立方向**，保持正視片刻，等狀態顯示“正在留意頭部朝向”。
3. 默認左右轉頭偏離至少 35°、連續 0.6 秒後遮擋；回到 20°以內並穩定 0.5 秒後恢復。觸發/恢復角度、持續時間可在 **功能設置 → 隱私保護** 調整。

選擇 **立即遮擋所有屏幕** 可以手動進入，不需要耳機數據。手動遮擋只會手動解除；回正頭部不會替你揭開。每屏都有 **解除遮擋** 按鈕，覆蓋窗口收到鍵盤輸入時也可按 **Esc** 或 **⇧⌘P**。這些是應用內解除方式，不是系統級全局快捷鍵。手動解除後，自動檢測要等回到中立並穩定後才重新就緒，避免剛退出就再次遮擋。

已遮擋時發生斷流、斷連或校準變化，會保留遮擋並要求手動解除；重連不會直接暴露內容。關閉自動檢測也不會自行揭開已有遮擋。短暫異常會清除判定中的保持時間，不會把中斷前後樣本拼成一個完整動作。

自動檢測開關控制的是隱私規則；要停止耳機數據採集，可另選菜單中的 **停止傳感器採集**。兩個功能和調試窗口共用採集會話，不各自開關一份傳感器。

覆蓋層使用公開 AppKit 窗口 API，以 `NSVisualEffectView` 的 `behindWindow` 模式實際模糊桌面和其他窗口；前景卡片與按鈕在 macOS 26 及以上使用原生 Liquid Glass。沒有截屏、屏幕錄製、保存屏幕內容或私有濾鏡流程。系統開啓“減少透明度”時使用實色輔助功能回退。

**這是視覺模糊，不是 macOS 鎖屏**：模糊強度由系統材質決定，公開 API 不提供任意高斯半徑，不承諾任何字號或對比度的內容都不可辨認。應用仍在運行，系統安全窗口、Mission Control、某些全屏或 Spaces 切換可能在覆蓋層之上。詳見 [窗口實現與邊界](docs/privacy-window-limitations.md)。

## Neck Exercise

從菜單欄選擇 **開始頸部活動**。若已遮擋，先明確解除遮擋；應用不會為了打開活動窗口自動揭開內容。自然坐好並面向屏幕，點擊 **校準並開始**。

默認流程是左轉、右轉、左側傾、右側傾、輕微低頭。面向你的 3D 頭部模型示範鏡像動作：模型向它的右側轉，你向左轉；模型低頭，你也低頭。模型緩慢轉到示範姿態後等待，不需要追趕動畫。

每一步只要求沿指定方向達到或超過設定幅度，連續保持默認 0.6 秒，再返回中立並保持 0.5 秒。沒有光點、目標圈或精確角度匹配；保持條來自實際採樣，不隨示範動畫自行完成。低於閾值會重置本次保持計時，另一軸的輕微自然活動不阻止達幅計時。返回中立範圍為各軸最多 6°，小幅度設置時會相應縮小，避免與動作閾值重疊。

默認轉頭 20°、側傾 12°、低頭 10°，可在 **功能設置 → 頸部活動** 調小到自己的舒適範圍。若實際動作被識別為相反方向，可反轉對應軸。進行中的幅度設置不可修改，調整前請結束活動。

可以隨時暫停、繼續、跳過或結束。跳過單獨計數，不計為完成。斷流會暫停動作判定，恢復後按界面提示重新校準；保持時間不會跨過丟失的數據。本次“活動用時”統計有有效採樣的活動時間，不包括暫停和斷流，不是健康評分。

活動期間暫停隱私保護的自動姿態觸發，手動遮擋仍可用並會暫停活動。完成、提前結束或關閉活動窗口後，恢復原來的自動隱私檢測設置，但清除活動參考：**回到工作姿態後重新校準屏幕中立方向**，再恢復自動判斷。兩個功能沒有各自創建新的耳機採集實例。

只在舒適範圍內緩慢活動，疼痛、眩暈或不適時停止。該功能是輕緩活動引導，不用於醫療診斷、治療或康復。模擬模式在窗口中明確標註，模擬完成結果不代表真實動作。

## 真實耳機測試

1. 將 AirPods 連接到這台 Mac 並佩戴，避免測試過程中自動切換到另一台 Apple 設備。選擇 **AirPods**，點擊 **開始**。
2. 按系統提示允許運動訪問。`Config/Info.plist` 已配置必需的 `NSMotionUsageDescription`。若拒絕，請檢查系統設置的 **隱私與安全性 → 運動與健身**，修改後重新開始；系統要求時退出重開應用。模擬模式不請求運動權限。更換簽名或重編譯後，系統可能重新詢問權限。
3. 等到“正在採集”、計數遞增且出現頻率。可用性、連接、授權、正在收幀是不同狀態：“可用”或“已連接”本身不代表已取得運動數據。
4. 保持自然正視姿態，點擊 **校準**。靜止時處理角應接近零；依次緩慢轉頭、點頭和側傾，觀察原始角、派生角、向量和曲線。校準使用最新有效採集幀，即使顯示已暫停也一樣。
5. **暫停顯示**應凍結數值和曲線，但計數、頻率、收幀時間繼續變化；**停止**應停止採集、禁止校準、隱藏實時頻率，並保留標明“非實時”的最後一幀。
6. 測試取下耳機、放回充電盒、斷開再連接、睡眠喚醒。恢復數據後參考姿態會清除，需要重新校準。界面不會把先前的樣本繼續標成實時。
7. 分別記錄 AirPods Pro 2 / Pro 3 的實際結果。型號名稱不替代運行時可用性檢測；公共運動 API 不提供選擇左/右耳或特定耳機型號的接口。

連接/首次權限、重新連接、系統睡眠等行為受 macOS 和耳機固件影響。自動化測試覆蓋軟件狀態機，不能代替這些硬件步驟。[第一階段驗證記錄](docs/verification.md) 保留採集基線；兩個新增功能按 [功能驗收步驟](docs/features-acceptance.md) 分別在 Pro 2、Pro 3 上驗證。

## 數據含義

| 字段 | 約定 |
| --- | --- |
| API 原始 yaw / pitch / roll | 直接保留 `CMAttitude` 數值；模型為弧度，UI 為角度 |
| quaternion | Hamilton 四元數 `(x, y, z, w)`，`w` 為標量；處理前歸一化，原始值保留 |
| rotationRate | rad/s，Apple 處理後的角速度，正號遵循右手規則 |
| userAcceleration / gravity | g；用戶加速度已分離重力，二者都保留耳機坐標，不轉換成世界坐標 |
| timestamp | `CMLogItem` 數據有效時的啓動相對時間，單位秒；不是 Unix 時間，也不解釋為耳機自身啓動時間 |
| receivedAt / receivedUptime | 回調到達時的 `Date` / 本機單調時間；分別用於可讀收幀時間和中斷判斷 |
| measuredFrequency | 最近 2 秒內有效樣本的 `(n−1)/(t_last−t_first)`；至少觀察 0.25 秒，非固定配置值 |

Apple 耳機坐標圖將 Z 軸指向上方、X 軸橫向、Y 軸前後向。不要照搬 iPhone 屏幕坐標或憑軸名預設動作正負號。具體佩戴方向、正負號和多軸行為需要實機確認。

活動的默認方向因子為 yaw −1、pitch −1、roll +1，三軸可在設置中獨立反轉；已保存的設置以界面顯示為準。默認映射不代表所有耳機和佩戴條件都已驗證。

相對四元數定義為 `q_current × inverse(q_reference)`，參考來自未平滑的最近有效姿態。處理角採用本應用明確的 `Rz(yaw) × Rx(pitch) × Ry(roll)` 分解（Yaw/Z、Pitch/X、Roll/Y），不保證與 Apple 未明確公開的多軸 Euler 分解逐項相同。原始 API Euler 單列顯示。接近 ±90° pitch 時 Euler 有奇異性，因此後續識別優先使用四元數；校準不提供絕對方位、位置或無漂移保證。

上述公式保留為原調試頁的公共坐標增量。隱私和活動規則使用獨立的 `headRelativeQuaternion`：在校準時頭部局部坐標中，未平滑公式為 `inverse(q_reference) × q_current`。實際通過對現有平滑結果作基變換獲得，不增加第二次濾波。這樣換一個全局朝向校準時，轉頭、低頭與側傾軸不會跟著世界坐標混合。新增測試覆蓋 0°、±90°、180°朝向；新硬件仍需按驗收步驟檢查實際方向。

API 返回的是融合處理後的運動數據，不是左右耳的底層原始 IMU。`CMHeadphoneMotionManager` 沒有採樣間隔或參考坐標系設置接口。本應用不讀取音頻，也不承諾固定採樣頻率。

## 處理與線程邊界

```text
HeadphoneMotionSource / SimulatedMotionSource
    → 有界 AsyncStream<MotionSourceEvent>（256）
    → MotionSession actor → MotionProcessor
        → 每位訂閱者獨立的有界 AsyncStream<ProcessedMotion>
            → InteractionSession actor
                → PrivacyMachine / NeckExerciseMachine
                → InteractionStore @MainActor（約 10 Hz）
                    → 多屏 AppKit 覆蓋窗口 / SwiftUI 活動與設置
        → SessionSnapshot → MotionStore @MainActor → SwiftUI（約 10 Hz）
```

- `Sources/MotionCore`：純 Swift 數據模型、四元數、校準、時間相關平滑和頻率估計。姿態用最短路徑 SLERP，向量用指數平滑；時間常數默認 80 ms，可關閉。濾波不會覆蓋原始數據。
- `Sources/MotionRuntime`：平台適配、模擬源、狀態機與分發。Core Motion 的對象在主 actor 管理；回調在專用串行 `OperationQueue` 上立即複製成 `Sendable` 值，處理由獨立 actor 串行完成。只有回調橋接器用小範圍鎖。
- `Sources/InteractionCore`：可獨立測試的隱私狀態機、頸部活動狀態機和參數邊界，不持有 UI 或傳感器對象。
- `InteractionSession`：按實際接收樣本運行兩個規則，協調活動期間暫停自動隱私檢測、校準標識和斷流處理。沿用唯一的 `MotionSession`；原調試窗口的顯示暫停不影響功能判斷。
- `AirPodsMotionLab/Privacy`：擁有 AppKit 覆蓋窗口、顯示器/Space 觀察器及解除操作；不決定動作是否完成。
- `AirPodsMotionLab/Exercise` 與 `Settings`：原生 SceneKit 3D 頭部示範、幅度與保持進度、舒適範圍和參數設置。模型在本機程序化構建，無外部模型資產；視覺動畫不參與動作判定。
- `AirPodsMotionLab/Stores` 與 `Views`：約 10 Hz 取快照；圖表最多 330 點，表示顯示採樣而非完整傳感器歷史。暫停只影響顯示，錯誤與連接狀態仍可見。

無效數值、異常四元數、重複/倒退時間戳會被拒絕並計數。超過 1 秒的採樣間隔清除參考、平滑和頻率窗口；超過 2 秒沒有有效到達幀會顯示中斷；仍有採集意圖時最多每 3 秒重新嘗試一次。首次授權尚未決定時保留原始請求，避免循環重啓打斷權限流程；拒絕/受限制權限會停止嘗試。手動停止、退出或數據源切換會釋放採集；世代編號和串行生命週期操作阻止遲到回調恢復舊會話。

消費者不會阻塞採集。輸入或訂閱緩衝滿時丟最舊的數據，界面顯示累計丟棄數；頻率只代表實際接收並接受的數據，不推算缺失樣本。重連可能改變參考坐標，舊校準不會跨連接沿用。

交互規則比調試狀態更早處理數據不連續：樣本間隔超過 0.25 秒會清除保持進度，接收延遲超過 0.3 秒會暫停姿態判斷。每次校準帶獨立標識，兩個功能不會混用舊參考與新參考下的樣本。

## 測試與擴展

`./script/test.sh` 使用 Swift Testing，覆蓋四元數、任意參考校準、跨 ±180°、`q/-q`、奇點、時間相關平滑、不規則頻率、異常數據，以及注入假源後的權限、斷連、重試、背壓和資源釋放。也可直接運行 `swift test`；受限制的代理沙箱若無法再次啓動 SwiftPM manifest 沙箱，可用 `swift test --disable-sandbox`。Xcode 應用 scheme 用於運行；包測試入口是上述腳本或單獨打開 `Package.swift`。

新增測試還覆蓋遲滯與保持時間、手動解除後的重新就緒、斷流保持遮擋、校準變化、真實姿態條件下的目標與返回判定、暫停/跳過，以及單條 Mock 數據源下的兩功能協調。最終批次結果以 `build/tests.log` 和 [功能驗收記錄](docs/features-acceptance.md) 為準，不把規則測試等同於多顯示器或耳機實測。

模擬源產生三軸平滑合成姿態，以不等間隔送入相同流水線；角速度與重力由同一合成姿態計算，無平移用戶加速度。它驗證處理和 UI，不擬合 AirPods 噪聲、漂移或固件行為。

新增功能從這些接口進入：

- 識別算法：獨立模塊訂閱 `await session.samples()`；使用原始時間戳、四元數與向量，不消費 UI 的 10 Hz 快照。遇到時間斷點、掉樣或校準狀態變化時重置算法內部狀態。
- 新數據源：實現 `MotionSource`，用 `MotionSession(source:)` 注入，便於回放與測試。
- 現有交互：先在 `InteractionCore` 修改規則並測試，再由 `InteractionSession` 協調，最後更新 UI；不要從視圖另開傳感器，也不要把 UI 動畫進度當作完成依據。當前只包含隱私遮擋和頸部活動。

## 官方依據

- [CMHeadphoneMotionManager：平台、權限、耳機坐標圖](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)
- [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion)、[rotationRate](https://developer.apple.com/documentation/coremotion/cmdevicemotion/rotationrate)、[gravity](https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity)
- [CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp)
- [Apple 處理後姿態示例](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data)、[CMAttitude 相對姿態](https://developer.apple.com/documentation/coremotion/cmattitude/multiply(byinverseof:))

API 的平台可用性、連接回調隊列及四元數聲明也與公開 Xcode SDK 頭文件交叉核對。

## 文檔維護

文檔統一使用繁體中文。可在項目根目錄執行批量轉換或檢查：

```sh
swift script/convert_docs.swift --write
swift script/convert_docs.swift --check
```

工具使用系統 Foundation 的簡繁轉換能力，無需安裝第三方依賴。默認只檢查，使用 `--write` 才會修改 Markdown；可通過 `--root PATH` 指定另一個項目目錄。隱藏目錄、構建產物、第三方依賴及符號鏈接不會被處理。受限制環境可在 `swift` 後加上 `-module-cache-path build/DocModuleCache`，將編譯緩存放在項目內。

公開文檔只保留項目行為、通用環境要求和去識別的測試結論；不記錄參與者資料、賬號、本機絕對路徑、地理或時間信息。轉換工具只負責文字轉換，內容仍需在發佈前檢查。
