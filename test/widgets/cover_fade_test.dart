import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/utils/adaptive_motion.dart';
import 'package:kira/widgets/comic_cover_card.dart';
import 'package:kira/widgets/cover_image.dart';
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

  void expectCrossfade(
    WidgetTester tester, {
    required Duration fadeIn,
    required Duration fadeOut,
  }) {
    final image = imageOf(tester);
    expect(image.fadeInDuration, fadeIn);
    expect(image.fadeOutDuration, fadeOut);
  }

  test('crossfade keeps placeholder and image in sync', () {
    expect(coverFadeDuration, const Duration(milliseconds: 180));
    expect(coverFadeOutDuration, coverFadeDuration);
  });

  testWidgets('CoverImage crossfades placeholder out as the image fades in', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const CoverImage(url: imageUrl),
      disableAnimations: false,
    );
    expectCrossfade(
      tester,
      fadeIn: const Duration(milliseconds: 180),
      fadeOut: const Duration(milliseconds: 180),
    );
  });

  testWidgets('CoverImage skips the crossfade when animations are disabled', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const CoverImage(url: imageUrl),
      disableAnimations: true,
    );
    expectCrossfade(tester, fadeIn: Duration.zero, fadeOut: Duration.zero);
  });

  testWidgets('NovelCover inherits the shared crossfade', (tester) async {
    await pumpCover(
      tester,
      const NovelCover(url: imageUrl),
      disableAnimations: false,
    );
    expectCrossfade(
      tester,
      fadeIn: const Duration(milliseconds: 180),
      fadeOut: const Duration(milliseconds: 180),
    );
  });

  testWidgets('ComicCoverCard inherits the shared crossfade', (tester) async {
    await pumpCover(
      tester,
      ComicCoverCard(
        comic: Comic(name: '漫画', pathWord: 'comic', cover: imageUrl),
        onTap: () {},
      ),
      disableAnimations: false,
    );
    expectCrossfade(
      tester,
      fadeIn: const Duration(milliseconds: 180),
      fadeOut: const Duration(milliseconds: 180),
    );
  });
}
