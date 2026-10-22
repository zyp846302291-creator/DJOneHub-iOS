// 本机 Xcode 27.1 编译 DJOneHub 必须加的配置
// 原因：本机 macOS 上 sandbox-exec 已被系统限制（sandbox_apply: Operation not permitted），
// Swift 宏插件服务器（swift-plugin-server）经 sandbox 启动失败 → 所有 @State/@AppStorage 宏报
// "SwiftUIMacros.StateMacro could not be found / produced malformed response"。
//
// 解决：给编译器传 -disable-sandbox 绕过 sandbox-exec。
// 在 Xcode GUI 中：Target → Build Settings → Other Swift Flags 加 "-disable-sandbox"
// 命令行构建：
//   xcodebuild -project DJOneHub.xcodeproj -scheme DJOneHub \
//     -destination 'platform=iOS Simulator,name=iPhone Duo' \
//     -configuration Debug build CODE_SIGNING_ALLOWED=NO \
//     OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'
//
// 已知副作用：宏展开不再走沙盒（Apple 不推荐，但本机别无选择）；其他机器不需要此参数。
