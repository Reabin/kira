import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/comic_comment.dart';
import 'package:kira/pages/comic_comments_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _ComicCommentsApi extends Fake implements MangaApi {
  static const _comment = ComicComment(
    id: 1,
    createAt: '2026-05-03 12:00:00',
    userId: 'reader-1',
    userName: '读者甲',
    userAvatar: '',
    comment: '第一条评论',
    replyCount: 0,
  );

  @override
  Future<({List<ComicComment> list, int total})> getComicComments(
    String comicId, {
    String replyId = '',
    int limit = 10,
    int offset = 0,
  }) async => (list: const [_comment], total: 1);
}

class _Client extends Fake implements ApiClient {
  @override
  final MangaApi manga = _ComicCommentsApi();
}

void main() {
  late ApiClient originalApi;

  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    originalApi = ApiClient();
    ApiClient.setTestInstance(_Client());
  });

  tearDown(() {
    ApiClient.setTestInstance(originalApi);
    teardownSecureCredentialStoreForTest();
  });

  Finder buttonFor(IconData icon) => find.ancestor(
    of: find.byIcon(icon),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('作品评论在 $brightness 下评论用主色、辅助按钮用次色并保留布局', (tester) async {
      await tester.pumpWidget(
        wrapWithApp(
          Theme(
            data: ThemeData(brightness: brightness),
            child: const ComicCommentsSheet(
              comicId: 'comic-test',
              comicName: '测试漫画',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final post = buttonFor(Icons.comment_outlined);
      final top = buttonFor(Icons.arrow_upward_rounded);
      final close = buttonFor(Icons.keyboard_arrow_down_rounded);
      final cs = Theme.of(tester.element(post)).colorScheme;
      final postStyle = tester.widget<FilledButton>(post).style!;
      expect(postStyle.backgroundColor!.resolve({}), cs.primary);
      expect(postStyle.foregroundColor!.resolve({}), cs.onPrimary);
      for (final button in [top, close]) {
        final style = tester.widget<FilledButton>(button).style!;
        expect(style.backgroundColor!.resolve({}), cs.secondaryContainer);
        expect(style.foregroundColor!.resolve({}), cs.onSecondaryContainer);
        expect(style.elevation!.resolve({}), 6);
        expect(tester.getSize(button), const Size.square(52));
      }
      expect(postStyle.elevation!.resolve({}), 6);
      expect(tester.getSize(post).height, 52);
      final postRect = tester.getRect(post);
      final topRect = tester.getRect(top);
      final closeRect = tester.getRect(close);
      expect(postRect.right + 8, closeTo(topRect.left, 0.01));
      expect(topRect.left, closeTo(closeRect.left, 0.01));
      expect(topRect.bottom + 8, closeTo(closeRect.top, 0.01));
      expect(postRect.bottom, closeTo(closeRect.bottom, 0.01));

      final nameRect = tester.getRect(find.text('测试漫画'));
      final countRect = tester.getRect(
        find.byKey(const ValueKey('comic-comments-count')),
      );
      expect(countRect.left, greaterThan(nameRect.right));
      expect(countRect.center.dy, closeTo(nameRect.center.dy, 1));
      final rowRect = tester.getRect(
        find.byKey(const ValueKey('comic-comments-subtitle')),
      );
      expect(countRect.right, closeTo(rowRect.right, 0.01));

      final materials = find.descendant(
        of: find.byType(ComicCommentsSheet),
        matching: find.byType(Material),
      );
      expect(find.ancestor(of: post, matching: materials), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
