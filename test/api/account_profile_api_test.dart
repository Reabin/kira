import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/api/api_transport.dart';
import 'package:kira/api/user/user_api.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/data_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Future<ResponseBody> Function(RequestOptions)? respond;
  var closeCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final responder = respond;
    if (responder != null) return responder(options);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 200,
        'results': {'user_id': 'clicked-id', 'username': 'clicked-user'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) => closeCount++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Dio primary;
  late Dio comment;
  late _Adapter primaryAdapter;
  late _Adapter profileAdapter;
  late _Adapter copyProfileAdapter;
  late UserApi api;

  setUp(() async {
    setupSecureCredentialStoreForTest();
    SharedPreferences.setMockInitialValues({
      'user_token': 'current-token',
      'user_username': 'current-user',
      'login_source': 'hotmanga',
      'auto_login': true,
    });
    await UserManager().init();
    primaryAdapter = _Adapter();
    profileAdapter = _Adapter();
    copyProfileAdapter = _Adapter();
    primary = Dio()..httpClientAdapter = primaryAdapter;
    comment = Dio()..httpClientAdapter = primaryAdapter;
    api = UserApi(
      ApiTransport(
        dio: primary,
        commentDio: comment,
        user: UserManager(),
        cache: DataCache(),
      ),
      profileDioFactory: (options) =>
          Dio(options)..httpClientAdapter = profileAdapter,
      copyProfileDioFactory: (options) =>
          Dio(options)..httpClientAdapter = copyProfileAdapter,
    );
  });

  tearDown(() {
    primary.close();
    comment.close();
    teardownSecureCredentialStoreForTest();
  });

  test('HOT profile uses exact clicked token on an isolated client', () async {
    final profile = await api.getCredentialInfo(
      token: 'clicked-token',
      source: 'hotmanga',
    );
    expect(profile['username'], 'clicked-user');
    expect(primaryAdapter.requests, isEmpty);
    expect(profileAdapter.requests, hasLength(1));
    final request = profileAdapter.requests.single;
    expect(request.uri.path, '/api/v3/member/info');
    expect(routes.expand((route) => route), contains(request.uri.host));
    expect(request.headers['Authorization'], 'Token clicked-token');
    expect(request.headers['Cookie'], isNull);
    expect(request.followRedirects, isFalse);
    expect(UserManager().token, 'current-token');
  });

  test(
    'COPY profile uses its configured host and profile-specific headers',
    () async {
      await UserManager().setCopyApiHost('copy-profile.test');
      final profile = await api.getCredentialInfo(
        token: 'copy-token',
        source: 'copy',
      );
      expect(profile['user_id'], 'clicked-id');
      expect(primaryAdapter.requests, isEmpty);
      expect(profileAdapter.requests, isEmpty);
      expect(copyProfileAdapter.requests, hasLength(1));
      final request = copyProfileAdapter.requests.single;
      expect(request.uri.host, 'copy-profile.test');
      expect(request.uri.path, '/api/v3/member/info');
      expect(request.method, 'GET');
      expect(request.uri.queryParameters, {'platform': '3'});
      expect(request.headers['Authorization'], 'Token copy-token');
      expect(request.headers['platform'], '3');
      expect(request.headers['version'], UserManager().copyAppVersion);
      expect(
        request.headers['User-Agent'],
        'COPY/${UserManager().copyAppVersion}',
      );
      expect(request.headers['webp'], '1');
      expect(
        request.headers['Referer'],
        'com.copymanga.app-${UserManager().copyAppVersion}',
      );
      expect(request.headers['Content-Type'], contains('form-urlencoded'));
      expect(request.headers['source'], 'copyApp');
      expect(request.headers['X-Requested-With'], isNull);
      expect(request.headers['Cookie'], isNull);
      expect(request.headers['Origin'], isNull);
      expect(request.followRedirects, isFalse);
      expect(copyProfileAdapter.closeCount, 1);
      expect(UserManager().token, 'current-token');
    },
  );

  test(
    'COPY profile rejects HTTP, business and malformed success responses',
    () async {
      await UserManager().setCopyApiHost('copy-profile.test');
      for (final scenario in [
        (status: 401, data: <String, Object>{'code': 401}),
        (status: 200, data: <String, Object>{'code': 403}),
        (status: 200, data: <String, Object>{'code': 200, 'results': []}),
      ]) {
        copyProfileAdapter.respond = (_) async => ResponseBody.fromString(
          jsonEncode(scenario.data),
          scenario.status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
        await expectLater(
          api.getCopyCredentialInfo('clicked-token'),
          throwsA(isA<DioException>()),
        );
      }
      expect(copyProfileAdapter.requests, hasLength(3));
      expect(copyProfileAdapter.closeCount, 3);
    },
  );
}
