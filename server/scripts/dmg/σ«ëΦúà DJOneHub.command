#!/bin/zsh
set -eu
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/DJOneHub"
RUNTIME="$DEST/runtime"
NOTIFIER_DIR="$DEST/notifier"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM=$(id -u)

echo "DJOneHub 一键安装"
echo "安装目录：$DEST"
echo

# 1. 停止旧的服务与通知助手
launchctl bootout "gui/$UID_NUM/com.jamie.djonehub" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID_NUM/com.jamie.djonehub-notifier" >/dev/null 2>&1 || true

# 2. 复制主程序与运行库
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
ditto --norsrc --noextattr --noqtn --noacl ./djonehub "$RUNTIME"
chmod 755 "$RUNTIME/djonehub" "$RUNTIME/bin/djonehub-macos" "$RUNTIME/lib/libusb-1.0.0.dylib"

# 3. 复制通知助手
mkdir -p "$NOTIFIER_DIR"
rm -rf "$NOTIFIER_DIR/DJOneHubNotifier.app"
ditto --norsrc --noextattr --noqtn --noacl ./DJOneHubNotifier.app "$NOTIFIER_DIR/DJOneHubNotifier.app"

# 4. 注册开机自启
mkdir -p "$AGENTS" "$HOME/Library/Logs/DJOneHub"
cat > "$AGENTS/com.jamie.djonehub.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jamie.djonehub</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNTIME/bin/djonehub-macos</string>
    <string>-listen</string>
    <string>127.0.0.1:7575</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/DJOneHub/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/DJOneHub/launchd.log</string>
  <key>WorkingDirectory</key>
  <string>$RUNTIME</string>
</dict>
</plist>
EOF

cat > "$AGENTS/com.jamie.djonehub-notifier.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jamie.djonehub-notifier</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NOTIFIER_DIR/DJOneHubNotifier.app/Contents/MacOS/DJOneHubNotifier</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/DJOneHub/notifier.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/DJOneHub/notifier.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID_NUM" "$AGENTS/com.jamie.djonehub.plist"
launchctl bootstrap "gui/$UID_NUM" "$AGENTS/com.jamie.djonehub-notifier.plist"

# 5. 等待服务就绪并打开管理页面
printf '正在启动 DJOneHub'
ok=0
for i in {1..50}; do
  if curl -fsS --max-time 1 http://127.0.0.1:7575/ >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.2
done
if [ "$ok" = 1 ]; then
  echo "，管理页面已打开。"
  open http://127.0.0.1:7575
else
  echo "，未能就绪，请查看 $HOME/Library/Logs/DJOneHub/launchd.log"
fi
echo "安装完成：开机自动启动；4G/GPS/提醒等设置请在管理页面调整。"
echo
sleep 1
