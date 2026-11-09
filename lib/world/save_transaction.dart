/// 世界目录保存事务：lock 之外的 journal、backup、临时文件和原子替换。
///
/// 流程对应白皮书 8.5；锁由 [WorldLock] 在打开世界时持有。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'chunk_file.dart';
import 'geometry.dart';
import 'world_index.dart';
import 'world_meta.dart';
import 'world_store.dart';

enum SaveActionKind { add, modify, delete }

/// 保存事务失败；[rolledBack] 表示是否已经恢复到保存前状态。
class WorldSaveException implements Exception {
  const WorldSaveException(
    this.message, {
    this.cause,
    required this.rolledBack,
  });

  final String message;
  final Object? cause;
  final bool rolledBack;

  @override
  String toString() => message;
}

/// 恢复失败；需要人工处理，不能继续保存。
class WorldRecoveryException implements Exception {
  const WorldRecoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WorldSaveResult {
  const WorldSaveResult({
    required this.transactionId,
    required this.revision,
    required this.cleanupPending,
  });

  final String transactionId;
  final int revision;
  final bool cleanupPending;
}

class WorldRecoveryResult {
  const WorldRecoveryResult({
    required this.recovered,
    required this.transactionId,
  });

  final bool recovered;
  final String? transactionId;
}

/// 保存事务入口。
class WorldSave {
  WorldSave._();

