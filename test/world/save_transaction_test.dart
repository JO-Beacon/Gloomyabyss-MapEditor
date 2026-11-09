import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/chunk_file.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';
import 'package:gloomyabyss_map_editor/world/save_transaction.dart';
import 'package:gloomyabyss_map_editor/world/world_index.dart';
import 'package:gloomyabyss_map_editor/world/world_meta.dart';
import 'package:gloomyabyss_map_editor/world/world_store.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gloomy_save_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  WorldMeta makeMeta({int revision = 0}) =>
      WorldMeta.fromJson(<String, dynamic>{
        'version': 2,
        'name': 'test',
        'block_size': 128,
        'chunk_format_version': 1,
        'definitions': <String, dynamic>{
          'id': 'default',
          'version': 1,
          'hash': 'sha256:${'a' * 64}',
        },
        'index_revision': revision,
        'start': <String, dynamic>{'col': 0, 'row': 0, 'z': 0},
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
      });

  WorldIndex makeIndex({int revision = 0}) =>
      WorldIndex.fromJson(<String, dynamic>{
        'revision': revision,
        'full_checked_at': '',
        'portals': <dynamic>[],
        'props_objects': <dynamic>[],
        'solid_groups': <dynamic>[],
      });

  void writeWorld({int revision = 0}) {
    final store = WorldStore(temp.path);
    File(store.metaPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(makeMeta(revision: revision).encode());
    File(store.indexPath)
        .writeAsStringSync(makeIndex(revision: revision).encode());
    final chunk = File(chunkPath(temp.path, 0, 0, 0))
      ..createSync(recursive: true)
      ..writeAsStringSync('; prop=0,box,1,2\n; terrain\n');
    expect(chunk.existsSync(), isTrue);
  }

  ChunkFile dirtyChunk() => ChunkFile(
    z: 0,
    cx: 0,
    cy: 0,
    blockSize: 128,
    instructions: const <ChunkInstruction>[
      PropInstruction(z: 0, type: 'box', col: 3, row: 4),
    ],
    terrainRows: const <String>['.'],
  );

  test('保存写入块、索引和 meta，并清理事务文件', () {
    writeWorld();
    final result = WorldSave.commit(
      store: WorldStore(temp.path),
      meta: makeMeta(),
      index: makeIndex(),
      dirtyChunks: <ChunkCoord, ChunkFile>{
        const ChunkCoord(0, 0, 0): dirtyChunk(),
      },
    );
    expect(result.revision, 1);
    expect(result.cleanupPending, isFalse);

    final store = WorldStore(temp.path);
    expect(store.loadMeta().indexRevision, 1);
    expect(store.loadIndex().revision, 1);
    expect(store.readChunk(0, 0, 0)!.instructions, hasLength(1));
    expect(File('${temp.path}/.save/journal.json').existsSync(), isFalse);
    expect(Directory('${temp.path}/.save/backup').existsSync(), isFalse);
  });

  test('空的脏块保存时删除块文件', () {
    writeWorld();
    WorldSave.commit(
      store: WorldStore(temp.path),
      meta: makeMeta(),
      index: makeIndex(),
      dirtyChunks: <ChunkCoord, ChunkFile>{
        const ChunkCoord(0, 0, 0): ChunkFile(
          z: 0,
          cx: 0,
          cy: 0,
          blockSize: 128,
          instructions: const <ChunkInstruction>[],
          terrainRows: const <String>[],
        ),
      },
    );
    expect(File(chunkPath(temp.path, 0, 0, 0)).existsSync(), isFalse);
  });

  test('中途失败时立即回滚原文件', () {
    writeWorld();
    final original = File(chunkPath(temp.path, 0, 0, 0)).readAsStringSync();
    var calls = 0;
    expect(
      () => WorldSave.commit(
        store: WorldStore(temp.path),
        meta: makeMeta(),
        index: makeIndex(),
        dirtyChunks: <ChunkCoord, ChunkFile>{
          const ChunkCoord(0, 0, 0): dirtyChunk(),
        },
        beforeAction: (path) {
          calls++;
          if (calls == 2) throw StateError('注入失败');
        },
      ),
      throwsA(isA<WorldSaveException>()),
    );
    expect(File(chunkPath(temp.path, 0, 0, 0)).readAsStringSync(), original);
    expect(WorldStore(temp.path).loadMeta().indexRevision, 0);
    expect(WorldStore(temp.path).loadIndex().revision, 0);
    expect(File('${temp.path}/.save/journal.json').existsSync(), isFalse);
  });

  test('外部修改原文件时中止并回滚', () {
    writeWorld();
    final metaFile = File(WorldStore(temp.path).metaPath);
    final original = metaFile.readAsStringSync();
    expect(
      () => WorldSave.commit(
        store: WorldStore(temp.path),
        meta: makeMeta(),
        index: makeIndex(),
        dirtyChunks: <ChunkCoord, ChunkFile>{
          const ChunkCoord(0, 0, 0): dirtyChunk(),
        },
        beforeAction: (path) {
          if (path == 'world.meta.json') {
            metaFile.writeAsStringSync('$original\n');
          }
        },
      ),
      throwsA(isA<WorldSaveException>()),
    );
    expect(metaFile.readAsStringSync(), original);
  });

  test('恢复 prepared journal 时恢复备份并删除新增文件', () {
    writeWorld();
    final metaFile = File(WorldStore(temp.path).metaPath);
    final originalMeta = metaFile.readAsBytesSync();
    final originalHash = _sha256(originalMeta);
    final originalStat = metaFile.statSync();
    final added = File('${temp.path}/chunks/0/9_9.chunk')
      ..createSync(recursive: true)
      ..writeAsStringSync('; terrain\n');
    final backup = File('${temp.path}/.save/backup/world.meta.json')
      ..createSync(recursive: true)
      ..writeAsBytesSync(originalMeta);
    final journal = <String, dynamic>{
      'transaction_id': 'tx-test',
      'status': 'prepared',
      'entries': <dynamic>[
        <String, dynamic>{
          'path': 'world.meta.json',
          'action': 'modify',
          'temp': 'world.meta.json.tmp.tx-test',
          'size': originalStat.size,
          'modified_ms': originalStat.modified.millisecondsSinceEpoch,
          'sha256': originalHash,
        },
        <String, dynamic>{
          'path': 'chunks/0/9_9.chunk',
          'action': 'add',
          'temp': 'chunks/0/9_9.chunk.tmp.tx-test',
        },
      ],
    };
    File('${temp.path}/.save/journal.json')
        .writeAsStringSync(jsonEncode(journal));
    metaFile.writeAsStringSync('changed');

    final result = WorldSave.recover(temp.path);
    expect(result.recovered, isTrue);
    expect(metaFile.readAsStringSync(), utf8.decode(originalMeta));
    expect(added.existsSync(), isFalse);
    expect(File('${temp.path}/.save/journal.json').existsSync(), isFalse);
    expect(backup.existsSync(), isFalse);
  });

  test('恢复 committed journal 只清理事务文件', () {
    writeWorld();
    final metaFile = File(WorldStore(temp.path).metaPath);
    final kept = metaFile.readAsStringSync();
    final backup = File('${temp.path}/.save/backup/world.meta.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('backup');
    File('${temp.path}/.save/journal.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'transaction_id': 'tx-done',
        'status': 'committed',
        'entries': <dynamic>[],
      }),
    );
    WorldSave.recover(temp.path);
    expect(metaFile.readAsStringSync(), kept);
    expect(backup.existsSync(), isFalse);
    expect(File('${temp.path}/.save/journal.json').existsSync(), isFalse);
  });
}

String _sha256(List<int> bytes) => crypto.sha256.convert(bytes).toString();
