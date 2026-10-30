import 'package:flutter_test/flutter_test.dart';
import 'package:kira/utils/log_sanitizer.dart';

void main() {
  group('LogSanitizer.text', () {
    test('redacts plain key/value pairs', () {
      final cleaned = LogSanitizer.text('failed token=FAKE_TOKEN passwd:FAKE');

      expect(cleaned, isNot(contains('FAKE_TOKEN')));
      expect(cleaned, isNot(contains('FAKE')));
      expect(cleaned, contains('token=${LogSanitizer.redacted}'));
    });

    test('redacts quoted json keys', () {
      final cleaned = LogSanitizer.text(
        'body {"token":"FAKE_JSON","password":"FAKE_PW","name":"ok"}',
      );

      expect(cleaned, isNot(contains('FAKE_JSON')));
      expect(cleaned, isNot(contains('FAKE_PW')));
      expect(cleaned, contains('"name":"ok"'));
    });

    test('redacts the whole authorization value regardless of scheme', () {
      const cases = [
        'Authorization: Bearer FAKE_TOKEN',
        'authorization: Token FAKE_TOKEN',
        'Authorization: Basic FAKE_BASIC',
        'proxy-authorization=Basic FAKE_PROXY',
      ];

      for (final value in cases) {
        final cleaned = LogSanitizer.text(value);
        expect(cleaned, isNot(contains('FAKE')), reason: value);
        expect(cleaned, contains(LogSanitizer.redacted), reason: value);
      }
    });

    test('redacts the whole cookie header', () {
      final cleaned = LogSanitizer.text('Cookie: sid=FAKE_A; session=FAKE_B');

      expect(cleaned, isNot(contains('FAKE_A')));
      expect(cleaned, isNot(contains('FAKE_B')));
      expect(cleaned, contains(LogSanitizer.redacted));
    });

    test('redacts multi word and escaped values', () {
      final cleaned = LogSanitizer.text('password="FAKE ONE TWO" note="kept"');

      expect(cleaned, isNot(contains('FAKE ONE TWO')));
      expect(cleaned, contains('note="kept"'));
    });

    test('redacts camelCase and snake_case aliases', () {
      final cleaned = LogSanitizer.text(
        'apiKey=FAKE_KEY accessToken=FAKE_ACCESS user_token=FAKE_USER',
      );

      expect(cleaned, isNot(contains('FAKE_KEY')));
      expect(cleaned, isNot(contains('FAKE_ACCESS')));
      expect(cleaned, isNot(contains('FAKE_USER')));
    });

    test('strips credentials embedded in urls', () {
      final cleaned = LogSanitizer.text(
        'GET https://demo-user:FAKE_URL_PASS@example.invalid/v1/models',
      );

      expect(cleaned, isNot(contains('FAKE_URL_PASS')));
      expect(cleaned, contains('example.invalid/v1/models'));
    });

    test('keeps ordinary diagnostics and is idempotent', () {
      const raw = 'HTTP 500 GET /api/home timeout=3000';
      final once = LogSanitizer.text(raw);

      expect(once, contains('HTTP 500'));
      expect(once, contains('timeout=3000'));
      expect(LogSanitizer.text(once), once);
    });
  });

  group('LogSanitizer.context', () {
    test('redacts sensitive keys by normalized name', () {
      final sanitized = LogSanitizer.context({
        'apiKey': 'FAKE_KEY',
        'Authorization ': 'Bearer FAKE_TOKEN',
        'user_token': 'FAKE_USER',
        'screen': 'profile',
      });

      expect(sanitized['apiKey'], LogSanitizer.redacted);
      expect(sanitized['user_token'], LogSanitizer.redacted);
      expect(sanitized['screen'], 'profile');
      expect(sanitized.values.join(), isNot(contains('FAKE')));
    });

    test('redacts nested sensitive values without stringifying first', () {
      final sanitized = LogSanitizer.context({
        'payload': {
          'token': ['FAKE_A', 'FAKE_B'],
          'page': 3,
        },
      });

      expect(sanitized['payload'], contains(LogSanitizer.redacted));
      expect(sanitized['payload'], contains('page: 3'));
      expect(sanitized['payload'], isNot(contains('FAKE_A')));
      expect(sanitized['payload'], isNot(contains('FAKE_B')));
    });

    test('survives circular references and throwing toString', () {
      final circular = <String, Object?>{'name': 'loop'};
      circular['self'] = circular;

      final sanitized = LogSanitizer.context({
        'cycle': circular,
        'bad': _Bad(),
      });

      expect(sanitized['cycle'], contains('loop'));
      expect(sanitized['bad'], '_Bad');
    });

    test('truncates long values', () {
      final sanitized = LogSanitizer.context({'body': 'x' * 5000});

      expect(
        sanitized['body']!.length,
        lessThanOrEqualTo(LogSanitizer.maxContextValueLength + 3),
      );
    });
  });
}

class _Bad {
  @override
  String toString() => throw StateError('nope');
}
