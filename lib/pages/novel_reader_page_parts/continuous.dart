part of '../novel_reader_page.dart';

/// 滚动模式的连续阅读：卷末继续下滑，无缝追加下一卷。
///
/// 只保留「当前卷 + 下一卷」两卷正文。翻页模式、目录跳卷、工具栏上/下一卷
/// 仍是整卷替换（[_NovelReaderPageState._loadVolume]），不走这里。
extension _NovelReaderContinuousPart on _NovelReaderPageState {
  /// 与 [NovelReaderPage._adjacentVolume] 同一套判定，但以任意卷为起点：
  /// 优先卷自身的前后链接，回退到卷列表顺序。
  String? _adjacentVolumeOf(String volumeId, int direction) {
    final volume = _volumeDetails[volumeId]?.volume;
    final linked = direction < 0 ? volume?.prev : volume?.next;
    if (linked != null && linked.isNotEmpty && linked != volumeId) {
      return linked;
    }
    final index = _volumes.indexWhere((item) => item.id == volumeId);
    final next = index + direction;
    return index >= 0 && next >= 0 && next < _volumes.length
        ? _volumes[next].id
        : null;
  }

  /// 卷栈末尾之后的下一卷；栈为空时从当前卷算起。
  String? get _nextStackVolumeId => _adjacentVolumeOf(
    _stackVolumes.isEmpty ? _volumeId : _stackVolumes.last.volumeId,
    1,
  );

  /// 加载一卷正文供追加，同一卷的并发请求共享一次网络往返。
  Future<NovelVolumeContent> _stackContent(String volumeId) {
    final pending = _stackLoads[volumeId];
    if (pending != null) return pending;
    final loading = _source.loadContent(_pathWord, volumeId).then((
      NovelVolumeContent? content,
    ) {
      if (content == null) throw const _NoCachedVolume();
      if (content.detail.isLocked) throw NovelAccessException(content.detail);
      return content;
    });
    _stackLoads[volumeId] = loading;
    // 失败后允许下一次预取/追加重试，不能把失败 Future 永久缓存。
    // 这里同时消费掉错误，避免派生的 Future 变成未处理异常。
    unawaited(
      loading.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _stackLoads.remove(volumeId);
        },
      ),
    );
    return loading;
  }

  /// 进入卷末约两屏时预取下一卷，触发点到来时内容已就绪。
  void _prefetchNextVolume() {
    if (_paged || _loading || _disposed) return;
    final next = _nextStackVolumeId;
    if (next == null || _stackLoads.containsKey(next)) return;
    unawaited(
      _stackContent(next).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          // 预取失败不打扰读者：滚动到接缝时才显示错误与重试。
          _warn(error, stack, 'continuous.prefetch');
        },
      ),
    );
  }

  /// 卷末最后一行上移，距视口底部超过 10% 屏高：把下一卷正文接到当前卷之后。
  Future<void> _appendNextVolume({bool force = false}) async {
    if (_paged || _loading || _disposed || _appending) return;
    final next = _nextStackVolumeId;
    if (next == null) return;
    if (!force && _seamError != null) return;
    final session = _session;
    final request = _request;
    _refresh(() {
      _appending = true;
      _seamError = null;
      _seamUnavailable = false;
    });
    try {
      final content = await _stackContent(next);
      if (!_active(session) || request != _request) return;
      final volume = NovelReaderVolumeDocument(
        volumeId: next,
        volumeName: content.detail.volume.name,
        document: NovelReaderDocument(
          content.entries,
          ignoreBlankParagraphs: _settings.ignoreBlankParagraphs,
        ),
      );
      if (volume.document.itemCount == 0) {
        _refresh(() {
          _appending = false;
          _seamError = const _NoCachedVolume();
        });
        return;
      }
      final location = _viewerLocation ?? _location;
      _refresh(() {
        _appending = false;
        _stackContents[next] = content;
        _volumeDetails[next] = content.detail;
        _stackVolumes.add(volume);
        // 当前卷跟着正文走：工具栏、书签、目录与重试都以它为准。
        _volumeId = next;
        // 只保留当前卷 + 下一卷：追加第三卷时，读者已在第二卷里，回收第一卷。
        final recycled = _stackVolumes.length > 2;
        if (recycled) {
          final dropped = _stackVolumes.removeAt(0);
          _stackContents.remove(dropped.volumeId);
          _stackLoads.remove(dropped.volumeId);
        }
        _stack = NovelReaderStack(List.of(_stackVolumes));
        _document = _stack;
        ++_contentRevision;
        if (location != null) {
          // 回收改变了 item 下标：按当前位置重定位，视口不会跳。
          _target = _document!.anchorFor(
            _document!.itemFor(location.anchor),
            alignment: location.anchor.alignment,
          );
          if (recycled) ++_jumpRevision;
        }
      });
    } catch (error, stack) {
      _warn(error, stack, 'continuous.append');
      if (!_active(session) || request != _request) return;
      _refresh(() {
        _appending = false;
        _seamError = error;
        _seamUnavailable = error is NovelDownloadUnavailableException;
      });
    }
  }

  /// 接缝处的内联提示：只在加载失败 / 本地未下载时出现，正常加载保持
  /// 无缝（读者看到的是卷末最后一段与空白）。
  Widget? _buildSeam() {
    final error = _seamError;
    if (error == null || _paged) return null;
    final l10n = AppLocalizations.of(context)!;
    final palette = NovelReaderPalette.resolve(
      _settings,
      MediaQuery.platformBrightnessOf(context),
    );
    final message = _seamUnavailable
        ? l10n.novelDownloadUnavailable
        : novelErrorMessage(error, fallback: l10n.novelReaderLoadFailed);
    return Padding(
      key: const ValueKey('novel-reader-seam'),
      padding: const EdgeInsets.only(top: AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTypography.meta(
              Theme.of(context).textTheme,
            )?.copyWith(color: palette.foreground.withValues(alpha: 0.7)),
          ),
          if (!_seamUnavailable)
            TextButton(
              key: const ValueKey('novel-reader-seam-retry'),
              onPressed: _appending
                  ? null
                  : () => unawaited(_appendNextVolume(force: true)),
              child: Text(l10n.retryButton),
            ),
        ],
      ),
    );
  }
}
