import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/novel.dart';
import '../models/novel_download.dart';
import '../models/novel_volume_snapshot.dart';
import 'app_logger.dart';
import 'json_helpers.dart';

/// Durable, account-independent local books. Nothing under this root is a cache.
/// Only indexed, validated files are ever read, copied or deleted.
class NovelDownloadStore {
  static final NovelDownloadStore _instance = NovelDownloadStore._();
  factory NovelDownloadStore() => _instance;
  NovelDownloadStore._({
    Future<Directory> Function()? directory,
    this.beforeWrite,
    this.copyFile,
  }) : _directory = directory ?? _defaultDirectory;

  NovelDownloadStore.forTesting({
    required Directory rootDirectory,
    Future<void> Function(String path)? beforeWrite,
    Future<void> Function(File source, File destination)? copyFile,
  }) : this._(
         directory: () async => rootDirectory,
         beforeWrite: beforeWrite,
         copyFile: copyFile,
       );

  static const directoryName = 'novel_downloads';
  static const manifestName = 'manifest_v1.json';
  static const version = 1;
  final Future<Directory> Function() _directory;
  final Future<void> Function(String path)? beforeWrite;
  final Future<void> Function(File source, File destination)? copyFile;
  Directory? _root;
  Future<void>? _initializing;
  final _books = <String, _LocalBook>{};
  final _tails = <String, Future<void>>{};
  bool _migrating = false;
  String? manifestError;

  String? get rootPath => _root?.path;
  bool get isMigrating => _migrating;
  bool get hasManifestError => manifestError != null;
  List<LocalNovelInfo> get localNovels =>
      List.unmodifiable([for (final book in _books.values) _info(book)]);

