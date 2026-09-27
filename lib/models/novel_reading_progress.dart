import '../utils/json_helpers.dart';

/// 轻小说的本地阅读位置，不依赖 API 模型，也不保存屏幕像素偏移。
class NovelReadingProgress {
  const NovelReadingProgress({
    required this.pathWord,
    required this.name,
    required this.cover,
    required this.volumeId,
    required this.volumeName,
    required this.chapterName,
    required this.updatedAt,
    int entryIndex = 0,
    int paragraphIndex = 0,
    double paragraphAlignment = 0,
    double progress = 0,
    this.txtAddr = '',
    this.readVolumeIds = const {},
  }) : entryIndex = entryIndex < 0 ? 0 : entryIndex,
       paragraphIndex = paragraphIndex < 0 ? 0 : paragraphIndex,
       paragraphAlignment =
           paragraphAlignment > double.negativeInfinity &&
               paragraphAlignment < double.infinity
           ? paragraphAlignment
           : 0,
       progress = progress != progress
           ? 0
           : progress < 0
           ? 0
           : progress > 1
           ? 1
           : progress;

  final String pathWord;
  final String name;
  final String cover;
  final String volumeId;
  final String volumeName;

  /// 单卷 contents 中的原始索引，插图也占一个 entry；不能使用过滤后索引。
  final int entryIndex;
  final String chapterName;
  final int paragraphIndex;

  /// 段落 leadingEdge 相对视口的比例。长段落顶部可在视口外，允许负值。
  final double paragraphAlignment;
  final double progress;
  final DateTime updatedAt;

  /// 可用于检查单卷文本版本；旧记录缺省为空，不获取该地址的内容。
  final String txtAddr;

  /// 读过的卷 id 集合，详情页据此淡化已读章节卡片；旧记录缺省为空集。
  final Set<String> readVolumeIds;

  factory NovelReadingProgress.fromJson(Map<String, dynamic> json) {
    final pathWord = jsonString(json, 'pathWord');
    final volumeId = jsonString(json, 'volumeId');
    final updatedAt = DateTime.tryParse(jsonString(json, 'updatedAt'));
    if (json['pathWord'] is! String ||
        json['volumeId'] is! String ||
        pathWord.trim().isEmpty ||
        volumeId.trim().isEmpty ||
        updatedAt == null) {
      throw const FormatException(
        'Invalid novel reading progress identity/date',
      );
    }

    return NovelReadingProgress(
      pathWord: pathWord,
      name: jsonString(json, 'name'),
      cover: jsonString(json, 'cover'),
      volumeId: volumeId,
      volumeName: jsonString(json, 'volumeName'),
      entryIndex: jsonInt(json, 'entryIndex'),
      chapterName: jsonString(json, 'chapterName'),
      paragraphIndex: jsonInt(json, 'paragraphIndex'),
      paragraphAlignment: jsonDouble(json, 'paragraphAlignment'),
      progress: jsonDouble(json, 'progress'),
      updatedAt: updatedAt,
      txtAddr: jsonString(json, 'txtAddr'),
      readVolumeIds: jsonList(
        json,
        'readVolumeIds',
      ).whereType<String>().toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
    'pathWord': pathWord,
    'name': name,
    'cover': cover,
    'volumeId': volumeId,
    'volumeName': volumeName,
    'entryIndex': entryIndex,
    'chapterName': chapterName,
    'paragraphIndex': paragraphIndex,
    'paragraphAlignment': paragraphAlignment,
    'progress': progress,
    'updatedAt': updatedAt.toIso8601String(),
    'txtAddr': txtAddr,
    'readVolumeIds': readVolumeIds.toList(),
  };

  NovelReadingProgress copyWith({
    String? pathWord,
    String? name,
    String? cover,
    String? volumeId,
    String? volumeName,
    int? entryIndex,
    String? chapterName,
    int? paragraphIndex,
    double? paragraphAlignment,
    double? progress,
    DateTime? updatedAt,
    String? txtAddr,
    Set<String>? readVolumeIds,
  }) => NovelReadingProgress(
    pathWord: pathWord ?? this.pathWord,
    name: name ?? this.name,
    cover: cover ?? this.cover,
    volumeId: volumeId ?? this.volumeId,
    volumeName: volumeName ?? this.volumeName,
    entryIndex: entryIndex ?? this.entryIndex,
    chapterName: chapterName ?? this.chapterName,
    paragraphIndex: paragraphIndex ?? this.paragraphIndex,
    paragraphAlignment: paragraphAlignment ?? this.paragraphAlignment,
    progress: progress ?? this.progress,
    updatedAt: updatedAt ?? this.updatedAt,
    txtAddr: txtAddr ?? this.txtAddr,
    readVolumeIds: readVolumeIds ?? this.readVolumeIds,
  );
}
