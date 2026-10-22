# DJOneHub 完整项目（交接版）

> 本包为 DJOneHub 项目完整源码，供接手方（WorkBuddy / 开发者）继续开发、构建与发布。
> 版本：iOS App v3.0（Build 27）· 主服务与代理为当前开发版

## 一、项目结构

```
DJOneHub-full-source/
├── ios/       # iOS App 源码（SwiftUI，Xcode 工程）
├── proxy/     # Go 代理（djonehub-remote：iPhone↔主服务 WebSocket 信令/音频转发）
└── server/    # 主服务（djonehub-macos：AT 指令控制 4G 模块 + Mac 音频桥）
```

## 二、模块说明

| 模块 | 路径 | 语言/技术 | 作用 |
|---|---|---|---|
| iOS App | `ios/DJOneHub.xcodeproj` | SwiftUI | 拨号盘、通话记录、短信、CallKit 通话界面 |
| Go 代理 | `proxy/` | Go | 监听 7576，转发到主服务 7575 |
| 主服务 | `server/` | Go | AT 指令控制 4G 模块（拨号/接听/短信/eSIM），UAC 语音桥接 |
| 推送中继 | `proxy/push-relay-worker/` | Cloudflare Worker | 接收 App 上报的 VoIP token，向 APNs 发 PushKit 推送 |

## 三、运行链路

```
iPhone App ──WebSocket──► proxy(7576) ──HTTP──► server(7575) ──USB──► 4G 模块
   (CallKit)              Go 代理                主服务               (BAIWANG/QDC)
```

## 四、iOS 端构建

1. 打开 `ios/DJOneHub.xcodeproj`
2. Signing & Capabilities：Team 选自己的开发者账号，自动签名
3. **需要的能力**（当前项目尚未配置 entitlements，需在 Xcode 添加）：
   - Push Notifications（VoIP 推送依赖）
   - Background Modes：Voice over IP + Audio（Info.plist 已含 audio/voip/fetch）
4. 创建 **VoIP Services 证书**（developer.apple.com → Certificates → VoIP Services），导出 .p12 给推送服务端
5. 真机 Run 或 Archive → Distribute App → App Store Connect

## 五、Mac 端服务运行

一键启动：`proxy/start-djonehub.command`（双击运行，会启动主服务 7575 + 代理 7576）

> 注意：主服务二进制位于 `~/Library/Application Support/DJOneHub/runtime/bin/djonehub-macos`（由 server/ 源码构建后安装）

## 六、当前状态与已知事项

- ✅ iOS App v3.0：已适配 iPhone Duo 折叠屏（展开横屏左右分栏布局已**回退**，当前为原横屏布局；竖屏/横屏/折叠外屏均有适配）
- ✅ 通话功能：呼出/来电、CallKit、静音/免提/DTMF
- ✅ 短信收发、通话记录、联系人本地读取（不上传服务器）
- ✅ VoIP 推送：PushKit 已实现，token 上报到 Cloudflare Worker relay（`pushRelayURL/v1/devices/register`）
- ⚠️ 待配置：VoIP 推送的 entitlements、证书、推送服务端 .p12（详见 `ios/配置发布说明.md`）
- ⚠️ 审核注意：App Store 审核需说明外接 4G 模块用途（5.2.5 条款），并提供演示模式说明

## 七、常见端口

| 服务 | 端口 |
|---|---|
| 主服务 djonehub-macos | 7575 |
| 代理 djonehub-remote | 7576 |
| adb（勿常驻，会占用 USB 语音接口） | 5037 |

## 八、备注

- iOS 源码内含演示模式（demoMode）开关，用于 App Store 审核演示，正常使用不受影响
- server/ 含 Windows 支持（主服务可跨平台）
- 完整配置与发布细节见 `ios/配置发布说明.md`
