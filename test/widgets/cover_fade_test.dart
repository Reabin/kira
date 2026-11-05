import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/utils/adaptive_motion.dart';
import 'package:kira/widgets/comic_cover_card.dart';
import 'package:kira/widgets/cover_image.dart';
import 'package:kira/widgets/cover_placeholder.dart';
import 'package:kira/widgets/novel_widgets.dart';

import '../test_helpers.dart';

void main() {
  setUp(setupSecureCredentialStoreForTest);
  tearDown(teardownSecureCredentialStoreForTest);

  const imageUrl = 'https://images.invalid/cover.jpg';

  Future<void> pumpCover(
    WidgetTester tester,
    Widget cover, {
    required bool disableAnimations,
  }) async {
    final media = MediaQueryData(
      size: const Size(800, 600),
      disableAnimations: disableAnimations,
    );
    await tester.pumpWidget(
      wrapWithApp(
        MediaQuery(
          data: media,
          child: Center(child: SizedBox(width: 120, height: 220, child: cover)),
        ),
      ),
    );
  }

  CachedNetworkImage imageOf(WidgetTester tester) =>
      tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));

  void expectFadeIn(WidgetTester tester, {required Duration duration}) {
    final image = imageOf(tester);
    expect(image.fadeInDuration, duration);
    expect(image.fadeInCurve, Curves.easeOut);
    expect(image.fadeOutDuration, Duration.zero);
  }

  test('cover fade-in lasts 200ms', () {
    expect(coverFadeDuration, const Duration(milliseconds: 200));
  });

  testWidgets('CoverImage fades in without fading the placeholder out', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const CoverImage(url: imageUrl),
      disableAnimations: false,
    );
    expectFadeIn(tester, duration: const Duration(milliseconds: 200));
  });

  testWidgets('CoverImage keeps a fixed background outside the fading image', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const CoverImage(url: imageUrl),
      disableAnimations: false,
    );
    final cover = find.byType(CoverImage);
    final background = tester.widget<ColoredBox>(
      find.descendant(of: cover, matching: find.byType(ColoredBox)).first,
    );
    expect(background.child, same(imageOf(tester)));
    expect(
      background.color,
      Theme.of(tester.element(cover)).colorScheme.surfaceContainerHighest,
    );
    expect(tester.getSize(cover), const Size(120, 220));
  });

  testWidgets('CoverImage skips the fade-in when animations are disabled', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const CoverImage(url: imageUrl),
      disableAnimations: true,
    );
    expectFadeIn(tester, duration: Duration.zero);
  });

  testWidgets('CoverImage preserves custom placeholders and errors', (
    tester,
  ) async {
    const placeholder = SizedBox(key: ValueKey('custom-placeholder'));
    const error = SizedBox(key: ValueKey('custom-error'));
    await pumpCover(
      tester,
      const CoverImage(
        url: imageUrl,
        placeholder: placeholder,
        errorWidget: error,
      ),
      disableAnimations: false,
    );
    final image = imageOf(tester);
    final context = tester.element(find.byType(CoverImage));
    expect(image.placeholder!(context, imageUrl), same(placeholder));
    expect(
      image.errorWidget!(context, imageUrl, Exception('failed')),
      same(error),
    );
    expectFadeIn(tester, duration: const Duration(milliseconds: 200));
  });

  testWidgets('NovelCover inherits the shared fade-in', (tester) async {
    await pumpCover(
      tester,
      const NovelCover(url: imageUrl),
      disableAnimations: false,
    );
    expectFadeIn(tester, duration: const Duration(milliseconds: 200));
  });

  testWidgets('ComicCoverCard inherits the shared fade-in', (tester) async {
    await pumpCover(
      tester,
      ComicCoverCard(
        comic: Comic(name: '漫画', pathWord: 'comic', cover: imageUrl),
        onTap: () {},
      ),
      disableAnimations: false,
    );
    expectFadeIn(tester, duration: const Duration(milliseconds: 200));
  });

  testWidgets('CoverPlaceholder remains static', (tester) async {
    await pumpCover(tester, const CoverPlaceholder(), disableAnimations: false);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CoverPlaceholder),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(tester.hasRunningAnimations, isFalse);
  });
}
