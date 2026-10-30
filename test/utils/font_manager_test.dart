import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/app_storage.dart';
import 'package:kira/utils/font_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FontManager().reloadFromPrefs();
  });

  tearDown(() {
    FontManager().reloadFromPrefs();
  });

  group('FontManager remote catalog cache', () {
    test('keeps the remote font list for three days', () {
      expect(FontManager.fontListCacheTtl, const Duration(days: 3));
    });

    test('loads a valid persistent catalog without a remote request', () async {
      await AppStorage.cache.put('font_list_v1', {
        'fonts': [
          {'name': 'CachedFont', 'url': 'https://example.com/cached-font.ttf'},
        ],
      }, ttl: FontManager.fontListCacheTtl);

      final fonts = await FontManager().fetchAvailableFonts();

      expect(fonts, hasLength(1));
      expect(fonts.single.name, 'CachedFont');
    });
  });

  group('FontManager downloaded fonts', () {
    late Directory root;
    late Directory fontDir;
    late PathProviderPlatform originalPaths;

    setUp(() async {
      originalPaths = PathProviderPlatform.instance;
      root = await Directory.systemTemp.createTemp('kira_font_manager_test');
      fontDir = Directory('${root.path}${Platform.pathSeparator}fonts')
        ..createSync(recursive: true);
      PathProviderPlatform.instance = _FakePaths(root.path);
      FontManager().reloadFromPrefs();
    });

    tearDown(() {
      PathProviderPlatform.instance = originalPaths;
      FontManager().reloadFromPrefs();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test(
      'keeps a downloaded font that vanished from the remote catalog',
      () async {
        await AppStorage.cache.put('font_list_v1', {
          'fonts': [
            {'name': 'FontB', 'url': 'https://example.com/b.ttf'},
          ],
        }, ttl: FontManager.fontListCacheTtl);
        File(
          '${fontDir.path}${Platform.pathSeparator}FontA.ttf',
        ).writeAsBytesSync([1, 2, 3]);

        final fonts = await FontManager().fetchAvailableFonts();

        expect(fonts.map((font) => font.name), containsAll(['FontA', 'FontB']));
        final fontA = fonts.singleWhere((font) => font.name == 'FontA');
        expect(fontA.url, isEmpty);
      },
    );

    test('deleteFont drops the downloaded-only entry', () async {
      await AppStorage.cache.put('font_list_v1', {
        'fonts': [
          {'name': 'FontB', 'url': 'https://example.com/b.ttf'},
        ],
      }, ttl: FontManager.fontListCacheTtl);
      File(
        '${fontDir.path}${Platform.pathSeparator}FontA.ttf',
      ).writeAsBytesSync([1, 2, 3]);

      final manager = FontManager();
      await manager.fetchAvailableFonts();
      expect(manager.cachedList.map((font) => font.name), contains('FontA'));

      await manager.deleteFont('FontA');

      expect(
        manager.cachedList.map((font) => font.name),
        isNot(contains('FontA')),
      );
      expect(manager.cachedList.map((font) => font.name), contains('FontB'));
    });

    test('catalog entry wins over the downloaded-only entry', () async {
      await AppStorage.cache.put('font_list_v1', {
        'fonts': [
          {'name': 'FontA', 'url': 'https://example.com/a.ttf'},
        ],
      }, ttl: FontManager.fontListCacheTtl);
      File(
        '${fontDir.path}${Platform.pathSeparator}FontA.ttf',
      ).writeAsBytesSync([1, 2, 3]);

      final fonts = await FontManager().fetchAvailableFonts();

      expect(fonts.where((font) => font.name == 'FontA'), hasLength(1));
      expect(
        fonts.singleWhere((font) => font.name == 'FontA').url,
        'https://example.com/a.ttf',
      );
    });

    test(
      'importLocalFont stores the file and registers a custom entry',
      () async {
        await AppStorage.cache.put('font_list_v1', {
          'fonts': [
            {'name': 'FontB', 'url': 'https://example.com/b.ttf'},
          ],
        }, ttl: FontManager.fontListCacheTtl);

        final manager = FontManager();
        final imported = await manager.importLocalFont(
          name: 'MyLocal',
          bytes: Uint8List.fromList([0, 1, 0, 0, 9, 9, 9]),
        );

        expect(imported, isTrue);
        expect(await manager.isFontDownloaded('MyLocal'), isTrue);

        final fonts = await manager.fetchAvailableFonts();
        final local = fonts.singleWhere((font) => font.name == 'MyLocal');
        expect(local.isCustom, isTrue);
        expect(local.url, isEmpty);

        // The entry survives a cold start (re-created catalog from prefs).
        manager.reloadFromPrefs();
        final reloaded = await FontManager().fetchAvailableFonts();
        final persisted = reloaded.singleWhere(
          (font) => font.name == 'MyLocal',
        );
        expect(persisted.isCustom, isTrue);
        expect(persisted.url, isEmpty);
      },
    );

    test('importLocalFont rejects non-font bytes', () async {
      final manager = FontManager();
      final imported = await manager.importLocalFont(
        name: 'Broken',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );

      expect(imported, isFalse);
      expect(await manager.isFontDownloaded('Broken'), isFalse);
    });
  });

  group('FontManager custom fonts', () {
    test('addCustomFont persists name and url', () async {
      final manager = FontManager();
      final added = await manager.addCustomFont(
        name: ' MyFont ',
        url: 'https://example.com/fonts/myfont.ttf',
      );
      expect(added, isTrue);

      final fonts = await manager.fetchAvailableFonts();
      final custom = fonts.where((font) => font.name == 'MyFont').toList();
      expect(custom, hasLength(1));
      expect(custom.single.url, 'https://example.com/fonts/myfont.ttf');
      expect(custom.single.isCustom, isTrue);

      manager.reloadFromPrefs();
      final reloaded = await FontManager().fetchAvailableFonts();
      expect(
        reloaded.any((font) => font.name == 'MyFont' && font.isCustom),
        isTrue,
      );
    });

    test('addCustomFont rejects invalid input', () async {
      final manager = FontManager();
      expect(
        await manager.addCustomFont(name: '', url: 'https://a.com/a.ttf'),
        isFalse,
      );
      expect(await manager.addCustomFont(name: 'A', url: ''), isFalse);
      expect(
        await manager.addCustomFont(name: 'A', url: 'ftp://a.com/a.ttf'),
        isFalse,
      );
      expect(await manager.addCustomFont(name: 'A', url: 'not-a-url'), isFalse);
      expect(
        await manager.addCustomFont(
          name: FontManager.defaultFontId,
          url: 'https://a.com/a.ttf',
        ),
        isFalse,
      );
    });

    test('removeCustomFont drops catalog entry', () async {
      final manager = FontManager();
      await manager.addCustomFont(
        name: 'TempFont',
        url: 'https://example.com/temp.ttf',
      );
      await manager.removeCustomFont('TempFont');
      final fonts = await manager.fetchAvailableFonts();
      expect(fonts.any((font) => font.name == 'TempFont'), isFalse);
    });
  });
}
