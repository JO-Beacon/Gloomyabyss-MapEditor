import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/chunk_file.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';
import 'package:gloomyabyss_map_editor/world/world_store.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gloomy_world_store_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('扫描规范块路径并忽略非规范路径', () {
    File('${temp.path}/chunks/0/0_0.chunk')
      ..createSync(recursive: true)
      ..writeAsStringSync('; terrain\n');
    File('${temp.path}/chunks/-1/-2_0.chunk')
      ..createSync(recursive: true)
      ..writeAsStringSync('; terrain\n');
    File('${temp.path}/chunks/0/01_0.chunk')
      ..createSync(recursive: true)
      ..writeAsStringSync('; terrain\n');
    File('${temp.path}/chunks/0/0_0.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('bad');
    Directory('${temp.path}/chunks/01').createSync(recursive: true);

    final result = WorldStore(temp.path).scanChunks();
    expect(result.chunks, <ChunkCoord>[
      const ChunkCoord(-1, -2, 0),
      const ChunkCoord(0, 0, 0),
    ]);
    expect(result.issues, hasLength(3));
  });

  test('读写块文件', () {
    final store = WorldStore(temp.path);
    final chunk = ChunkFile(
      z: -1,
      cx: -2,
      cy: 0,
      blockSize: 128,
      instructions: const <ChunkInstruction>[
        PropInstruction(z: -1, type: 'box', col: -255, row: 3),
      ],
      terrainRows: const <String>['..#'],
    );

    expect(store.readChunk(-1, -2, 0), isNull);
    store.writeChunk(chunk);
    final loaded = store.readChunk(-1, -2, 0);
    expect(loaded, isNotNull);
    expect(loaded!.instructions.single, isA<PropInstruction>());
    expect(loaded.terrainRows, <String>['..#']);
    expect(store.listLayers(), <int>[-1]);
    expect(store.deleteChunk(-1, -2, 0), isTrue);
    expect(store.readChunk(-1, -2, 0), isNull);
  });

  test('块路径使用世界根目录和规范十进制', () {
    expect(
      chunkPath(temp.path, -1, -2, 0),
      '${temp.path}${Platform.pathSeparator}chunks'
      '${Platform.pathSeparator}-1'
      '${Platform.pathSeparator}-2_0.chunk',
    );
  });
}
