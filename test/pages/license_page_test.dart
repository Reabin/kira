import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kira/pages/license_page.dart';
import 'package:kira/providers/license_providers.dart';
import 'package:kira/routing/app_router.dart';
import 'package:kira/widgets/collapsible_content.dart';
import 'package:kira/widgets/error_retry_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _CountingLicense extends LicenseEntry {
  _CountingLicense(this.packages, this.content, {this.failuresLeft = 0});

  @override
  final List<String> packages;
  final List<LicenseParagraph> content;
  int reads = 0;
  int failuresLeft;

  @override
  Iterable<LicenseParagraph> get paragraphs {
    reads++;
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('License paragraph unreadable');
    }
    return content;
  }
}

LicenseEntryCollector _collectorOf(List<LicenseEntry> entries) =>
    () => Stream<LicenseEntry>.fromIterable(entries);

void main() {
  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(teardownSecureCredentialStoreForTest);

  Widget appWith({
    required Widget child,
    LicenseEntryCollector? collector,
    ThemeData? theme,
    bool wrapInScaffold = false,
  }) {
    return wrapWithApp(
      ProviderScope(
        overrides: [
          if (collector != null)
            licenseEntryCollectorProvider.overrideWithValue(collector),
        ],
        child: theme == null ? child : Theme(data: theme, child: child),
      ),
      wrapInScaffold: wrapInScaffold,
    );
  }

  Future<void> pumpLicenses(
    WidgetTester tester,
    LicenseEntryCollector collector,
  ) async {
    await tester.pumpWidget(
      appWith(child: const ProjectLicensePage(), collector: collector),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDetail(
    WidgetTester tester, {
    String packageName = 'example',
    LicenseEntryCollector? collector,
  }) async {
    await tester.pumpWidget(
      appWith(
        child: PackageLicensePage(packageName: packageName),
        collector: collector,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> collapseProject(WidgetTester tester) async {
    await tester.tap(find.text('Kira'));
    await tester.pumpAndSettle();
  }

  Future<GoRouter> pumpRouter(
    WidgetTester tester,
    LicenseEntryCollector collector,
  ) async {
    final router = GoRouter(
      initialLocation: '/license',
      routes: [
        GoRoute(
          path: '/license',
          name: AppRoutes.license,
          builder: (_, _) => const ProjectLicensePage(),
          routes: [
            GoRoute(
              path: ':packageName',
              name: AppRoutes.packageLicense,
              builder: (_, state) => PackageLicensePage(
                packageName: state.pathParameters['packageName']!,
              ),
            ),
            GoRoute(
              path: 'font/:fontId',
              name: AppRoutes.fontLicense,
              builder: (_, state) =>
                  FontLicensePage(fontId: state.pathParameters['fontId']!),
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
    await tester.pumpWidget(
      appWith(
        child: Router.withConfig(config: router),
        collector: collector,
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('project license matches LICENSE and stays above dependencies', (
    tester,
  ) async {
    await pumpLicenses(tester, () => const Stream<LicenseEntry>.empty());

    expect(find.text('开源许可'), findsOneWidget);
    expect(find.text('Kira'), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      File('LICENSE').readAsStringSync().replaceAll('\r\n', '\n').trim(),
    );
    await collapseProject(tester);
    expect(find.text('第三方依赖'), findsOneWidget);
    expect(find.text('未收集到第三方许可'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Kira')).dy,
      lessThan(tester.getTopLeft(find.text('第三方依赖')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dependencies are plain sorted rows with license counts', (
    tester,
  ) async {
    await pumpLicenses(
      tester,
      _collectorOf(const [
        LicenseEntryWithLineBreaks([
          'Zulu',
          'alpha',
          'alpha',
        ], 'Shared copyright'),
        LicenseEntryWithLineBreaks(['alpha'], 'Additional NOTICE'),
      ]),
    );
    await collapseProject(tester);

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('Zulu'), findsOneWidget);
    expect(find.text('2 份许可'), findsOneWidget);
    expect(find.text('1 份许可'), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(CollapsibleContent), findsOneWidget);
    expect(
      find.ancestor(of: find.text('alpha'), matching: find.byType(Card)),
      findsNothing,
    );
    expect(find.text('Shared copyright'), findsNothing);
    expect(
      tester.getTopLeft(find.text('alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Zulu')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('list opens separate details with every applicable notice', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      _collectorOf(const [
        LicenseEntryWithLineBreaks(['Zulu', 'alpha'], 'Shared copyright'),
        LicenseEntryWithLineBreaks(['alpha'], 'Additional NOTICE'),
      ]),
    );
    await collapseProject(tester);
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(PackageLicensePage), findsOneWidget);
    expect(find.text('Shared copyright'), findsOneWidget);
    expect(find.text('Additional NOTICE'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('第三方依赖'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('第三方依赖'), findsOneWidget);
    await tester.tap(find.text('Zulu'));
    await tester.pumpAndSettle();
    expect(find.text('Shared copyright'), findsOneWidget);
    expect(find.text('Additional NOTICE'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'only the duplicate Kira MIT notice is omitted from dependencies',
    (tester) async {
      final projectLicense = File('LICENSE').readAsStringSync();
      await pumpRouter(
        tester,
        _collectorOf([
          LicenseEntryWithLineBreaks(['kira', 'shared'], projectLicense),
          const LicenseEntryWithLineBreaks(['kira'], 'Additional Kira notice'),
        ]),
      );
      await collapseProject(tester);
      expect(find.text('kira'), findsOneWidget);
      expect(find.text('shared'), findsOneWidget);
      expect(find.text('1 份许可'), findsNWidgets(2));

      await tester.tap(find.text('kira'));
      await tester.pumpAndSettle();
      expect(find.text('Additional Kira notice'), findsOneWidget);
      expect(find.textContaining('MIT License'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('shared'));
      await tester.pumpAndSettle();
      expect(find.textContaining('MIT License'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'list does not parse paragraphs and detail preserves formatting',
    (tester) async {
      final entry = _CountingLicense(
        ['example'],
        const [
          LicenseParagraph(
            'Centered license title',
            LicenseParagraph.centeredIndent,
          ),
          LicenseParagraph('Indented condition', 1),
          LicenseParagraph('Copyright retained verbatim', 0),
        ],
      );
      await pumpRouter(tester, _collectorOf([entry]));
      await collapseProject(tester);
      expect(entry.reads, 0);

      await tester.tap(find.text('example'));
      await tester.pumpAndSettle();
      expect(entry.reads, 1);
      expect(
        tester.widget<Text>(find.text('Centered license title')).textAlign,
        TextAlign.center,
      );
      final indented = find
          .ancestor(
            of: find.text('Indented condition'),
            matching: find.byType(Padding),
          )
          .first;
      expect(
        tester.widget<Padding>(indented).padding,
        const EdgeInsets.only(left: 16, bottom: 12),
      );
      expect(find.text('Copyright retained verbatim'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('font licenses are declared and open their license text', (
    tester,
  ) async {
    await pumpRouter(tester, () => const Stream<LicenseEntry>.empty());
    await collapseProject(tester);

    expect(find.text('字体'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('字体')).dy,
      lessThan(tester.getTopLeft(find.text('第三方依赖')).dy),
    );
    expect(find.text('MiSans'), findsOneWidget);
    expect(find.text('霞鹜文楷'), findsOneWidget);
    expect(find.text('SIL Open Font License 1.1'), findsOneWidget);

    await tester.tap(find.text('MiSans'));
    await tester.pumpAndSettle();
    expect(find.byType(FontLicensePage), findsOneWidget);
    final miSansText = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(miSansText, contains('本应用使用 MiSans 字体'));

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('霞鹜文楷'));
    await tester.pumpAndSettle();
    final wenKaiText = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(wenKaiText, contains('Reserved Font Name'));
    expect(wenKaiText, contains('SIL Open Font License, Version 1.1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('collection failure shows its cause and retry recovers', (
    tester,
  ) async {
    var attempts = 0;
    await pumpLicenses(tester, () {
      if (attempts++ == 0) {
        return Stream<LicenseEntry>.error(Exception('NOTICES unreadable'));
      }
      return Stream<LicenseEntry>.value(
        const LicenseEntryWithLineBreaks(['recovered'], 'Recovered license'),
      );
    });
    await collapseProject(tester);
    expect(find.text('Exception: NOTICES unreadable'), findsOneWidget);
    expect(find.byType(ErrorRetryView), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('recovered'), findsOneWidget);
    expect(find.byType(ErrorRetryView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail paragraph failure shows its cause and can be retried', (
    tester,
  ) async {
    final entry = _CountingLicense(
      ['example'],
      const [LicenseParagraph('Recovered paragraph', 0)],
      failuresLeft: 1,
    );
    await pumpDetail(tester, collector: _collectorOf([entry]));
    expect(
      find.text('Exception: License paragraph unreadable'),
      findsOneWidget,
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered paragraph'), findsOneWidget);
    expect(entry.reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail opened by deep link shows only the requested package', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      packageName: 'requested',
      collector: _collectorOf(const [
        LicenseEntryWithLineBreaks([
          'requested',
          'shared',
        ], 'Requested copyright'),
        LicenseEntryWithLineBreaks(['other'], 'Unrelated copyright'),
      ]),
    );
    expect(find.text('Requested copyright'), findsOneWidget);
    expect(find.text('Unrelated copyright'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('project stays readable while dependency collection is pending', (
    tester,
  ) async {
    final controller = StreamController<LicenseEntry>();
    addTearDown(() {
      unawaited(controller.close());
    });
    await tester.pumpWidget(
      appWith(
        child: const ProjectLicensePage(),
        collector: () => controller.stream,
      ),
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.text('Kira'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    controller.add(
      const LicenseEntryWithLineBreaks(['loaded'], 'Loaded license'),
    );
    final closed = controller.close();
    await tester.pumpAndSettle();
    await closed;
    expect(find.text('loaded'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning from detail preserves list position and project fold',
    (tester) async {
      await pumpRouter(
        tester,
        _collectorOf([
          for (var index = 0; index < 80; index++)
            LicenseEntryWithLineBreaks([
              'package_${index.toString().padLeft(2, '0')}',
            ], 'Notice $index'),
        ]),
      );
      await collapseProject(tester);
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('package_60'),
        500,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      await tester.tap(find.text('package_60'));
      await tester.pumpAndSettle();
      expect(find.text('Notice 60'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        offset,
      );
      expect(find.text('package_60').hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Kira'),
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CollapsibleContent)).height, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('project license ignores custom app font on $platform', (
      tester,
    ) async {
      final theme = ThemeData(
        platform: platform,
        fontFamily: 'CustomAppFont',
        fontFamilyFallback: const ['CustomAppFallback'],
      );
      final systemStyle = Typography.material2021(
        platform: platform,
        colorScheme: theme.colorScheme,
      ).black.bodyMedium!;
      await tester.pumpWidget(
        appWith(
          child: const ProjectLicensePage(),
          theme: theme,
          collector: () => const Stream<LicenseEntry>.empty(),
        ),
      );
      await tester.pumpAndSettle();
      final projectStyle = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .style!;
      expect(projectStyle.fontFamily, systemStyle.fontFamily);
      expect(
        projectStyle.fontFamilyFallback,
        isNot(contains('CustomAppFallback')),
      );
      expect(projectStyle.inherit, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dependency license ignores custom app font on $platform', (
      tester,
    ) async {
      final theme = ThemeData(
        platform: platform,
        fontFamily: 'CustomAppFont',
        fontFamilyFallback: const ['CustomAppFallback'],
      );
      final systemStyle = Typography.material2021(
        platform: platform,
        colorScheme: theme.colorScheme,
      ).black.bodyMedium!;
      await tester.pumpWidget(
        appWith(
          child: const PackageLicensePage(packageName: 'example'),
          theme: theme,
          collector: _collectorOf(const [
            LicenseEntryWithLineBreaks(['example'], 'System font license body'),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      final body = find.text('System font license body');
      final style = tester.widget<Text>(body).style!;
      expect(style.fontFamily, systemStyle.fontFamily);
      expect(style.fontFamilyFallback, isNot(contains('CustomAppFallback')));
      expect(style.inherit, isFalse);
      final richText = find.descendant(
        of: body,
        matching: find.byType(RichText),
      );
      expect(
        tester.widget<RichText>(richText).text.style!.fontFamily,
        systemStyle.fontFamily,
      );
      expect(
        Theme.of(
          tester.element(find.text('example')),
        ).textTheme.bodyMedium!.fontFamily,
        'CustomAppFont',
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('large text and reduced motion fit $size in dark mode', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/license',
        routes: [
          GoRoute(
            path: '/license',
            name: AppRoutes.license,
            builder: (_, _) => const ProjectLicensePage(),
            routes: [
              GoRoute(
                path: ':packageName',
                name: AppRoutes.packageLicense,
                builder: (_, state) => PackageLicensePage(
                  packageName: state.pathParameters['packageName']!,
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      });
      await tester.pumpWidget(
        appWith(
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: true,
                textScaler: const TextScaler.linear(2),
              ),
              child: Router.withConfig(config: router),
            ),
          ),
          theme: ThemeData.dark(),
          collector: _collectorOf(const [
            LicenseEntryWithLineBreaks([
              'a_long_dependency_package_name',
            ], 'Copyright preserved at large text sizes.'),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kira'));
      await tester.pump();
      expect(tester.getSize(find.byType(CollapsibleContent)).height, 0);
      final target = find.text('a_long_dependency_package_name');
      final scrollable = find.byType(Scrollable).first;
      for (
        var attempt = 0;
        target.hitTestable().evaluate().isEmpty;
        attempt++
      ) {
        expect(
          attempt,
          lessThan(20),
          reason: 'dependency row never scrolled into view',
        );
        await tester.drag(scrollable, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(
        find.text('Copyright preserved at large text sizes.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
