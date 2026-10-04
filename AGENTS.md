# Repository Guidelines

## Project Structure & Module Organization

Platform folders (`android/`, `ios/`, `linux/`, `macos/`, `web/`, `windows/`) hold only platform-specific integration code. Static assets live in `assets/` and must be declared in `pubspec.yaml`. `ref/`（gitignored）存放接口文档，仅作参考 —— never import from it, and never cite anything under `ref/` as current behaviour.

### `lib/` 一级目录速览

| 目录 | 职责 |
| ------ | ---------- |
| `api/` | `ApiTransport` + 领域 API（`manga/` `network/` `novel/` `user/` 子目录）、`ai_api.dart`、`hitokoto_api.dart`（一言）、`copy_settings_auto_updater.dart`，`api_client.dart` 为 facade |
| `models/` | 数据模型 `fromJson`/`toJson`（基类 `cached_repository.dart` 与 `secure_credential_store.dart` 也在此） |
| `repositories/` | 各领域 `CachedRepository` 子类（manga home + copy home、comic detail、bookshelf、search init、小说正文缓存）与小说数据源 `novel_reader_source.dart` —— 实现 `models/cached_repository.dart` 基类 |
| `providers/` | Riverpod providers：`app_providers`（单例）、`settings_providers`（子 store）、`repository_providers`（数据仓库）、`novel_providers`（小说）、`backup_providers`（备份） |
| `pages/` | 页面与路由目标（最大目录：41 个顶层文件 + 15 个子目录，共 126 文件） |
| `routing/` | `app_router.dart`（GoRouter 声明 + `AppRoutes` + `*Extra` 传参类）、`MainShell`（底部导航）、`dismiss_keyboard_observer.dart` |
| `theme/` | 设计令牌：spacing/radius/shadows/typography/icon-size/status-colors + `player_chrome`/`reader_chrome`/`novel_reader_theme` |
| `widgets/` | 复用组件（骨架、错误态、登录过期、列表页等）—— 模式见 `docs/widgets.md` |
| `backup/` | 备份子系统：本地/WebDAV、加解密编解码、分类筛选、定时调度与日志（`backup_scheduler.dart`、`webdav_client.dart`） |
| `utils/` | JSON 安全助手、`AppLogger`、`Services`（服务定位器）、下载/小说下载管理、阅读历史与统计、应用更新等 |
| `l10n/` | ARB 模板与生成的 `app_localizations*.dart`（`app_zh.arb` 为模板，`app_zh_Hant.arb` 为繁体镜像） |

大文件按 `*_parts/` 拆分：宿主文件写 `part 'xxx_parts/yyy.dart';`，分片以 `part of '../host.dart';` + `extension HostXxxPart on Host` 挂载。现有 4 处：`user_manager_parts/`、`download_manager_parts/`、`ai_api_parts/`、`routing/main_shell_parts/`。

## Maintenance Scope

Anime was removed outright (`569f482`), not merely frozen — treat it as absent, not as deprecated code to keep compiling. Two live product areas: **漫画（拷贝 + 热辣）** 与 **轻小说**. Both are active; 轻小说 design details live in `docs/novel.md`. `ref/` 已被 gitignore 排除，只存放接口文档 — never import from it.

## Architecture Patterns

### State Management: Riverpod (incremental)
- **New pages**: Use `ConsumerStatefulWidget` + `ref.read(provider)` for dependencies.
- **Existing pages**: Still use singleton access (`UserManager()`, `ApiClient()`) — both patterns coexist widely; `lib/utils/services.dart` (`Services.api`, `Services.override<T>()` for tests) is the intended middle ground but is barely adopted yet.
- **Providers live in `lib/providers/`**: `app_providers.dart` (singletons), `settings_providers.dart` (sub-stores), `repository_providers.dart` (data repos).

