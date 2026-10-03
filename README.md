# PikGo

在自己的 iPhone 上用開發者除錯通道模擬 GPS，並寫入健康步數。主畫面是地圖：**點到哪，系統定位就跳到哪**。

本專案參考 [StikDebug](https://github.com/StikDebug/StikDebug)（AGPL-3.0）改寫，加上皮克敏用的座標跳點與步數。LocalDevVPN 從 App Store 安裝即可。

這不是普通 App Store App 能做的事。iOS 不讓一般 App 改系統 GPS。這裡用的是和 Xcode Simulate Location 同一條 **開發者通道**：

```
地圖點擊
  → PikGo
    → pairing 檔 + LocalDevVPN 迴路隧道
      → location_simulation 服務
        → 系統 CLLocation 變成你點的座標
```

## 工程資訊

- 顯示名稱：`PikGo`
- Bundle ID：`com.chouhsiang.pikgo`
- Widget：`com.chouhsiang.pikgo.NavigationWidget`
- Xcode 專案：`PikGo.xcodeproj`
- 遠端：https://github.com/chouhsiang/pikgo

## 使用流程

### 1. 手機準備

1. 設定 → 隱私權與安全性 → **開發者模式** 打開，重開機
2. 手機解鎖，插著 USB，點「信任這台電腦」
3. App Store（美區）安裝 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)
4. 打開 LocalDevVPN，按 **Connect**（流量只在本機迴路，不送外網）

### 2. 產生 pairing 檔

需要 **Remote Pairing** 檔（`.mobiledevicepairing` / `.plist`），升級或重置手機會失效。配對說明可參考 [StikDebug Guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)。

手機解鎖、停在主畫面，在這台 Mac 執行：

```bash
./scripts/open-idevice-pair.sh
```

會打開 [idevice pair](https://github.com/jkcoxson/idevice_pair/releases/latest)。安裝後：

1. 選你的 iPhone
2. 選 **Remote pairing**
3. 按 **Create / Generate**（手機再確認信任）
4. 存檔，AirDrop 到 iPhone 的「檔案」

### 3. 用 Xcode 安裝

1. 打開 `PikGo.xcodeproj`
2. Signing：登入 Apple ID，確認 Bundle ID 是你的
3. 選已連接的 iPhone，Cmd+R 安裝
4. 手機：設定 → 一般 → VPN 與裝置管理 → 信任憑證

免費帳號側載大約 7 天要重簽一次。

### 4. 第一次使用

1. LocalDevVPN 保持 Connect
2. 開 PikGo → **設定** → 匯入 pairing 檔
3. **狀態** 分頁四項都打勾後才算可以使用：pairing、LocalDevVPN、位置模擬、健康步數
4. 到 **位置** 點地圖任意位置，定位會立刻跳過去
5. **座標** 可收藏地點；**步數** 可寫入健康 App

沒匯入 pairing、或 VPN 沒開時，地圖仍可點，但不會真的改系統 GPS。

## 這個 fork 改了什麼

- 主分頁改成 **狀態 / 位置 / 座標 / 步數 / 設定**
- 點地圖會立刻呼叫 `simulate_location`
- 開車、腳踏車、走路、飛機可各自設定路線速度（預設 18 km/h）
- 健康步數寫入（HealthKit）
- 4G 也能維持位置模擬通道（必要時切飛航模式重建通道）

## 注意

- 只給你自己的裝置、開發與測試用。請不要拿去詐欺、規避平台規則或侵犯他人權益
- pairing 檔等同裝置除錯憑證，不要上傳、不要提交 git
- 系統更新或還原後要重新產生 pairing
- 中國地圖若有偏移，是 GCJ-02 / WGS-84 座標系差異，不是點擊沒生效

## 授權

本專案沿用上游 **AGPL-3.0**。若你對外散佈改過的 App，必須一併提供對應原始碼。