  /// 提交一次保存。
  ///
  /// [meta] 和 [index] 是保存前的内存状态；事务会把 index_revision 和
  /// revision 都加一，然后写入磁盘。[dirtyChunks] 里的块会写入，
  /// [deleteChunks] 里的块会删除。
  static WorldSaveResult commit({
    required WorldStore store,
    required WorldMeta meta,
    required WorldIndex index,
    required Map<ChunkCoord, ChunkFile> dirtyChunks,
    Set<ChunkCoord> deleteChunks = const <ChunkCoord>{},
    void Function(String relativePath)? beforeAction,
  }) {
    final revision = meta.indexRevision + 1;
    final newMeta = meta.withIndexRevision(revision);
    final newIndex = index.withRevision(revision);
    final metaErrors = newMeta.validate();
    if (metaErrors.isNotEmpty) {
      throw WorldSaveException(
        '保存校验失败：${metaErrors.join('；')}',
        rolledBack: true,
      );
    }
    final indexErrors = newIndex.validate();
    if (indexErrors.isNotEmpty) {
      throw WorldSaveException(
        '索引校验失败：${indexErrors.join('；')}',
        rolledBack: true,
      );
    }
    for (final entry in dirtyChunks.entries) {
      final key = entry.key;
      final chunk = entry.value;
      if (chunk.z != key.z || chunk.cx != key.cx || chunk.cy != key.cy) {
        throw WorldSaveException(
          '块 ${key.z}/${key.cx}_${key.cy} 与 ChunkFile 坐标不一致',
          rolledBack: true,
        );
      }
    }
    final writeChunks = <ChunkCoord, ChunkFile>{};
    final effectiveDeleteChunks = <ChunkCoord>{...deleteChunks};
    for (final entry in dirtyChunks.entries) {
      if (entry.value.isEmpty) {
        effectiveDeleteChunks.add(entry.key);
      } else {
        writeChunks[entry.key] = entry.value;
      }
    }
    for (final key in effectiveDeleteChunks) {
      if (writeChunks.containsKey(key)) {
        throw WorldSaveException(
          '块 ${key.z}/${key.cx}_${key.cy} 同时被写入和删除',
          rolledBack: true,
        );
      }
    }

    final tx = 'tx-${DateTime.now().microsecondsSinceEpoch}';
    final entries = <_JournalEntry>[];
    try {
      final metaFile = File(store.metaPath);
      final indexPath = _abs(store, 'world.index.json');
      final indexFile = File(indexPath);
      if (!metaFile.existsSync()) {
        throw const FormatException('缺少 world.meta.json，不能保存');
      }
      entries.add(
        _entryFor(
          store,
          'world.index.json',
          indexFile.existsSync() ? SaveActionKind.modify : SaveActionKind.add,
          tx,
        ),
      );
      entries.add(
        _entryFor(store, 'world.meta.json', SaveActionKind.modify, tx),
      );

      final dirtyPaths = <String>{
        for (final chunk in writeChunks.values) chunk.relativePath,
      };
      for (final chunk in writeChunks.values) {
        final target = File(_abs(store, chunk.relativePath));
        entries.add(
          _entryFor(
            store,
            chunk.relativePath,
            target.existsSync() ? SaveActionKind.modify : SaveActionKind.add,
            tx,
          ),
        );
      }
      for (final key in effectiveDeleteChunks) {
        final relative = chunkRelativePath(key.z, key.cx, key.cy);
        if (dirtyPaths.contains(relative)) continue;
        if (File(_abs(store, relative)).existsSync()) {
          entries.add(_entryFor(store, relative, SaveActionKind.delete, tx));
        }
      }

      final journal = _Journal(
        transactionId: tx,
        status: 'prepared',
        entries: entries,
      );
      final journalFile = _journalFile(store);
      _writeAtomic(
        journalFile,
        const JsonEncoder.withIndent('  ').convert(journal.toJson()),
        tempSuffix: tx,
      );
    } catch (error, stack) {
      _discardPrepared(store);
      throw WorldSaveException('保存准备失败：$error', cause: stack, rolledBack: true);
    }

    var writesStarted = false;
    try {
      // 3. 备份原文件
      for (final entry in entries) {
        if (entry.kind == SaveActionKind.add) continue;
        final original = File(_abs(store, entry.path));
        if (!original.existsSync()) {
          throw FormatException('原文件不存在：${entry.path}');
        }
        final backup = File(_backupPath(store, entry.path));
        backup.parent.createSync(recursive: true);
        original.copySync(backup.path);
        final backupHash = _sha256(backup.readAsBytesSync());
        if (backupHash != entry.sha256) {
          throw FormatException('备份 hash 不一致：${entry.path}');
        }
      }

      // 4. 写块
      for (final chunk in writeChunks.values) {
        final relative = chunk.relativePath;
        _before(relative, beforeAction);
        writesStarted = true;
        _writeTarget(
          store: store,
          relative: relative,
          content: chunk.encode(),
          transactionId: tx,
          expectExists:
              _entryForPath(entries, relative).kind != SaveActionKind.add,
          beforeAction: beforeAction,
        );
      }

      // 5. 删除空块
      for (final entry in entries.where(
        (e) => e.kind == SaveActionKind.delete,
      )) {
        _before(entry.path, beforeAction);
        writesStarted = true;
        _verifyOriginal(store, entry);
        File(_abs(store, entry.path)).deleteSync();
      }

      // 6. 写索引
      _before('world.index.json', beforeAction);
      writesStarted = true;
      _writeTarget(
        store: store,
        relative: 'world.index.json',
        content: newIndex.encode(),
        transactionId: tx,
        expectExists:
            _entryForPath(entries, 'world.index.json').kind !=
            SaveActionKind.add,
        beforeAction: beforeAction,
      );

      // 7. 写 meta
      _before('world.meta.json', beforeAction);
      writesStarted = true;
      _writeTarget(
        store: store,
        relative: 'world.meta.json',
        content: newMeta.encode(),
        transactionId: tx,
        expectExists: true,
        beforeAction: beforeAction,
      );

      // 8. 标记 committed
      final journal = _readJournal(_journalFile(store));
      final committed = _Journal(
        transactionId: journal.transactionId,
        status: 'committed',
        entries: journal.entries,
      );
      _writeAtomic(
        _journalFile(store),
        const JsonEncoder.withIndent('  ').convert(committed.toJson()),
        tempSuffix: tx,
      );

      // 9. 清理
      final cleanupPending = !_cleanup(store);
      return WorldSaveResult(
        transactionId: tx,
        revision: revision,
        cleanupPending: cleanupPending,
      );
    } catch (error, stack) {
      if (!writesStarted) {
        _discardPrepared(store);
        throw WorldSaveException('保存失败：$error', cause: stack, rolledBack: true);
      }
      final rolledBack = _rollbackPrepared(store);
      throw WorldSaveException(
        rolledBack ? '保存失败，已回滚：$error' : '保存失败，回滚失败：$error',
        cause: stack,
        rolledBack: rolledBack,
      );
    }
  }

