import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

import '../api/novel/novel_api.dart' show NovelApiException;
import '../l10n/app_localizations.dart';
import '../models/novel.dart';
import '../models/user_manager.dart';
import '../pages/chapter_comments_sheet.dart'
    show CommentFontScaler, CommentSettingsPanel, buildCommentBodyStyle;
import '../providers/app_providers.dart';
import '../providers/novel_providers.dart';
import '../providers/settings_providers.dart';
import '../routing/app_router.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../theme/app_spacing.dart';
import '../utils/app_logger.dart';
import '../utils/comment_text.dart';
import '../utils/time_format.dart';
import '../utils/toast.dart';
import 'account_avatar.dart';
import 'comment_skeleton.dart';
import 'error_retry_view.dart';
import 'load_more_footer.dart';
import 'novel_paged_controller.dart';
import 'novel_widgets.dart';
import 'text_controller_scope.dart';

/// One inline-expandable reply section's state, mirroring the comic sheet.
@immutable
class _NovelReplyState {
  final bool expanded;
  final bool loading;
  final bool loadingMore;
  final Object? error;
  final List<NovelComment> replies;
  final int? total;

  const _NovelReplyState({
    this.expanded = false,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.replies = const [],
    this.total,
  });

  _NovelReplyState copyWith({
    bool? expanded,
    bool? loading,
    bool? loadingMore,
    Object? error,
    List<NovelComment>? replies,
    int? total,
  }) => _NovelReplyState(
    expanded: expanded ?? this.expanded,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: error,
    replies: replies ?? this.replies,
    total: total ?? this.total,
  );
}

/// Book comments and replies use the same documented endpoint, always with
/// the book UUID (not path_word). No request is made until this sheet opens.
///
/// Layout and interactions follow the comic comment sheet: inline expandable
/// replies (no second sheet), floating 评论/回到顶部/关闭 buttons that hide on
/// scroll down, tap-to-reply on cards and replies.
class NovelCommentsSheet extends ConsumerStatefulWidget {
  const NovelCommentsSheet({
    super.key,
    required this.bookUuid,
    this.replyId,
    this.allowPosting = true,
  });

  final String bookUuid;
  final String? replyId;
  final bool allowPosting;

  @override
  ConsumerState<NovelCommentsSheet> createState() => _NovelCommentsSheetState();
}

class _NovelCommentsSheetState extends ConsumerState<NovelCommentsSheet> {
  static const _replyPageSize = 3;
  static const _listBottomPadding = 80.0;

