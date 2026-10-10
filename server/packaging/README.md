# DJOneHub for macOS（Universal）

适用于 Apple Silicon 与 Intel Mac（macOS 13 及以上）。

## 安装

1. 完整解压 ZIP。
2. 在终端进入解压后的目录，执行：

   ```sh
   ./install
   ```

3. 打开 DJOneHub App，或执行 `djonehub start`。

程序仅监听 `127.0.0.1:7575`。macOS 首次通话会要求麦克风权限。

## 平台说明

- 后端、App 与 libusb 包含 arm64 + x86_64。
- Apple Silicon 已在开发机验证；Intel Mac 尚未真机验证。
- 发行包未包含或镜像任何模块侧双向通话运行时。首次在 App「设置 → 语音运行时」确认后，App 会从固定的上游官方来源获取指定版本，逐个校验 SHA-256 并保存到本机；后续不会重复下载。
- 短信、4G 网络、GPS、来电提醒、通话状态与控制仍可使用。双向通话还取决于模块型号、固件、SIM、运营商和上游运行时是否仍可用。

完整边界见仓库根目录 `OPEN_SOURCE_SCOPE.md`。
