# DJOneHub Bug 排查报告

> 排查日期：2026-10-22 · 范围：ios/ + proxy/（含 push-relay-worker）+ server/ 全量
> 方法：go vet / go build / go test 全绿后，人工精读 iOS 与 proxy 全部源码，server 由两个子代理深查并发与安全，关键结论均经人工复核源码行号。
>
> **⚡ 修复状态（2026-10-22 第二轮）**：除 B1（源码缺失，需向交接方索要）外，其余 25 项已全部修复。
> 标记说明：✅ 已修复 · ⏸️ 需开发者账号（见 送审交接清单.md）· ❌ 未修复
> 修复后验证：server go vet/build/test 8 包全绿 · proxy go vet/build 全绿 · iOS 代码层修改完成

## 一、阻断级问题（链路跑不通 / 交接缺失）

### B1. server 源码不完整：主程序入口缺失 🔴
- `server/cmd/` 与 `server/macos/` 目录为**空**，但 `SOURCE_STRUCTURE.md` 与 4 个构建脚本（`scripts/build-macos.sh` 等）都指向 `./cmd/djonehub-macos`
- 后果：HTTP API 层、gin 路由、通话状态机、USB AT 通道、web 页面 embed 全部缺失，**无法从源码重建主服务**；本机 runtime 里的二进制（2026-10-10 构建）与源码无法对应
- 行动：向交接方索要 `cmd/djonehub-macos/` 与 `macos/` 目录

### B2. VoIP 推送链路协议不匹配：按此源码推送必失败 🔴
- proxy 端 `proxy/push_relay.go:46-59`：POST `/v1/events/call`，body 仅 `{caller, call_uuid}`，认证仅 `X-Device-ID` header（且 `proxy.go:21` 默认空）
- Worker 端 `push-relay-worker/src/index.mjs:1028-1049` `receiveCall` 强制要求：
  1. body 含 `device_id` + `device_secret`（authenticate 从 body 读）→ 缺失即 **401**
  2. `event === "incoming_call"` → proxy 未发 → **400**
  3. `call_uuid` 必须匹配 UUID 正则 → proxy 兜底生成的 `call-20060102-150405`（`signaling.go:487`）→ **400**
  4. `expires_at` 有效时间戳 → proxy 未发 → **400**
- 结论：proxy ↔ Worker 是**两套不同代次的协议**（Worker 实为 AirSIM 系代码，见 wrangler.example.toml 的 `airsim-push-relay`），来电唤醒 iPhone 功能从未按当前源码工作过

### B3. 推送 payload 字段与 iOS 解析不一致：来电永远显示"未知号码" 🔴
- Worker 发送 payload 字段为 `number` / `caller_name`（index.mjs:1109-1110）
- iOS 读取 `dict["caller"]`（`PushKitManager.swift:106`）→ 永远取不到，兜底"未知号码"

### B4. 来电状态字符串两侧矛盾（需 B1 源码仲裁）🔴
- proxy 判断该推 VoIP push 的条件：`state == "ringing"`（`signaling.go:483`）
- iOS 判断该弹 CallKit 的条件：`state == "incoming" || "waiting"`（`SignalingClient.swift:250`、`CallManager.swift:217`）
- 若 server 推送的是 `incoming`：推送永不触发；若是 `ringing`：iPhone 在线时 CallKit 永不弹出。两者不可能同时成立，与 B1 一起需找回 server 通话状态机源码核对

## 二、高严重度

### H1. PushKit 回调未同步上报 CallKit（违反 Apple 规范）iOS
- `PushKitManager.swift:53-57`：`didReceiveIncomingPushWith` 里 completion() 立即调用，而 reportNewIncomingCall 经 `DispatchQueue.main.async` 的 NotificationCenter 异步触发（:112）
- Apple 要求：VoIP push 到达必须**在 completion 前同步**调用 reportNewIncomingCall，否则系统会杀掉 App 且审核必拒。真机表现：后台来电到达瞬间 App 被 terminate

### H2. eSIM 写锁通知 channel 无锁并发操作 → double-close panic / data race（server）
- `internal/esim/manager.go:931-938`（notifyWriteDone 读-替换-close 三步无锁），读方 :879/:902 无锁读同一字段
- 两个写操作收尾交错时可 `close of closed channel` panic；发生在后台 goroutine 则整个进程崩溃