  late final UserManager _user = ref.read(userManagerProvider);
  late final _settings = ref.read(commentSettingsProvider);
  final ScrollController _scroll = ScrollController();
  late final NovelPagedController<NovelComment> _comments;
  final Map<String, _NovelReplyState> _replyStates = {};
  final Map<String, int> _replyRequests = {};
  final ValueNotifier<bool> _showFloatingButtons = ValueNotifier(true);
  DialogRoute<void>? _postDialog;
  String? _token;
  int _accountGeneration = 0;
  bool _posting = false;
  double _lastScrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _token = _user.copyToken;
    _comments = NovelPagedController<NovelComment>(
      loadPage: (offset) => ref
          .read(novelApiProvider)
          .getComments(
            bookUuid: widget.bookUuid,
            replyId: widget.replyId,
            offset: offset,
          ),
      keyOf: (comment) => comment.id,
    )..addListener(_rebuild);
    _user.addListener(_onAccountChanged);
    _settings.addListener(_rebuild);
    _scroll.addListener(_handleScrollDirection);
    unawaited(_comments.refresh());
  }

  void _rebuild() {
    if (!mounted) return;
    setState(() {});
    // 首屏未填满、展开回复或分页完成后，列表可能已经接近底部；
    // 与漫画评论区一致，自动继续加载，不让用户点击「加载更多」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryLoadMoreWhenNearBottom();
    });
  }

  void _tryLoadMoreWhenNearBottom() {
    if (!_comments.hasMore ||
        _comments.loading ||
        _comments.error != null ||
        _comments.items.isEmpty ||
        !_scroll.hasClients) {
      return;
    }
    if (_scroll.position.extentAfter <= 240) {
      unawaited(_comments.loadMore());
    }
  }

  bool _onListScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0) _tryLoadMoreWhenNearBottom();
    return false;
  }

  void _onAccountChanged() {
    if (!mounted || _token == _user.copyToken) return;
    _token = _user.copyToken;
    ++_accountGeneration;
    _posting = false;
    final dialog = _postDialog;
    _postDialog = null;
    if (dialog != null && dialog.isActive) {
      dialog.navigator?.removeRoute(dialog);
    }
    _replyStates.clear();
    _replyRequests.clear();
    _comments.clear();
    unawaited(_comments.loadMore());
  }

  @override
  void dispose() {
    _user.removeListener(_onAccountChanged);
    _settings.removeListener(_rebuild);
    _scroll.removeListener(_handleScrollDirection);
    _scroll.dispose();
    _showFloatingButtons.dispose();
    _comments.dispose();
    super.dispose();
  }

  // ── Scrolling: floating buttons show/hide like the comic sheet ──────────

  static const _directionDeadZone = 2.0;

  void _handleScrollDirection() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final offset = position.pixels;
    // 抵达底部时始终恢复显示，否则滑到底后按钮无法再出现。
    if (offset >= position.maxScrollExtent && !_showFloatingButtons.value) {
      _showFloatingButtons.value = true;
    } else if (offset > _lastScrollOffset + _directionDeadZone &&
        _showFloatingButtons.value) {
      _showFloatingButtons.value = false;
    } else if (offset < _lastScrollOffset - _directionDeadZone &&
        !_showFloatingButtons.value) {
      _showFloatingButtons.value = true;
    }
    _lastScrollOffset = offset;
  }

  void _scrollToTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ── Posting ────────────────────────────────────────────────────────────

  Future<void> _login() async {
    await context.pushNamed(
      AppRoutes.login,
      queryParameters: {'copyOnly': 'true'},
    );
    if (mounted && _user.isCopyLoggedIn) await _comments.refresh();
  }

  Future<bool> _post(String content, {String? replyId}) async {
    if (_posting || !CommentText.isValid(content) || !widget.allowPosting) {
      return false;
    }
    if (!_user.isCopyLoggedIn) {
      await _login();
      return false;
    }
    final generation = _accountGeneration;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _posting = true);
    try {
      await ref
          .read(novelApiProvider)
          .postComment(
            bookUuid: widget.bookUuid,
            content: content,
            replyId: replyId,
          );
      if (!mounted || generation != _accountGeneration) return false;
      showToast(context, l10n.novelCommentPosted);
      if (replyId != null) {
        // 回复可能指向楼中楼，不一定是顶层评论；刷新它所属的根评论，
        // 让新回复仍出现在同一 inline 回复区。
        final rootId = _rootCommentIdForReply(replyId);
        final target = _comments.items
            .where((comment) => comment.id == rootId)
            .firstOrNull;
        if (target != null) {
          final current = _replyStateOf(rootId);
          setState(() {
            _replyStates[rootId] = current.copyWith(
              expanded: true,
              total: _replyCount(target, current) + 1,
            );
          });
          unawaited(_loadReplies(target, forceRefresh: true));
        } else {
          unawaited(_comments.refresh());
        }
      } else {
        unawaited(_comments.refresh());
      }
      return true;
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'novel_comments.post',
        ),
      );
      if (mounted && generation == _accountGeneration) {
        showToast(context, l10n.novelCommentFailed, isError: true);
      }
      return false;
    } finally {
      if (mounted && generation == _accountGeneration) {
        setState(() => _posting = false);
      }
    }
  }

  String _rootCommentIdForReply(String replyId) {
    for (final entry in _replyStates.entries) {
      if (entry.value.replies.any((reply) => reply.id == replyId)) {
        return entry.key;
      }
    }
    // A top-level comment's own id is already the root id.
    return replyId;
  }

  /// 发表对话框：回复某条评论（点击卡片触发）或发表新评论（悬浮按钮触发）。
  /// 控制器由对话框自持，文本长度与漫画侧一致（1–200）。
  Future<void> _showPostDialog({NovelComment? replyTo}) async {
    final l10n = AppLocalizations.of(context)!;
    if (!_user.isCopyLoggedIn) {
      return _login();
    }
    if (!widget.allowPosting) {
      showToast(context, l10n.novelCommentsClosed, isError: true);
      return;
    }

    final generation = _accountGeneration;
    final isReply = replyTo != null;
    final title = isReply
        ? l10n.novelCommentReplyTitle(_displayName(replyTo))
        : l10n.novelPostComment;
    final hintText = isReply
        ? l10n.novelCommentReplyHint(_displayName(replyTo))
        : l10n.novelWriteComment;

    var submitting = false;
    String? errorText;

    Future<void> submit(
      BuildContext dialogContext,
      StateSetter setLocal,
      TextEditingController controller,
    ) async {
      if (!mounted || generation != _accountGeneration) return;
      final content = controller.text.trim();
      if (!CommentText.isValid(content)) {
        setLocal(() => errorText = l10n.chapterCommentsLengthRange);
        return;
      }
      setLocal(() {
        submitting = true;
        errorText = null;
      });
      final posted = await _post(content, replyId: isReply ? replyTo.id : null);
      if (!mounted || generation != _accountGeneration) return;
      if (posted && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      } else if (dialogContext.mounted) {
        setLocal(() => submitting = false);
      }
    }

    final dialog = DialogRoute<void>(
      context: context,
      builder: (dialogContext) => TextControllerScope(
        builder: (dialogContext, controller) => StatefulBuilder(
          builder: (dialogContext, setLocal) {
            final canSubmit =
                !submitting && CommentText.isValid(controller.text);
            return AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isReply) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            dialogContext,
                          ).colorScheme.surfaceContainerLow,
                          borderRadius: AppRadius.mdR,
                        ),
                        child: Text(
                          replyTo.comment,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    TextField(
                      controller: controller,
                      autofocus: true,
                      enabled: !submitting,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: CommentText.maxLength,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(CommentText.maxLength),
                      ],
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: hintText,
                        helperText: l10n.chapterCommentsLengthHelper,
                        errorText: errorText,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setLocal(() => errorText = null),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.cancelButton),
                ),
                FilledButton(
                  key: const ValueKey('novel-comment-submit'),
                  onPressed: canSubmit
                      ? () => submit(dialogContext, setLocal, controller)
                      : null,
                  child: submitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(isReply ? l10n.novelReply : l10n.novelPostComment),
                ),
              ],
            );
          },
        ),
      ),
    );
    _postDialog = dialog;
    try {
      await Navigator.of(context, rootNavigator: true).push(dialog);
    } finally {
      if (identical(_postDialog, dialog)) _postDialog = null;
    }
  }

  String _displayName(NovelComment comment) {
    final name = comment.userName.trim();
    return name.isEmpty
        ? AppLocalizations.of(context)!.commentSettingsAnonymousUser
        : name;
  }

  String _errorMessage(Object? error, String fallback) =>
      error is NovelApiException && error.isDiagnosticResponse
      ? error.message
      : fallback;

  // ── Inline replies (comic-sheet behavior) ──────────────────────────────

  _NovelReplyState _replyStateOf(String commentId) =>
      _replyStates[commentId] ?? const _NovelReplyState();

  int _replyCount(NovelComment comment, _NovelReplyState state) {
    final total = state.total ?? comment.count;
    return total < state.replies.length ? state.replies.length : total;
  }

  Future<void> _toggleReplies(NovelComment comment) async {
    final current = _replyStateOf(comment.id);
    if (current.expanded) {
      setState(() {
        _replyStates[comment.id] = current.copyWith(expanded: false);
      });
      return;
    }
    setState(() {
      _replyStates[comment.id] = current.copyWith(expanded: true);
    });
    if (current.replies.isEmpty && !current.loading) {
      await _loadReplies(comment);
    }
  }

  Future<void> _loadReplies(
    NovelComment comment, {
    bool loadMore = false,
    bool forceRefresh = false,
  }) async {
    final current = _replyStateOf(comment.id);
    if (loadMore) {
      if (current.loading || current.loadingMore) return;
      if (current.replies.length >= _replyCount(comment, current)) return;
    } else if (current.loading && !forceRefresh) {
      return;
    }
    final generation = _accountGeneration;
    final request = (_replyRequests[comment.id] ?? 0) + 1;
    _replyRequests[comment.id] = request;
    bool isCurrent() =>
        mounted &&
        generation == _accountGeneration &&
        request == _replyRequests[comment.id];
    setState(() {
      _replyStates[comment.id] = current.copyWith(
        expanded: true,
        loading: !loadMore,
        loadingMore: loadMore,
      );
    });
    try {
      final page = await ref
          .read(novelApiProvider)
          .getComments(
            bookUuid: widget.bookUuid,
            replyId: comment.id,
            limit: _replyPageSize,
            offset: loadMore ? current.replies.length : 0,
          );
      if (!isCurrent()) return;
      final merged = loadMore
          ? [
              ...current.replies,
              ...page.list.where(
                (item) =>
                    !current.replies.any((existing) => existing.id == item.id),
              ),
            ]
          : [...page.list];
      // 回复按时间正序（从旧到新）。
      merged.sort((a, b) => a.createAt.compareTo(b.createAt));
      final latest = _replyStateOf(comment.id);
      setState(() {
        _replyStates[comment.id] = latest.copyWith(
          loading: false,
          loadingMore: false,
          replies: merged,
          total: page.total,
        );
      });
    } catch (e, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          e,
          stackTrace: stack,
          source: 'novel_comments.replies',
        ),
      );
      if (!isCurrent()) return;
      final latest = _replyStateOf(comment.id);
      setState(() {
        _replyStates[comment.id] = latest.copyWith(
          loading: false,
          loadingMore: false,
          error: e,
        );
      });
    }
  }

  // ── Settings ───────────────────────────────────────────────────────────

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width,
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: (_) => CommentSettingsPanel(
        isChapterComments: false,
        showFilteringSettings: false,
        useCompactLayout: false,
        showUserAvatar: _settings.showAvatar,
        showUserName: _settings.showUserName,
        showCommentTime: _settings.showTime,
        commentFontScale: _settings.fontScale,
        commentPreload: false,
        commentAutoLoadAll: false,
        onLayoutChanged: (_) {},
        onShowAvatarChanged: _settings.setShowAvatar,
        onShowUserNameChanged: _settings.setShowUserName,
        onShowCommentTimeChanged: _settings.setShowTime,
        onFontScaleChanged: _settings.setFontScale,
        onPreloadChanged: (_) {},
        onAutoLoadAllChanged: (_) {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.replyId == null
                            ? l10n.chapterCommentsComment
                            : l10n.novelReplyTitle,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.comicCommentSettingsTooltip,
                      onPressed: _showSettings,
                      icon: const Icon(Icons.tune),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: cs.outlineVariant),
              Expanded(
                child: CommentFontScaler(
                  scale: _settings.fontScale,
                  child: _buildList(context),
                ),
              ),
            ],
          ),
          _buildFloatingButtons(context),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return RefreshIndicator(
      onRefresh: _comments.refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onListScrollNotification,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (_comments.loading && _comments.items.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  _listBottomPadding,
                ),
                sliver: SliverList.separated(
                  itemCount: 6,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, _) => const CommentSkeleton(),
                ),
              )
            else if (_comments.error != null && _comments.items.isEmpty)
              SliverErrorRetryView(
                message: _errorMessage(
                  _comments.error,
                  l10n.novelCommentsFailed,
                ),
                onRetry: _comments.refresh,
              )
            else if (_comments.items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: NovelEmptyView(
                  message: l10n.novelNoComments,
                  icon: Icons.chat_bubble_outline,
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  _listBottomPadding,
                ),
                sliver: SliverList.separated(
                  itemCount: _comments.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _buildCommentCard(context, _comments.items[index]),
                ),
              ),
            if (_comments.items.isNotEmpty && _comments.hasMore)
              SliverToBoxAdapter(
                child: _comments.error != null
                    ? LoadMoreFooter(
                        loading: false,
                        onPressed: _comments.loadMore,
                        label: l10n.novelLoadMoreFailed,
                      )
                    : _comments.loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: ExpressiveLoadingIndicator()),
                      )
                    : const SizedBox(height: 32),
              ),
          ],
        ),
      ),
    );
  }

  /// 右下角悬浮按钮组，与漫画评论区一致：评论、回到顶部、关闭。
  /// 向下滚动隐藏，向上滚动或抵达底部时恢复。
  Widget _buildFloatingButtons(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final squareStyle = FilledButton.styleFrom(
      backgroundColor: cs.primaryContainer,
      foregroundColor: cs.onPrimaryContainer,
      elevation: 6,
      shadowColor: AppShadows.floatingTint(0.22),
      minimumSize: const Size.square(52),
      maximumSize: const Size.square(52),
      fixedSize: const Size.square(52),
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smR),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Positioned(
      right: 16,
      bottom: 16,
      child: ValueListenableBuilder<bool>(
        valueListenable: _showFloatingButtons,
        builder: (context, visible, child) => AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 1.2),
          curve: Curves.easeInOutCubic,
          duration: const Duration(milliseconds: 260),
          child: AnimatedOpacity(
            key: const ValueKey('novel-comment-floating-buttons-opacity'),
            opacity: visible ? 1.0 : 0.0,
            curve: Curves.easeInOutCubic,
            duration: const Duration(milliseconds: 260),
            child: child!,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FilledButton.icon(
                style: squareStyle.copyWith(
                  fixedSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
                  minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
                  maximumSize: const WidgetStatePropertyAll(
                    Size.fromHeight(52),
                  ),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
                onPressed: _posting || !widget.allowPosting
                    ? null
                    : () => _showPostDialog(),
                icon: const Icon(Icons.comment_outlined),
                label: Text(l10n.chapterCommentsComment),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 52,
                    child: FilledButton(
                      style: squareStyle,
                      onPressed: _scrollToTop,
                      child: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox.square(
                    dimension: 52,
                    child: FilledButton(
                      style: squareStyle,
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommentCard(BuildContext context, NovelComment comment) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final showTime = _settings.showTime && comment.createAt.isNotEmpty;
    final showHeader =
        _settings.showAvatar || _settings.showUserName || showTime;
    final replyState = _replyStateOf(comment.id);
    final canExpandReplies =
        _replyCount(comment, replyState) > 0 || replyState.expanded;
    final displayName = comment.userName.trim().isEmpty
        ? l10n.commentSettingsAnonymousUser
        : comment.userName;

    return Container(
      key: ValueKey('novel-comment-${comment.id}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: AppRadius.lgR,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.6),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 只让主评论内容响应“回复楼主”；回复子树不再被父级
          // GestureDetector 包住，避免点击楼中楼时错误地使用楼主 id。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showPostDialog(replyTo: comment),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showHeader) ...[
                  Row(
                    children: [
                      if (_settings.showAvatar) ...[
                        AccountAvatar(avatar: comment.userAvatar, radius: 14),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      Expanded(
                        child: _settings.showUserName
                            ? Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.labelMedium?.copyWith(
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.78,
                                  ),
                                  fontWeight: FontWeight.w500,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (showTime) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            TimeFormat.relativeOf(comment.createAt, l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.72,
                              ),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                SelectableText(
                  comment.comment,
                  onTap: () => _showPostDialog(replyTo: comment),
                  style: buildCommentBodyStyle(tt, compact: false),
                ),
              ],
            ),
          ),
          if (canExpandReplies) ...[
            const SizedBox(height: 10),
            _buildExpandControl(context, comment, replyState),
          ],
          if (canExpandReplies && replyState.expanded)
            _buildReplySection(context, comment, replyState),
        ],
      ),
    );
  }

  /// 展开/收起控制，样式与漫画评论区一致。
  Widget _buildExpandControl(
    BuildContext context,
    NovelComment comment,
    _NovelReplyState replyState,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final actionStyle = theme.textTheme.bodyMedium?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return InkWell(
      borderRadius: AppRadius.fullR,
      onTap: () => _toggleReplies(comment),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              replyState.expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Text(
              replyState.expanded
                  ? l10n.novelCommentCollapseReplies
                  : l10n.novelCommentExpandReplies(
                      _replyCount(comment, replyState),
                    ),
              style: actionStyle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplySection(
    BuildContext context,
    NovelComment comment,
    _NovelReplyState replyState,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final replies = replyState.replies;
    final totalReplies = _replyCount(comment, replyState);
    final skeletonCount = totalReplies.clamp(1, _replyPageSize);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (replyState.loading && replies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Column(
                children: [
                  for (var index = 0; index < skeletonCount; index++) ...[
                    if (index > 0) const SizedBox(height: AppSpacing.md),
                    const CommentReplySkeleton(),
                  ],
                ],
              ),
            ),
          if (replyState.error != null && replies.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _errorMessage(
                        replyState.error,
                        l10n.novelCommentReplyLoadFailed,
                      ),
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _loadReplies(comment),
                    child: Text(l10n.retryButton),
                  ),
                ],
              ),
            ),
          if (!replyState.loading &&
              replies.isEmpty &&
              replyState.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.novelCommentEmptyReplies,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          for (var i = 0; i < replies.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                children: [
                  _buildReplyItem(context, replies[i], comment),
                  if (i < replies.length - 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Divider(
                        height: 24,
                        thickness: 0.5,
                        color: cs.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
            ),
          if (replyState.error != null && replies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: replyState.loadingMore
                    ? null
                    : () => _loadReplies(comment, loadMore: true),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(l10n.novelCommentRetryLoadMoreReplies),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(0, 0),
                ),
              ),
            ),
          if (replyState.error == null &&
              replies.isNotEmpty &&
              replies.length < totalReplies)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: replyState.loadingMore
                    ? null
                    : () => _loadReplies(comment, loadMore: true),
                icon: replyState.loadingMore
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      )
                    : const Icon(Icons.expand_more_rounded, size: 18),
                label: Text(
                  l10n.novelCommentLoadMoreReplies(
                    replies.length,
                    totalReplies,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: cs.primary,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(0, 0),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReplyItem(
    BuildContext context,
    NovelComment reply,
    NovelComment parentComment,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    // 楼中楼回复目标：与漫画侧一致，回复楼主（OP）时不显示「→ 楼主」。
    final isReplyToOp = _isReplyToOp(reply, parentComment);
    final parentUserName = reply.parentUserName?.trim() ?? '';
    final showReplyTarget = !isReplyToOp && parentUserName.isNotEmpty;
    final showTime = _settings.showTime && reply.createAt.isNotEmpty;
    final displayName = reply.userName.trim().isEmpty
        ? l10n.commentSettingsAnonymousUser
        : reply.userName;
    final userStyle = tt.labelSmall?.copyWith(
      color: cs.onSurfaceVariant.withValues(alpha: 0.78),
      fontWeight: FontWeight.w500,
    );
    final replyTargetStyle = userStyle?.copyWith(
      color: cs.primary.withValues(alpha: 0.9),
      fontWeight: FontWeight.w600,
    );
    final timeStyle = tt.labelSmall?.copyWith(
      color: cs.onSurfaceVariant.withValues(alpha: 0.72),
      fontWeight: FontWeight.w400,
    );
    final bodyStyle = buildCommentBodyStyle(
      tt,
      compact: true,
    )?.copyWith(height: 1.45);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showPostDialog(replyTo: reply),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_settings.showAvatar) ...[
            AccountAvatar(avatar: reply.userAvatar, radius: 11),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: userStyle,
                            ),
                          ),
                          if (showReplyTarget) ...[
                            const SizedBox(width: AppSpacing.xs),
                            Icon(
                              Icons.arrow_right_alt_rounded,
                              size: 14,
                              color: cs.onSurfaceVariant.withValues(
                                alpha: 0.78,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Flexible(
                              child: Text(
                                parentUserName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: replyTargetStyle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (showTime) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        TimeFormat.relativeOf(reply.createAt, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: timeStyle,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(reply.comment, style: bodyStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isReplyToOp(NovelComment reply, NovelComment parentComment) {
    final replyParentUserId = reply.parentUserId?.trim() ?? '';
    final opUserId = parentComment.userId.trim();
    if (replyParentUserId.isNotEmpty && opUserId.isNotEmpty) {
      return replyParentUserId == opUserId;
    }
    final replyParentUserName = reply.parentUserName?.trim() ?? '';
    final opUserName = parentComment.userName.trim();
    if (replyParentUserName.isNotEmpty && opUserName.isNotEmpty) {
      return replyParentUserName == opUserName;
    }
    return false;
  }
}
