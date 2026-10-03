#!/bin/zsh
set -euo pipefail

# PikGo 3.1+ 需要 Remote Pairing 檔（.mobiledevicepairing / .plist）。
# 官方建議用 idevice pair：https://github.com/jkcoxson/idevice_pair
#
# 使用前：
# 1. iPhone 解鎖、停在主畫面，並已點「信任這台電腦」
# 2. 設定 → 隱私權與安全性 → 開發者模式 已開啟
# 3. 線仍插著

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/pairing"
mkdir -p "$OUT"

echo "iPhone USB 連線狀態："
if ioreg -p IOUSB -w 0 | grep -q 'iPhone'; then
  echo "  已偵測到 iPhone"
else
  echo "  目前沒看到 iPhone，請確認線材與解鎖"
fi

echo
echo "接著會開啟 idevice pair 下載頁。"
echo "安裝後打開 App → 選你的裝置 → Remote pairing → Create / Generate"
echo "把產生的檔案存到："
echo "  $OUT"
echo
echo "再 AirDrop 到 iPhone，在 App 的 Settings 匯入 pairing file。"
echo "（不要把 pairing 檔提交到 git）"

open "https://github.com/jkcoxson/idevice_pair/releases/latest"
open "$OUT"
