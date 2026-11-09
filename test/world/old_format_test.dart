import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';
import 'package:gloomyabyss_map_editor/world/old_format.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('gloomy_old_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  void writeWorld({
    String segment = 'main.seg',
    String segmentText = '; name=Main\n..#\n.#.\n',
    Map<String, dynamic>? extraWorld,
  }) {
    final world = <String, dynamic>{
      'version': 1,
      'segments': <dynamic>[
        <String, dynamic>{
          'id': 'main',
          'file': segment,
          'origin': <int>[0, 0, 0],
        },
      ],
      'pads': <dynamic>[
        <String, dynamic>{'id': 'p1', 'segment': 'main', 'col': 1, 'row': 1},
      ],
      'pad_links': <dynamic>[
        <String, dynamic>{'from': 'p1', 'to': 'p2', 'bidirectional': true},
      ],
      'portal_links': <dynamic>[
        <String, dynamic>{'from': 'main/door1', 'to': 'main/door2'},
      ],
      'seams': <dynamic>[],
      'start': <String, dynamic>{'col': 0, 'row': 0},
      ...?extraWorld,
    };
    File('${temp.path}/world.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(world));
    File('${temp.path}/$segment')
      ..createSync(recursive: true)
      ..writeAsStringSync(segmentText);
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

  test('读取旧世界、段和指令', () {
    writeWorld(
      segmentText:
          '; name=Main\n'
          '; prop=box,1,2\n'
          '; spawn=Obj_Froggit,2,3\n'
          '; solid=0,0,2,0,2,2\n'
          '; portal=door1,right,1,0,1\n'
          '; pad=p1,1,1\n'
          '..#\n'
          '.#.\n',
    );
    final world = OldWorldData.loadDirectory(temp.path);
    expect(world.version, 1);
    expect(world.segments, hasLength(1));
    final segment = world.segments.single;
    expect(segment.name, 'Main');
    expect(segment.width, 3);
    expect(segment.height, 2);
    expect(segment.instructions, hasLength(5));
    expect(segment.instructions[0], isA<OldPropInstruction>());
    expect(segment.instructions[1], isA<OldSpawnInstruction>());
    expect(segment.instructions[2], isA<OldSolidInstruction>());
    expect(segment.instructions[3], isA<OldPortalInstruction>());
    expect(segment.instructions[4], isA<OldPadInstruction>());
    expect(world.pads.single.id, 'p1');
    expect(world.padLinks.single.bidirectional, isTrue);
    expect(world.portalLinks.single.face, 'A');
    expect(world.startCol, 0);
    expect(world.startRow, 0);
    world.validateDefinitions(makeDefinitions());
  });

  test('未知指令默认报错，keepUnknown 时保留', () {
    writeWorld(segmentText: '; mystery=1\n.\n');
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
    final world = OldWorldData.loadDirectory(temp.path, keepUnknown: true);
    expect(
      world.segments.single.instructions.single,
      isA<OldUnknownInstruction>(),
    );
  });

  test('无限 repeat 拒绝', () {
    writeWorld(
      extraWorld: <String, dynamic>{
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
            'repeat': 'x',
            'repeat_count': 0,
          },
        ],
      },
    );
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
  });

  test('非 BMP 字符拒绝', () {
    writeWorld(segmentText: '😀\n');
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
  });

  test('地形行长度不一致拒绝', () {
    writeWorld(segmentText: '..\n.\n');
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
  });

  test('传送门超出旧段范围拒绝', () {
    writeWorld(segmentText: '; portal=p,right,2,0,1\n..\n');
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
  });

  test('重复段地形重叠拒绝', () {
    writeWorld(
      extraWorld: <String, dynamic>{
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'a',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
          },
          <String, dynamic>{
            'id': 'b',
            'file': 'main.seg',
            'origin': <int>[1, 0, 0],
          },
        ],
      },
    );
    expect(
      () => OldWorldData.loadDirectory(temp.path),
      throwsA(isA<OldFormatException>()),
    );
  });

  test('portal_planes 直接忽略，seams 保留', () {
    writeWorld(
      extraWorld: <String, dynamic>{
        'portal_planes': <dynamic>[
          <String, dynamic>{'axis': 'x'},
        ],
        'seams': <dynamic>[
          <String, dynamic>{'a': 'b'},
        ],
      },
    );
    final world = OldWorldData.loadDirectory(temp.path);
    expect(world.seams, hasLength(1));
  });
}