  static Future<Directory> _defaultDirectory() async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, directoryName),
  );

  Future<String> defaultRootPath() async => (await _directory()).path;

  Future<void> init({String? rootPath}) {
    if (_initializing case final pending?) return pending;
    if (_root != null) return Future.value();
    return _initializing ??= _initialize(rootPath).whenComplete(() {
      _initializing = null;
    });
  }

  Future<void> _initialize(String? path) async {
    final root = path == null ? await _directory() : Directory(path);
    await root.create(recursive: true);
    _root = Directory(await root.resolveSymbolicLinks());
    try {
      final file = await _file(manifestName);
      if (!await file.exists()) return;
      final json = await _readJson(file);
      if (jsonInt(json, 'version') != version || json['books'] is! List) {
        throw const FormatException('小说下载清单版本或结构无效');
      }
      final parsed = <String, _LocalBook>{};
      for (final raw in jsonList(json, 'books')) {
        final value = jsonMap({'v': raw}, 'v');
        if (value == null) throw const FormatException('小说下载书籍记录无效');
        final book = _LocalBook.fromJson(value);
        if (parsed.containsKey(book.book.pathWord)) {
          throw const FormatException('小说下载清单存在重复书籍');
        }
        parsed[book.book.pathWord] = book;
      }
      _books.addAll(parsed);
      for (final book in _books.values) {
        if (book.cover != null) {
          try {
            final cover = book.cover!;
            if (cover.path !=
                '${_bookPath(book.book.pathWord)}/cover_${cover.digest}.bin') {
              throw const FormatException('小说封面路径归属无效');
            }
            await _readAsset(
              cover,
              expectedPrefix: '${_bookPath(book.book.pathWord)}/',
            );
          } catch (error, stack) {
            _log(error, stack);
            book.cover = null;
          }
        }
        for (final volume in book.downloaded.values) {
          await _loadVolume(book, volume);
        }
      }
    } catch (error, stack) {
      manifestError = '小说下载清单损坏，请保留目录并修复';
      _log(error, stack);
      // Never overwrite an unreadable index, nor scan/delete unknown directories.
      _books.clear();
    }
  }

  LocalNovelInfo? getLocalNovelInfo(String pathWord) {
    final book = _books[pathWord];
    return book == null ? null : _info(book);
  }

  Set<String> downloadedVolumes(String pathWord) =>
      getLocalNovelInfo(pathWord)?.downloadedVolumeIds ?? const <String>{};

  String? coverPath(String pathWord) {
    final asset = _books[pathWord]?.cover;
    return asset == null || _root == null
        ? null
        : p.join(_root!.path, asset.path);
  }

  LocalNovelInfo _info(_LocalBook book) => LocalNovelInfo(
    book: book.book,
    volumes: List.unmodifiable(book.volumes),
    coverPath: coverPath(book.book.pathWord),
    downloaded: Map.unmodifiable({
      for (final entry in book.downloaded.entries)
        entry.key: LocalNovelVolumeInfo(
          volume: entry.value.volume,
          status: entry.value.status,
          completed: entry.value.completed,
          total: entry.value.total,
          error: entry.value.error,
        ),
    }),
  );

  Future<NovelVolumeSnapshot?> readVolumeSnapshot(
    String pathWord,
    String volumeId,
  ) async {
    await init();
    return _serialize(_volumeKey(pathWord, volumeId), () async {
      final book = _books[pathWord];
      final record = book?.downloaded[volumeId];
      if (book == null || record == null) return null;
      return _validateVolume(book, record);
    });
  }

  Future<Uint8List?> readImageBytes(
    String pathWord,
    String volumeId,
    String url,
  ) async {
    await init();
    return _serialize(_volumeKey(pathWord, volumeId), () async {
      final record = _books[pathWord]?.downloaded[volumeId];
      final asset = record?.images[url];
      if (record == null || asset == null) return null;
      try {
        return await _readAsset(
          asset,
          expectedPrefix: '${_volumePath(pathWord, volumeId)}/images/',
        );
      } catch (error, stack) {
        _log(error, stack);
        record.images.remove(url);
        if (record.status != NovelDownloadStatus.needsRepair) {
          record.status = NovelDownloadStatus.partial;
          record.completed = 1 + record.images.length;
        }
        return null;
      }
    });
  }

  Future<void> saveSnapshot({
    required NovelBook book,
    required List<NovelVolume> volumes,
    required NovelVolumeSnapshot snapshot,
    bool Function()? isCurrent,
  }) async {
    await init();
    _checkWritable();
    final pathWord = book.pathWord;
    final volumeId = snapshot.detail.volume.id;
    snapshot.validate(pathWord: pathWord, volumeId: volumeId);
    await _serialize(_volumeKey(pathWord, volumeId), () async {
      _checkCurrent(isCurrent);
      final bytes = utf8.encode(jsonEncode(snapshot.toJson()));
      final digest = _digest(bytes);
      final relative =
          '${_volumePath(pathWord, volumeId)}/snapshot_$digest.json';
      final file = await _file(relative);
      final existed = await file.exists();
      await _atomicWrite(file, bytes);
      if (isCurrent?.call() == false) {
        if (!existed) await file.delete();
        throw const NovelDownloadWriteCancelled();
      }
      final local = _books.putIfAbsent(
        pathWord,
        () => _LocalBook(book, volumes),
      );
      local.book = book;
      local.volumes = List.of(volumes);
      final old = local.downloaded[volumeId];
      final record = _LocalVolume(snapshot.detail.volume)
        ..snapshot = _Asset(relative, bytes.length, digest)
        ..total = 1 + snapshot.imageUrls.length;
      // Reuse images only for this exact TXT+directory revision.
      if (old?.snapshot?.digest == digest) record.images.addAll(old!.images);
      record.completed = 1 + record.images.length;
      record.status = record.completed == record.total
          ? NovelDownloadStatus.completed
          : NovelDownloadStatus.partial;
      local.downloaded[volumeId] = record;
      try {
        await _saveVolume(pathWord, record);
        await _saveManifest();
      } catch (error) {
        // A retry must not mistake uncommitted in-memory state for a durable
        // download (especially a text-only volume with no later image writes).
        if (old == null) {
          local.downloaded.remove(volumeId);
        } else {
          local.downloaded[volumeId] = old;
        }
        rethrow;
      }
    });
  }

  Future<void> saveImage(
    String pathWord,
    String volumeId,
    String url,
    List<int> bytes, {
    bool Function()? isCurrent,
  }) async {
    _checkWritable();
    if (bytes.isEmpty) throw const FormatException('小说插图文件为空');
    await _serialize(_volumeKey(pathWord, volumeId), () async {
      _checkCurrent(isCurrent);
      final book = _books[pathWord];
      final record = book?.downloaded[volumeId];
      if (book == null || record == null) throw StateError('小说正文尚未保存');
      final snapshot = await _validateVolume(book, record);
      if (snapshot == null || !snapshot.imageUrls.contains(url)) {
        throw const FormatException('插图不属于当前小说快照');
      }
      final relative =
          '${_volumePath(pathWord, volumeId)}/images/${_hash(url)}.bin';
      final file = await _file(relative);
      final existed = await file.exists();
      await _atomicWrite(file, bytes);
      if (isCurrent?.call() == false) {
        if (!existed) await file.delete();
        throw const NovelDownloadWriteCancelled();
      }
      final previous = record.images[url];
      record.images[url] = _Asset(relative, bytes.length, _digest(bytes));
      record.completed = 1 + record.images.length;
      record.status = record.completed == record.total
          ? NovelDownloadStatus.completed
          : NovelDownloadStatus.partial;
      try {
        await _saveVolume(pathWord, record);
        await _saveManifest();
      } catch (error) {
        if (previous == null) {
          record.images.remove(url);
        } else {
          record.images[url] = previous;
        }
        record.completed = 1 + record.images.length;
        record.status = NovelDownloadStatus.partial;
        rethrow;
      }
    });
  }

  Future<void> saveCover(
    String pathWord,
    List<int> bytes, {
    bool Function()? isCurrent,
  }) async {
    _checkWritable();
    if (bytes.isEmpty) throw const FormatException('小说封面为空');
    await _serialize('book:$pathWord', () async {
      _checkCurrent(isCurrent);
      final book = _books[pathWord];
      if (book == null) return;
      final relative = '${_bookPath(pathWord)}/cover_${_digest(bytes)}.bin';
      final file = await _file(relative);
      final existed = await file.exists();
      await _atomicWrite(file, bytes);
      if (isCurrent?.call() == false) {
        if (!existed) await file.delete();
        throw const NovelDownloadWriteCancelled();
      }
      final previous = book.cover;
      book.cover = _Asset(relative, bytes.length, _digest(bytes));
      try {
        await _saveManifest();
      } catch (error) {
        book.cover = previous;
        rethrow;
      }
    });
  }

  Future<void> deleteVolume(String pathWord, String volumeId) async {
    await init();
    _checkWritable();
    await _serialize(_volumeKey(pathWord, volumeId), () async {
      final book = _books[pathWord];
      final record = book?.downloaded[volumeId];
      if (book == null || record == null) return;
      // Persist removal before deleting files: a crash may leave an orphan, not
      // a manifest falsely claiming a complete download.
      book.downloaded.remove(volumeId);
      try {
        await _saveManifest();
      } catch (error) {
        book.downloaded[volumeId] = record;
        rethrow;
      }
      for (final relative in _volumeFiles(pathWord, record)) {
        await _deleteOwned(relative);
      }
    });
  }

  Future<void> deleteNovel(String pathWord) async {
    await init();
    _checkWritable();
    final book = _books[pathWord];
    if (book == null) return;
    for (final id in List<String>.of(book.downloaded.keys)) {
      await deleteVolume(pathWord, id);
    }
    await _serialize('book:$pathWord', () async {
      _books.remove(pathWord);
      try {
        await _saveManifest();
      } catch (error) {
        _books[pathWord] = book;
        rethrow;
      }
      if (book.cover case final asset?) await _deleteOwned(asset.path);
    });
  }

  Future<void> waitForWrites() async {
    while (_tails.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_tails.values));
    }
  }

  Future<void> _loadVolume(_LocalBook book, _LocalVolume record) async {
    try {
      final pathWord = book.book.pathWord;
      final json = await _readJson(
        await _file(_volumeManifest(pathWord, record.volume.id)),
      );
      if (jsonInt(json, 'version') != version ||
          jsonString(json, 'path_word') != pathWord ||
          jsonString(json, 'volume_id') != record.volume.id) {
        throw const FormatException('小说卷清单身份无效');
      }
      record.snapshot = _Asset.fromJson(jsonMap(json, 'snapshot') ?? {});
      for (final entry in (jsonMap(json, 'images') ?? {}).entries) {
        final asset = jsonMap({'v': entry.value}, 'v');
        if (asset == null) throw const FormatException('小说插图清单无效');
        record.images[entry.key] = _Asset.fromJson(asset);
      }
      await _validateVolume(book, record);
    } catch (error, stack) {
      _repair(record, error, stack);
    }
  }

  Future<NovelVolumeSnapshot?> _validateVolume(
    _LocalBook book,
    _LocalVolume record,
  ) async {
    try {
      final asset = record.snapshot;
      if (asset == null) throw const FormatException('小说正文快照缺失');
      final base = _volumePath(book.book.pathWord, record.volume.id);
      if (asset.path != '$base/snapshot_${asset.digest}.json') {
        throw const FormatException('小说正文快照路径无效');
      }
      final bytes = await _readAsset(asset, expectedPrefix: '$base/');
      final raw = jsonDecode(utf8.decode(bytes));
      final json = jsonMap({'v': raw}, 'v');
      if (json == null) throw const FormatException('小说正文快照无效');
      final snapshot = NovelVolumeSnapshot.fromJson(json);
      snapshot.validate(
        pathWord: book.book.pathWord,
        volumeId: record.volume.id,
      );
      record.volume = snapshot.detail.volume;
      final validImages = <String, _Asset>{};
      for (final url in snapshot.imageUrls) {
        final image = record.images[url];
        if (image == null) continue;
        try {
          if (image.path != '$base/images/${_hash(url)}.bin') {
            throw const FormatException('小说插图路径无效');
          }
          await _readAsset(image, expectedPrefix: '$base/images/');
          validImages[url] = image;
        } catch (error, stack) {
          _log(error, stack);
        }
      }
      record.images
        ..clear()
        ..addAll(validImages);
      record.total = snapshot.imageUrls.length + 1;
      record.completed = validImages.length + 1;
      record.status = record.completed == record.total
          ? NovelDownloadStatus.completed
          : NovelDownloadStatus.partial;
      record.error = null;
      return snapshot;
    } catch (error, stack) {
      _repair(record, error, stack);
      return null;
    }
  }

  void _repair(_LocalVolume record, Object error, StackTrace stack) {
    record.status = NovelDownloadStatus.needsRepair;
    record.completed = 0;
    record.error = '本地小说文件损坏或缺失，需要重新下载';
    _log(error, stack);
  }

  Future<void> _saveVolume(String pathWord, _LocalVolume record) async {
    await _atomicWrite(
      await _file(_volumeManifest(pathWord, record.volume.id)),
      utf8.encode(
        jsonEncode({
          'version': version,
          'path_word': pathWord,
          'volume_id': record.volume.id,
          'snapshot': record.snapshot?.toJson(),
          'images': record.images.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
        }),
      ),
    );
  }

  Future<void> _saveManifest() => _serialize('manifest', () async {
    await _atomicWrite(
      await _file(manifestName),
      utf8.encode(
        jsonEncode({
          'version': version,
          'books': _books.values.map((book) => book.toJson()).toList(),
        }),
      ),
    );
  });

  /// All paths are both lexically contained and checked for symlink ancestors.
  /// IDs never become path segments; only SHA-256 digests do.
  Future<File> _file(String relative, {Directory? root}) async {
    final directory = root ?? _root;
    if (directory == null) throw StateError('小说下载存储尚未初始化');
    if (relative.isEmpty ||
        relative.contains('\\') ||
        p.posix.isAbsolute(relative) ||
        relative
            .split('/')
            .any(
              (part) =>
                  part.isEmpty ||
                  part == '.' ||
                  part == '..' ||
                  part.contains(':'),
            )) {
      throw const FormatException('小说下载路径越界');
    }
    final target = p.normalize(p.join(directory.path, relative));
    if (!p.isWithin(directory.path, target)) {
      throw const FormatException('小说下载路径越界');
    }
    var current = directory.path;
    for (final part in relative.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('小说下载路径包含符号链接');
      }
    }
    return File(target);
  }

  Future<Uint8List> _readAsset(
    _Asset asset, {
    required String expectedPrefix,
  }) async {
    if (!asset.path.startsWith(expectedPrefix)) {
      throw const FormatException('小说资源路径归属无效');
    }
    final bytes = await (await _file(asset.path)).readAsBytes();
    if (bytes.length != asset.length ||
        _digest(bytes) != asset.digest ||
        bytes.isEmpty) {
      throw const FormatException('小说资源文件校验失败');
    }
    return bytes;
  }

  Future<void> _atomicWrite(File file, List<int> bytes) async {
    await beforeWrite?.call(file.path);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<Map<String, dynamic>> _readJson(File file) async {
    final raw = jsonDecode(await file.readAsString());
    final json = jsonMap({'v': raw}, 'v');
    if (json == null) throw const FormatException('小说下载 JSON 无效');
    return json;
  }

  Future<T> _serialize<T>(String key, Future<T> Function() action) {
    final previous = _tails[key];
    final barrier = Completer<void>();
    _tails[key] = barrier.future;
    Future<T> run() async {
      try {
        return await action();
      } finally {
        if (identical(_tails[key], barrier.future)) {
          unawaited(_tails.remove(key));
        }
        barrier.complete();
      }
    }

    return previous == null ? run() : previous.then((_) => run());
  }

  void _checkWritable() {
    if (manifestError != null) throw StateError(manifestError!);
    if (_migrating) throw StateError('小说下载目录正在迁移');
  }

  static void _checkCurrent(bool Function()? check) {
    if (check?.call() == false) throw const NovelDownloadWriteCancelled();
  }

  static String _digest(List<int> bytes) => sha256.convert(bytes).toString();
  static String _hash(String value) => _digest(utf8.encode(value));
  static String _bookPath(String pathWord) => 'novels/${_hash(pathWord)}';
  static String _volumePath(String pathWord, String volumeId) =>
      '${_bookPath(pathWord)}/volumes/${_hash(volumeId)}';
  static String _volumeManifest(String pathWord, String volumeId) =>
      '${_volumePath(pathWord, volumeId)}/manifest_v1.json';
  static String _volumeKey(String pathWord, String volumeId) =>
      'volume:${_hash('$pathWord\n$volumeId')}';

  Iterable<String> _volumeFiles(String pathWord, _LocalVolume record) sync* {
    final base = _volumePath(pathWord, record.volume.id);
    if (record.snapshot case final asset?) {
      if (asset.path == '$base/snapshot_${asset.digest}.json') yield asset.path;
    }
    for (final entry in record.images.entries) {
      if (entry.value.path == '$base/images/${_hash(entry.key)}.bin') {
        yield entry.value.path;
      }
    }
    yield _volumeManifest(pathWord, record.volume.id);
  }

  Future<void> _deleteOwned(String relative, {Directory? root}) async {
    try {
      final base = root ?? _root!;
      final file = await _file(relative, root: base);
      if (await file.exists()) await file.delete();
      // Prune only empty ancestors of an indexed file, never walk unknown trees.
      var directory = file.parent;
      while (p.isWithin(base.path, directory.path)) {
        if (!await directory.exists()) {
          directory = directory.parent;
          continue;
        }
        if (!await directory.list(followLinks: false).isEmpty) break;
        await directory.delete();
        directory = directory.parent;
      }
    } catch (error, stack) {
      _log(error, stack);
    }
  }

  /// Resolve existing ancestors too, so a not-yet-created path through a symlink
  /// cannot bypass overlap protection.
  static Future<String> canonicalDirectory(String value) async {
    var directory = Directory(p.normalize(p.absolute(value)));
    final missing = <String>[];
    while (!await directory.exists()) {
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      missing.add(p.basename(directory.path));
      directory = parent;
    }
    final base = await directory.resolveSymbolicLinks();
    return p.normalize(p.joinAll([base, ...missing.reversed]));
  }

  static bool pathsOverlap(String first, String second) {
    var a = p.normalize(p.absolute(first));
    var b = p.normalize(p.absolute(second));
    if (Platform.isWindows) {
      a = a.toLowerCase();
      b = b.toLowerCase();
    }
    return p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
  }

  static Future<void> probeDirectory(String path) async {
    final directory = Directory(path);
    await directory.create(recursive: true);
    final file = File(
      p.join(path, '.novel_probe_${DateTime.now().microsecondsSinceEpoch}'),
    );
    try {
      await file.writeAsString('probe', flush: true);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> migrateTo(
    String target, {
    Future<void> Function(String path)? commit,
    void Function(NovelDownloadMigrationProgress progress)? onProgress,
  }) async {
    await init();
    _checkWritable();
    final destination = await canonicalDirectory(target);
    final source = _root!;
    if (p.equals(source.path, destination)) return;
    if (pathsOverlap(source.path, destination)) {
      throw ArgumentError('小说下载目录不能互相包含');
    }
    _migrating = true;
    final created = <File>[];
    final createdDirectories = <Directory>[];
    var committed = false;
    try {
      await waitForWrites();
      final targetDirectory = Directory(destination);
      if (await targetDirectory.exists()) {
        if (!await targetDirectory.list(followLinks: false).isEmpty) {
          throw StateError('目标目录必须为空，不能覆盖已有数据');
        }
      } else {
        await targetDirectory.create(recursive: true);
        createdDirectories.add(targetDirectory);
      }
      await probeDirectory(destination);
      final files = <String>{
        if (await (await _file(manifestName)).exists()) manifestName,
        for (final book in _books.values) ...[
          if (book.cover case final asset?) asset.path,
          for (final record in book.downloaded.values)
            ..._volumeFiles(book.book.pathWord, record),
        ],
      };
      var completed = 0;
      for (final relative in files) {
        final from = await _file(relative);
        // Missing files stay marked repairable rather than blocking relocation.
        if (await from.exists()) {
          final to = await _file(relative, root: targetDirectory);
          var parent = to.parent;
          final missing = <Directory>[];
          while (!await parent.exists()) {
            missing.add(parent);
            parent = parent.parent;
          }
          for (final dir in missing.reversed) {
            await dir.create();
            createdDirectories.add(dir);
          }
          if (await to.exists()) throw StateError('迁移目标出现已有文件');
          created.add(to);
          if (copyFile case final copy?) {
            await copy(from, to);
          } else {
            await from.copy(to.path);
          }
          if (_digest(await from.readAsBytes()) !=
              _digest(await to.readAsBytes())) {
            throw const FileSystemException('小说迁移文件校验失败');
          }
        }
        onProgress?.call(
          NovelDownloadMigrationProgress(++completed, files.length),
        );
      }
      await commit?.call(destination);
      _root = targetDirectory;
      committed = true;
      // Delete only indexed files. Unknown directories and files stay untouched.
      for (final relative in files) {
        await _deleteOwned(relative, root: source);
      }
    } finally {
      if (!committed) {
        for (final file in created.reversed) {
          try {
            if (await file.exists()) await file.delete();
          } catch (error, stack) {
            _log(error, stack);
          }
        }
        for (final dir in createdDirectories.reversed) {
          try {
            if (await dir.exists() &&
                await dir.list(followLinks: false).isEmpty) {
              await dir.delete();
            }
          } catch (error, stack) {
            _log(error, stack);
          }
        }
      }
      _migrating = false;
    }
  }

  static void _log(Object error, StackTrace stack) {
    unawaited(
      AppLogger.instance.recordWarning(
        error,
        stackTrace: stack,
        source: 'novel_download_store',
      ),
    );
  }
}

class NovelDownloadWriteCancelled implements Exception {
  const NovelDownloadWriteCancelled();
}

class _Asset {
  final String path;
  final int length;
  final String digest;
  const _Asset(this.path, this.length, this.digest);
  Map<String, dynamic> toJson() => {
    'path': path,
    'length': length,
    'sha256': digest,
  };
  factory _Asset.fromJson(Map<String, dynamic> json) {
    final digest = jsonString(json, 'sha256');
    final length = jsonInt(json, 'length');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || length <= 0) {
      throw const FormatException('小说资源校验信息无效');
    }
    return _Asset(jsonString(json, 'path'), length, digest);
  }
}

class _LocalVolume {
  NovelVolume volume;
  _Asset? snapshot;
  final images = <String, _Asset>{};
  NovelDownloadStatus status = NovelDownloadStatus.needsRepair;
  int completed = 0;
  int total = 1;
  String? error;
  _LocalVolume(this.volume);
}

class _LocalBook {
  NovelBook book;
  List<NovelVolume> volumes;
  _Asset? cover;
  final downloaded = <String, _LocalVolume>{};
  _LocalBook(this.book, this.volumes);

  Map<String, dynamic> toJson() => {
    'book': book.toJson(),
    'volumes': volumes.map((v) => v.toJson()).toList(),
    'downloaded': downloaded.values.map((v) => v.volume.toJson()).toList(),
    'cover': cover?.toJson(),
  };

  factory _LocalBook.fromJson(Map<String, dynamic> json) {
    final book = NovelBook.fromJson(jsonMap(json, 'book') ?? {});
    if (book.pathWord.isEmpty ||
        json['volumes'] is! List ||
        json['downloaded'] is! List) {
      throw const FormatException('小说本地书籍元数据无效');
    }
    final local = _LocalBook(book, [
      for (final raw in jsonList(json, 'volumes'))
        NovelVolume.fromJson(jsonMap({'v': raw}, 'v') ?? {}),
    ]);
    for (final raw in jsonList(json, 'downloaded')) {
      final volume = NovelVolume.fromJson(jsonMap({'v': raw}, 'v') ?? {});
      if (volume.id.isEmpty || local.downloaded.containsKey(volume.id)) {
        throw const FormatException('小说本地卷记录无效');
      }
      local.downloaded[volume.id] = _LocalVolume(volume);
    }
    if (jsonMap(json, 'cover') case final cover?) {
      local.cover = _Asset.fromJson(cover);
    }
    return local;
  }
}
