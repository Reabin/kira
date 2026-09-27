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

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Dio primary;
  late Dio comment;
  late _Adapter primaryAdapter;
  late _Adapter profileAdapter;
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
    'COPY profile never probes guessed paths or sends tokens to HOT',
    () async {
      await expectLater(
        api.getCredentialInfo(token: 'copy-token', source: 'copy'),
        throwsA(isA<CopyProfileUnavailableException>()),
      );
      expect(primaryAdapter.requests, isEmpty);
      expect(profileAdapter.requests, isEmpty);
    },
  );
}
