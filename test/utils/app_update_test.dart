import 'package:flutter_test/flutter_test.dart';
import 'package:kira/models/user_manager.dart';
import 'package:kira/utils/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The update decision must be platform-scoped: a release without an
/// installable asset for the running platform (e.g. APK-only checked from
/// Windows) must never surface as an update.
void main() {
  ReleaseAsset asset(
    String name, {
    required AssetPlatform platform,
    List<int>? versionParts,
  }) {
    return ReleaseAsset(
      name: name,
      downloadUrl: 'https://example.com/$name',
      mirrorUrl: 'https://mirror.example.com/$name',
      size: 1024,
      platform: platform,
      createdAt: DateTime.utc(2026),
      versionParts: versionParts ?? const [],
    );
  }

  group('buildStableUpdateInfo', () {
    const base = (
      tagName: 'v1.5.0',
      releaseName: 'App v1.5.0',
      notes: 'notes',
      pageUrl: 'https://github.com/caolib/kira/releases/tag/v1.5.0',
    );

    AppUpdateInfo? check({
      required String currentVersion,
      required List<ReleaseAsset> assets,
      AssetPlatform platform = AssetPlatform.windows,
      String? skippedVersion,
    }) {
      return AppUpdateService.buildStableUpdateInfo(
        currentVersion: currentVersion,
        tagName: base.tagName,
        releaseName: base.releaseName,
        releaseNotes: base.notes,
        releasePageUrl: base.pageUrl,
        assets: assets,
        currentPlatform: platform,
        skippedVersion: skippedVersion,
      );
    }

    test('newer release with no asset for the platform is not an update', () {
      final info = check(
        currentVersion: '1.4.0',
        assets: [
          asset('kira-v1.5.0-arm64-v8a.apk', platform: AssetPlatform.android),
        ],
      );
      expect(info, isNotNull);
      expect(info!.noAssetForPlatform, isTrue);
      expect(info.isCurrentVersion, isFalse);
      expect(info.latestVersion, '1.5.0');
    });

    test(
      'newer release with a platform asset is an update, platform first',
      () {
        final info = check(
          currentVersion: '1.4.0',
          assets: [
            asset('kira-v1.5.0-arm64-v8a.apk', platform: AssetPlatform.android),
            asset('kira-v1.5.0-windows.exe', platform: AssetPlatform.windows),
          ],
        );
        expect(info, isNotNull);
        expect(info!.noAssetForPlatform, isFalse);
        expect(info.assets.first.platform, AssetPlatform.windows);
      },
    );

    test('tag equal to installed version reports current version', () {
      final info = check(
        currentVersion: '1.5.0',
        assets: [
          asset('kira-v1.5.0-windows.exe', platform: AssetPlatform.windows),
        ],
      );
      expect(info, isNotNull);
      expect(info!.isCurrentVersion, isTrue);
      expect(info.noAssetForPlatform, isFalse);
    });

    test('skipped version suppresses the update', () {
      final info = check(
        currentVersion: '1.4.0',
        assets: [
          asset('kira-v1.5.0-windows.exe', platform: AssetPlatform.windows),
        ],
        skippedVersion: '1.5.0',
      );
      expect(info, isNull);
    });

    test('empty tag yields nothing', () {
      final info = AppUpdateService.buildStableUpdateInfo(
        currentVersion: '1.4.0',
        tagName: '  ',
        releaseName: '',
        releaseNotes: '',
        releasePageUrl: '',
        assets: [
          asset('kira-v1.5.0-windows.exe', platform: AssetPlatform.windows),
        ],
        currentPlatform: AssetPlatform.windows,
      );
      expect(info, isNull);
    });
  });

  group('buildBetaUpdateInfo', () {
    const tagName = 'CI';

    AppUpdateInfo? check({
      required String currentBuildNumber,
      required List<ReleaseAsset> assets,
      AssetPlatform platform = AssetPlatform.windows,
    }) {
      return AppUpdateService.buildBetaUpdateInfo(
        currentVersion: '1.3.2',
        currentBuildNumber: currentBuildNumber,
        tagName: tagName,
        releaseName: 'CI APK',
        releaseNotes: '',
        releasePageUrl: '',
        assets: assets,
        currentPlatform: platform,
      );
    }

    test(
      'a newer APK build does not prompt a Windows install (regression)',
      () {
        final info = check(
          currentBuildNumber: '370',
          assets: [
            asset(
              'kira-1.3.2+371-arm64-v8a.apk',
              platform: AssetPlatform.android,
              versionParts: [1, 3, 2, 371],
            ),
            asset(
              'kira-1.3.1+368-windows.exe',
              platform: AssetPlatform.windows,
              versionParts: [1, 3, 1, 368],
            ),
          ],
        );
        expect(info, isNotNull);
        expect(info!.isCurrentVersion, isTrue);
        expect(info.noAssetForPlatform, isFalse);
      },
    );

    test('newer platform build is an update, platform asset first', () {
      final info = check(
        currentBuildNumber: '370',
        assets: [
          asset(
            'kira-1.3.2+372-arm64-v8a.apk',
            platform: AssetPlatform.android,
            versionParts: [1, 3, 2, 372],
          ),
          asset(
            'kira-1.3.3+371-windows.exe',
            platform: AssetPlatform.windows,
            versionParts: [1, 3, 3, 371],
          ),
        ],
      );
      expect(info, isNotNull);
      expect(info!.isCurrentVersion, isFalse);
      expect(info.isBetaChannel, isTrue);
      expect(info.assets.first.platform, AssetPlatform.windows);
    });

    test('repeated checks keep an uninstalled newer build available', () {
      final assets = [
        asset(
          'kira-1.3.3+371-windows.exe',
          platform: AssetPlatform.windows,
          versionParts: [1, 3, 3, 371],
        ),
      ];
      final first = check(currentBuildNumber: '370', assets: assets);
      final second = check(currentBuildNumber: '370', assets: assets);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!.isCurrentVersion, isFalse);
      expect(second!.isCurrentVersion, isFalse);
    });

    test('installed latest build reports current version', () {
      final info = check(
        currentBuildNumber: '371',
        assets: [
          asset(
            'kira-1.3.3+371-windows.exe',
            platform: AssetPlatform.windows,
            versionParts: [1, 3, 3, 371],
          ),
        ],
      );
      expect(info, isNotNull);
      expect(info!.isCurrentVersion, isTrue);
    });

    test('newer non-platform assets do not affect the selected build', () {
      final info = check(
        currentBuildNumber: '370',
        assets: [
          asset(
            'kira-1.3.3+371-windows.exe',
            platform: AssetPlatform.windows,
            versionParts: [1, 3, 3, 371],
          ),
          asset(
            'kira-1.3.3+372-arm64-v8a.apk',
            platform: AssetPlatform.android,
            versionParts: [1, 3, 3, 372],
          ),
        ],
      );
      expect(info, isNotNull);
      expect(info!.assets.first.name, 'kira-1.3.3+371-windows.exe');
    });

    test('no platform asset at all is not an update', () {
      final info = check(
        currentBuildNumber: '370',
        assets: [
          asset(
            'kira-1.3.3+371-arm64-v8a.apk',
            platform: AssetPlatform.android,
            versionParts: [1, 3, 3, 371],
          ),
        ],
      );
      expect(info, isNotNull);
      expect(info!.noAssetForPlatform, isTrue);
      expect(info.isBetaChannel, isTrue);
    });
  });

  group('downloadCandidates', () {
    final apk = asset(
      'kira-1.5.0-arm64-v8a.apk',
      platform: AssetPlatform.android,
    );

    test('direct download when the mirror checkbox is off', () {
      expect(InAppInstaller.downloadCandidates(apk, useMirror: false), [
        'https://example.com/kira-1.5.0-arm64-v8a.apk',
      ]);
    });

    test('mirror chain falls back through mirrors then the direct URL', () {
      // 未 init 的 UserManager 用默认前缀（gh-proxy.org），
      // 顺序应为：默认镜像 → 备选镜像 → GitHub 直链。
      expect(InAppInstaller.downloadCandidates(apk, useMirror: true), [
        'https://gh-proxy.org/https://example.com/kira-1.5.0-arm64-v8a.apk',
        'https://ghproxy.net/https://example.com/kira-1.5.0-arm64-v8a.apk',
        'https://example.com/kira-1.5.0-arm64-v8a.apk',
      ]);
    });

    test('custom mirrors join the chain before the direct URL', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final user = UserManager();
      await user.init();
      await user.addCustomUpdateMirrorPrefix('https://my.mirror');
      await user.setUpdateMirrorPrefix('https://my.mirror');
      addTearDown(() async {
        await user.removeCustomUpdateMirrorPrefix('https://my.mirror');
        await user.setUpdateMirrorPrefix(UserManager.defaultUpdateMirrorPrefix);
      });

      expect(InAppInstaller.downloadCandidates(apk, useMirror: true), [
        'https://my.mirror/https://example.com/kira-1.5.0-arm64-v8a.apk',
        'https://gh-proxy.org/https://example.com/kira-1.5.0-arm64-v8a.apk',
        'https://ghproxy.net/https://example.com/kira-1.5.0-arm64-v8a.apk',
        'https://example.com/kira-1.5.0-arm64-v8a.apk',
      ]);
    });
  });
}
