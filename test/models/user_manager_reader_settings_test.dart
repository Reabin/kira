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

  void testSharedSetting<T>({
    required String key,
    required T initial,
    required T changed,
    required T Function() readFacade,
    required T Function() readStore,
    required Future<void> Function(T) writeFacade,
    required Future<void> Function(T) writeStore,
    bool skipsSameValue = false,
  }) {
    test('$key shares state, notifications and persistence', () async {
      expect(readFacade(), initial);
      expect(readStore(), initial);
      final snapshots = <(T, T)>[];
      var storeNotifications = 0;
      void facadeListener() => snapshots.add((readFacade(), readStore()));
      void storeListener() => storeNotifications++;
      user.addListener(facadeListener);
      user.reader.addListener(storeListener);
      addTearDown(() {
        user.removeListener(facadeListener);
        user.reader.removeListener(storeListener);
      });
      final prefs = await SharedPreferences.getInstance();

      await writeFacade(changed);
      expect(readStore(), changed);
      expect(readFacade(), changed);
      expect(prefs.get(key), changed);
      expect(snapshots, [(changed, changed)]);
      expect(storeNotifications, 1);

      snapshots.clear();
      storeNotifications = 0;
      await writeStore(initial);
      expect(readFacade(), initial);
      expect(prefs.get(key), initial);
      expect(snapshots, [(initial, initial)]);
      expect(storeNotifications, 1);

      snapshots.clear();
      storeNotifications = 0;
      await writeFacade(initial);
      expect(snapshots, skipsSameValue ? isEmpty : [(initial, initial)]);
      expect(storeNotifications, skipsSameValue ? 0 : 1);

      await writeStore(changed);
      teardownSecureCredentialStoreForTest();
      for (var boot = 0; boot < 3; boot++) {
        user.reader.resetPrefsCache();
        await user.init(persistMigrations: false);
        expect(readFacade(), changed);
        expect(readStore(), changed);
        expect(prefs.get(key), changed);
      }

      await prefs.remove(key);
      await user.init(persistMigrations: false);
      expect(readFacade(), initial);
      expect(readStore(), initial);
    });
  }

  testSharedSetting(
    key: 'reader_scroll_direction',
    initial: 2,
    changed: 0,
    readFacade: () => user.readerScrollDirection,
    readStore: () => user.reader.scrollDirection,
    writeFacade: user.setReaderScrollDirection,
    writeStore: user.reader.setScrollDirection,
  );
  testSharedSetting(
    key: 'reader_image_gap',
    initial: 0.0,
    changed: 8.0,
    readFacade: () => user.readerImageGap,
    readStore: () => user.reader.imageGap,
    writeFacade: user.setReaderImageGap,
    writeStore: user.reader.setImageGap,
  );
  testSharedSetting(
    key: 'reader_volume_key',
    initial: true,
    changed: false,
    readFacade: () => user.readerVolumeKey,
    readStore: () => user.reader.volumeKey,
    writeFacade: user.setReaderVolumeKey,
    writeStore: user.reader.setVolumeKey,
  );
  testSharedSetting(
    key: 'reader_instant_page_turn',
    initial: false,
    changed: true,
    readFacade: () => user.readerInstantPageTurn,
    readStore: () => user.reader.instantPageTurn,
    writeFacade: user.setReaderInstantPageTurn,
    writeStore: user.reader.setInstantPageTurn,
  );
  testSharedSetting(
    key: 'reader_page_rtl',
    initial: false,
    changed: true,
    readFacade: () => user.readerPageRTL,
    readStore: () => user.reader.pageRTL,
    writeFacade: user.setReaderPageRTL,
    writeStore: user.reader.setPageRTL,
  );
  testSharedSetting(
    key: 'reader_page_vertical',
    initial: false,
    changed: true,
    readFacade: () => user.readerPageVertical,
    readStore: () => user.reader.pageVertical,
    writeFacade: user.setReaderPageVertical,
    writeStore: user.reader.setPageVertical,
  );
  testSharedSetting(
    key: 'reader_dimming',
    initial: 0.3,
    changed: 0.7,
    readFacade: () => user.readerDimming,
    readStore: () => user.reader.dimming,
    writeFacade: user.setReaderDimming,
    writeStore: user.reader.setDimming,
  );
  testSharedSetting(
    key: 'reader_auto_scroll_enabled',
    initial: false,
    changed: true,
    readFacade: () => user.readerAutoScrollEnabled,
    readStore: () => user.reader.autoScrollEnabled,
    writeFacade: user.setReaderAutoScrollEnabled,
    writeStore: user.reader.setAutoScrollEnabled,
  );
  testSharedSetting(
    key: 'reader_auto_scroll_pause',
    initial: 3.0,
    changed: 4.0,
    readFacade: () => user.readerAutoScrollPause,
    readStore: () => user.reader.autoScrollPause,
    writeFacade: user.setReaderAutoScrollPause,
    writeStore: user.reader.setAutoScrollPause,
  );
  testSharedSetting(
    key: 'reader_auto_scroll_resume',
    initial: false,
    changed: true,
    readFacade: () => user.readerAutoScrollResume,
    readStore: () => user.reader.autoScrollResume,
    writeFacade: user.setReaderAutoScrollResume,
    writeStore: user.reader.setAutoScrollResume,
  );
  testSharedSetting(
    key: 'reader_auto_scroll_resume_delay',
    initial: 2.0,
    changed: 3.0,
    readFacade: () => user.readerAutoScrollResumeDelay,
    readStore: () => user.reader.autoScrollResumeDelay,
    writeFacade: user.setReaderAutoScrollResumeDelay,
    writeStore: user.reader.setAutoScrollResumeDelay,
  );
  testSharedSetting(
    key: 'reader_auto_scroll_distance',
    initial: 0.8,
    changed: 0.5,
    readFacade: () => user.readerAutoScrollDistance,
    readStore: () => user.reader.autoScrollDistance,
    writeFacade: user.setReaderAutoScrollDistance,
    writeStore: user.reader.setAutoScrollDistance,
  );
  testSharedSetting(
    key: 'reader_continuous_reading',
    initial: true,
    changed: false,
    readFacade: () => user.readerContinuousReading,
    readStore: () => user.reader.continuousReading,
    writeFacade: user.setReaderContinuousReading,
    writeStore: user.reader.setContinuousReading,
  );
  testSharedSetting(
    key: 'image_viewer_auto_rotate_landscape',
    initial: false,
    changed: true,
    readFacade: () => user.imageViewerAutoRotateLandscape,
    readStore: () => user.reader.viewerAutoRotateLandscape,
    writeFacade: user.setImageViewerAutoRotateLandscape,
    writeStore: user.reader.setViewerAutoRotateLandscape,
    skipsSameValue: true,
  );
  testSharedSetting(
    key: 'image_viewer_landscape_rotation',
    initial: 1,
    changed: -1,
    readFacade: () => user.imageViewerLandscapeRotation,
    readStore: () => user.reader.viewerLandscapeRotation,
    writeFacade: user.setImageViewerLandscapeRotation,
    writeStore: user.reader.setViewerLandscapeRotation,
    skipsSameValue: true,
  );
  testSharedSetting(
    key: 'image_load_timeout',
    initial: 15,
    changed: 30,
    readFacade: () => user.imageLoadTimeout,
    readStore: () => user.reader.imageLoadTimeout,
    writeFacade: user.setImageLoadTimeout,
    writeStore: user.reader.setImageLoadTimeout,
  );
  testSharedSetting(
    key: 'image_retry_count',
    initial: 1,
    changed: 3,
    readFacade: () => user.imageRetryCount,
    readStore: () => user.reader.imageRetryCount,
    writeFacade: user.setImageRetryCount,
    writeStore: user.reader.setImageRetryCount,
  );

  for (final values in [
    (
      pause: 0.1,
      delay: 0.1,
      distance: 0.1,
      expectedPause: 0.5,
      expectedDelay: 1.0,
      expectedDistance: 0.2,
    ),
    (
      pause: 20.0,
      delay: 20.0,
      distance: 2.0,
      expectedPause: 8.0,
      expectedDelay: 5.0,
      expectedDistance: 1.0,
    ),
  ]) {
    test(
      'auto-scroll limits apply on reload, not on write: ${values.pause}',
      () async {
        await user.setReaderAutoScrollPause(values.pause);
        await user.reader.setAutoScrollResumeDelay(values.delay);
        await user.setReaderAutoScrollDistance(values.distance);
        expect(user.readerAutoScrollPause, values.pause);
        expect(user.readerAutoScrollResumeDelay, values.delay);
        expect(user.readerAutoScrollDistance, values.distance);

        await user.init(persistMigrations: false);
        expect(user.readerAutoScrollPause, values.expectedPause);
        expect(user.reader.autoScrollPause, values.expectedPause);
        expect(user.readerAutoScrollResumeDelay, values.expectedDelay);
        expect(user.reader.autoScrollResumeDelay, values.expectedDelay);
        expect(user.readerAutoScrollDistance, values.expectedDistance);
        expect(user.reader.autoScrollDistance, values.expectedDistance);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getDouble('reader_auto_scroll_pause'), values.pause);
        expect(
          prefs.getDouble('reader_auto_scroll_resume_delay'),
          values.delay,
        );
        expect(prefs.getDouble('reader_auto_scroll_distance'), values.distance);
      },
    );
  }

  test(
    'viewer rotation normalizes through both paths and skips unchanged direction',
    () async {
      await user.setImageViewerLandscapeRotation(-90);
      expect(user.reader.viewerLandscapeRotation, -1);
      var notifications = 0;
      void listener() => notifications++;
      user.addListener(listener);
      addTearDown(() => user.removeListener(listener));

      await user.reader.setViewerLandscapeRotation(-180);
      expect(user.imageViewerLandscapeRotation, -1);
      expect(notifications, 0);
      await user.reader.setViewerLandscapeRotation(0);
      expect(user.imageViewerLandscapeRotation, 1);
      expect(notifications, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('image_viewer_landscape_rotation'), 1);
    },
  );

  test(
    'reader re-init binds subsequent writes to the new prefs backend',
    () async {
      final oldPrefs = await SharedPreferences.getInstance();
      await user.reader.setVolumeKey(false);
      await user.reader.setImageGap(8.0);
      await user.reader.setImageRetryCount(3);

      SharedPreferences.setMockInitialValues({});
      await user.init(persistMigrations: false);
      final newPrefs = await SharedPreferences.getInstance();
      await user.reader.setVolumeKey(false);
      await user.reader.setImageGap(8.0);
      await user.reader.setImageRetryCount(3);
      expect(newPrefs.getBool('reader_volume_key'), isFalse);
      expect(newPrefs.getDouble('reader_image_gap'), 8.0);
      expect(newPrefs.getInt('image_retry_count'), 3);

      await user.setReaderVolumeKey(true);
      await user.setReaderImageGap(4.0);
      await user.setImageRetryCount(2);
      expect(newPrefs.getBool('reader_volume_key'), isTrue);
      expect(newPrefs.getDouble('reader_image_gap'), 4.0);
      expect(newPrefs.getInt('image_retry_count'), 2);
      expect(oldPrefs.getBool('reader_volume_key'), isFalse);
      expect(oldPrefs.getDouble('reader_image_gap'), 8.0);
      expect(oldPrefs.getInt('image_retry_count'), 3);
    },
  );
}
