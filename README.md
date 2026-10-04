# PikGo

在自己的 iPhone 上，用開發者除錯通道模擬 GPS，並把步數寫入「健康」。

主畫面是地圖：**點到哪，系統定位就跳到哪**。這不是普通 App Store App 能做的事；PikGo 走的是和 Xcode Simulate Location 同一條開發者通道。

本專案參考 [StikDebug](https://github.com/StikDebug/StikDebug)（AGPL-3.0）改寫，專注在座標跳點與步數。授權與出處見 [NOTICE.md](NOTICE.md)。

```
地圖點擊
  → PikGo
    → pairing 檔 + LocalDevVPN 迴路隧道
      → location_simulation
        → 系統 CLLocation 變成你點的座標
```

## 功能

- **狀態**：檢查 pairing、LocalDevVPN、位置模擬通道、健康步數
- **地圖**：點擊即跳點；開車 / 腳踏車 / 走路 / 飛機可各自設定路線速度
- **座標**：收藏地點並直接模擬
- **步數**：寫入 HealthKit
- **設定**：匯入 pairing、恢復實際位置、背景保活

## 需求

- iOS 17.4 或更新
- 已開啟開發者模式的裝置
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)
- Remote Pairing 檔（`.mobiledevicepairing` / `.plist`）
- Xcode 與免費或付費 Apple Developer 帳號

## 建置

1. Clone 本倉庫，打開 `PikGo.xcodeproj`
2. Signing 改成**你自己的** Team 與 Bundle ID  
   倉庫裡的 `com.chouhsiang.pikgo` 只是維護者本機用的代號，請不要直接拿去上架或發給別人當正式 ID
3. 選已連接的 iPhone，Cmd+R 安裝
4. 手機：設定 → 一般 → VPN 與裝置管理 → 信任憑證

免費帳號側載大約 7 天要重簽一次。

## 使用

1. 設定 → 隱私權與安全性 → **開發者模式** 打開，重開機
2. 安裝並連上 LocalDevVPN（流量只在本機迴路）
3. 產生 pairing 檔。說明見 [StikDebug Guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)，或在 Mac 執行：

   ```bash
   ./scripts/open-idevice-pair.sh
   ```

4. PikGo → 設定 → 匯入 pairing 檔
5. 狀態分頁四項打勾後，到地圖點擊即可跳點

沒有 pairing 或 VPN 時，地圖仍可點，但不會改系統 GPS。

## 目錄

```
PikGo.xcodeproj     Xcode 專案
PikGo/              App 原始碼
PikGoWidget/        導航 Live Activity
PikGoShared/        App 與 Widget 共用型別
PikGoTests/         單元測試
scripts/            pairing 輔助腳本
```

`pairing/`、`DerivedData/`、`tools/` 是本機檔案，已列入 `.gitignore`，請不要提交。

## 注意

- 只給你自己的裝置、開發與測試用。請不要拿去詐欺、規避平台規則或侵犯他人權益
- pairing 檔等同裝置除錯憑證，不要上傳、不要提交 git
- 系統更新或還原後要重新產生 pairing
- `PikGo/idevice/libidevice_ffi.a` 是編譯所需的 idevice FFI，約 54 MB

## 授權

GNU Affero General Public License v3.0。若你對外散佈改過的 App，必須一併提供對應原始碼。
