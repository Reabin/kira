import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(teardownSecureCredentialStoreForTest);

  test(
    'comment display settings are shared through facade and sub-store',
    () async {
      final user = UserManager();
      await user.init();
      await user.setCommentShowAvatar(false);
      await user.setCommentShowUserName(false);
      await user.setCommentShowTime(false);
      expect(user.comment.showAvatar, isFalse);
      expect(user.comment.showUserName, isFalse);
      expect(user.comment.showTime, isFalse);
      await user.comment.setShowAvatar(true);
      await user.comment.setShowUserName(true);
      await user.comment.setShowTime(true);
      expect(user.commentShowAvatar, isTrue);
      expect(user.commentShowUserName, isTrue);
      expect(user.commentShowTime, isTrue);
      await user.init();
      expect(user.commentShowAvatar, isTrue);
      expect(user.commentShowUserName, isTrue);
      expect(user.commentShowTime, isTrue);
    },
  );

  test('image viewer auto-rotate settings persist', () async {
    final user = UserManager();
    await user.init();

    expect(user.imageViewerAutoRotateLandscape, isFalse);
    expect(user.imageViewerLandscapeRotation, 1);

    await user.setImageViewerAutoRotateLandscape(true);
    await user.setImageViewerLandscapeRotation(-1);
    await user.init();

    expect(user.imageViewerAutoRotateLandscape, isTrue);
    expect(user.imageViewerLandscapeRotation, -1);
  });

  test('image viewer rotation normalizes to left or right', () async {
    final user = UserManager();
    await user.init();

    await user.setImageViewerLandscapeRotation(0);
    expect(user.imageViewerLandscapeRotation, 1);

    await user.setImageViewerLandscapeRotation(-90);
    expect(user.imageViewerLandscapeRotation, -1);
  });

  test('network selection mode and fixed node persist', () async {
    final user = UserManager();
    await user.init();

    expect(user.networkSelectionMode, NetworkSelectionMode.route);

    await user.setFixedNodeHost('mapi.hotmangasd.com');
    await user.setNetworkSelectionMode(NetworkSelectionMode.fixedNode);
    await user.init();

    expect(user.networkSelectionMode, NetworkSelectionMode.fixedNode);
    expect(user.fixedNodeHost, 'mapi.hotmangasd.com');
  });

  test(
    'a persisted legacy automatic(==2) selection mode falls back to route on init',
    () async {
      // 历史版本曾持久化索引 2(automatic),该模式已删除,init 后应回落 route。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'network_selection_mode': 2,
      });
      UserManager().network.resetPrefsCache();
      var user = UserManager();
      await user.init();
      expect(user.networkSelectionMode, NetworkSelectionMode.route);

      // 模拟重启:回落后的 route 索引应被持久化,再次 init 仍是 route。
      UserManager().network.resetPrefsCache();
      user = UserManager();
      await user.init();
      expect(user.networkSelectionMode, NetworkSelectionMode.route);
    },
  );

  test('last nav key defaults to comic and persists', () async {
    final user = UserManager();
    await user.init();

    expect(user.lastNavKey, UserManager.defaultNavKey);

    await user.setLastNavKey('search');
    await user.init();

    expect(user.lastNavKey, 'search');
  });

  test('last nav key falls back to comic when saved key is invalid', () async {
    SharedPreferences.setMockInitialValues({'last_nav_key': 'missing'});

    final user = UserManager();
    await user.init();

    expect(user.lastNavKey, UserManager.defaultNavKey);
  });

  test('dark mode cover brightness defaults and persists', () async {
    final user = UserManager();
    await user.init();

    expect(
      user.darkModeCoverBrightness,
      UserManager.defaultDarkModeCoverBrightness,
    );

    await user.setDarkModeCoverBrightness(0.7);
    await user.init();

    expect(user.darkModeCoverBrightness, 0.7);
  });

  test('dark mode cover brightness allows 10 percent minimum', () async {
    final user = UserManager();
    await user.init();

    await user.setDarkModeCoverBrightness(0.1);
    expect(user.darkModeCoverBrightness, 0.1);

    await user.setDarkModeCoverBrightness(0.05);
    expect(
      user.darkModeCoverBrightness,
      UserManager.minDarkModeCoverBrightness,
    );
  });

  test('display mode refresh rate defaults to auto and persists', () async {
    final user = UserManager();
    await user.init();

    expect(
      user.displayModeRefreshRate,
      UserManager.defaultDisplayModeRefreshRate,
    );

    for (final rate in [120, 165, 0]) {
      await user.setDisplayModeRefreshRate(rate);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('pref_display_mode_refresh_rate'), rate);
      await user.init();
      expect(user.displayModeRefreshRate, rate);
    }
  });

  test('display mode refresh rate falls back to auto when invalid', () async {
    SharedPreferences.setMockInitialValues({
      'pref_display_mode_refresh_rate': -1,
    });

    final user = UserManager();
    await user.init();

    expect(
      user.displayModeRefreshRate,
      UserManager.defaultDisplayModeRefreshRate,
    );
  });

  test('update mirror prefix defaults to gh.zwy.one and persists', () async {
    final user = UserManager();
    await user.init();

    expect(UserManager.defaultUpdateMirrorPrefix, 'https://gh.zwy.one/');
    expect(UserManager.updateMirrorPrefixOptions, [
      'https://gh.zwy.one/',
      'https://ghproxy.net/',
    ]);

    // 空值回落默认，合法地址补全尾斜杠。
    expect(
      UserManager.normalizeUpdateMirrorPrefix(''),
      UserManager.defaultUpdateMirrorPrefix,
    );
    expect(
      UserManager.normalizeUpdateMirrorPrefix('https://gh.zwy.one'),
      'https://gh.zwy.one/',
    );

    await user.setUpdateMirrorPrefix('https://ghproxy.net');
    expect(user.updateMirrorPrefix, 'https://ghproxy.net/');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_mirror_prefix'), 'https://ghproxy.net/');
  });

  test('session survives a restart when secure storage was wiped and only the '
      'prefs mirror remains', () async {
    // Simulates the reported device: v1.7 moved the token out of prefs, the
    // keystore lost it, only the mirror is left. init() must restore the
    // session from the mirror and heal the secure layer.
    final store = _WipedSecureStore();
    SecureCredentialStore.setInstance(store);
    SharedPreferences.setMockInitialValues({
      'login_source': 'copy',
      'secure_mirror_user_token': 'copy-token',
    });

    final user = UserManager();
    await user.init();

    expect(user.isLoggedIn, isTrue);
    expect(user.token, 'copy-token');
    expect(store.secure['user_token'], 'copy-token');
  });
}

/// Secure layer that starts wiped: reads see nothing until something writes,
/// which is what a device with lost keystore data looks like at startup.
class _WipedSecureStore extends InMemorySecureCredentialStore {
  final secure = <String, String?>{};

  @override
  bool get mirrorEnabled => true;

  @override
  Future<String?> doRead(String key) async => secure[key];

  @override
  Future<void> doWrite(String key, String value) async {
    secure[key] = value;
  }

  @override
  Future<void> doDelete(String key) async {
    secure.remove(key);
  }
}
