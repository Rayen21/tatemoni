#!/bin/bash
# ============================================================
#  たてモニ ─ メニューバー版アプリを組み立てる  v4.5
#  （内部の本名は くるりんパッ。ソースのファイル名は変えていない）
#
#  やること:
#    1. 居残りを止める
#    2. 中身（デーモン）をビルド
#    3. 皮（メニューバー）をビルド
#    4. たてモニ.app に詰める
#    5. 署名する（許可の設定が消えないようにするため）
#
#  終わったら Finder に たてモニ.app が出ます。
#  ダブルクリックすると メニューバーに アイコンが出ます。
#
#  v4.4 → v4.5: 2026-08-18 6章【4】対応（GitHub公開向け）
#    中身・皮とも、Apple Silicon用とIntel用を両方ビルドしてから
#    lipo で1本の universal バイナリにまとめるよう変更した。
#    ★親分の手元にIntel Macが無く、Intel側の実機動作は確認できて
#      いない（swiftcのクロスコンパイルが通ること・lipoでの結合が
#      成功することまでは確認できるが、それ以上は確認手段が無い）。★
# ============================================================

cd "$(dirname "$0")" || exit 1

echo ""
echo "============================================================"
echo "  たてモニ  アプリ組み立て  v4.5"
echo "============================================================"
echo ""

# --- 0. 道具があるか確かめる ---
if ! command -v swiftc >/dev/null 2>&1; then
  echo "  ❌ swiftc が見つかりません。"
  echo "     ターミナルで  xcode-select --install  を実行してください。"
  echo ""
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi

# --- 1. 居残りを止める ---
echo "  ▶ 居残っているものを止めます…"
pkill -TERM -f kururin_pa_daemon 2>/dev/null
pkill -TERM -f kururin_pa_app 2>/dev/null
sleep 1
pkill -9 -f kururin_pa_daemon 2>/dev/null
pkill -9 -f kururin_pa_app 2>/dev/null

# --- 2. 中身（デーモン）をビルド（Apple Silicon + Intel の universal）---
echo ""
echo "  ▶ 中身をビルド中…（初回は1分ほどかかります）"
echo "     Apple Silicon 用と Intel 用を両方作って、1本にまとめます"
swiftc -O -target arm64-apple-macosx12.3 kururin_pa_daemon.swift -o kururin_pa_daemon_arm64 2> ビルドエラー.txt
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 中身のビルドに失敗しました（Apple Silicon用）。内容："
  echo "  ------------------------------------------------------"
  cat ビルドエラー.txt
  echo "  ------------------------------------------------------"
  echo ""
  echo "  くろに「ビルドエラー.txt を読んで」と言ってください。"
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
swiftc -O -target x86_64-apple-macosx12.3 kururin_pa_daemon.swift -o kururin_pa_daemon_x86_64 2> ビルドエラー.txt
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 中身のビルドに失敗しました（Intel用）。内容："
  echo "  ------------------------------------------------------"
  cat ビルドエラー.txt
  echo "  ------------------------------------------------------"
  echo ""
  echo "  くろに「ビルドエラー.txt を読んで」と言ってください。"
  rm -f kururin_pa_daemon_arm64
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
lipo -create -output kururin_pa_daemon kururin_pa_daemon_arm64 kururin_pa_daemon_x86_64
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 中身の合体（lipo）に失敗しました。"
  rm -f kururin_pa_daemon_arm64 kururin_pa_daemon_x86_64
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
rm -f kururin_pa_daemon_arm64 kururin_pa_daemon_x86_64
echo "  ✅ 中身 OK（universal: Apple Silicon + Intel）"

# --- 3. 皮（メニューバー）をビルド（Apple Silicon + Intel の universal）---
echo ""
echo "  ▶ 皮をビルド中…"
swiftc -O -target arm64-apple-macosx12.3 kururin_pa_app.swift -o kururin_pa_app_arm64 2> ビルドエラー.txt
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 皮のビルドに失敗しました（Apple Silicon用）。内容："
  echo "  ------------------------------------------------------"
  cat ビルドエラー.txt
  echo "  ------------------------------------------------------"
  echo ""
  echo "  くろに「ビルドエラー.txt を読んで」と言ってください。"
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
swiftc -O -target x86_64-apple-macosx12.3 kururin_pa_app.swift -o kururin_pa_app_x86_64 2> ビルドエラー.txt
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 皮のビルドに失敗しました（Intel用）。内容："
  echo "  ------------------------------------------------------"
  cat ビルドエラー.txt
  echo "  ------------------------------------------------------"
  echo ""
  echo "  くろに「ビルドエラー.txt を読んで」と言ってください。"
  rm -f kururin_pa_app_arm64
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
lipo -create -output kururin_pa_app kururin_pa_app_arm64 kururin_pa_app_x86_64
if [ $? -ne 0 ]; then
  echo ""
  echo "  ❌ 皮の合体（lipo）に失敗しました。"
  rm -f kururin_pa_app_arm64 kururin_pa_app_x86_64
  read -n 1 -p "  何かキーを押すと閉じます "
  exit 1
