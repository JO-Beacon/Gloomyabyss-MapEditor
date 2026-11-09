import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/preview/preview_world.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';

void main() {
  late Directory source;

  setUp(() {
    source = Directory.systemTemp.createTempSync('gloomy_preview_test_');
  });

  tearDown(() {
    if (source.existsSync()) source.deleteSync(recursive: true);
  });

  DefinitionPackage makeDefinitions() {
    final files = <String, List<int>>{
      'terrain.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'tile_size': 20,
          'types': <dynamic>[
            <String, dynamic>{
              'code': '.',
              'name': 'floor',
              'color': <int>[10, 20, 30],
            },
            <String, dynamic>{
              'code': '#',
              'name': 'wall',
              'color': <int>[90, 90, 90],
            },
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

  void writeOldWorld() {
    File('${source.path}/world.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
          },
        ],
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 1, 'row': 1},
      }),
    );
    File('${source.path}/main.seg').writeAsStringSync(
      '; prop=box,2,2\n'
      '; spawn=Obj_Froggit,3,1\n'
      '; portal=door1,right,1,3,2\n'
      '..#.\n'
      '.#..\n'
      '....\n'
      '....\n',
    );
  }

  test('旧世界迁移后可以只读预览，源目录不变', () {
    writeOldWorld();
    final before = <String, String>{
      for (final file in source.listSync().whereType<File>())
        file.path: file.readAsStringSync(),
    };

    final world = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: makeDefinitions(),
    );
    addTearDown(world.dispose);

    expect(world.temporaryDirectory, isNotNull);
    expect(world.sourcePath, source.path);
    expect(world.layers, <int>[0]);
    expect(world.terrainCodeAt(0, 0, 0), '.');
    expect(world.terrainCodeAt(0, 2, 0), '#');
    expect(world.terrainCodeAt(0, 4, 0), isNull);
    expect(world.index.propsObjects.length, 2);
    expect(world.index.portals.length, 1);
    expect(world.boundsFor(0).width, greaterThanOrEqualTo(4));
    expect(world.boundsFor(0).height, greaterThanOrEqualTo(4));

    for (final entry in before.entries) {
      expect(File(entry.key).readAsStringSync(), entry.value);
    }
  });

  test('新格式目录直接预览，不创建临时目录', () {
    writeOldWorld();
    final migrated = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: makeDefinitions(),
    );
    addTearDown(migrated.dispose);

    final loaded = PreviewWorld.loadOrMigrate(
      path: migrated.worldPath,
      definitions: makeDefinitions(),
    );
    addTearDown(loaded.dispose);

    expect(loaded.temporaryDirectory, isNull);
    expect(loaded.terrainCodeAt(0, 2, 0), '#');
    expect(loaded.index.portals.single.id, isNotEmpty);
    expect(loaded.meta.blockSize, 128);
  });
}
