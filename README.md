<p align="center">
  <img src="assets/ic_launcher.png" width="96" alt="kira 图标">
</p>

# kira · iOS 自用分支

基于 [caolib/kira](https://github.com/caolib/kira) 的 Flutter 漫画与轻小说客户端。本 Fork 在安卓代码基础上适配 iPhone，并增加最近更新地区筛选、iOS 返回手势和音量键翻页。

**iOS 改动位于 [`ios-port` 分支](https://github.com/Reabin/kira/tree/ios-port)**，相关变更见 [PR #1](https://github.com/Reabin/kira/pull/1)。当前应用版本为 **1.7.2+518**，最低支持 **iOS 14**。

## 安装到自己的 iPhone

只有 Windows 电脑也可以使用 GitHub Actions 构建 IPA，再通过 AltServer / AltStore 签名安装。

1. 打开 [Build iOS IPA](https://github.com/Reabin/kira/actions/workflows/build-ios.yml)，选择一次成功的 `ios-port` 构建。
2. 在构建页面的 **Artifacts** 下载 `kira-ios-unsigned`，解压取得 `kira-ios-unsigned.ipa`。
3. 使用自己的 Apple 账号，通过 AltStore 签名并安装。
4. 更新时使用相同账号覆盖安装，建议保留原应用，避免卸载导致本地数据丢失。

IPA 未签名，不能直接点击安装；GitHub 下载构建产物需要登录。产物保留 14 天，过期后可在上述工作流选择 **Run workflow → ios-port** 重新构建。签名的有效期及刷新要求取决于使用的 Apple 账号和安装方式。

[515 版成功构建](https://github.com/Reabin/kira/actions/runs/37851815997) · [详细安装与构建说明](docs/ios-build.md)

## 本分支功能

| 功能 | 使用方式 |
| --- | --- |
| 漫画与轻小说 | 保留上游的阅读、书架、下载及相关设置 |
| 首页最近更新 | 轮播图位于顶部，最近更新位于其下，提供与其他栏目一致的“更多”入口 |
| 多选关注地区 | 可组合选择日漫、韩漫、美漫；默认日漫，至少保留一项，三项全选显示全部 |
| 章节排序记忆 | 点击章节列表的排序按钮后，所有漫画共用上次的正序／倒序选择，重启及清缓存保留 |
| 保存筛选配置 | 重启和清理缓存后保留选择；首页与“更多”列表共用配置 |
| iOS 返回手势 | 漫画及小说详情页支持从左侧边缘滑动返回 |
| 音量键翻页 | 漫画阅读设置 → 翻页设置 → 音量键翻页；音量＋上一页，音量－下一页 |
| 代理与测速 | 返回网络设置页后刷新网络配置并重测，不因缺少系统 HTTP 代理地址判定 VPN 未启用 |
| iOS 系统功能 | 相册保存、分享、`kira://` 链接和备用图标 |

音量键翻页仅在漫画的翻页模式生效。开关自动保存；切后台或阅读页被其他页面、弹层覆盖时暂停监听，返回后重新启用。iOS 通过系统音量变化识别按键，控制中心调节音量也可能触发翻页；沿用 HaKa 所用插件的行为，按键后系统媒体音量会归位至 50%；关闭开关后可正常调节音量。

最近更新按当前首页数据源的更新时间倒序展示。列表缓存 5 分钟，首页可先显示有效快照再后台刷新；需要最新结果时可下拉刷新。首次筛选地区可能额外查询漫画详情，加载会比直接列表请求慢。

## 当前边界

- 首页选择拷贝漫画，不代表详情和阅读图片也切换到拷贝。当前详情与章节仍沿用热辣接口，图片可能带热辣水印；完整的拷贝阅读链路尚未移植。
- iOS 下载需保持应用在前台，尚未实现后台持续下载。
- 应用无法通用确认第三方 VPN 的开关状态。测速反映当前应用网络路径的连接延迟，不是下载带宽。
- HTTPS Universal Links 尚未配置；当前支持 `kira://` 链接。
- 515 版音量键翻页在用户真机测试中未生效。517 版改用 HaKa 的同一插件，实际效果仍需 iPhone 验证。

## 开发与构建

本分支基于上游提交 `fc3f242fee2e3b68de94bc35296fc73db60031c3`，后续上游更新需要另行同步。

```sh
git clone --branch ios-port https://github.com/Reabin/kira.git
cd kira
flutter pub get --enforce-lockfile
flutter analyze
```

当前 iOS 工作流使用 Flutter 3.44.2、Xcode 26.3、macOS 15 和 CocoaPods，先运行静态检查与相关测试，再构建真机 Release 应用并打包 IPA。Windows 无法本地编译 iOS，请使用 Actions；Mac 本地构建步骤见 [iOS 构建指南](docs/ios-build.md)。

开发时保持 `pubspec.lock`，不要提交 Apple 账号、签名证书或其他凭据。项目结构与贡献约定见 [AGENTS.md](AGENTS.md)。

## 上游与许可证

感谢 [caolib/kira](https://github.com/caolib/kira) 的原作者与贡献者。本仓库是个人维护的 Fork，不代表上游官方发布。

代码沿用 [MIT License](LICENSE)，保留原作者版权声明。

## 内容说明

kira 是非官方第三方客户端，内容来自第三方服务，应用不生产或上传漫画、小说内容。第三方接口和内容可用性可能变化。

展示内容可能包含不适宜未成年人浏览的信息；请自行确认内容适合浏览，并遵守所在地适用规则。内容相关问题请联系对应提供方，客户端问题可在本 Fork 提交 Issue。
