import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/api/api_client.dart';
import 'package:kira/api/manga/manga_api.dart';
import 'package:kira/models/comic.dart' hide Theme;
import 'package:kira/models/user_manager.dart';
import 'package:kira/pages/home_page.dart';
import 'package:kira/providers/repository_providers.dart';
import 'package:kira/repositories/manga_home_repository.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/widgets/section_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _Api extends Fake implements ApiClient {
  @override
  final MangaApi manga = _Manga();
}

class _Manga extends Fake implements MangaApi {
  @override
  Future<({List<Comic> list, int total})> getCopyComicList({
    String ordering = '',
    int limit = 21,
    int offset = 0,
    String? theme,
    String? top,
  }) async => (list: <Comic>[], total: 0);
}

class _HomeRepository extends MangaHomeRepository {
  final data = CopyMangaHomeData(
    home: CopyMangaHome(
      recComics: [Comic(name: '测试作品', pathWord: 'test', cover: '')],
    ),
  );

  @override
  Future<CopyMangaHomeData?> loadBFromCache() async => data;

  @override
  Future<CopyMangaHomeData> loadB() async => data;
}

void main() {
  late ApiClient original;
  setUp(() async {
    setupSecureCredentialStoreForTest();
    original = ApiClient();
    ApiClient.setTestInstance(_Api());
    SharedPreferences.setMockInitialValues({
      'manga_home_source': 'copy',
      'banner_visible': false,
    });
    await UserManager().init();
  });

  tearDown(() {
    ApiClient.setTestInstance(original);
    teardownSecureCredentialStoreForTest();
  });

  Future<void> mount(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaHomeRepositoryProvider.overrideWithValue(_HomeRepository()),
        ],
        child: wrapWithApp(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: TextScaler.linear(textScale),
              ),
              child: const HomePage(),
            ),
          ),
          wrapInScaffold: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
    'copy section is unframed and collapses without changing titles',
    (tester) async {
      await mount(tester);
      expect(find.widgetWithText(SectionHeader, '推荐'), findsOneWidget);
      final label = tester.widget<Text>(find.text('测试作品'));
      expect(label.maxLines, 1);
      final section = find
          .ancestor(
            of: find.widgetWithText(SectionHeader, '推荐'),
            matching: find.byType(Material),
          )
          .first;
      expect(tester.widget<Material>(section).color, Colors.transparent);

      await tester.tap(find.text('推荐'));
      await tester.pump();
      expect(UserManager().isCopyHomeSectionCollapsed('copy-rec'), isTrue);
      expect(find.text('测试作品').hitTestable(), findsNothing);

      await tester.tap(find.text('推荐'));
      await tester.pump();
      expect(UserManager().isCopyHomeSectionCollapsed('copy-rec'), isFalse);
      expect(find.text('测试作品').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copy section header fits a narrow screen with large text', (
    tester,
  ) async {
    await mount(tester, textScale: 2);
    expect(find.text('推荐'), findsOneWidget);
    await tester.tap(find.text('推荐'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('more opens the list without toggling the section', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomePage()),
        GoRoute(
          path: '/copy/:kind',
          name: AppRoutes.copyMangaList,
          builder: (_, state) =>
              Scaffold(body: Text('list:${state.pathParameters['kind']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaHomeRepositoryProvider.overrideWithValue(_HomeRepository()),
        ],
        child: wrapWithApp(
          Router.withConfig(config: router),
          wrapInScaffold: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(SectionHeader, '推荐'),
        matching: find.text('更多'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('list:recommendations'), findsOneWidget);
    expect(UserManager().isCopyHomeSectionCollapsed('copy-rec'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
