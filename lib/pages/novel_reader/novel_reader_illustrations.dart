import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/novel.dart';
import '../../theme/app_spacing.dart';
import '../../theme/reader_chrome.dart';
import '../../utils/app_logger.dart';
import '../../widgets/error_retry_view.dart';
import '../../widgets/pinch_zoomable.dart';

/// A continuous gallery over the contents sheet, deliberately independent of
/// reader navigation, text anchors and persisted reading progress.
class NovelReaderIllustrations extends StatefulWidget {
  NovelReaderIllustrations({
    super.key,
    required this.volumeName,
    required this.illustrations,
    required this.loadBytes,
  }) : assert(illustrations.isNotEmpty);

  final String volumeName;
  final List<NovelContentEntry> illustrations;

  /// The novel API's credential-free content client, not the manga image client.
  final Future<List<int>> Function(String url) loadBytes;

  @override
  State<NovelReaderIllustrations> createState() =>
      _NovelReaderIllustrationsState();
}

class _NovelReaderIllustrationsState extends State<NovelReaderIllustrations> {
  bool _zoomed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme.apply(
      bodyColor: ReaderChrome.onSurface,
      displayColor: ReaderChrome.onSurface,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          brightness: Brightness.dark,
          surface: ReaderChrome.surface,
          onSurface: ReaderChrome.onSurface,
          onSurfaceVariant: ReaderChrome.onSurfaceMuted,
        ),
        textTheme: textTheme,
      ),
      child: Dialog.fullscreen(
        backgroundColor: ReaderChrome.surface,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.volumeName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                          color: ReaderChrome.onSurfaceMuted,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('novel-illustrations-close'),
                      tooltip: l10n.closeButton,
                      color: ReaderChrome.onSurface,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                // Zoom the bounded viewport, not an unbounded list item. At
                // normal scale one-finger drags scroll the continuous images;
                // while zoomed they pan the viewport until it is reset.
                child: PinchZoomable(
                  onZoomChanged: (zoomed) => setState(() => _zoomed = zoomed),
                  child: ListView.builder(
                    key: const ValueKey('novel-illustrations-list'),
                    padding: EdgeInsets.zero,
                    physics: _zoomed
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    itemCount: widget.illustrations.length,
                    itemBuilder: (context, index) => _IllustrationImage(
                      key: ValueKey('novel-illustration-$index'),
                      entry: widget.illustrations[index],
                      loadBytes: widget.loadBytes,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IllustrationImage extends StatefulWidget {
  const _IllustrationImage({
    super.key,
    required this.entry,
    required this.loadBytes,
  });

  final NovelContentEntry entry;
  final Future<List<int>> Function(String url) loadBytes;

  @override
  State<_IllustrationImage> createState() => _IllustrationImageState();
}

class _IllustrationImageState extends State<_IllustrationImage> {
  late Future<Uint8List?> _image = _load();

  // Keep unloaded rows non-zero until decoding finishes, so a lazy list does
  // not request every illustration while their intrinsic sizes are unknown.
  static const _placeholder = AspectRatio(
    aspectRatio: 1,
    child: Center(
      child: CircularProgressIndicator(color: ReaderChrome.onSurface),
    ),
  );

  Future<Uint8List?> _load() async {
    try {
      final url = widget.entry.content;
      if (url == null || url.isEmpty) {
        throw const FormatException('Missing illustration URL');
      }
      return Uint8List.fromList(await widget.loadBytes(url));
    } catch (error, stack) {
      unawaited(
        AppLogger.instance.recordWarning(
          'Illustration load failed (${error.runtimeType})',
          stackTrace: stack,
          source: 'novel_reader.illustration',
        ),
      );
      return null;
    }
  }

  Widget _error(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.lg),
    child: ErrorRetryView(
      icon: Icons.broken_image_outlined,
      message: AppLocalizations.of(context)!.novelReaderImageFailed,
      onRetry: () {
        setState(() {
          _image = _load();
        });
      },
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return _placeholder;
      }
      final bytes = snapshot.data;
      if (snapshot.hasError || bytes == null) return _error(context);
      return Image.memory(
        bytes,
        width: double.infinity,
        fit: BoxFit.fitWidth,
        semanticLabel: widget.entry.name.isEmpty
            ? AppLocalizations.of(context)!.novelReaderIllustration
            : widget.entry.name,
        frameBuilder: (context, child, frame, synchronous) =>
            synchronous || frame != null ? child : _placeholder,
        errorBuilder: (context, error, stack) => _error(context),
      );
    },
  );
}
