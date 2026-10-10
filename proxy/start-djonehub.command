#!/bin/bash
# DJOneHub 一键启动脚本
# 双击即可运行，启动主服务 + Go代理

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_BIN="/Users/zhouyuanpei/Library/Application Support/DJOneHub/runtime/bin/djonehub-macos"
PROXY_BIN="$PROJECT_DIR/djonehub-remote"

echo "=============================="
echo "  DJOneHub 一键启动"
echo "=============================="
echo ""

# 1. 启动主服务（7575）
if lsof -i :7575 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✓ 主服务(7575) 已在运行"
else
    echo "→ 启动主服务..."
    nohup "$MAIN_BIN" -listen 127.0.0.1:7575 > /tmp/djonehub-macos.log 2>&1 &
    sleep 2
    if lsof -i :7575 -sTCP:LISTEN >/dev/null 2>&1; then
        echo "✓ 主服务已启动"
    else
        echo "✗ 主服务启动失败，查看 /tmp/djonehub-macos.log"
    fi
fi

# 2. 启动 Go 代理（7576）
if lsof -i :7576 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✓ Go代理(7576) 已在运行"
else
    echo "→ 启动 Go 代理..."
    cd "$PROJECT_DIR"
    nohup ./djonehub-remote > /tmp/djonehub-remote.log 2>&1 &
    sleep 1
    if lsof -i :7576 -sTCP:LISTEN >/dev/null 2>&1; then
        echo "✓ Go代理已启动"
    else
        echo "✗ Go代理启动失败，查看 /tmp/djonehub-remote.log"
    fi
fi

# 3. 检查 DJOneHubNotifier
if pgrep -f DJOneHubNotifier >/dev/null 2>&1; then
    echo "✓ DJOneHubNotifier 已在运行"
else
    echo "→ 启动 DJOneHubNotifier..."
    open -a DJOneHubNotifier
    sleep 1
    echo "✓ DJOneHubNotifier 已启动"
fi

echo ""

# 4. 显示模块状态
echo "→ 模块状态:"
STATUS=$(curl -s --max-time 3 http://127.0.0.1:7575/api/status 2>/dev/null)
if [ -n "$STATUS" ]; then
    echo "$STATUS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  SIM: {'✓' if d.get('sim_inserted') else '✗'}  运营商: {d.get('operator','?')}  信号: {d.get('signal_dbm','?')}dBm\")
" 2>/dev/null || echo "  (获取状态失败)"
else
    echo "  (主服务未就绪)"
fi

echo ""
IP=$(ipconfig getifaddr en0 2>/dev/null || echo "?")
echo "=============================="
echo "  全部就绪！"
echo "  iPhone 连接地址: $IP:7576"
echo "=============================="
echo ""
echo "按回车键退出窗口（服务继续后台运行）..."
read
