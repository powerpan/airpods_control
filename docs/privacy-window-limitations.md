# Privacy Shield 窗口實現與邊界

Privacy Shield 是視覺遮擋，不是鎖屏、身份驗證或防截屏系統。

## 實現

- 每個 `NSScreen.frame` 創建獨立的無邊框 `NSPanel`，覆蓋完整顯示區域而不只覆蓋 `visibleFrame`。窗口 `isOpaque = false`、背景為透明，根視圖是真實的 AppKit 背景模糊層。
- 使用公開的 `.screenSaver` 窗口層級，以及 `.canJoinAllSpaces`、`.canJoinAllApplications`、`.fullScreenAuxiliary`、`.stationary`、`.ignoresCycle` 集合行為。`canJoinAllApplications` 在 macOS 13 起可用，兼容本工程的 macOS 14 最低版本。
- 全屏底層使用 `NSVisualEffectView` 的 `.hudWindow` 材質、`.behindWindow` 混合和 `.active` 狀態，直接由系統模糊後方真實桌面/窗口；前景 SwiftUI 容器保持透明。採用淺色 HUD 外觀，讓真實背景色彩更容易透出；不額外疊加染色層，也不通過降低整層 alpha 混入清晰的桌面像素。沒有生成漸變冒充背景模糊，也沒有覆蓋整屏的淺色蒙版。
- macOS 26 及以上的浮動提示和按鈕使用公開 SwiftUI Liquid Glass：`GlassEffectContainer`、`glassEffect` 和 `.glass` 按鈕樣式。macOS 14–15 的前景卡片回退到 `.withinWindow` 材質，全屏背後模糊仍由同一個 AppKit 根視圖提供。
- 只給前景提示做約 180 ms 的漸入/漸出；解除時全屏模糊保留到動畫結束，然後移除窗口。開啓“減少動態效果”時不等待動畫；只有系統“減少透明度”開啓時使用整屏實色可訪問性回退。
- 沒有調用截屏、屏幕錄製或 WindowServer 私有 API。當前源碼需要含 Liquid Glass API 的 Xcode 26 或更新 SDK 編譯，最低運行版本仍為 macOS 14。
- 監聽顯示配置、活動 Space、系統喚醒；先創建並展示新佈局所需窗口，再關閉舊窗口。窗口配置變化無法作為跨顯示器原子事務完成，因此不能承諾熱插拔瞬間絕無暴露。
- 每屏都有“解除遮擋”按鈕，首個鼠標點擊即可操作。面板可接收鍵盤，Escape 或 ⇧⌘P 請求解除。僅安裝本應用局部鍵盤監聽，不請求輔助功能權限或全局按鍵訪問。
- 面板使用 `.nonactivatingPanel`，不為顯示遮擋主動激活主應用。進入時請求鍵盤焦點；解除後在適當條件下恢復之前的應用/窗口。快速開關使用代際編號和可取消過渡任務，舊動畫不會關閉新遮擋。

## 限制與人工驗收

這些 AppKit 配置表達窗口參與 Spaces/全屏的意圖，並不授予系統級控制。需要在實際系統上分別驗證普通桌面、另一個應用的全屏空間、多個獨立 Spaces、Stage Manager、鏡像/擴展顯示器、旋轉/縮放及顯示器熱插拔。

這是系統材質模糊，不是可指定高斯半徑的截屏濾鏡。公開 `NSVisualEffectView` API 不提供模糊半徑，其結果會隨系統版本、外觀和輔助功能設置變化；不能保證所有字號、圖像或高對比內容都不可辨認。實際驗收必須在背後放置正文、較大文字和圖片，檢查當前系統的模糊強度。對必須保證他人無法讀取的內容，請使用真正鎖屏。

系統鎖屏與登錄界面、安全授權提示、Mission Control 等系統管理界面，或者使用更高窗口層級的程序，可能仍在覆蓋層上方或暫時改變窗口呈現。本應用不能保證覆蓋這些界面；系統切換動畫也不受應用控制。未鎖定 Mac 的其他用戶仍可能切換應用、退出程序或使用系統操作。不要用它代替真正鎖屏。

鍵盤解除只在本應用收到鍵盤事件時有效；如果系統轉移了鍵盤焦點，請點擊任一屏上的“解除遮擋”。程序退出會銷毀覆蓋窗口。後台狀態機負責傳感器斷流時繼續保持遮擋，窗口控制器不會因為耳機斷連自行揭開內容。

視覺覆蓋不會撤銷其他程序已有的屏幕錄製權限，也無法保證某個錄製工具或遠程控制程序一定錄到覆蓋層。被遮擋的應用仍在運行，窗口內容未被隱藏、刪除或加密。

## 官方依據

- [NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
- [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)
- [fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [NSWindow.Level.screenSaver](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct/screensaver)
- [NSEvent 局部事件監聽](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:))
- [NSVisualEffectView 與 behind-window blending](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
- [hudWindow](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum/hudwindow)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- 公開 Xcode SDK `NSWindow.h` 對 `.stationary` 和全屏行為的說明，以及 `NSPanel.h` 的鍵盤/模態屬性。
