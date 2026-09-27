import '../api/novel/novel_text.dart';
import '../utils/json_helpers.dart';
import 'novel.dart';

/// The original decoded TXT and its exact directory revision. Never reconstruct
/// this text from reader paragraphs: empty lines are part of the server indices.
class NovelVolumeSnapshot {
  final NovelVolumeDetail detail;
  final String text;

  const NovelVolumeSnapshot({required this.detail, required this.text});

  NovelVolumeContent get content => NovelText.parse(detail, text);

  Set<String> get imageUrls => {
    for (final entry in detail.volume.contents)
      if (entry.isImage && entry.content?.isNotEmpty == true) entry.content!,
  };

  void validate({String? pathWord, String? volumeId}) {
    if (detail.isLocked ||
        !detail.hasText ||
        detail.book.pathWord.isEmpty ||
        detail.volume.id.isEmpty ||
        (pathWord != null && detail.book.pathWord != pathWord) ||
        (volumeId != null && detail.volume.id != volumeId)) {
      throw const FormatException('小说卷快照身份或正文无效');
    }
    NovelText.parse(detail, text);
  }

  Map<String, dynamic> toJson() => {'detail': detail.toJson(), 'text': text};

  factory NovelVolumeSnapshot.fromJson(Map<String, dynamic> json) {
    final detail = jsonMap(json, 'detail');
    final text = json['text'];
    if (detail == null || text is! String) {
      throw const FormatException('小说卷快照格式无效');
    }
    final result = NovelVolumeSnapshot(
      detail: NovelVolumeDetail.fromJson(detail),
      text: text,
    );
    result.validate();
    return result;
  }
}
