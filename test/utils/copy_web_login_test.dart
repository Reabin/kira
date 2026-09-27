import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/copy_web_login.dart';

void main() {
  group('parseCopyWebStorage', () {
    test('extracts a token and nested profile without guessing identity', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'token': 'storage-token',
          'userInfo':
              '{"user_id":"storage-id","username":"storage-user","nickname":"昵称","avatar":"user/cover/avatar.png"}',
        },
        'ss': <String, Object>{},
      });
      expect(credentials?.token, 'storage-token');
      expect(credentials?.userId, 'storage-id');
      expect(credentials?.username, 'storage-user');
      expect(credentials?.nickname, '昵称');
    });

    test('arbitrary hex storage values are not treated as account tokens', () {
      expect(
        parseCopyWebStorage({
          'ls': {'password_hash': '0123456789abcdef0123456789abcdef'},
        }),
        isNull,
      );
    });

    test('does not borrow a conflicting token account from the same scope', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'token': 'token-b',
          'userInfo': {
            'token': 'token-a',
            'user_id': 'id-a',
            'username': 'user-a',
            'nickname': 'name-a',
            'avatar': 'avatar-a',
          },
        },
      });
      expect(credentials?.token, 'token-b');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.username, isEmpty);
      expect(credentials?.nickname, isEmpty);
      expect(credentials?.avatar, isEmpty);
    });

    test('skips conflicting JSON subtrees and accepts matching token profiles', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'token': '"token-b"',
          'old':
              '{"token":"token-a","profile":{"user_id":"id-a","nickname":"name-a"}}',
          'current':
              '[{"token":"token-b","profile":{"user_id":"id-b","nickname":"name-b"}}]',
        },
      });
      expect(credentials?.token, 'token-b');
      expect(credentials?.userId, 'id-b');
      expect(credentials?.nickname, 'name-b');
    });

    test('does not borrow an identity from a different storage scope', () {
      final credentials = parseCopyWebStorage({
        'ls': {'token': 'unknown-token'},
        'ss': {'user_id': 'other-id'},
      });
      expect(credentials?.token, 'unknown-token');
      expect(credentials?.userId, isEmpty);
    });
  });

  group('parseCopyWebCookies', () {
    test('解析拷贝官网完整 cookie', () {
      final credentials = parseCopyWebCookies({
        'webp': '1',
        '_ga': 'GA1.1.000000000.0000000000',
        'name': '%E6%B5%8B%E8%AF%95%E7%94%A8%E6%88%B7',
        'token': 'test_token_0123456789abcdef0123456789ab',
        'user_id': '00000000-0000-0000-0000-000000000001',
        'avatar':
            '"user/cover/00000000000000000000000000000001/0000000000.jpg"',
        'email': '""',
        'csrftoken': 'test_csrf_token_0000000000000000',
        'sessionid': 'test_session_id_000000000000000000',
      });

      expect(credentials, isNotNull);
      expect(credentials!.token, 'test_token_0123456789abcdef0123456789ab');
      expect(credentials.userId, '00000000-0000-0000-0000-000000000001');
      expect(credentials.nickname, '测试用户');
      expect(
        credentials.avatar,
        'user/cover/00000000000000000000000000000001/0000000000.jpg',
      );
    });

    test('缺少 token 时返回 null（未登录）', () {
      expect(parseCopyWebCookies({'webp': '1', '_ga': 'x'}), isNull);
      expect(parseCopyWebCookies({}), isNull);
    });

    test('token 为空字符串时返回 null', () {
      expect(parseCopyWebCookies({'token': ''}), isNull);
      expect(parseCopyWebCookies({'token': '""'}), isNull);
    });

    test('可选字段缺失时回退为空字符串', () {
      final credentials = parseCopyWebCookies({'token': 'abc'});

      expect(credentials, isNotNull);
      expect(credentials!.token, 'abc');
      expect(credentials.userId, '');
      expect(credentials.nickname, '');
      expect(credentials.avatar, '');
    });

    test('name 非法编码时不影响 token 解析', () {
      final credentials = parseCopyWebCookies({
        'token': 'abc',
        'name': '%E4%B8%AD%', // 截断的编码
      });

      expect(credentials, isNotNull);
      expect(credentials!.token, 'abc');
      expect(credentials.nickname, '');
    });

    test('带引号的 token 会去引号', () {
      final credentials = parseCopyWebCookies({'token': '"abc123"'});

      expect(credentials, isNotNull);
      expect(credentials!.token, 'abc123');
    });
  });
}