### H3. 配置文件并发读改写 → 静默丢配置（server）
- `internal/config/persist.go:86-95,122-131`：`UpdateNotificationInFile`/`UpdateWebCredentialsInFile` 无锁，与 `persist_devices.go`（有 `deviceFileMu`）互不感知，且共用同一个 `path+".tmp"`
- 并发保存时后写者覆盖前写者（丢设备/丢通知配置），还会把 YAML 注释全部抹掉

### H4. Web 默认弱凭证 admin/admin + AT 注入组合（server）
- `internal/config/config.go:251-252` 默认 admin/admin，`persist.go:112-115` 明文落盘
- 配合 `modem/manager.go:2142`（USSD 拼接）、`:376`（ATD 拼接）无字符白名单：本机任意进程可登录后注入 `\r\n` 执行任意 AT（清短信 `AT+CMGD=1,4`、改 USB 配置 `AT+QCFG` 等）

## 三、中严重度

| # | 模块 | 位置 | 问题 |
|---|---|---|---|
| M1 | iOS | SignalingClient.swift:277-283 | 首连失败不重连（`guard isConnected` 挡住 scheduleReconnect），Mac 不在线时 App 停留后台永不重试 |
| M2 | server | modem/manager.go:2129-2163 | ExecuteUSSD 无互斥（QMI 版有 usdMu，AT 版漏了），并发 USSD 互偷结果 |
| M3 | server | modem/manager.go:356-361 | GetQPCMVChan 懒初始化竞态，并发时订阅者拿到孤儿 channel 永远收不到 URC（影响语音桥流控） |
| M4 | server | esim/manager.go:840 + modem/commands.go:406-423 | 并发 eSIM 读操作的 ClearLogicalChannels 互相关闭对方正在用的逻辑通道 |
| M5 | server | pkg/mbim/device.go:55-87 | Open 失败不回收 readLoop goroutine 与 transport，探测失败累积泄漏 |
| M6 | server | modem/manager.go:485/563/1706 等 | running/healthy 跨 goroutine 无锁读写（data race） |
| M7 | server | modem/manager.go:227 | `fuser` macOS 默认不存在（静默失效）且无超时，异常时可挂死整个启动链路 |
| M8 | iOS | PushKitManager.swift:67、ContentView.swift:24 | URL 强解包 `!`，relayURL 带尾斜杠/空格或 host 非法时直接 crash |
| M9 | iOS | CallManager.swift:204-211 | isHangingUp 在服务器无响应（断线）时永远为 true，期间来电不弹 CallKit |
| M10 | iOS | PushKitManager.swift:80 | environment 硬编码 "sandbox"，TestFlight/App Store 版推送必失败 |

## 四、低严重度 / 文档问题

| # | 模块 | 位置 | 问题 |
|---|---|---|---|
| L1 | proxy | opus_codec.go 全文件 | 死代码：全项目零引用；README 宣称"Opus 音频"与实际 PCM 直传不符 |
| L2 | proxy | signaling.go:196 | mute 转发 `/api/calls/audio/mute`，server 源码中无此路由（因 B1 无法最终确认，需实测） |
| L3 | server | modem/manager.go:1511,1523 | 已读短信 CMGD 删除失败被静默吞掉，SIM 存满后收信静默失效 |
| L4 | server | pkg/logger/log_broadcaster.go:48-53 | Unsubscribe 双调即 close 已关 channel panic |
| L5 | server | modem/manager.go:770,783 | readLoop 错误路径阻塞发送缺 stop 旁路，窄窗口 goroutine 泄漏挂死 StopAndWait |
| L6 | proxy | signaling.go:97 | RemoteAddr 切片无保护，异常地址理论上 panic |
| L7 | iOS | DJOneHubApp.swift:15-23 | onAppear + onChange 双触发 PushKitManager.start，可能创建多个 PKPushRegistry |
| L8 | proxy | push_relay.go | SendCallPush 错误无人消费（`go` 起的调用返回值丢弃），推送失败无任何日志 |

## 五、验证结果（修复后）