  /// 启动时恢复：prepared 回滚，committed 只清理。
  static WorldRecoveryResult recover(String worldRoot) {
    final journalFile = File(_journalPath(worldRoot));
    if (!journalFile.existsSync()) {
      return const WorldRecoveryResult(recovered: false, transactionId: null);
    }
    final journal = _readJournal(journalFile);
    if (journal.status == 'prepared') {
      final store = WorldStore(worldRoot);
      for (final entry in journal.entries) {
        final temp = File(_abs(store, entry.tempPath));
        if (temp.existsSync()) temp.deleteSync();
        if (entry.kind == SaveActionKind.add) {
          final target = File(_abs(store, entry.path));
          if (target.existsSync()) target.deleteSync();
          continue;
        }
        final backup = File(_backupPath(store, entry.path));
        if (!backup.existsSync()) {
          throw WorldRecoveryException('备份缺失：${entry.path}');
        }
        final backupHash = _sha256(backup.readAsBytesSync());
        if (entry.sha256 != null && backupHash != entry.sha256) {
          throw WorldRecoveryException('备份 hash 不一致：${entry.path}');
        }
        final target = File(_abs(store, entry.path));
        target.parent.createSync(recursive: true);
        backup.copySync(target.path);
      }
      _cleanup(store);
      return WorldRecoveryResult(
        recovered: true,
        transactionId: journal.transactionId,
      );
    }
    if (journal.status == 'committed') {
      final store = WorldStore(worldRoot);
      _cleanup(store);
      return WorldRecoveryResult(
        recovered: true,
        transactionId: journal.transactionId,
      );
    }
    throw WorldRecoveryException('未知 journal 状态：${journal.status}');
  }

  static void _before(String path, void Function(String)? callback) {
    callback?.call(path);
  }

  static void _writeTarget({
    required WorldStore store,
    required String relative,
    required String content,
    required String transactionId,
    required bool expectExists,
    void Function(String)? beforeAction,
  }) {
    final entry = _entryForPath(
      _readJournal(_journalFile(store)).entries,
      relative,
    );
    // 先按 journal 校验一次，再写临时文件；写完后替换前再校验一次。
    if (expectExists) {
      _verifyOriginal(store, entry);
    } else {
      final target = File(_abs(store, relative));
      if (target.existsSync()) {
        throw FormatException('新增文件已存在：$relative');
      }
    }
    final target = File(_abs(store, relative));
    target.parent.createSync(recursive: true);
    final temp = File('${target.path}.tmp.$transactionId');
    temp.writeAsStringSync(content, flush: true);
    if (expectExists) {
      _verifyOriginal(store, entry);
    } else if (target.existsSync()) {
      throw FormatException('新增文件已存在：$relative');
    }
    temp.renameSync(target.path);
  }

  static _JournalEntry _entryForPath(List<_JournalEntry> entries, String path) {
    for (final entry in entries) {
      if (entry.path == path) return entry;
    }
    throw FormatException('journal 缺少条目：$path');
  }

  static void _verifyOriginal(WorldStore store, _JournalEntry entry) {
    final file = File(_abs(store, entry.path));
    if (!file.existsSync()) {
      throw FormatException('原文件不存在：${entry.path}');
    }
    final stat = file.statSync();
    if (stat.size != entry.size ||
        stat.modified.millisecondsSinceEpoch != entry.modifiedMs ||
        _sha256(file.readAsBytesSync()) != entry.sha256) {
      throw FormatException('原文件已被外部修改：${entry.path}');
    }
  }

  static _JournalEntry _entryFor(
    WorldStore store,
    String relative,
    SaveActionKind kind,
    String transactionId,
  ) {
    final target = File(_abs(store, relative));
    if (kind == SaveActionKind.add) {
      if (target.existsSync()) {
        throw FormatException('新增文件已存在：$relative');
      }
      return _JournalEntry(
        path: relative,
        kind: kind,
        tempPath: '$relative.tmp.$transactionId',
      );
    }
    if (!target.existsSync()) {
      throw FormatException('原文件不存在：$relative');
    }
    final stat = target.statSync();
    return _JournalEntry(
      path: relative,
      kind: kind,
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      sha256: _sha256(target.readAsBytesSync()),
      tempPath: '$relative.tmp.$transactionId',
    );
  }

  static void _writeAtomic(
    File target,
    String content, {
    required String tempSuffix,
  }) {
    target.parent.createSync(recursive: true);
    final temp = File('${target.path}.tmp.$tempSuffix');
    temp.writeAsStringSync(content, flush: true);
    temp.renameSync(target.path);
  }

