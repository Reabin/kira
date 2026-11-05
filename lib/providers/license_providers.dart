import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/package_license.dart';
import '../utils/app_logger.dart';

/// 许可条目流的创建器；测试通过覆盖它注入数据。
///
/// 缓存的是「如何创建流」而不是流本身：`LicenseRegistry.licenses` 返回的是
/// 单订阅流，重试或重新收集时必须新建，不能复用同一个实例。
final licenseEntryCollectorProvider = Provider<LicenseEntryCollector>(
  (ref) =>
      () => LicenseRegistry.licenses,
);

/// 按包名归并后的第三方许可。
///
/// 列表页和详情页共用同一份结果：进入详情不重新收集，返回列表也不重算；
/// 失败时 `ref.invalidate` 即可整体重试。
final packageLicensesProvider = FutureProvider<List<PackageLicense>>(
  (ref) async {
    try {
      final collect = ref.read(licenseEntryCollectorProvider);
      return await collectPackageLicenses(collect());
    } catch (error, stackTrace) {
      unawaited(
        AppLogger.instance.recordWarning(
          error,
          stackTrace: stackTrace,
          source: 'licenses',
        ),
      );
      rethrow;
    }
  },
  // 许可来自打包资源，失败多为数据损坏。Riverpod 3 默认自动退避重试会让
  // 错误一闪而过；这里保留错误态，由用户点「重试」重新收集。
  retry: (_, _) => null,
);
