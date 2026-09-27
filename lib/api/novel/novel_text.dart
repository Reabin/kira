import 'dart:convert';

import 'package:charset/charset.dart' show gbk;

import '../../models/novel.dart';

/// The server's txt_encoding, not the CDN's Content-Type, determines encoding.
class NovelText {
  const NovelText._();

  static String decode(List<int> bytes, String encoding) {
    final normalized = encoding.trim().toLowerCase().replaceAll('-', '');
    final String text;
    switch (normalized) {
      case 'utf8':
        text = utf8.decode(bytes);
      case 'gbk':
      case 'gb2312':
      case 'cp936':
        text = gbk.decode(bytes);
      default:
        throw const FormatException('不支持的正文编码');
    }
    // A BOM is not a line or paragraph, but all other whitespace is content.
    return text.isNotEmpty && text.codeUnitAt(0) == 0xfeff
        ? text.substring(1)
        : text;
  }

  static NovelVolumeContent parse(NovelVolumeDetail detail, String text) {
    // split (unlike LineSplitter) preserves leading/trailing empty lines.
    final lines = text.split(RegExp(r'\r\n|\n|\r'));
    final entries = <NovelReaderEntry>[];
    for (final (index, entry) in detail.volume.contents.indexed) {
      var paragraphs = const <String>[];
      if (entry.isText) {
        final start = entry.startLines;
        final end = entry.endLines;
        if (start < 0 || end < start || end > lines.length) {
          throw FormatException('正文目录行号超出范围（条目 $index）');
        }
        paragraphs = List<String>.unmodifiable(lines.sublist(start, end));
      }
      // Images remain separate entries, in the original contents order.
      entries.add(
        NovelReaderEntry(
          entryIndex: index,
          entry: entry,
          paragraphs: paragraphs,
        ),
      );
    }
    return NovelVolumeContent(
      detail: detail,
      entries: List<NovelReaderEntry>.unmodifiable(entries),
    );
  }
}