  static bool _cleanup(WorldStore store) {
    try {
      final backup = Directory(
        '${_saveDir(store.rootPath)}${Platform.pathSeparator}backup',
      );
      if (backup.existsSync()) backup.deleteSync(recursive: true);
      final journal = _journalFile(store);
      if (journal.existsSync()) journal.deleteSync();
      final journalTmp = File('${journal.path}.tmp');
      if (journalTmp.existsSync()) journalTmp.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static void _discardPrepared(WorldStore store) {
    final journal = _journalFile(store);
    if (journal.existsSync()) journal.deleteSync();
    final journalTmp = File('${journal.path}.tmp');
    if (journalTmp.existsSync()) journalTmp.deleteSync();
    final backup = Directory(
      '${_saveDir(store.rootPath)}${Platform.pathSeparator}backup',
    );
    if (backup.existsSync()) backup.deleteSync(recursive: true);
  }

  static bool _rollbackPrepared(WorldStore store) {
    try {
      final journal = _readJournal(_journalFile(store));
      recover(store.rootPath);
      return journal.status == 'prepared';
    } on Object {
      return false;
    }
  }

  static File _journalFile(WorldStore store) =>
      File(_journalPath(store.rootPath));

  static String _journalPath(String worldRoot) =>
      '${_saveDir(worldRoot)}${Platform.pathSeparator}journal.json';

  static String _saveDir(String worldRoot) =>
      '$worldRoot${Platform.pathSeparator}.save';

  static String _backupPath(WorldStore store, String relative) =>
      '${_saveDir(store.rootPath)}${Platform.pathSeparator}backup'
      '${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
}

String _abs(WorldStore store, String relative) =>
    '${store.rootPath}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

class _Journal {
  const _Journal({
    required this.transactionId,
    required this.status,
    required this.entries,
  });

  final String transactionId;
  final String status;
  final List<_JournalEntry> entries;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'transaction_id': transactionId,
    'status': status,
    'entries': entries.map((e) => e.toJson()).toList(growable: false),
  };

  static _Journal fromJson(Map<String, dynamic> json) {
    final transactionId = json['transaction_id'];
    final status = json['status'];
    final rawEntries = json['entries'];
    if (transactionId is! String || status is! String || rawEntries is! List) {
      throw const FormatException('journal 字段不完整');
    }
    final entries = <_JournalEntry>[];
    for (var i = 0; i < rawEntries.length; i++) {
      final raw = rawEntries[i];
      if (raw is! Map<String, dynamic>) {
        throw FormatException('journal.entries[$i] 必须是对象');
      }
      entries.add(_JournalEntry.fromJson(raw));
    }
    return _Journal(
      transactionId: transactionId,
      status: status,
      entries: entries,
    );
  }
}

class _JournalEntry {
  const _JournalEntry({
    required this.path,
    required this.kind,
    required this.tempPath,
    this.size,
    this.modifiedMs,
    this.sha256,
  });

  final String path;
  final SaveActionKind kind;
  final String tempPath;
  final int? size;
  final int? modifiedMs;
  final String? sha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'action': kind.name,
    'temp': tempPath,
    if (size != null) 'size': size,
    if (modifiedMs != null) 'modified_ms': modifiedMs,
    if (sha256 != null) 'sha256': sha256,
  };

  static _JournalEntry fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final action = json['action'];
    final temp = json['temp'];
    if (path is! String || action is! String || temp is! String) {
      throw const FormatException('journal entry 字段不完整');
    }
    SaveActionKind kind;
    switch (action) {
      case 'add':
        kind = SaveActionKind.add;
      case 'modify':
        kind = SaveActionKind.modify;
      case 'delete':
        kind = SaveActionKind.delete;
      default:
        throw FormatException('未知 journal action：$action');
    }
    final size = json['size'];
    final modifiedMs = json['modified_ms'];
    final hash = json['sha256'];
    if (size != null && size is! int) {
      throw const FormatException('journal size 必须是整数');
    }
    if (modifiedMs != null && modifiedMs is! int) {
      throw const FormatException('journal modified_ms 必须是整数');
    }
    if (hash != null && hash is! String) {
      throw const FormatException('journal sha256 必须是字符串');
    }
    return _JournalEntry(
      path: path,
      kind: kind,
      tempPath: temp,
      size: size as int?,
      modifiedMs: modifiedMs as int?,
      sha256: hash as String?,
    );
  }
}

_Journal _readJournal(File file) {
  if (!file.existsSync()) {
    throw const FormatException('缺少 journal.json');
  }
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, dynamic>) {
    throw const FormatException('journal.json 必须是对象');
  }
  return _Journal.fromJson(value);
}