fi
rm -f kururin_pa_app_arm64 kururin_pa_app_x86_64
rm -f ビルドエラー.txt
echo "  ✅ 皮 OK（universal: Apple Silicon + Intel）"

# --- 4. 古いアプリを消す ---
#  ★★ .app は 過去版に残さない ★★  （2026-08-13 に判明した問題）
#
#   macOS の「画面収録」の一覧は、アプリを 名前ではなく
#   背番号（バンドルID）で覚えている。そして表示する名前は
#   「その背番号のアプリを最後に見た場所のファイル名」から取る。
#
#   だから 過去版に たてモニ_2026-08-13_1547.app のような
#   日付つきの .app を残すと、一覧の表示が
#   「たてモニ_2026-08-13_1547」になってしまう。
#
#   .app は このスクリプトで いつでも作り直せる。残す意味がない。
#   ★残すのは ソース（.swift）だけ。★
#
#  ★2026-08-17 の直し★
#   ここは前は ビルドの「前」に置いてあった。
#   そのせいで ビルドに失敗すると 古い .app も消えたあとで、
#   新しい .app も無い状態になっていた（くろが入れたバグ）。
#   両方のビルドが成功した「あと」に消すよう ここへ移動した。
mkdir -p 過去版
rm -rf "たてモニ.app"
rm -rf "くるりんパッ.app"          # 旧名が残っていたら それも消す
echo "  ▶ 前の .app を消しました（新しい物と入れ替えます）"

# --- 5. アプリの形に詰める ---
echo ""
echo "  ▶ たてモニ.app を組み立て中…"
APP="たてモニ.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp kururin_pa_app    "$APP/Contents/MacOS/kururin_pa_app"
cp kururin_pa_daemon "$APP/Contents/MacOS/kururin_pa_daemon"
chmod +x "$APP/Contents/MacOS/kururin_pa_app"
chmod +x "$APP/Contents/MacOS/kururin_pa_daemon"

# ★アイコン★ 親分が作ったもの。消すな。
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "  ✅ アイコン AppIcon.icns を入れました"
else
  echo "  ⚠️ AppIcon.icns が見つかりません（アイコンなしで作ります）"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>たてモニ</string>
    <key>CFBundleDisplayName</key>       <string>たてモニ</string>
    <key>CFBundleExecutable</key>        <string>kururin_pa_app</string>
    <!-- ★背番号は com.yama.kururin-pa から変えるな（2026-08-13 の失敗）★
         これを変えると macOS から見て「別のアプリ」になり、
         画面収録の許可がゼロに戻る。しかも自動で聞いてこなくなる。
         表示名がおかしかった原因は 過去版に溜まった古い .app であって、
         背番号ではなかった。古い .app を消せば表示名は直る。 -->
    <key>CFBundleIdentifier</key>        <string>com.yama.kururin-pa</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key>           <string>1.1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- 6. 署名（ad-hoc）---
#  署名しておかないと、作り直すたびに macOS が「別のアプリ」と見なし、
#  「画面収録」の許可を入れ直すことになる。
echo ""
echo "  ▶ 署名中…"
codesign --force --deep --sign - "$APP" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "  ✅ 署名 OK"
else
  echo "  ⚠️ 署名できませんでした（動きますが、作り直すたびに"
  echo "     画面収録の許可を入れ直すことになります）"
fi

# 隔離フラグを外す（ダウンロード扱いで開けなくなるのを防ぐ）
xattr -dr com.apple.quarantine "$APP" 2>/dev/null

# --- 7. 中間物を片付ける ---
#  kururin_pa_app / kururin_pa_daemon（拡張子なし）は、
#  ビルドで毎回作り直される途中の産物。もう .app の中にコピー済み。
#  ルートに置きっぱなしにしない（引き継ぎメモ 4章のルール）。
rm -f kururin_pa_app kururin_pa_daemon
echo "  ✅ 中間物（拡張子なしの2つ）を片付けました"

echo ""
echo "============================================================"
echo "  ✅ できました"
echo ""
echo "     $(pwd)/たてモニ.app"
echo ""
echo "  【はじめの1回だけ】"
echo "    1. たてモニ.app をダブルクリック"
echo "    2. メニューバーの右のほうに アイコンが出る"
echo "    3. 使い方の窓が出るので、ひととおり読む"
echo "    4. 「縦・ホームボタンが 下」を選ぶと"
echo "       画面収録の許可を聞かれる → 許可する"
echo "    5. たてモニを いったん終了して 開き直す"
echo "       （許可は開き直さないと効きません）"
echo ""
echo "  ※ 中身のログは「たてモニ動作ログ.txt」に残ります。"
echo "============================================================"
echo ""
read -n 1 -p "  何かキーを押すと閉じます "
echo ""
open -R "$APP"
