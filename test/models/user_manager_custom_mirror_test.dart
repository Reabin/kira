import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserManager user;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    user = UserManager();
    // 单例可能携带上次测试的内存态；清掉镜像相关键后再 init 复位。
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('update_mirror_custom_prefixes');
    await prefs.remove('update_mirror_prefix');
    await user.init();
  });

  group('addCustomUpdateMirrorPrefix', () {
    test('规范化（去空白 + 补尾斜杠）并持久化', () async {
      expect(
        await user.addCustomUpdateMirrorPrefix(' https://mirror.example '),
        isTrue,
      );
      expect(
        await user.addCustomUpdateMirrorPrefix('http://mirror.example:8080'),
        isTrue,
      );
      expect(user.customUpdateMirrorPrefixes, [
        'https://mirror.example/',
        'http://mirror.example:8080/',
      ]);

      await user.init();
      expect(user.customUpdateMirrorPrefixes, [
        'https://mirror.example/',
        'http://mirror.example:8080/',
      ]);
    });

    test('空值与非法地址不入选（会被折成内置默认）', () async {
      expect(await user.addCustomUpdateMirrorPrefix(''), isFalse);
      expect(await user.addCustomUpdateMirrorPrefix('   '), isFalse);
      expect(await user.addCustomUpdateMirrorPrefix('not a url'), isFalse);
      expect(user.customUpdateMirrorPrefixes, isEmpty);
    });

    test('与内置项或已有自定义项重复返回 false', () async {
      expect(
        await user.addCustomUpdateMirrorPrefix(
          UserManager.defaultUpdateMirrorPrefix,
        ),
        isFalse,
      );
      expect(
        await user.addCustomUpdateMirrorPrefix('https://mirror.example'),
        isTrue,
      );
      expect(
        await user.addCustomUpdateMirrorPrefix(' https://mirror.example/ '),
        isFalse,
      );
      expect(user.customUpdateMirrorPrefixes, ['https://mirror.example/']);
    });
  });

  group('removeCustomUpdateMirrorPrefix', () {
    test('删除指定项并持久化', () async {
      await user.addCustomUpdateMirrorPrefix('https://a.example');
      await user.addCustomUpdateMirrorPrefix('https://b.example');

      await user.removeCustomUpdateMirrorPrefix('https://a.example/');
      expect(user.customUpdateMirrorPrefixes, ['https://b.example/']);

      await user.init();
      expect(user.customUpdateMirrorPrefixes, ['https://b.example/']);
    });

    test('删除当前启用的自定义项时回落到内置默认，且不复活', () async {
      await user.addCustomUpdateMirrorPrefix('https://mirror.example');
      await user.setUpdateMirrorPrefix('https://mirror.example');
      expect(user.updateMirrorPrefix, 'https://mirror.example/');

      await user.removeCustomUpdateMirrorPrefix('https://mirror.example/');
      expect(user.updateMirrorPrefix, UserManager.defaultUpdateMirrorPrefix);
      expect(user.customUpdateMirrorPrefixes, isEmpty);

      await user.init();
      expect(user.updateMirrorPrefix, UserManager.defaultUpdateMirrorPrefix);
      expect(user.customUpdateMirrorPrefixes, isEmpty);
    });
  });

  group('切换镜像源不丢自定义项', () {
    test('切到内置项后自定义项仍留在列表里', () async {
      await user.addCustomUpdateMirrorPrefix('https://mirror.example');
      await user.setUpdateMirrorPrefix('https://mirror.example');

      await user.setUpdateMirrorPrefix(UserManager.defaultUpdateMirrorPrefix);
      expect(user.updateMirrorPrefix, UserManager.defaultUpdateMirrorPrefix);
      expect(user.customUpdateMirrorPrefixes, ['https://mirror.example/']);

      await user.init();
      expect(user.customUpdateMirrorPrefixes, ['https://mirror.example/']);
    });
  });

  group('init 清洗与迁移', () {
    test('持久化列表去重、与内置重复项丢弃，并回写规范化结果', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('update_mirror_custom_prefixes', [
        'https://a.example',
        ' https://a.example ', // 规范化后重复
        'https://gh-proxy.org/', // 与内置重复
        'not a url', // 非法，折成默认后同样命中内置项
      ]);
      await user.init();

      expect(user.customUpdateMirrorPrefixes, ['https://a.example/']);
      expect(prefs.getStringList('update_mirror_custom_prefixes'), [
        'https://a.example/',
      ]);
    });

    test('只存在于 update_mirror_prefix 的旧值与列表合并并落盘', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('update_mirror_prefix', 'https://old.example');
      await prefs.setStringList('update_mirror_custom_prefixes', [
        'https://a.example',
      ]);
      await user.init();

      expect(user.updateMirrorPrefix, 'https://old.example/');
      expect(user.customUpdateMirrorPrefixes, [
        'https://a.example/',
        'https://old.example/',
      ]);
      expect(prefs.getStringList('update_mirror_custom_prefixes'), [
        'https://a.example/',
        'https://old.example/',
      ]);

      // 并入的那条可删除；删除后回落默认，重启不复活。
      await user.removeCustomUpdateMirrorPrefix('https://old.example');
      expect(user.updateMirrorPrefix, UserManager.defaultUpdateMirrorPrefix);
      await user.init();
      expect(user.customUpdateMirrorPrefixes, ['https://a.example/']);
    });

    test('只读重载（persistMigrations: false）不写回 prefs', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('update_mirror_custom_prefixes', [
        'https://a.example',
      ]);
      await prefs.setString('update_mirror_prefix', 'https://old.example');
      await user.init(persistMigrations: false);

      // 内存里仍是规范化后的合并结果，但磁盘上保持原样。
      expect(user.customUpdateMirrorPrefixes, [
        'https://a.example/',
        'https://old.example/',
      ]);
      expect(prefs.getStringList('update_mirror_custom_prefixes'), [
        'https://a.example',
      ]);
    });
  });

  group('updateMirrorFallbackChain', () {
    test('自定义项排在内置项之后，重复项只保留一次', () {
      expect(
        UserManager.updateMirrorFallbackChain('https://my.mirror', [
          'https://a.example/',
          'https://ghproxy.net/', // 与内置重复
        ]),
        [
          'https://my.mirror/',
          UserManager.defaultUpdateMirrorPrefix,
          'https://ghproxy.net/',
          'https://a.example/',
        ],
      );
    });
  });
}
