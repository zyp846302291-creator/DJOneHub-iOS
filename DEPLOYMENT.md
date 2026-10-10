# 部署指南

本仓库包含完整源码与构建脚本，按以下步骤可从零部署整套系统。

## 1. 硬件要求

| 设备 | 要求 |
| --- | --- |
| 4G USB 模块 | BAIWANG / QDC 系列，支持 USB 语音（UAC）与 AT 指令（参考 `server/MACOS.md`、`DJOneHubNative` 的 QDC507 硬件资料） |
| SIM 卡 | 三大运营商 SIM 卡（实体卡或 eSIM 均可），需已开通语音与短信 |
| Mac | Apple Silicon 或 Intel，macOS 12+，作为主机常开 |
| iPhone | iOS 16+，需 Apple 开发者账号用于真机安装 |

## 2. 网络要求

- iPhone 与 Mac 在同一局域网，或通过 Tailscale 组网
- 代理监听端口：`7576`（默认）

## 3. 部署步骤

### 3.1 构建主服务

```bash
cd server
go build -o djonehub-macos ./cmd/djonehub-macos
./djonehub-macos -listen 127.0.0.1:7575
```

Mac 端完整说明（AT 端口、开机自启、演示模式）见 `server/MACOS.md`。

### 3.2 构建代理

```bash
cd proxy
go build -o djonehub-remote .
./djonehub-remote   # 监听 0.0.0.0:7576
```

### 3.3 构建 Mac 音频桥（DJOneHubNotifier）

```bash
cd server/macos/DJOneHubNotifier
./build-app.sh      # 产物：dist/DJOneHubNotifier.app
```

启动 Notifier 后，它会在通话建立时自动连接模块 USB 语音通道。

### 3.4 安装 iOS App

```bash
cd ios
xcodegen generate   # 若直接使用 DJOneHub.xcodeproj 可跳过
open DJOneHub.xcodeproj
```

- 在 Xcode 中设置你的 **Team（Apple 开发者账号）** 与签名
- 连接 iPhone，选择设备后 Run
- 或使用脚本（需替换 `YOUR_DEVICE_UDID`）：

```bash
./build-and-install.sh
```

## 4. iPhone 端配置

打开 App →「更多」页：

- 地址：填写代理地址（局域网 IP 或 Tailscale IP）
- 端口：`7576`
- 保存后回到「概览」，等待显示"已连接"

## 5. 验证清单

- [ ] 主服务启动，`http://127.0.0.1:7575` 可访问
- [ ] 代理监听 `7576`，iPhone「更多」页显示已连接
- [ ] 概览页显示 SIM 已插入、运营商、信号强度
- [ ] 从 App 拨号，对方可接通、声音正常
- [ ] 锁屏来电弹出 CallKit 系统通话界面

## 6. 已知限制

- 后台 CallKit 来电推送（VoIP Push）需要 APNs 证书与 App Store 正式发布，当前仓库不含（见 README「寻求帮助」）
- 各运营商/固件的 AT 指令差异可能需按 `server/docs` 调整
- 主服务默认仅监听 `127.0.0.1`，对外访问请通过代理端口 `7576`
