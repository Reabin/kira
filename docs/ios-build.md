# iOS 安装、构建与验证

本指南对应 `Reabin/kira` 的 `ios-port` 分支，当前版本为 **1.7.2+518**，最低支持 **iOS 14**。应用 Bundle ID 为 `io.github.reabin.kira`。

## Windows 用户：取得安装包

1. 登录 GitHub，打开 [Build iOS IPA](https://github.com/Reabin/kira/actions/workflows/build-ios.yml)。
2. 选择 `ios-port` 分支的成功构建；[515 版构建记录](https://github.com/Reabin/kira/actions/runs/37851815997)可作为参考。
3. 下载 **Artifacts → kira-ios-unsigned**，解压得到 `kira-ios-unsigned.ipa`。
4. 通过 Windows 上的 AltServer 和 iPhone 上的 AltStore，使用自己的 Apple 账号签名安装。

构建产物保留 14 天。如果已过期，选择 **Run workflow**，分支选 `ios-port` 后运行。工作流完成后重新下载。

IPA 未签名，无法直接点击安装。签名有效期和刷新方式按安装工具及 Apple 账号要求处理。更新时建议使用原账号覆盖安装；更改 Bundle ID 或签名账号可能使应用安装为另一份。卸载可能丢失本地设置、阅读进度和下载文件。

## 云端构建

工作流文件：[`build-ios.yml`](../.github/workflows/build-ios.yml)。

| 项目 | 当前配置 |
| --- | --- |
| 触发 | 推送到 `ios-port` 或手动运行 |
| 构建环境 | macOS 15、Xcode 26.3 |
| Flutter | 3.44.2 |
| 原生依赖 | CocoaPods，关闭 Swift Package Manager |
| Dart 依赖 | `flutter pub get --enforce-lockfile` |
| 检查 | 静态分析、相关回归测试、iOS 元数据检查 |
| 编译 | 真机 Release，`--no-codesign` |
| 输出 | `kira-ios-unsigned` 构建产物，保留 14 天 |

此流程无需把 Apple 账号或签名证书交给 GitHub，也不会发布到 App Store。构建失败时查看失败步骤的日志；成功打包不等于通过全部真机验收。

## Mac 本地构建

准备与工作流一致的 Flutter、Xcode 和 CocoaPods，并使用本仓库锁定依赖：

```sh
git clone --branch ios-port https://github.com/Reabin/kira.git
cd kira
flutter config --no-enable-swift-package-manager
flutter pub get --enforce-lockfile
flutter analyze
flutter build ios --release --no-codesign
```

输出为 `build/ios/iphoneos/Runner.app`。打包供个人签名使用：

```sh
mkdir -p build/ios/sideload/Payload
cp -R build/ios/iphoneos/Runner.app build/ios/sideload/Payload/
cd build/ios/sideload
zip -qry kira-ios-unsigned.ipa Payload
```

Windows 无法执行 Xcode 编译，使用上述云端流程即可。

## 最近更新与地区筛选

首页顺序为轮播图、最近更新及其他栏目。最近更新的“更多”打开完整列表，支持分页、下拉刷新和详情跳转。

“关注地区”支持日漫、韩漫、美漫多选，默认日漫，至少保留一项，三项全选显示全部。首页与完整列表共用配置；重启、清理缓存后保留选择，并迁移旧版日漫/全部配置。

列表按当前首页来源的更新时间倒序展示。首页最多展示 12 部，每次查询最多扫描 5 页；完整列表保留分页偏移和未展示的同页结果。

地区缺失时复用漫画详情缓存，最多 4 个持续工作槽核实，按已核实的连续结果逐步展示，维持排序。首次过滤需要额外请求，仍可能比其他栏目慢。

列表缓存 5 分钟，地区缓存 30 天。首页可先显示与来源、筛选匹配的最近有效快照（最多 1 小时），随后后台刷新。手动刷新清除当前筛选的分页列表缓存；刷新期间保留内容，失败提供重试。

首页来源选择与阅读来源尚未完全贯通：当前详情和章节仍走热辣接口。因此从拷贝首页进入漫画后，图片可能带热辣水印。

## 音量键翻页

在漫画阅读设置的 **翻页设置 → 音量键翻页** 开启，只在翻页模式生效。音量＋上一页，音量－下一页，开关自动保存，关闭后恢复音量调节。

监听仅在应用前台且阅读路由未被其他页面或弹层覆盖时启用。返回阅读页、切应用后恢复、解锁或音频中断结束时重新激活，没有开启后台音频。

iOS 通过输出音量变化间接识别按键。517 版直接使用与 [HaKa](https://github.com/raoxwup/haka_comic) 相同的 `volume_button_override 0.0.1` 插件，按键后系统媒体音量归位至 50%，关闭开关后可正常调节音量。控制中心等其他系统音量调整也可能触发翻页。

## 代理与测速

系统 HTTP 代理地址与 VPN 隧道不同。未取得 HTTP 代理地址时显示由 iOS 管理网络、VPN 状态无法确认，不据此判断 VPN 未启用。

系统模式下测速前刷新代理配置；返回网络设置页后刷新并重测，旧测速进行中时排队启动新测速。每节点连接探测总时限 5 秒，失败或超时返回不可达。

测速是连接建立延迟，不是下载带宽。是否经过 VPN 取决于系统和分流规则；“直连”只绕过应用层 HTTP/SOCKS 代理，系统 VPN 仍可能处理连接。

## 其他 iOS 行为

- 漫画及小说详情支持左侧边缘返回，可以中途取消手势。
- 保存图片时请求相册权限，图片放入 kira 相簿。
- 支持分享、备用图标和 `kira://` 链接，尚未配置 HTTPS Universal Links。
- 下载使用应用沙盒；已开启“文件”App 文档共享，后台持续下载尚未实现。
- 刷新率由 Flutter/iOS 管理，安卓手动刷新率设置不适用于 iOS。
- 更新 IPA 需重新签名，不使用 APK 更新流程。

## 真机验收

| 场景 | 检查内容 |
| --- | --- |
| 首次启动与账号 | 登录、书架及已有数据是否正常 |
| 最近更新 | 轮播图位置、地区多选、更多入口、分页、下拉刷新 |
| 配置保存 | 重启后地区选择及音量开关保留；清理缓存保留设置 |
| 返回手势 | 漫画/小说详情边缘返回，滑动中途取消 |
| 音量键 | 首次翻页、回桌面/切应用后返回、锁屏解锁后翻页 |
| 音频中断 | 接听电话后返回阅读器，按键继续生效 |
| 监听释放 | 打开设置/评论弹层后暂停，关闭后恢复；关闭开关和退出后音量正常 |
| 阅读与下载 | 翻页、缩放、亮度、轻小说、前台下载及离线重启 |
| 系统功能 | 相册保存、分享、图标切换、备份导入导出；iPad 分享弹窗 |
| 网络 | 切换 VPN 后返回网络设置页，检查提示和测速更新 |

515 版已通过静态分析、相关自动测试和云端真机 Release 编译，IPA 版本号及 ZIP 完整性检查通过。硬件按键和系统中断恢复仍以 iPhone 实测为准。

515 版用户真机反馈按键未翻页。517 版替换自写原生监听，直接使用 HaKa 的同版本插件，Dart 层补充路由与前后台重新启动。最终效果需要重新实测。

## 章节排序记忆

518 版保存漫画详情页的正序／倒序选择，所有漫画共用。首次默认正序；点击排序按钮即保存，退出详情页、切换漫画、重启及清理缓存后保留，设置备份也包含该项。仅改变章节展示顺序，阅读器的上一话／下一话顺序不变。
