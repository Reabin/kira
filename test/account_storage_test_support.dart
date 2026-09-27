import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/secure_credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FailingAccountSecureStore extends InMemorySecureCredentialStore {
  String? failKey;
  String? failValue;
  bool failAllWrites = false;
  Future<void> Function(String key, String value)? beforeWrite;

  @override
  Future<void> doWrite(String key, String value) async {
    await beforeWrite?.call(key, value);
    await super.doWrite(key, value);
    if (failAllWrites || (failKey == key && failValue == value)) {
      failKey = null;
      throw StateError('Injected secure write failure');
    }
  }
}

/// Exercise real SharedPreferences caching and success flags over a fake
/// platform channel, instead of mocking BackupPreferences itself.
class AccountPreferencesPlatform {
  static const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final values = <String, Object>{};
  String? failKey;
  Object? failValue;
  bool throwOnFailure = false;

  void install() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getAll') return Map.of(values);
          final arguments = call.arguments;
          if (arguments is! Map) {
            throw StateError('Missing preference arguments');
          }
          final key = arguments['key'];
          if (key is! String) throw StateError('Missing preference key');
          if (call.method == 'remove') {
            values.remove(key);
            return true;
          }
          if (call.method.startsWith('set')) {
            final value = arguments['value'];
            if (key == 'flutter.$failKey' && value == failValue) {
              failKey = null;
              if (throwOnFailure) throw PlatformException(code: 'injected');
              return false;
            }
            if (value != null) values[key] = value;
            return true;
          }
          throw StateError('Unexpected preference method: ${call.method}');
        });
  }

  void dispose() {
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}
