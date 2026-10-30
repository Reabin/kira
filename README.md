<p align="center">
  <img src="assets/ic_launcher.png" width="96" alt="kira 图标">
</p>

# kira · iOS 自用分支

基于 [caolib/kira](https://github.com/caolib/kira) 的 Flutter 漫画与轻小说客户端。本 Fork 在安卓代码基础上适配 iPhone / iPad，并增加最近更新地区筛选、iOS 返回手势。

**iOS 改动位于 [`ios-port` 分支](https://github.com/Reabin/kira/tree/ios-port)**，相关变更见 [PR #1](https://github.com/Reabin/kira/pull/1)。当前应用版本为 **1.7.4+596**，最低支持 **iOS 14**。

## 安装到自己的 iPhone / iPad

只有 Windows 电脑也可以使用 GitHub Actions 构建 IPA，再通过 AltServer / AltStore 签名安装。

1. 打开 [Build Apple IPA](https://github.com/Reabin/kira/actions/workflows/build-ios.yml)，选择一次成功的 `ios-port` 构建。
2. 在构建页面的 **Artifacts** 下载对应设备产物：`kira-ipad-unsigned` 或 `kira-iphone-unsigned`，解压取得 IPA。
3. 使用自己的 Apple 账号，通过 AltStore 签名并安装。
4. 更新时使用相同账号覆盖安装，建议保留原应用，避免卸载导致本地数据丢失。

IPA 未签名，不能直接点击安装；GitHub 下载构建产物需要登录。产物保留 14 天，过期后可在上述工作流选择 **Run workflow → ios-port**，明确选择 `ipad` 或 `iphone` 重新构建。提交代码不再自动触发安装包构建。签名的有效期及刷新要求取决于使用的 Apple 账号和安装方式。

[查看最新构建](https://github.com/Reabin/kira/actions/workflows/build-ios.yml) · [详细安装与构建说明](docs/ios-build.md)

本次提供 **iPad 版本**，按 iPad Pro 11 英寸（M5）检查架构、横竖屏和窗口缩放；安装包仅声明支持 iPad，不包含 iPhone 设备支持。详见 [iPad 构建说明](docs/ipad-build.md)。

## 本分支功能

| 功能 | 使用方式 |
| --- | --- |
| 漫画与轻小说 | 保留上游的阅读、书架、下载及相关设置 |
| 首页最近更新 | 轮播图位于顶部，最近更新位于其下，提供与其他栏目一致的“更多”入口 |
| 多选关注地区 | 可组合选择日漫、韩漫、美漫；默认日漫，至少保留一项，三项全选显示全部 |
| 章节排序记忆 | 正序／倒序同时作用于章节和大页；倒序先显示最新章节所在大页，重启及清缓存保留 |
| iPad 横屏双页 | 漫画翻页模式下，横屏且窗口足够宽时显示相邻两页；窄窗口或竖屏自动恢复单页 |
| 转屏与布局动画 | 新旧画面渐变衔接；首页封面、标题及底部导航沿轨迹重排，仿真翻页保留开关 |
| 保存筛选配置 | 重启和清理缓存后保留选择；首页与“更多”列表共用配置 |
| iOS 返回手势 | 漫画及小说详情页支持从左侧边缘滑动返回 |
| 代理与测速 | 返回网络设置页后刷新网络配置并重测，不因缺少系统 HTTP 代理地址判定 VPN 未启用 |
| iOS 系统功能 | 相册保存、分享、`kira://` 链接和备用图标 |


最近更新按当前首页数据源的更新时间倒序展示。列表缓存 5 分钟，首页可先显示有效快照再后台刷新；需要最新结果时可下拉刷新。首次筛选地区可能额外查询漫画详情，加载会比直接列表请求慢。

iOS 已移除音量键翻页插件和设置入口，音量键正常调节系统音量。

## 当前边界

- 首页选择拷贝漫画，不代表详情和阅读图片也切换到拷贝。当前详情与章节仍沿用热辣接口，图片可能带热辣水印；完整的拷贝阅读链路尚未移植。
- iOS 下载需保持应用在前台，尚未实现后台持续下载。
- 应用无法通用确认第三方 VPN 的开关状态。测速反映当前应用网络路径的连接延迟，不是下载带宽。
- HTTPS Universal Links 尚未配置；当前支持 `kira://` 链接。

## 开发与构建

已同步上游截至 2026 年 10 月 26 日的提交 `dde2cde0896a1a7f07ad66b75f887de48d7bd227`（1.7.4），包含轻小说专注模式、阅读性能优化、全局文字缩放和历史记录切换；保留本分支的 iPad 双页阅读、章节大页倒序与 iOS 网络适配。

```sh
git clone --branch ios-port https://github.com/Reabin/kira.git
cd kira
flutter pub get --enforce-lockfile
flutter analyze
```

当前 iOS 工作流使用 Flutter 3.44.2、Xcode 26.3、macOS 15 和 CocoaPods，先运行静态检查与相关测试，再构建真机 Release 应用并打包 IPA。Windows 无法本地编译 iOS，请使用 Actions；Mac 本地构建步骤见 [iOS 构建指南](docs/ios-build.md)。

本地与云端保持相同的 pub 源：`PUB_HOSTED_URL=https://pub.dev`，并使用 `--enforce-lockfile` 避免隐式升级依赖。

开发时保持 `pubspec.lock`，不要提交 Apple 账号、签名证书或其他凭据。项目结构与贡献约定见 [AGENTS.md](AGENTS.md)。

## 上游与许可证

感谢 [caolib/kira](https://github.com/caolib/kira) 的原作者与贡献者。本仓库是个人维护的 Fork，不代表上游官方发布。

代码沿用 [MIT License](LICENSE)，保留原作者版权声明。

## 内容说明

kira 是非官方第三方客户端，内容来自第三方服务，应用不生产或上传漫画、小说内容。第三方接口和内容可用性可能变化。

展示内容可能包含不适宜未成年人浏览的信息；请自行确认内容适合浏览，并遵守所在地适用规则。内容相关问题请联系对应提供方，客户端问题可在本 Fork 提交 Issue。