### Navigation: GoRouter
- All routes defined declaratively in `lib/routing/app_router.dart` with `AppRoutes` name constants.
- Use `context.pushNamed(AppRoutes.xxx)` instead of `Navigator.push(MaterialPageRoute(...))`.
- For routes that need extra data, use `extra` parameter with typed classes (`ComicDetailExtra`, `ReaderExtra`, `NovelReaderExtra`, `RankingExtra`).
- Bottom-nav shell uses `ShellRoute` via `MainShell`. The horizontal swipe between branches and the GNav capsule bar are product features — do not remove them in a refactor.
- `dismiss_keyboard_observer.dart` suppresses the keyboard reappearing when returning to the home/search branch; `test/routing/main_shell_focus_test.dart` locks that behaviour down.

### API Layer: Transport + Domain Classes
- Call sites: `ApiClient().manga.getMangaHome()` not `ApiClient().getMangaHome()`.
- AI 相关调用走 `AiApi`（`lib/api/ai_api.dart`），它**不**挂在 `ApiClient` 上，用独立的 `AppDio` 与 `AiSettings`；评论摘要、章节分析都从这里出。
- 分层背景（`ApiTransport` / 领域 API 类 / `ApiClient` facade、测试替身）见 `docs/architecture.md`。

### Data Layer: CachedRepository
- Call `repo.load()` for auto-cache-first, `repo.loadFromCache()` for cache-only, `repo.invalidateCache()` to refresh. Concurrent `load()` calls share one in-flight future, so callers never stampede the API.
- Cache I/O goes through `AppStorage.cache` / `AppStorage.preferences` (`lib/utils/app_storage.dart`), which is what keeps tests away from real SharedPreferences.
- 新建/改造 repository 前读 `docs/architecture.md`：仓库需定义的成员、四种缓存策略（parallel / sequential / TTL-gate / API-transparent）与 `DualCachedRepository` 的唯一用例。

### Model Serialization
- 大多数模型手写 `fromJson`/`toJson`，只有 3 个 `json_serializable` 生成类；改完生成类跑 `dart run build_runner build`。
- 动某个模型前先查 `docs/architecture.md` 的序列化一节：哪些类走生成、哪些手写、为什么 `comic.dart` 两种风格混用。

### Internationalization
- `l10n.yaml` at project root configures `gen-l10n`. Template ARB is `app_zh.arb`; `app_zh_Hant.arb` holds the Traditional Chinese mirror (简繁双语).
- Access strings via `AppLocalizations.of(context)!.keyName`.
- Parameterized strings become methods: `l10n.deleteLocalComicsContent(count)` returns `String`.

### UserManager: Facade + Sub-stores
- `UserManager` 是 facade，内部委托给同为单例的子 store（`ReaderSettings`、`CommentSettings`、`ThemeSettings`、`NetworkSettings`、`CopyAccountStore`，`Services.reader` == `UserManager().reader`）；子 store 变更经 facade 单次 `notifyListeners()` 转发 —— 只关心单一域就监听子 store 本身。
- **改动双写 key（`UserManager` 与子 store 各存一份的偏好，如 `api_route`、`reader_mode`、`theme_mode`、`logo_index`，全量清单见 `docs/architecture.md`）时，走子 store 并删掉 `UserManager` 侧副本** —— `readerMode` 是完工范式；`ThemeSettings.setBannerVisible` 与 `CommentSettings.setPreload` / `setCompactLayout` 是尚无人调用的子 store setter，把 UI 指过去并删副本。

## Build, Test, and Development Commands

Run these from the repository root:

- `flutter pub get` — install dependencies
- `flutter run` — launch on current device/emulator
- `flutter analyze` — run lint rules from `analysis_options.yaml` (64 strict rules on top of `flutter_lints`); currently clean
- `flutter test` — run automated tests under `test/` (1172 cases, ~80 s; `--reporter compact` keeps the output manageable)
- `flutter build apk --release --target-platform android-arm64` — Android release artifact
- `dart format lib test` — format source files before review (not enforced repo-wide, see Testing)
- `dart run build_runner build` — regenerate `.g.dart` files after model changes
- `flutter gen-l10n` — regenerate localization files after ARB changes
- `run-kira` — skill to start / stop / hot-restart / hot-reload the running kira app. Hot-reload is auto-triggered by a PostToolUse(Edit|Write) hook after code edits; reach for the skill explicitly for cold starts, hot-restarts, or stops.

