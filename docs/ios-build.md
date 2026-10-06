# iPhone 自用构建

iOS 使用与 Android 相同的 `lib/`、资源及依赖，包含当前漫画和轻小说功能。
最低系统版本为 iOS 14（文件选择插件要求）。
本适配基于上游 `fc3f242fee2e3b68de94bc35296fc73db60031c3`（1.7.2+509）。

## 在 Windows 上取得 IPA

1. 在自己的 Fork 中打开 Actions，若提示工作流未启用，启用它们。
2. 选择 **Build iOS IPA**，点击 **Run workflow**，选择包含适配的分支。
3. 成功后下载 `kira-ios-unsigned` artifact，解压取得 IPA。
4. 用 Windows AltServer / AltStore Classic 和自己的 Apple 账号重新签名安装。
   IPA 未签名，不能直接点击安装。普通免费账号需要定期刷新签名。

工作流使用 macOS、Flutter 3.44.2 和 CocoaPods，先进行静态检查及相关测试，
再编译真机 Release 应用。不会上传 Apple 账号、证书或发布 App Store。

## iOS 平台行为

- 保存图片时请求相册访问权限，图片放入 kira 相簿。
- 注册 `kira://` 分享链接；HTTPS Universal Links 尚未配置（需要网站端关联文件）。
- 下载使用应用沙盒，开启了“文件”App 的文档共享；不要将备份或登录凭据存到 Documents。
- 安卓音量键翻页不在 iOS 显示，保留触摸翻页和自动滚动。
- 刷新率由 Flutter/iOS 自动管理；安卓的手动刷新率设置不适用于 iOS。
- iOS 没有 Android 前台下载服务，下载时保持应用在前台；后台持续下载尚未移植。
- 安装新版 IPA 仍需 AltStore 签名，不能使用 APK 更新器。
- Bundle ID 为 `io.github.reabin.kira`；更改它或签名账号可能导致安装为另一个应用。

## 真机验收

云端编译通过不等于真机验收通过。安装后检查首次启动、拷贝/热辣登录、
漫画翻页/缩放/亮度、轻小说阅读、下载与离线重启、相册保存、分享链接、
图标切换、备份导入导出。iPad 还应验证分享弹窗。

本地 Mac 构建：

```sh
flutter config --no-enable-swift-package-manager
flutter pub get
flutter build ios --release --no-codesign
```
