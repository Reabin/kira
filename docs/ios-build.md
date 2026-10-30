# iOS 安装、构建与验证

本次构建仅供 iPad 安装，iPad Pro 11 英寸（M5）说明见 [iPad 构建与适配](ipad-build.md)。

本指南对应 `Reabin/kira` 的 `ios-port` 分支，当前版本为 **1.7.4+596**，最低支持 **iOS 14**。应用 Bundle ID 为 `io.github.reabin.kira`。

## Windows 用户：取得安装包

1. 登录 GitHub，打开 [Build Apple IPA](https://github.com/Reabin/kira/actions/workflows/build-ios.yml)。
2. 选择 `ios-port` 分支的成功构建。
3. 下载 **Artifacts → kira-ipad-unsigned** 或 **kira-iphone-unsigned**，解压取得对应 IPA。
4. 通过 Windows 上的 AltServer 和 iPhone 上的 AltStore，使用自己的 Apple 账号签名安装。

构建产物保留 14 天。如果已过期，选择 **Run workflow**，分支选 `ios-port` 并明确选择设备 `ipad` 或 `iphone` 后运行。工作流完成后重新下载。

IPA 未签名，无法直接点击安装。签名有效期和刷新方式按安装工具及 Apple 账号要求处理。更新时建议使用原账号覆盖安装；更改 Bundle ID 或签名账号可能使应用安装为另一份。卸载可能丢失本地设置、阅读进度和下载文件。

## 云端构建

工作流文件：[`build-ios.yml`](../.github/workflows/build-ios.yml)。

| 项目 | 当前配置 |
| --- | --- |
| 触发 | 手动运行并选择 `ipad` / `iphone`；提交代码不自动构建 |
| 构建环境 | macOS 15、Xcode 26.3 |
| Flutter | 3.44.2 |
| 原生依赖 | CocoaPods，关闭 Swift Package Manager |
| Dart 依赖 | `flutter pub get --enforce-lockfile` |
| 检查 | 静态分析、相关回归测试、iOS 元数据检查 |
| 编译 | 真机 Release，`--no-codesign` |
| 输出 | `kira-ipad-unsigned` 或 `kira-iphone-unsigned`，保留 14 天 |

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

## iOS 音量键

本版已移除音量键翻页插件、监听逻辑与开关，iPhone 音量键正常调节音量，不再因翻页将音乐音量归位至50%。

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
| 配置保存 | 重启后地区选择及章节排序保留；清理缓存保留设置 |
| 返回手势 | 漫画/小说详情边缘返回，滑动中途取消 |
| 阅读与下载 | 翻页、缩放、亮度、轻小说、前台下载及离线重启 |
| 系统功能 | 相册保存、分享、图标切换、备份导入导出；iPad 分享弹窗 |
| 网络 | 切换 VPN 后返回网络设置页，检查提示和测速更新 |

构建检查结果以对应版本的 Actions 记录为准。


## 章节排序记忆

518 版保存漫画详情页的正序／倒序选择，所有漫画共用。首次默认正序；点击排序按钮即保存，退出详情页、切换漫画、重启及清理缓存后保留，设置备份也包含该项。仅改变章节展示顺序，阅读器的上一话／下一话顺序不变。

## 上游同步

本版在此前同步基础上合并上游 dde2cde0896a1a7f07ad66b75f887de48d7bd227（2026-10-26、1.7.4）的40次提交。保留iOS适配、最近更新地区筛选和章节排序记忆；移除后续添加的iOS音量插件。

同步时补充账号初始化兼容处理：仅在已保存账号确实需要去重或同步时重写列表，避免单纯补齐来源标签而丢失原始迁移数据。相关冷启动、账号去重、写入失败回滚与只读恢复测试通过。

558版修复大页倒序：大页的显示顺序与章节顺序一起反转，倒序进入时加载最新章节所在大页。大页保留服务器分页边界，因此末页不足100话时倒序首个大页也可能少于100话；阅读记录仍使用原始服务器页位置，保持旧记录兼容。iPad横屏双页规则见ipad-build.md。
