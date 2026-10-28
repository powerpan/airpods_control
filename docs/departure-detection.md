# 離座偵測與保持遮擋

普通轉頭仍使用原有角度與保持時間：轉開後遮擋，回正並穩定後恢復。離座偵測是另一種觸發原因。確認持續行走後，Privacy Shield 會保持遮擋，直到使用原有解除按鈕、菜單入口或覆蓋窗口收到的 Esc／⇧⌘P 明確解除。

這裡的「離座」是根據行走活動作出的保守推斷，不是位置測量。應用不知道書桌在哪裡，也無法證明佩戴者已離開或返回書桌。

## 使用方式

在 **功能設置 → 隱私保護** 開啓自動隱私保護，保留 **離座偵測 → 持續行走後保持遮擋**。坐在書桌前、面向屏幕，使用既有中立方向校準入口。這個主動操作同時確認書桌基準；單純靜止不會建立基準。

可靠步行或跑步證據持續約 2.5 秒後，遮擋文案會改為離座保持提示。若此前已因轉頭遮擋，只更新保持狀態與文案，沿用原來的覆蓋窗口。之後停止行走、在別處長時間靜止或朝向原本的屏幕方向，都不會自動解除。

返回後使用原有方式解除。此操作視為主動確認繼續使用電腦：應用等待約 0.75 秒穩定姿態後重新校準，並等待中立方向穩定及 5 秒離座偵測冷卻。若沒有有效數據，界面會提示等待數據或手動校準；解除操作本身仍立即有效，不需額外解鎖步驟。校準或解除界線之前的活動事件會被拒絕；冷卻期間收到的新事件，最早從冷卻結束後才開始累積保持時間。

關閉自動隱私保護或離座偵測，只停止新的自動判定，不清除已成立的保持遮擋。手動遮擋仍然只能手動解除。頸部活動期間暫停離座判定；結束後沿用既有要求，回到書桌前重新校準。

## 官方活動來源

使用 `CMHeadphoneActivityManager`，沒有對加速度二次積分，也沒有另開一份 `CMHeadphoneMotionManager`。活動適配器與現有姿態來源負責不同的公開服務，由同一個 `InteractionSession` 協調。

| 項目 | 處理方式 |
| --- | --- |
| 系統 | 活動識別 API 從 macOS 15 起可用；整個應用仍支持 macOS 14，舊系統顯示離座偵測不可用，繼續原有轉頭遮擋 |
| 權限 | 沿用 `NSMotionUsageDescription`，檢查活動服務的授權狀態；拒絕、受限或錯誤有獨立提示 |
| 耳機 | 依據運行時可用性及相容耳機連接狀態；Apple 範例列出 AirPods Pro 2 和 AirPods 4，Pro 3 的活動識別需實測，不以型號名稱代替能力檢查 |
| 回調 | 在專用串行隊列接收，立即複製成 `Sendable` 值，不在回調更新 SwiftUI |
| 標籤 | 保留 stationary、walking、running、unknown、automotive；它們不是互斥枚舉，可能同時成立或全部為假 |
| 事件頻率 | 活動類型變化時回報，不能要求固定頻率或連續重複 walking 回調 |
| 不可用時 | 顯示原因並保留轉頭遮擋；不以未經驗證的加速度閾值冒充步行識別 |

耳機活動 handler 的公開 SDK 註解表示 automotive／cycling 目前不受支持；`cycling` 屬性在 macOS 不可用，適配器不讀取它。規則仍排除 automotive，以免未來或測試來源的混合標籤被當作可靠步行。

## 證據與時間

只有 `high` 置信度、walking 或 running 為真，且 stationary、unknown、automotive 都為假的事件，才能開始累積離座證據。低置信度、互相矛盾的標籤、未知活動或無標籤都不能觸發；walking 與 running 同時成立仍可作為行走證據。

`startDate` 是活動變化發生的日期，不是回調到達時間；繼承的 `timestamp` 是數據有效時的啓動相對秒數。適配器另存回調收到時的日期和本機單調時間。日期用於拒絕過舊、未來或校準／重置界線之前的事件；保持時間從採納事件後的本機單調時間開始，不把回調之前的過去時長補算成已完成。目前拒絕超過 5 秒的來源延遲、超過 0.5 秒的排隊延遲，以及重複或倒序事件；校準／重置後有 5 秒冷卻。這些保守門檻可能捨棄仍在行走的初始分類，需要硬件觀察後再調整。

一個有效 walking 事件即可開始候選，之後由協調層計時。期間必須仍有有效的共享姿態流、活動服務及連接狀態；不以「沒有重複活動回調」判斷中斷。新的 stationary 或不可靠事件會清除尚未成立的候選，但已成立的離座保持不受它們影響。

手動解除、重新校準、切換來源、斷連、休眠、數據失效及活動暫停都會清除未成立的證據。新一輪判定使用新的事件界線，並保留冷卻，避免遲到的 walking 事件跨過解除操作。已確認的離座遮擋則只由手動解除清除，不受這些重置事件影響。

## 模塊邊界

- `ActivitySource`／`HeadphoneActivitySource` 將公開 Core Motion 活動服務轉為可注入資料流；測試可注入 Mock，不需要真實耳機。
- `DepartureMachine` 維護主動確認的書桌基準、事件界線、可靠行走候選和保持計時，不持有 UI 或平台管理器。
- `PrivacyMachine` 擁有離座保持狀態，區分可自動恢復的轉頭遮擋與只能手動解除的保持遮擋。
- `InteractionSession` 協調單一姿態流、活動流、服務健康、校準、重新就緒與頸部活動暫停。
- `InteractionStore` 仍以約 10 Hz 快照更新界面，沿用原有覆蓋控制器的顯示與解除入口。設定中的離座開關與其他隱私參數一併保存；舊設定沒有這個欄位時可正常載入。

覆蓋窗口的材質、動畫、顯示器處理和鍵盤事件範圍沒有因離座偵測而改變。它仍是視覺遮擋，不是系統鎖屏；詳見 [窗口實現與邊界](privacy-window-limitations.md)。

## 驗證與限制

完整測試共 97 項通過，macOS Debug 應用編譯通過。新增規則測試使用合成活動事件與 Mock 資料流，檢查保持、恢復、重置及事件時序；它們不能證明真實耳機的步態分類準確率。macOS 14 降級以注入不可用來源驗證，尚未在該系統版本實機執行。人工步驟見 [功能驗收：離座偵測](features-acceptance.md#離座偵測)。

真正的活動識別延遲、置信度變化、韌體差異、重新佩戴與音頻設備切換仍需硬件驗證。坐姿下的節律性晃動可能被官方分類器誤判；很短的步行、緩慢挪動、原地站起或活動回調延遲過大，則可能沒有足夠證據觸發。行走觸發也無法區分離開書桌與在書桌旁移動。應用選擇保守接受證據，因此可能漏報，不承諾偵測每次離座。

## 官方依據

- [CMHeadphoneActivityManager](https://developer.apple.com/documentation/coremotion/cmheadphoneactivitymanager)
- [Getting motion-activity data from headphones](https://developer.apple.com/documentation/coremotion/getting-motion-activity-data-from-headphones)
- [CMMotionActivity](https://developer.apple.com/documentation/coremotion/cmmotionactivity)
- [CMMotionActivity.startDate](https://developer.apple.com/documentation/coremotion/cmmotionactivity/startdate)
- [CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp)

平台可用性、回調型別及不受支持的標籤也已與公開 Xcode SDK 頭文件交叉核對。
