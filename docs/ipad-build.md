# iPad Pro 11 英寸（M5）构建

本次版本为 1.7.4+594，提供 iPad 专用 IPA。继续使用相同应用标识和个人签名安装方式，覆盖安装保留应用数据。

## 与 iPhone 构建的区别

M5 不要求独立的一套阅读器代码。使用 iPad 真机 ARM64 构建，并将最终包的 `UIDeviceFamily` 限定为 `[2]`。这表示支持 iPad 家族，不是只允许运行在 M5 上，也不宣称有专用芯片优化。

源码保留 iPhone/iPad 通用工程配置。Actions 手动选择 `ipad` 或 `iphone` 后，仅在该次构建中将所有 Runner 配置的 `TARGETED_DEVICE_FAMILY` 设为 `2` 或 `1`。本次只触发 `ipad`，不生成 iPhone 包；以后按用户指定的设备编译。

## 按官方文档核对

| 项目 | 本次处理 |
| --- | --- |
| 设备与架构 | 编译后检查 `UIDeviceFamily=[2]`、`DTPlatformName=iphoneos`，主程序和 Flutter App 框架均含 ARM64 |
| 屏幕方向 | 保留 iPad 竖屏、倒置竖屏、横屏左右四方向 |
| 窗口缩放 | 不设置 `UIRequiresFullScreen=true`；保留现有 UIKit scene 生命周期，单场景支持窗口大小变化，不新增多实例窗口 |
| 弹层 | 修复已打开设置弹窗仍使用旧窗口高度的问题；转屏和缩小窗口后按当前高度重新计算上限 |
| 布局检查 | 用 834×1210、1210×834、420×650 的逻辑窗口测试弹窗转屏与缩放、内容可滚动和无溢出；设备全屏物理像素与窗口逻辑尺寸分别处理 |
| 分享 | 保留现有 `sharePositionOrigin` 锚点，避免 iPad 分享弹窗缺少来源位置 |
| 间接输入 | 保留 `UIApplicationSupportsIndirectInputEvents` 配置；此次没有新增键盘快捷键或手写识别功能 |

参考：[苹果 iPad Pro M5 屏幕规格](https://www.apple.com/ipad/compare/?modelList=ipad-pro-11-m5%2Cipad-8th-gen)、[Xcode 设备架构说明](https://help.apple.com/xcode/mac/current/en.lproj/dev34b59f90c.html)、[支持的屏幕方向](https://developer.apple.com/documentation/uikit/uiviewcontroller/supportedinterfaceorientations)、[iPad 窗口缩放与全屏兼容模式](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequiresfullscreen)。

## 下载与安装

1. 打开仓库 Actions 的 **Build Apple IPA**，选择 `ios-port` 分支。
2. 手动运行时选择 `device_family=ipad`。
3. 成功后下载 `kira-ipad-unsigned`，解压取得 `kira-ipad-unsigned.ipa`。
4. 通过原来的 AltStore/Apple 账号在 iPad 上签名安装。该安装包不用于 iPhone。

编译、架构及窗口尺寸测试不等于 M5 真机验收。请在实际设备检查全屏横竖切换、窗口缩放、阅读缩放与进度、设置弹层、分享弹窗，以及键盘/触控板连接时的常规操作。iPad 的多应用窗口布局也应实际检查。

## 横屏双页阅读（558版）

在漫画阅读设置中选择“翻页”模式。iOS窗口横屏、宽度至少900且高度至少600逻辑像素时，自动显示相邻两张漫画页；竖屏和窄窗口恢复单页。连续滚动模式仍按原方式滚动，不会自动改变用户选择的阅读模式。

沿用左右阅读方向：右到左时先读右页，左到右时先读左页。每话独立配对，不跨话拼页；奇数末页的另一侧留空。翻屏一次前进一组，进度条仍定位原始页码，底栏显示当前两页范围。单页、双页切换，以及前后章节拼接和内存裁剪时保留阅读位置。

目录倒序同时反转大页顺序，第一大页从最新章节所在批次开始。切换排序和重新进入时按对应顺序加载；旧阅读记录的原始分页位置保持兼容。

图片仍使用章节接口提供的URL，不另行替换缩略图或压缩文件。普通阅读按屏幕像素限制内存解码尺寸；双击大图查看器不设置该解码尺寸限制。服务端图片本身是否经过压缩，客户端不能据此保证。

自动回归覆盖倒序的大页请求、未知/过期总数回补、切换排序与在途请求、横屏左右阅读、奇数页、跨话、前插与裁剪、转屏与窄窗口、进度条第二页定位。实际M5设备的阅读体验仍需真机确认。

标准macOS构建环境使用`macos-15-intel`（原环境排队过久时切换）。构建机CPU与应用目标架构不同，Xcode仍交叉编译iPad真机ARM64，并在打包后校验。参考[GitHub标准运行器](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)及[镜像Xcode清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。

## 1.7.4 合并与 iPad 检查

保留上游专注模式、全局文字缩放、历史切换和减少动画设置。新组织的轻小说设置仅在 Android 显示音量键翻页开关。通用弹层同时支持专注模式淡出预览和窗口变化后重新计算高度；漫画阅读设置的独立弹层也改为按当前窗口限制高度和宽度，避免横屏后仍使用旧尺寸。网络、分享锚点、iOS 返回手势、四方向和 iPad 真机架构配置继续保留。

依赖源随上游统一到 pub.dev，使用锁文件安装；Flutter 版本仍为 3.44.2。本次仅构建 iPad，不引入 AI 图片增强。
