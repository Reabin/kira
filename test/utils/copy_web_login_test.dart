import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/copy_web_login.dart';

void main() {
  group('parseCopyWebStorage', () {
    test('separate token and profile keys do not establish identity', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'token': 'storage-token',
          'userInfo':
              '{"user_id":"storage-id","username":"storage-user","nickname":"昵称","avatar":"user/cover/avatar.png"}',
        },
        'ss': <String, Object>{},
      });
      expect(credentials?.token, 'storage-token');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.username, isEmpty);
      expect(credentials?.nickname, isEmpty);
      expect(credentials?.avatar, isEmpty);
      expect(credentials?.profileBoundToToken, isFalse);
    });

    test('raw storage fields are not one authentication object', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'token': 'new-token',
          'user_id': 'old-id',
          'username': 'old-user',
          'nickname': 'old-name',
          'avatar': 'old-avatar',
        },
      });
      expect(credentials?.token, 'new-token');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.username, isEmpty);
      expect(credentials?.nickname, isEmpty);
      expect(credentials?.avatar, isEmpty);
      expect(credentials?.profileBoundToToken, isFalse);
    });

    test('accepts profile fields in the same JSON object as the token', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'auth':
              '{"token":"storage-token","user_id":"storage-id","username":"storage-user","nickname":"昵称","avatar":"user/cover/avatar.png"}',
        },
      });
      expect(credentials?.token, 'storage-token');
      expect(credentials?.userId, 'storage-id');
      expect(credentials?.username, 'storage-user');
      expect(credentials?.nickname, '昵称');
      expect(credentials?.avatar, 'user/cover/avatar.png');
      expect(credentials?.profileBoundToToken, isTrue);
    });

    test('h5 localStorage uses userid, not user_id', () {
      // 官网 h5 站写的是 localStorage["user"] = {"token":..,"userid":..}
      // （无下划线）。漏掉这个键名会丢掉唯一身份，同一账号每次登录（官网
      // 每次轮换 token）都被当成新账号，账号中心就堆出重复卡片。
      final credentials = parseCopyWebStorage({
        'ls': {
          'user': '{"token":"h5-token","userid":"h5-user-id"}',
        },
        'ss': {'init': 'true'},
      });
      expect(credentials?.token, 'h5-token');
      expect(credentials?.userId, 'h5-user-id');
      expect(credentials?.profileBoundToToken, isTrue);
    });

    test('accepts profile nested inside its token authentication object', () {
      final credentials = parseCopyWebStorage({
        'ss': {
          'auth':
              '{"token":"storage-token","profile":{"user_id":"storage-id","username":"storage-user"}}',
        },
      });
      expect(credentials?.token, 'storage-token');
      expect(credentials?.userId, 'storage-id');
      expect(credentials?.username, 'storage-user');
      expect(credentials?.profileBoundToToken, isTrue);
    });

    test('a profile sibling outside the token object is not associated', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'state': {
            'auth': {'token': 'new-token'},
            'profile': {'user_id': 'old-id'},
          },
        },
      });
      expect(credentials?.token, 'new-token');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.profileBoundToToken, isFalse);
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

    test('rejects conflicting account subtrees below an auth object', () {
      final credentials = parseCopyWebStorage({
        'ls': {
          'auth': {
            'token': 'token-b',
            'old': {
              'token': 'token-a',
              'profile': {'user_id': 'id-a'},
            },
          },
        },
      });
      expect(credentials?.token, 'token-b');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.profileBoundToToken, isFalse);
    });

    test('matching token selects a bound profile from the matching scope', () {
      final credentials = parseCopyWebStorage({
        'ls': {'auth': '{"token":"old-token","user_id":"old-id"}'},
        'ss': {'auth': '{"token":"new-token","user_id":"new-id"}'},
      }, matchingToken: 'new-token');
      expect(credentials?.token, 'new-token');
      expect(credentials?.userId, 'new-id');
      expect(credentials?.profileBoundToToken, isTrue);
    });

    test('matching token cannot fabricate a candidate from bare profile', () {
      expect(
        parseCopyWebStorage({
          'ls': {'profile': '{"user_id":"old-id"}'},
        }, matchingToken: 'new-token'),
        isNull,
      );
    });

    test('a scope with a conflicting current token is skipped', () {
      expect(
        parseCopyWebStorage({
          'ls': {
            'token': 'old-token',
            'auth': '{"token":"new-token","user_id":"new-id"}',
          },
        }, matchingToken: 'new-token'),
        isNull,
      );
    });

    test('token-only JSON remains a login candidate', () {
      final credentials = parseCopyWebStorage({
        'ls': {'auth': '{"token":"new-token"}'},
      });
      expect(credentials?.token, 'new-token');
      expect(credentials?.userId, isEmpty);
      expect(credentials?.username, isEmpty);
      expect(credentials?.profileBoundToToken, isFalse);
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
      expect(credentials.profileBoundToToken, isFalse);
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

  group('登录表单密码', () {
    test('用户名一致时允许写入', () {
      expect(
        canApplyLoginForm(
          accountUsername: 'user-a',
          accountNickname: 'nick-a',
          formUsername: 'user-a',
          password: 'pass-a',
        ),
        isTrue,
      );
    });

    test('官网 cookie 只有昵称时按昵称匹配', () {
      // 拷贝官网把登录名写进 cookie 的 name 字段，本机存成昵称。
      expect(
        canApplyLoginForm(
          accountUsername: '',
          accountNickname: 'user-a',
          formUsername: 'user-a',
          password: 'pass-a',
        ),
        isTrue,
      );
    });

    test('用户名和昵称都对不上时不写入', () {
      expect(
        canApplyLoginForm(
          accountUsername: 'user-a',
          accountNickname: 'nick-a',
          formUsername: 'wrong-user',
          password: 'pass-a',
        ),
        isFalse,
      );
      // 空用户名 + 空昵称同样不匹配，避免把密码写到任意账号上。
      expect(
        canApplyLoginForm(
          accountUsername: '',
          accountNickname: '',
          formUsername: 'user-a',
          password: 'pass-a',
        ),
        isFalse,
      );
    });

    test('密码或用户名缺失时不写入', () {
      expect(
        canApplyLoginForm(
          accountUsername: 'user-a',
          accountNickname: '',
          formUsername: 'user-a',
          password: '',
        ),
        isFalse,
      );
      expect(
        canApplyLoginForm(
          accountUsername: 'user-a',
          accountNickname: '',
          formUsername: '   ',
          password: 'pass-a',
        ),
        isFalse,
      );
    });
  });
}
