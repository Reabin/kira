# 发布流程

用户说「按 `docs/release.md` 发布」时，照此执行。

## 步骤

### 1. 问版本号

问用户本次版本号（如 `v1.7.4`、`v1.7.4-beta`），不要自己推断。
先 `git tag --sort=-v:refname | head` 看上一个 tag 供参考，并校验：

- 格式须为 `^v\d+\.\d+\.\d+(-[\w.]+)?$`
- 本地已有该 tag → 问用户是重发还是新版本
- 远端已有该 tag → 已发布，停止并报告

### 2. 改版本号

`pubspec.yaml` 的 `version:` 改成 `<X.Y.Z>+<原值>`；`+NNN` 由 pre-commit hook 重算，不必精确。

### 3. 写 CHANGELOG

基线用上一个同类型 tag（beta 取上个 beta，正式版取上个正式版），收集提交：

```bash
git log --pretty=format:%s <baseline>..HEAD
```

整体覆盖 `docs/CHANGELOG.md`（只写本次发布，不追加历史），格式：

```markdown
- 🐛 fix: 中文简述
- ✨ feat: 中文简述

> [!TIP]
>
> 1. 升级注意事项
```

- 面向用户，删掉 CI / 重构 / release commit / 版本号提交
- 顺序按 `fix` → `feat` → `style`，与 `git show v1.7.3:docs/CHANGELOG.md` 一致
- TIP 块按需，没有就省

写完打开 `docs/CHANGELOG.md` 给用户审查，**等用户明确确认**再继续。

### 4. 提交并打 tag

```bash
git add pubspec.yaml docs/CHANGELOG.md
git commit -m "chore: release vX.Y.Z"
git tag -a vX.Y.Z -m "Release vX.Y.Z"
```

hook 改写 `+NNN` 属预期，接受即可。

### 5. 推送

```bash
git rev-parse HEAD origin/main   # 确认本地未落后；不要用 ls-remote，会挂起
git status --short               # 应为空
git push --atomic origin main vX.Y.Z
```

失败时读原文再判断（多半是网络/代理），不要 `--force`，不要无脑重试。
远端已有该 tag = 已发布，停止。

### 6. 收尾

报告版本号、tag、`https://github.com/<repo>/actions`。`release.yml` 会自动构建并直接创建
GitHub Release（无 draft 阶段），正文取 `docs/CHANGELOG.md`。

## 中断恢复

按 tag 状态续做，不要从头重跑：

| 状态 | 继续 |
| --- | --- |
| 未 commit | 第 4 步 |
| 已 commit 未打 tag | 第 4 步 |
| 已打 tag 未 push | 第 5 步 |
| 已 push | 已结束 |

未推送前发现错误可用 `git commit --amend` 修正后重打 tag；**已推送不得改写历史**。
