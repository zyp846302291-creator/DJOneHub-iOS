#!/bin/bash
# DJOneHub 一键启动脚本

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== DJOneHub 一键启动 ===${NC}"

# 1. 启动主服务
echo -e "\n${YELLOW}[1/3] 启动 DJOneHub 主服务 (7575)...${NC}"
if lsof -i :7575 > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ 已在运行${NC}"
else
    nohup ~/Library/Application\ Support/DJOneHub/runtime/bin/djonehub-macos -listen 127.0.0.1:7575 > /tmp/djonehub-macos.log 2>&1 &
    sleep 2
    if lsof -i :7575 > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 启动成功${NC}"
    else
        echo -e "${RED}  ✗ 启动失败，查看日志: tail /tmp/djonehub-macos.log${NC}"
    fi
fi

# 2. 启动远程代理
echo -e "\n${YELLOW}[2/3] 启动 DJOneHub-remote 代理 (7576)...${NC}"
if lsof -i :7576 > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ 已在运行${NC}"
else
    cd ~/小米互联服务/project/DJOneHub-remote
    nohup ./djonehub-remote > /tmp/djonehub-remote.log 2>&1 &
    sleep 2
    if lsof -i :7576 > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 启动成功${NC}"
    else
        echo -e "${RED}  ✗ 启动失败，查看日志: tail /tmp/djonehub-remote.log${NC}"
    fi
fi

# 3. 启动 DJOneHub App
echo -e "\n${YELLOW}[3/3] 启动 DJOneHub App...${NC}"
if pgrep -f DJOneHubNotifier > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ 已在运行${NC}"
else
    open /Applications/DJOneHubNotifier.app
    sleep 3
    if pgrep -f DJOneHubNotifier > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 启动成功${NC}"
    else
        echo -e "${RED}  ✗ 启动失败${NC}"
    fi
fi

# 4. 检查 Tailscale
echo -e "\n${YELLOW}[网络] 检查 Tailscale...${NC}"
if pgrep -if tailscale > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ tailscale 已运行${NC}"
    tailscale status 2>/dev/null | head -5
else
    echo -e "${RED}  ✗ tailscale 未运行${NC}"
fi

# 汇总
echo -e "\n${GREEN}=== 启动完成 ===${NC}"
echo ""
echo "  服务状态:"
echo "  • DJOneHub 主服务 (7575):  $(lsof -i :7575 > /dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
echo "  • 代理 (7576):             $(lsof -i :7576 > /dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
echo "  • DJOneHub App:            $(pgrep -f DJOneHubNotifier > /dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
echo "  • Tailscale:               $(pgrep -if tailscale > /dev/null 2>&1 && echo '✅ 运行中' || echo '❌ 未运行')"
echo ""
echo "  iPhone 连接地址: ws://<Tailscale IP>:7576/ws"
echo ""