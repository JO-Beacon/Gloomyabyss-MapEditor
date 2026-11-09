import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/chunk_file.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';
import 'package:gloomyabyss_map_editor/world/world_index_builder.dart';

void main() {
  DefinitionPackage makeDefinitions() {
    final files = <String, List<int>>{
      'terrain.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'tile_size': 20,
          'types': <dynamic>[
            <String, dynamic>{'code': '.', 'name': 'floor'},
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
              'width': 2,
              'height': 3,
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
    final manifest = <String, dynamic>{
      'id': 'default',
      'version': 1,
      'hash': hash,
      'upgrades': <dynamic>[],
    };
    return DefinitionPackage.fromFiles(<String, List<int>>{
      ...files,
      'manifest.json': utf8.encode(jsonEncode(manifest)),
    });
  }

  ChunkFile chunk(int cx, {required List<ChunkInstruction> instructions}) {
    return ChunkFile(
      z: 0,
      cx: cx,
      cy: 0,
      blockSize: 128,
      instructions: instructions,
      terrainRows: const <String>[],
    );
  }

  test('从块文件生成传送门、道具对象和碰撞组索引', () {
    final chunks = <ChunkCoord, ChunkFile>{
      const ChunkCoord(0, 0, 0): chunk(
        0,
        instructions: const <ChunkInstruction>[
          PropInstruction(z: 0, type: 'box', col: 1, row: 2),
          SpawnInstruction(z: 0, type: 'Obj_Froggit', col: 3, row: 4),
          PortalInstruction(
            id: 'lp1',
            dir: 'right',
            x: 5,
            y: 6,
            length: 3,
            z: 0,
          ),
          SolidInstruction(
            z: 0,
            group: 's1',
            points: <(double, double)>[(0, 0), (10, 0), (0, 10)],
          ),
        ],
      ),
      const ChunkCoord(0, 1, 0): chunk(
        1,
        instructions: const <ChunkInstruction>[
          PortalInstruction(
            id: 'lp2',
            dir: 'right',
            x: 128,
            y: 6,
            length: 3,
            z: 0,
          ),
          SolidInstruction(
            z: 0,
            group: 's1',
            points: <(double, double)>[(20, 0), (30, 0), (20, 10)],
          ),
        ],
      ),
    };

    final result = buildWorldIndex(
      chunks: chunks,
      definitions: makeDefinitions(),
      revision: 7,
    );
    final index = result.index;
    expect(index.revision, 7);
    expect(index.portals.map((p) => p.id), <String>['lp1', 'lp2']);
    expect(index.portals[1].chunk, const BlockCoord(1, 0));
    expect(index.propsObjects, hasLength(2));
    final prop = index.propsObjects.singleWhere((e) => e.kind == 'prop');
    expect(prop.w, 2);
    expect(prop.h, 3);
    expect(index.solidGroups.single.pieces, hasLength(2));
    expect(index.solidGroups.single.pieces[0].index, 0);
    expect(index.solidGroups.single.pieces[1].index, 0);
    expect(index.solidGroups.single.bbox, const FloatRect(0, 0, 30, 10));
    expect(result.warnings, isEmpty);
  });

  test('退化碰撞片段只警告不进入索引', () {
    final result = buildWorldIndex(
      chunks: <ChunkCoord, ChunkFile>{
        const ChunkCoord(0, 0, 0): chunk(
          0,
          instructions: const <ChunkInstruction>[
            SolidInstruction(
              z: 0,
              group: 's1',
              points: <(double, double)>[(0, 0), (1, 1), (2, 2)],
            ),
          ],
        ),
      },
      definitions: makeDefinitions(),
      revision: 1,
    );
    expect(result.index.solidGroups, isEmpty);
    expect(result.warnings.any((w) => w.contains('退化')), isTrue);
  });

  test('未知类型直接报错', () {
    expect(
      () => buildWorldIndex(
        chunks: <ChunkCoord, ChunkFile>{
          const ChunkCoord(0, 0, 0): chunk(
            0,
            instructions: const <ChunkInstruction>[
              PropInstruction(z: 0, type: 'missing', col: 1, row: 2),
            ],
          ),
        },
        definitions: makeDefinitions(),
        revision: 1,
      ),
      throwsFormatException,
    );
  });
}
