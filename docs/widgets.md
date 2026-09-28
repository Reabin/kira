# Reusable Widget Patterns

抽取或新建可复用组件时（组件放 `lib/widgets/`），先确认下表场景是否已有既定组件 —— 每类都有定式，不要手搓替代品。

- **Skeleton/Shimmer**: Use `ShimmerBox` + `ShimmerShell` for loading states. Prefer `ComicCoverSkeletonGrid` or `ComicRowSkeletonList` for list placeholders. `ShimmerBox` must sit inside a `ShimmerShell` to animate.
- **Error states**: Use `ErrorRetryView` (box) or `SliverErrorRetryView` (in CustomScrollView). Provide `onRetry` callback. Inline banner-style errors (retry-all + dismiss, e.g. download center) are a different pattern — keep those bespoke.
- **Bottom sheets**: Build new sheets with `showAppSheet` / `AppSheet` (`lib/widgets/app_sheet.dart`). Sheets that must own their frame use `AppSheet.borderRadius` + `AppSheet.backgroundColor(cs)` + `AppSheetHandle()` — never hand-roll a 36x4 handle or a raw `Radius.circular(20/24)`.
- **Section headers**: Use `SectionHeader` (`lib/widgets/section_header.dart`) for "icon + 标题 (+ 更多)" rows; pass `trailing`/`onTap` for collapsible variants.
- **Cover placeholders**: Use `CoverPlaceholder()` / `CoverPlaceholder.error()` for cover image placeholder/error boxes.
- **Generic list pages**: Use `LocalContentListPage` with the `LocalContentEntry` interface + per-domain adapters; the comic one lives in `lib/widgets/local_content_list_page.dart`, the novel one is `NovelLocalContentEntry` in `lib/pages/local_novels_page.dart` — follow that pattern rather than widening the widget.
- **Login expired**: Use `showLoginExpiredDialog(context, content: …)` from `lib/widgets/login_expired_dialog.dart` — pass the page-specific copy; do not hand-roll the AlertDialog.
