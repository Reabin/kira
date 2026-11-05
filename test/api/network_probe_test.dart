import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_transport.dart';
import 'package:kira/api/network/network_api.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/data_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

class _Request extends Fake implements HttpClientRequest {
  bool aborted = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
}

class _Client extends Fake implements HttpClient {
  String Function(Uri)? proxy;
  String? usedRule;
  bool closed = false;
  bool fail = false;
  final request = _Request();
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    expect(method, 'HEAD');
    usedRule = proxy?.call(url);
    if (fail) throw const SocketException('Unreachable');
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setupSecureCredentialStoreForTest();
  });
  tearDown(teardownSecureCredentialStoreForTest);

  test(
    'Connectivity probe follows manual proxy and cleans up connection',
    () async {
      final user = UserManager();
      await user.init();
      await user.setManualProxy(
        host: '127.0.0.1',
        port: 7890,
        type: NetworkProxyType.http,
      );
      final api = NetworkApi(
        ApiTransport(
          dio: Dio(),
          commentDio: Dio(),
          user: user,
          cache: DataCache(),
        ),
      );
      final client = _Client();
      final result = await HttpOverrides.runZoned(
        () => api.testHostsConnectivity(['example.com']),
        createHttpClient: (_) => client,
      );
      expect(result['example.com'], isNotNull);
      expect(client.usedRule, 'PROXY 127.0.0.1:7890');
      expect(client.request.aborted, isTrue);
      expect(client.closed, isTrue);
    },
  );

  test(
    'No application proxy still runs the probe, connection failure reports null',
    () async {
      final user = UserManager();
      await user.init();
      await user.setNetworkProxyMode(NetworkProxyMode.direct);
      final api = NetworkApi(
        ApiTransport(
          dio: Dio(),
          commentDio: Dio(),
          user: user,
          cache: DataCache(),
        ),
      );
      final client = _Client()..fail = true;
      final result = await HttpOverrides.runZoned(
        () => api.testHostsConnectivity(['example.com']),
        createHttpClient: (_) => client,
      );
      expect(result['example.com'], isNull);
      expect(client.usedRule, 'DIRECT');
      expect(client.closed, isTrue);
    },
  );
}
