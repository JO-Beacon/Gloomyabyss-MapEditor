import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/chunk_file.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';
import 'package:gloomyabyss_map_editor/world/old_migration.dart';
import 'package:gloomyabyss_map_editor/world/world_store.dart';

void main() {
  late Directory source;
  late Directory output;

  setUp(() {
    source = Directory.systemTemp.createTempSync('gloomy_migrate_src_');
    output = Directory(
      '${source.parent.path}/gloomy_migrate_dst_${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() {
    if (source.existsSync()) source.deleteSync(recursive: true);
    if (output.existsSync()) output.deleteSync(recursive: true);
  });

  void writeSource({
    String segmentText = '',
    Map<String, dynamic>? worldExtra,
  }) {
    final world = <String, dynamic>{
      'version': 1,
      'segments': <dynamic>[
        <String, dynamic>{
          'id': 'main',
          'file': 'main.seg',
          'origin': <int>[5, 7, 2],
        },
      ],
      'pads': <dynamic>[
        <String, dynamic>{'id': 'p1', 'segment': 'main', 'col': 1, 'row': 1},
        <String, dynamic>{'id': 'p2', 'segment': 'main', 'col': 2, 'row': 1},
      ],
      'pad_links': <dynamic>[
        <String, dynamic>{'from': 'p1', 'to': 'p2', 'bidirectional': true},
      ],
      'portal_links': <dynamic>[
        <String, dynamic>{'from': 'main/door1', 'to': 'main/door2'},
      ],
      'seams': <dynamic>[],
      'start': <String, dynamic>{'col': 6, 'row': 8},
      ...?worldExtra,
    };
    File('${source.path}/world.json').writeAsStringSync(jsonEncode(world));
    File('${source.path}/main.seg').writeAsStringSync(
      segmentText.isEmpty
          ? '; prop=box,1,2\n'
                '; spawn=Obj_Froggit,2,1\n'
                '; portal=door1,right,1,0,1\n'
                '; portal=door2,right,2,0,1\n'
                '; solid=0,0,2,0,2,2\n'
                '; pad=p1,1,1\n'
                '..#\n'
                '.#.\n'
          : segmentText,
    );
  }

  DefinitionPackage makeDefinitions() {
    final files = <String, List<int>>{
      'terrain.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'tile_size': 20,
          'types': <dynamic>[
            <String, dynamic>{'code': '.', 'name': 'floor'},
            <String, dynamic>{'code': '#', 'name': 'wall'},
          ],
        }),
      ),
      'props.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'types': <dynamic>[
            <String, dynamic>{
              'id': 'box',
              'name': 'BOX',
              'width': 1,
              'height': 1,
            },
          ],
        }),
      ),
      'objects.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'types': <dynamic>[
            <String, dynamic>{
              'id': 'Obj_Froggit',
              'name': 'Froggit',
              'width': 1,
              'height': 1,
            },
          ],
        }),
      ),
    };
    final hash = computeDefinitionsHash(files);
    return DefinitionPackage.fromFiles(<String, List<int>>{
      ...files,
      'manifest.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'id': 'default',
          'version': 1,
          'hash': hash,
          'upgrades': <dynamic>[],
        }),
      ),
    });
  }

  test('旧世界目录转换为新世界目录', () {
    writeSource();
    File('${source.path}/notes.txt').writeAsStringSync('keep me');
    final definitions = makeDefinitions();
    final result = OldMigration.migrateDirectory(
      OldMigrationOptions(
        sourcePath: source.path,
        outputPath: output.path,
        oldDefinitions: definitions,
        targetDefinitions: definitions,
        name: 'migrated',
      ),
    );
    expect(result.written, isTrue);
    expect(File('${output.path}/notes.txt').readAsStringSync(), 'keep me');
    expect(result.report.segmentCount, 1);
    expect(result.report.chunkCount, 1);
    expect(result.report.portalMapping['main/door1'], 'main__door1');
    expect(result.report.portalMapping['main/door2'], 'main__door2');

    final store = WorldStore(output.path);
    final meta = store.loadMeta();
    expect(meta.name, 'migrated');
    expect(meta.start.col, 6);
    expect(meta.start.row, 8);
    expect(meta.start.z, 2);
    expect(meta.pads.map((p) => p.id), <String>['p1', 'p2']);
    expect(meta.padLinks.single.bidirectional, isTrue);
    expect(meta.portalLinks.single.from, 'main__door1');
    expect(meta.portalLinks.single.to, 'main__door2');

    final chunk = store.readChunk(
      2,
      0,
      0,
      terrainCodes: definitions.terrain.byCode.keys.toSet(),
    )!;
    expect(chunk.terrainRows, hasLength(9));
    expect(chunk.terrainRows[7], '\u0000\u0000\u0000\u0000\u0000..#');
    expect(chunk.terrainRows[8], '\u0000\u0000\u0000\u0000\u0000.#.');
    expect(chunk.instructions.whereType<PortalInstruction>(), hasLength(2));
    expect(chunk.instructions.whereType<SolidInstruction>(), hasLength(1));

    final index = store.loadIndex();
    expect(index.revision, 1);
    expect(index.portals.map((p) => p.id), <String>[
      'main__door1',
      'main__door2',
    ]);
    expect(index.propsObjects, hasLength(2));
    expect(index.solidGroups, hasLength(1));
    expect(index.solidGroups.single.pieces, hasLength(1));
  });

  test('跨块 solid 被切分到相邻块并共享 group', () {
    final rows = List<String>.filled(20, '.' * 20).join('\n');
    writeSource(
      segmentText: '; solid=0,0,20,0,20,20,0,20\n$rows\n',
      worldExtra: <String, dynamic>{
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[120, 0, 0],
          },
        ],
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 120, 'row': 0},
      },
    );
    final definitions = makeDefinitions();
    final result = OldMigration.migrateDirectory(
      OldMigrationOptions(
        sourcePath: source.path,
        outputPath: output.path,
        oldDefinitions: definitions,
        targetDefinitions: definitions,
      ),
    );
    expect(
      result.chunks.keys,
      containsAll(<ChunkCoord>[
        const ChunkCoord(0, 0, 0),
        const ChunkCoord(0, 1, 0),
      ]),
    );
    expect(result.index.solidGroups, hasLength(1));
    expect(result.index.solidGroups.single.pieces, hasLength(2));
    expect(result.index.solidGroups.single.bbox.w, 20);
    expect(result.index.solidGroups.single.bbox.h, 20);
  });

  test('dry-run 不创建输出目录', () {
    writeSource();
    final definitions = makeDefinitions();
    final result = OldMigration.migrateDirectory(
      OldMigrationOptions(
        sourcePath: source.path,
        outputPath: output.path,
        oldDefinitions: definitions,
        targetDefinitions: definitions,
        dryRun: true,
      ),
    );
    expect(result.written, isFalse);
    expect(output.existsSync(), isFalse);
    expect(result.report.chunkCount, 1);
  });

  test('repeat 只复制地形，不复制指令', () {
    writeSource(
      worldExtra: <String, dynamic>{
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
            'repeat': 'x',
            'repeat_count': 2,
          },
        ],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 0, 'row': 0},
      },
      segmentText: '; prop=box,0,0\n..\n..\n',
    );
    final definitions = makeDefinitions();
    final result = OldMigration.migrateDirectory(
      OldMigrationOptions(
        sourcePath: source.path,
        outputPath: output.path,
        oldDefinitions: definitions,
        targetDefinitions: definitions,
      ),
    );
    final chunk = result.chunks.values.single;
    expect(chunk.terrainRows, <String>['....', '....']);
    expect(chunk.instructions, hasLength(1));
    expect(chunk.instructions.single, isA<PropInstruction>());
  });

  test('输出目录已存在时拒绝', () {
    writeSource();
    output.createSync(recursive: true);
    final definitions = makeDefinitions();
    expect(
      () => OldMigration.migrateDirectory(
        OldMigrationOptions(
          sourcePath: source.path,
          outputPath: output.path,
          oldDefinitions: definitions,
          targetDefinitions: definitions,
        ),
      ),
      throwsA(isA<OldMigrationException>()),
    );
  });
}
