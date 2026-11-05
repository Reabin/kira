import 'package:flutter/foundation.dart';

import '../utils/project_license.dart';

/// 某个包在 NOTICES 中的全部许可条目。
class PackageLicense {
  const PackageLicense(this.name, this.entries);

  final String name;
  final List<LicenseNotice> entries;
}

/// 一条许可及其覆盖的包；正文按需解析，列表页不触达。
class LicenseNotice {
  LicenseNotice(this.entry);

  final LicenseEntry entry;

  late final List<LicenseParagraph> paragraphs = entry.paragraphs.toList();
}

/// 把 `LicenseRegistry` 的扁平条目流按包名归并、按名称排序。
///
/// 同一条许可可能覆盖多个包，每个包各持一份同一 [LicenseNotice]；同一包
/// 的多条许可（主许可 + NOTICE）按原始顺序保留。Kira 自身那条 MIT 许可在
/// 页面顶部单独展示，这里剔除，避免第三方列表里重复出现「kira」。
Future<List<PackageLicense>> collectPackageLicenses(
  Stream<LicenseEntry> stream,
) async {
  final packages = <String, List<LicenseNotice>>{};
  await for (final entry in stream) {
    final notice = LicenseNotice(entry);
    final isProjectLicense =
        entry is LicenseEntryWithLineBreaks &&
        entry.text.replaceAll('\r\n', '\n').trim() == projectLicenseText;
    for (final name in entry.packages.toSet()) {
      if (name == 'kira' && isProjectLicense) continue;
      (packages[name] ??= []).add(notice);
    }
  }
  final names = packages.keys.toList()
    ..sort((a, b) {
      final order = a.toLowerCase().compareTo(b.toLowerCase());
      return order == 0 ? a.compareTo(b) : order;
    });
  return [for (final name in names) PackageLicense(name, packages[name]!)];
}

/// 按包名查找；找不到返回 null。
PackageLicense? findPackageLicense(List<PackageLicense> packages, String name) {
  for (final package in packages) {
    if (package.name == name) return package;
  }
  return null;
}