### Other Entry Points
- `scripts/`: PowerShell helpers — `run.ps1 <win|mumu|emu>` (device boot + `KIRA_DEVICE`), `build_apk.ps1`, `build_windows.ps1`, `release.ps1` (invokes the CHANGELOG generator), `count_lib_dart_lines.ps1`.
- `docs/`: `persistence-and-cache.md`（动存储前必读）、`novel.md`（轻小说设计）、`architecture.md`（API 分层 / 缓存仓库解剖 / 序列化清单 / UserManager 双写现状）、`platform-build.md`（Windows / Android 构建排查）、`widgets.md`（复用组件模式）、`TODO.md`、`CHANGELOG.md`.
- `.github/workflows/`: `build-ci.yml` (manual Android APK), `release.yml` (`v*` tag → full release), `release-all.yaml` / `release-all-beta.yml` (manual, all platforms).

### Platform Build Notes (on-demand)

Windows / Android 构建问题按报错先读 `docs/platform-build.md`，不要直接改构建配置：

- **Windows**：`C4819` / `STL1011` / `C1083`（ephemeral 缺文件）/ `C1041`（PDB 锁）、要动 `windows/CMakeLists.txt`、想加媒体/视频依赖 —— 各报错的处理办法在文档里；删 `/utf-8` 是看似顺手、实会让中文区域系统构建失败的"修复"。
- **Android**：`flutter clean` 后 `flutter run` 报 `package identifier or launch activity not found` —— 先跑一次 `flutter build apk --debug` 即恢复；**不要**给 `MainActivity` 加 LAUNCHER intent-filter、也不要禁用它（会破坏切换 logo 功能），原因见文档。

### Platform Scope
Android is the only **released** target (`build_apk.ps1` + `.github/workflows/release*.yml` publish an arm64 APK). Windows is the **development/debug host** (`run-kira` runs `flutter run -d windows`); macOS/Linux are built by `release-all.yaml` / `release-all-beta.yml` but are not maintained by hand. The app never had a `platforms:` key in `pubspec.yaml` — do not claim one, and do not add platform-only native dependencies for the debug host.

## Coding Style & Naming Conventions

- 2-space indentation, trailing commas where they improve widget diffs, small focused widgets.
- `PascalCase` for classes/widgets, `camelCase` for members/methods, `snake_case.dart` for filenames, leading `_` for private APIs.
- **Never** use `as` type casts on dynamic JSON — use the safe JSON helpers (`jsonString`, `jsonInt`, `jsonList`, `jsonMap`, `jsonDouble`, `jsonBool`, `NullIfEmptyString`) from `lib/utils/`.
- **Never** leave empty catch blocks — use `AppLogger.recordWarning(error, stackTrace)`.
- **Never** use `@ts-ignore`-equivalent suppression; fix the type error instead.
- Prefer `const` constructors where possible.
- Import `comic.dart` with `hide Theme` to avoid Flutter `Theme` conflict.
 - **Prefer design tokens over hard-coded values**: use `AppSpacing` (4/8/12/16/20/24), `AppRadius` (xs~xl/full + `*R` getters), `AppIconSize` (xs 12 / sm 16 / md 18 / lg 20 / xl 24 / placeholder 32 / empty 48 / display 64), and the `ReaderChrome` color tokens. Only fall back to literals for genuinely ad-hoc values that carry component-specific meaning (e.g. a one-off 10px padding). `PlayerChrome` is a leftover class with no call sites (the video player went away with anime) — `ReaderChrome` is the live one.
 - **Text styles**: derive from `Theme.of(context).textTheme`; use `AppTypography.meta(tt)` for the small grey meta line (12px) and `AppTypography.fabLabel(tt)` for FAB labels instead of hand-writing `TextStyle(fontSize: …)`. Do not add page-local TextTheme copies.
 - **Component radius ladder**: 卡片 lg(16) / 对话框与弹层 xl(20) — enforced by `cardTheme`/`dialogTheme`/`bottomSheetTheme` in `main.dart`; don't override shapes per page.
 - **Semantic colors**: status colors go through `AppStatusColors` (`success/warning/danger/neutral/fill`, plus `hotAccent` for the comment hot-badge orange); never hand-code `Colors.green/orange/red` or raw `Color(0x…)` for these roles.

