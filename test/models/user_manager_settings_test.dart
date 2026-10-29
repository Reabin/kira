import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = UserManager();

  setUp(() async {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
    await user.init();
  });

  tearDown(teardownSecureCredentialStoreForTest);

  final settings = [
    (
      key: 'banner_visible',
      initial: true,
      readFacade: () => user.bannerVisible,
      readStore: () => user.theme.bannerVisible,
      writeFacade: user.setBannerVisible,
      writeStore: user.theme.setBannerVisible,
    ),
    (
      key: 'comment_compact_layout',
      initial: true,
      readFacade: () => user.commentCompactLayout,
      readStore: () => user.comment.compactLayout,
      writeFacade: user.setCommentCompactLayout,
      writeStore: user.comment.setCompactLayout,
    ),
    (
      key: 'comment_preload',
      initial: true,
      readFacade: () => user.commentPreload,
      readStore: () => user.comment.preload,
      writeFacade: user.setCommentPreload,
      writeStore: user.comment.setPreload,
    ),
    (
      key: 'comment_auto_load_all',
      initial: false,
      readFacade: () => user.commentAutoLoadAll,
      readStore: () => user.comment.autoLoadAll,
      writeFacade: user.setCommentAutoLoadAll,
      writeStore: user.comment.setAutoLoadAll,
    ),
  ];

  for (final setting in settings) {
    test(
      '${setting.key} shares state and notifies once through either path',
      () async {
        expect(setting.readFacade(), setting.initial);
        expect(setting.readStore(), setting.initial);
        final snapshots = <(bool, bool)>[];
        void listener() =>
            snapshots.add((setting.readFacade(), setting.readStore()));
        user.addListener(listener);
        addTearDown(() => user.removeListener(listener));
        final prefs = await SharedPreferences.getInstance();

        await setting.writeFacade(!setting.initial);
        expect(setting.readStore(), !setting.initial);
        expect(setting.readFacade(), !setting.initial);
        expect(prefs.getBool(setting.key), !setting.initial);
        expect(snapshots, [(!setting.initial, !setting.initial)]);

        snapshots.clear();
        await setting.writeStore(setting.initial);
        expect(setting.readFacade(), setting.initial);
        expect(prefs.getBool(setting.key), setting.initial);
        expect(snapshots, [(setting.initial, setting.initial)]);
      },
    );
  }

  test(
    'opening floating nav downgrades facade mode in the same notification',
    () async {
      await user.theme.setFloatingNavEnabled(false);
      final snapshots = <(BottomNavLabelMode, BottomNavLabelMode)>[];
      void listener() => snapshots.add((
        user.bottomNavLabelMode,
        user.theme.bottomNavLabelMode,
      ));
      user.addListener(listener);
      addTearDown(() => user.removeListener(listener));

      await user.setBottomNavLabelMode(BottomNavLabelMode.always);
      expect(snapshots, [
        (BottomNavLabelMode.always, BottomNavLabelMode.always),
      ]);
      snapshots.clear();

      await user.theme.setFloatingNavEnabled(true);
      expect(user.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
      expect(user.bottomNavShowLabels, isTrue);
      expect(snapshots, [
        (BottomNavLabelMode.selectedOnly, BottomNavLabelMode.selectedOnly),
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bottom_nav_label_mode'), 'selectedOnly');
      expect(prefs.getBool('bottom_nav_show_labels'), isTrue);

      snapshots.clear();
      await user.setBottomNavLabelMode(BottomNavLabelMode.selectedOnly);
      expect(snapshots, isEmpty);
    },
  );

  test(
    'legacy facade setter and store mode setter share label visibility',
    () async {
      await user.setBottomNavShowLabels(false);
      expect(user.theme.bottomNavLabelMode, BottomNavLabelMode.hidden);
      expect(user.bottomNavShowLabels, isFalse);
      await user.theme.setBottomNavShowLabels(true);
      expect(user.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
      expect(user.bottomNavShowLabels, isTrue);
    },
  );

  for (final visible in [true, false]) {
    test('facade loads legacy label visibility $visible', () async {
      SharedPreferences.setMockInitialValues({
        'bottom_nav_show_labels': visible,
      });
      await user.init(persistMigrations: false);
      expect(
        user.bottomNavLabelMode,
        visible ? BottomNavLabelMode.selectedOnly : BottomNavLabelMode.hidden,
      );
      expect(user.bottomNavShowLabels, visible);
      expect(user.theme.bottomNavShowLabels, visible);
    });
  }

  test(
    'read-only reload respects explicit mode and does not write its downgrade',
    () async {
      SharedPreferences.setMockInitialValues({
        'bottom_nav_show_labels': false,
        'bottom_nav_label_mode': 'always',
        'nav_floating_enabled': true,
      });
      await user.init(persistMigrations: false);
      expect(user.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
      expect(user.theme.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bottom_nav_label_mode'), 'always');
      expect(prefs.getBool('bottom_nav_show_labels'), isFalse);
    },
  );

  test(
    'default prefs backend retains settings across repeated initialization',
    () async {
      teardownSecureCredentialStoreForTest();
      await user.init(persistMigrations: false);
      for (final setting in settings) {
        await setting.writeFacade(!setting.initial);
      }
      await user.theme.setFloatingNavEnabled(false);
      await user.setBottomNavLabelMode(BottomNavLabelMode.always);

      for (var boot = 0; boot < 3; boot++) {
        user.theme.resetPrefsCache();
        user.comment.resetPrefsCache();
        await user.init(persistMigrations: false);
        for (final setting in settings) {
          expect(setting.readFacade(), !setting.initial);
          expect(setting.readStore(), !setting.initial);
        }
        expect(user.bottomNavLabelMode, BottomNavLabelMode.always);
        expect(user.bottomNavShowLabels, isTrue);
      }

      final prefs = await SharedPreferences.getInstance();
      for (final setting in settings) {
        await prefs.remove(setting.key);
      }
      await prefs.remove('bottom_nav_label_mode');
      await prefs.remove('bottom_nav_show_labels');
      await user.init(persistMigrations: false);
      for (final setting in settings) {
        expect(setting.readFacade(), setting.initial);
        expect(setting.readStore(), setting.initial);
      }
      expect(user.bottomNavLabelMode, BottomNavLabelMode.selectedOnly);
    },
  );

  test(
    'reload binds theme and comment writes to the newly initialized backend',
    () async {
      final oldPrefs = await SharedPreferences.getInstance();
      await user.theme.setBannerVisible(false);
      await user.comment.setPreload(false);

      SharedPreferences.setMockInitialValues({});
      await user.init(persistMigrations: false);
      final newPrefs = await SharedPreferences.getInstance();
      await user.theme.setBannerVisible(false);
      await user.comment.setPreload(false);
      expect(newPrefs.getBool('banner_visible'), isFalse);
      expect(newPrefs.getBool('comment_preload'), isFalse);

      await user.setBannerVisible(true);
      await user.setCommentPreload(true);
      expect(newPrefs.getBool('banner_visible'), isTrue);
      expect(newPrefs.getBool('comment_preload'), isTrue);
      expect(oldPrefs.getBool('banner_visible'), isFalse);
      expect(oldPrefs.getBool('comment_preload'), isFalse);
    },
  );
}
