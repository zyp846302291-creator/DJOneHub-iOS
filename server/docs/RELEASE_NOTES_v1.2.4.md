# DJOneHub v1.2.4

## 本次更新

- macOS 通话媒体路径改为 MaVo UAC 音频策略：8 kHz 模块通道由原生 Swift 音频服务承载。
- 通话录音恢复为独立旁路写入，修复录音时间轴卡顿问题。
- 新增本机号码读取，兼容 `AT+CNUM` 前置空字段返回。
- 短信读取后自动清理模块存储，可在 App 内开关。
- 重新整理独立 macOS App 的拨号、通话、短信、通讯录、设置与系统提醒体验。
- 保留 4G、GPS、eSIM、AT 调试、网络策略与来电记录能力。

## 发布边界

v1.2.4 公开 Release 不包含模块侧通话运行时，也不承诺下载后即可双向通话。详情见根目录 [OPEN_SOURCE_SCOPE.md](../OPEN_SOURCE_SCOPE.md)。