## Reusable Widget Patterns (on-demand)

新建或抽取可复用组件（放 `lib/widgets/`）前先读 `docs/widgets.md`。骨架屏 / 错误重试 / bottom sheet / section header / 封面占位 / 本地内容列表页 / 登录过期弹窗都有既定组件：`ShimmerShell` + `ShimmerBox`、`ErrorRetryView` / `SliverErrorRetryView`、`showAppSheet` / `AppSheet`、`SectionHeader`、`CoverPlaceholder`、`LocalContentListPage` + `LocalContentEntry`、`showLoginExpiredDialog` —— 用既定组件，不要手搓替代品。

## Testing Guidelines

- Use `flutter_test` for unit and widget coverage. Files: `*_test.dart`. Mirroring source paths is the rule for `lib/pages/**` (which has subdirectories); everything else (novel, copy-account, backup) sits flat at `test/` root. 119 files, ~1170 cases, full run ≈ 80 s.
- `test/test_helpers.dart` is mandatory for widget tests: `wrapWithApp(child)` injects the `AppLocalizations` delegate — a bare `MaterialApp` makes `AppLocalizations.of(context)!` throw. Call `setupSecureCredentialStoreForTest()` in `setUp` and `teardownSecureCredentialStoreForTest()` in `tearDown` to isolate account state. Persistence regressions must additionally exercise the default prefs-backed store across recreated instances.
- For `CachedRepository` subclasses: override `loadFromCache`/`saveToCache` with in-memory maps to avoid SharedPreferences in tests.
- New features and bug fixes should include tests when the behavior can be exercised outside platform-only code.
- **不要擅自跑全量测试**：默认只跑与改动相关的测试文件（`flutter test test/xxx_test.dart …`）；全量 `flutter test` 耗时且输出量大，仅在用户明确要求时执行。
- Baseline commands: `flutter analyze` (clean) and `flutter test` both pass on `main`; `dart format lib test` is not enforced repo-wide, so unrelated files may already differ — format the files you touched only.

## Commit & Pull Request Guidelines

Emoji-prefixed Conventional Commit types with concise Chinese summaries:
- `✨ feat: 添加检查更新功能`
- `🐛 fix: 登录过期后提醒用户登录`

don't update `docs/CHANGELOG.md`

## Security

- Do not commit signing material (`android/key.properties`, keystores).
- Credentials use `SecureCredentialStore`, backed by app-private SharedPreferences. The historical class name and `secure_mirror_*` prefix are compatibility names, not encryption guarantees; runtime Keystore/Keychain and `flutter_secure_storage` are no longer used.
- Availability is the chosen trade-off: an upgrade may require one login when old credentials exist only in the encrypted store, but subsequent cold starts must retain the newly saved session. Preserve legacy plaintext migration, logout markers, write-failure handling, backup encryption, and credential exclusions from ordinary backups/cache cleanup. See `docs/persistence-and-cache.md` before changing this path.
- Use `InMemorySecureCredentialStore` for isolated tests and the default prefs-backed store for persistence regressions.

## Persistence & Cache (on-demand)

涉及持久化存储/缓存改动时（新增用户偏好、业务缓存、敏感凭据、阅读历史等），先读 `docs/persistence-and-cache.md`：三层存储后端（`AppStorage.memory/cache/preferences`）、键名前缀约定、`CachedRepository` 用法与决策流程都在其中。
