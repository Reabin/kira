/// API 返回的章节名常自带卷名前缀（如「第一卷 序」），目录与书签里
/// 与卷名拼接会得到「第一卷 · 第一卷 序」。这里只在展示层去重：
/// 前缀与卷名一致（含两侧空白差异）时去掉，其余场景一律保留原名，
/// 不修改任何原始数据或跳转索引。
String stripVolumePrefix(String chapterName, String volumeName) {
  final chapter = chapterName.trim();
  final volume = volumeName.trim();
  if (chapter.isEmpty || volume.isEmpty) return chapterName;
  if (chapter == volume) return chapter;
  if (chapter.length > volume.length &&
      chapter.startsWith(volume) &&
      _isSeparator(chapter.codeUnitAt(volume.length))) {
    return chapter.substring(volume.length).trim();
  }
  if (volume.length > chapter.length &&
      volume.startsWith(chapter) &&
      _isSeparator(volume.codeUnitAt(chapter.length))) {
    // 卷名本身以章节名开头（少见）：保持章节名，不再重复拼接。
    return chapter;
  }
  return chapterName.trim();
}

bool _isSeparator(int codeUnit) {
  final unit = String.fromCharCode(codeUnit);
  return unit.trim().isEmpty || unit == '·' || unit == '・' || unit == '：';
}
