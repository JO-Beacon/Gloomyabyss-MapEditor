import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/preview/legacy_world_adapter.dart';
import 'package:gloomyabyss_map_editor/preview/preview_world.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';

void main() {
  late Directory source;

  setUp(() {
    source = Directory.systemTemp.createTempSync('gloomy_adapter_test_');
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
      '; pad=0,0,2,2\n'
      '..#.\n'
      '.#..\n'
      '....\n'
      '....\n',
    );
  }

  test('新格式转换成旧 UI 的 World 结构', () {
    writeOldWorld();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: makeDefinitions(),
    );
    addTearDown(preview.dispose);

    final data = LegacyWorldAdapter.fromPreview(preview);

    expect(data.world.segments.length, 1);
    final segment = data.world.segments.first;
    expect(segment.spec.originZ, 0);
    expect(segment.width, 4);
    expect(segment.height, 4);
    expect(segment.rows[0], '..#.');
    expect(segment.rows[1], '.#..');
    expect(segment.instructions, contains('; prop=box,2,2'));
    expect(segment.instructions, contains('; spawn=Obj_Froggit,3,1'));
    expect(
      segment.instructions.any(
        (line) => line.startsWith('; portal=') && line.endsWith(',right,1,3,2'),
      ),
      isTrue,
    );
    expect(data.terrain.byCode.containsKey(' '), isTrue);
    expect(data.terrain.byCode['.']!.color, 0xFF0A141E);

    // `; pad=0,0,2,2` 是旧引擎的四字段写法，迁移后应变成两个传送格和一条连接。
    expect((data.world.raw['pads'] as List).length, 2);
    expect((data.world.raw['pad_links'] as List).length, 1);
    expect((data.world.raw['pads'] as List).first['segment'], '层 0');
  });
}