- **server**：`go vet ./...` ✓ · `go build ./...` ✓ · `go test ./...` 8 包全绿（含修复后适配的 modem 测试）
- **proxy**：`go vet ./...` ✓ · `go build ./...` ✓（opus 依赖已移除）
- **iOS**：15 个 Swift 文件 `swiftc -parse` 全过；typecheck 与原始副本逐项对照，非宏错误集完全一致（未引入新错误）
- ⚠️ 本机 Xcode 27.1 的 swift-plugin-server 损坏（`--version` 直接挂死），无法完整模拟器编译——**原始未修改副本同样失败**，与代码无关。朋友机器上应可正常 Archive。若遇同样错误：重启 Mac 或重装 Xcode
- server `pkg/smscodec` PDU 解析边界检查完善、`apduarbiter` 并发实现正确、esim 对第三方 panic 有针对性 recover —— 这些区域未发现问题

## 五-B、逐项修复清单（2026-10-22）

| # | 状态 | 修复内容 | 涉及文件 |
|---|---|---|---|
| B1 | ❌ 待索要 | server/cmd 与 macos/ 源码缺失（向交接方索要） | - |
| B2 | ✅ | proxy 推送协议重写对齐 Worker（device_id+secret 认证、event、UUID、expires_at；iPhone 经 push_credentials 消息自动上报凭证） | proxy/push_relay.go, signaling.go, proxy.go; ios/SignalingClient.swift |
| B3 | ✅ | iOS 解析 number/caller_name/caller 多字段 | ios/PushKitManager.swift |
| B4 | ✅ | iOS 与 proxy 均兼容 incoming/waiting/ringing 三种状态 | ios/SignalingClient.swift, CallManager.swift; proxy/signaling.go |
| H1 | ✅ | VoIP push 回调内同步 report CallKit（completion 前） | ios/PushKitManager.swift, CallManager.swift |
| H2 | ✅ | opDone 替换/关闭加 opDoneMu | server/esim/manager.go |
| H3 | ✅ | 配置读改写共享 deviceFileMu + 独立 tmp 文件 | server/config/persist.go |
| H4 | ⏸️ 部分 | AT 注入已加拨号/USSD 白名单；admin/admin 改密属部署事项（见送审清单） | server/modem/manager.go |
| M1 | ✅ | 首连失败也走 scheduleReconnect | ios/SignalingClient.swift |
| M2 | ✅ | ExecuteUSSD 加 ussdMu 互斥 | server/modem/manager.go |
| M3 | ✅ | GetQPCMVChan 懒初始化加 qpcmvMu | server/modem/manager.go |
| M4 | ✅ | forEachEUICC 扫描序列化（scanMu） | server/esim/manager.go |
| M5 | ✅ | mbim Open 失败回收 readLoop+transport | server/pkg/mbim/device.go |
| M6 | ✅ | running/healthy 改 atomic.Bool（含测试适配） | server/modem/manager.go + *_test.go |
| M7 | ✅ | fuser 加 3s 超时 + 失败静默跳过 | server/modem/manager.go |
| M8 | ✅ | URL 构造去强解包（host/port 校验 + 回退默认） | ios/ContentView.swift, PushKitManager.swift |
| M9 | ✅ | isHangingUp 加 8s 兜底复位定时器 | ios/CallManager.swift |
| M10 | ✅ | 推送环境自动检测（receipt 判断 sandbox/production） | ios/PushKitManager.swift |
| L1 | ✅ | 删除 opus_codec.go + go mod tidy 移除依赖 | proxy/ |
| L2 | ✅ | mute 转发 404 静默降级 | proxy/signaling.go |
| L3 | ✅ | CMGD 失败记 Warn 日志 | server/modem/manager.go |
| L4 | ✅ | Unsubscribe 幂等防 double-close | server/pkg/logger/log_broadcaster.go |
| L5 | ✅ | readLoop 错误发送加 stop 旁路 | server/modem/manager.go |
| L6 | ✅ | RemoteAddr 用 net.SplitHostPort 安全切分 | proxy/signaling.go |
| L7 | ✅ | PushKitManager.start 去重 | ios/PushKitManager.swift |
| L8 | ✅ | 推送失败记日志 | proxy/signaling.go, push_relay.go |

## 六、修复优先级建议

1. **先找源码**：B1（cmd/ + macos/）——不解决它，B4/L2 无法仲裁，任何 server 侧修复都无法构建验证
2. **定推送协议**：B2/B3/M10 —— 决定走 AirSIM 新协议（改 proxy）还是还原 DJOneHub 旧 Worker（改 Worker），一次性对齐字段、认证、environment
3. **上架合规**：H1（PushKit 同步 report）——不修真机必炸且必被拒
4. **稳定性**：H2/H3（panic 与丢配置）→ M1-M9 按需
5. 低优先级与文档修正收尾
