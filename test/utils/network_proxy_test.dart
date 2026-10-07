import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/l10n/app_localizations_zh.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/network_proxy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setupSecureCredentialStoreForTest();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    teardownSecureCredentialStoreForTest();
  });

  test(
    'iOS missing HTTP proxy reports unknown VPN status, not inactive VPN',
    () async {
      final user = UserManager();
      await user.init();
      await user.setNetworkProxyMode(NetworkProxyMode.system);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final l10n = AppLocalizationsZh();
      expect(
        NetworkProxy.activeProxyDescription(l10n),
        l10n.networkIOSManagedNetwork,
      );
      expect(
        NetworkProxy.systemProxyDescription(l10n),
        l10n.networkIOSProxyStatusUnknown,
      );
      await user.setNetworkProxyMode(NetworkProxyMode.direct);
      expect(
        NetworkProxy.activeProxyDescription(l10n),
        l10n.networkIOSDirectActive,
      );
    },
  );

  test('proxy endpoint rule does not fall back to direct connection', () {
    const httpProxy = NetworkProxyEndpoint(
      host: '127.0.0.1',
      port: 7890,
      type: NetworkProxyType.http,
    );
    const socksProxy = NetworkProxyEndpoint(
      host: '127.0.0.1',
      port: 7891,
      type: NetworkProxyType.socks,
    );

    expect(httpProxy.findProxyRule, 'PROXY 127.0.0.1:7890');
    expect(socksProxy.findProxyRule, 'SOCKS 127.0.0.1:7891');
  });

  test('manual proxy mode uses the configured proxy only', () async {
    final user = UserManager();
    await user.init();
    await user.setManualProxy(
      host: '127.0.0.1',
      port: 7890,
      type: NetworkProxyType.http,
    );

    expect(
      NetworkProxy.findProxy(Uri.parse('https://www.google.com/')),
      'PROXY 127.0.0.1:7890',
    );
  });

  test('direct proxy mode bypasses any proxy', () async {
    SharedPreferences.setMockInitialValues({
      'network_proxy_mode': NetworkProxyMode.direct.index,
      'network_proxy_host': '127.0.0.1',
      'network_proxy_port': 7890,
    });

    final user = UserManager();
    await user.init();

    expect(user.networkProxyMode, NetworkProxyMode.direct);
    expect(
      NetworkProxy.findProxy(Uri.parse('https://www.google.com/')),
      'DIRECT',
    );
  });

  test(
    'unknown persisted proxy mode falls back to system proxy mode',
    () async {
      SharedPreferences.setMockInitialValues({'network_proxy_mode': 99});

      final user = UserManager();
      await user.init();

      expect(user.networkProxyMode, NetworkProxyMode.system);
    },
  );
}
