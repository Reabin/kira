# Architecture Deep-Dive

`AGENTS.md` 保留日常规则与约定；本文收录按需查阅的架构细节：API 分层结构、CachedRepository 解剖、模型序列化清单、UserManager 双写 key 现状、拷贝接口登录的密钥注入。

## 拷贝登录：两条通道与签名密钥

拷贝账号有两条登录通道，由 `CopyLoginChannel` 区分，登录页在密钥可用时展示切换器：

| 通道 | 打哪里 | 请求头 |
| --- | --- | --- |
| `web`（默认） | `copyLoginHost` 官网页面，WebView 自动填表 → 抓 cookie token | 浏览器头 |
| `app` | `copyApiHost` + `/api/v3/login` | `CopyAppHeaders`（15 项业务头 + 签名） |

**签名密钥**（`CopySignature.authKey`）= 拷贝官方 APK 签名证书 DER 的 MD5 hex。它不入库，取值顺序：测试注入（`debugKeyOverride`）→ 编译期 `--dart-define=COPY_AUTH_KEY=…` → 桌面运行时的同名环境变量。Android/iOS 没有运行时环境变量，只能走编译期注入。

未配置时 `CopySignature.isConfigured` 为 false，登录页不展示接口通道——签名无效时服务端**不报错**，只返回 `code 200` + 空数据，任其展示会变成「密码正确却登不上」。

注入方式：

```powershell
# 桌面调试：run.ps1 会把环境变量传给 flutter run 启动的进程
$env:COPY_AUTH_KEY = "<官方证书 MD5>"
.\scripts\run.ps1 win

# 打包 / Android：脚本读同名环境变量并转成 --dart-define
$env:COPY_AUTH_KEY = "<官方证书 MD5>"
.\scripts\build_apk.ps1
```

CI 从 `secrets.COPY_AUTH_KEY` 注入（四个 workflow 均已接好）。

**设备指纹**（`CopyAppHeaders`）：`device` / `deviceinfo` 首次生成后持久化到 `AppStorage.preferences` 的 `copy_device_id` / `copy_device_info`，跨会话保持稳定；`pseudoid` 是进程内随机一次。三者跳变会被服务端当作新设备。

## API Layer: Transport + Domain Classes

- `ApiTransport` holds shared Dio instance, auth tokens, cache headers, host rotation logic.
- Domain API classes (`MangaApi`, `NovelApi`, `NetworkApi`, `UserApi`) receive `ApiTransport` via constructor injection.
- `ApiClient` is a facade that creates the transport and exposes domain API objects as `.manga/.novel/.network/.user` fields; `ApiClient.setTestInstance()` swaps the singleton for tests. `ApiClient()` is always the same instance — calling it in a hot path is fine, but it does perform `UserManager()` + `DataCache()` lookups.

## Data Layer: CachedRepository 解剖

- `CachedRepository<T>` in `lib/models/cached_repository.dart` (the only `DualCachedRepository<A,B>` user is `MangaHomeRepository`, holding manga + copy-manga homes).
- Each repository defines: `cacheKey`, `ttl`, `skipApiIfCacheFresh`, `deserialize`/`serialize`, `fetchFromApi()`.
- Strategies: parallel (default), sequential, TTL-gate (`skipApiIfCacheFresh`) and API-transparent — configured via constructor params.

## Model Serialization

- **Generated models**: `Author`, `MangaTopic`, `Theme`, `ComicGroup` (in `comic.dart`), `ComicComment`, `ChapterComment` use `json_serializable` with `@JsonSerializable(fieldRename: FieldRename.snake)`. Run `dart run build_runner build` after changes. Only three `.g.dart` files exist — most models are not generated.
- **Hand-written models** (Comic, MangaHome, CopyMangaHome, MangaBanner, BookshelfItem, Chapter, novel models, etc.): hand-written `fromJson`/`toJson` — too many custom coercions for generated code. `comic.dart` deliberately mixes both styles; check per class before assuming a generator change is needed.

## UserManager: Facade + Sub-stores 双写现状

- `UserManager` is a singleton facade. Internally delegates to `ReaderSettings`, `CommentSettings`, `ThemeSettings`, `NetworkSettings` and `CopyAccountStore` — all singletons too, so `Services.reader` and `UserManager().reader` are the same object.
- Sub-stores are independent `ChangeNotifier`s. Sub-store changes are forwarded through the facade's single `notifyListeners()`, so a listener on `UserManager` rebuilds on *any* settings change, not just the domain it cares about. Listen to the sub-store directly when that matters.
- **The split is still partial and currently live**: **33 preference keys are declared in both** `UserManager` and a sub-store (e.g. `api_route`, `banner_visible`, `comment_preload`, `reader_dimming`, `reader_mode`, `theme_mode`, `bottom_nav_show_labels`, `logo_index`), each side keeping its own in-memory copy and writing SharedPreferences directly — 124 write / 70 read calls in `user_manager*.dart` alone. Both sides read the same key at init, so a stale copy only shows up when the two paths write it; today the UI happens to drive each such key through only one path.
- **When touching one of these keys, route it through the sub-store and delete the `UserManager` copy** — see `readerMode` (`UserManager.readerMode` delegates straight to `reader.mode`) for the finished pattern. `ThemeSettings.setBannerVisible` and `CommentSettings.setPreload` / `setCompactLayout` are sub-store setters nothing calls yet: point the UI at them and drop the `UserManager` copies.
