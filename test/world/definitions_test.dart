import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';

void main() {
  Map<String, List<int>> makeFiles({
    String? terrain,
    String? props,
    String? objects,
  }) {
    return <String, List<int>>{
      'terrain.json': utf8.encode(
        terrain ??
            jsonEncode(<String, dynamic>{
              'version': 1,
              'tile_size': 20,
              'types': <dynamic>[
                <String, dynamic>{
                  'code': '.',
                  'name': 'floor',
                  'color': <int>[255, 255, 255],
                  'block': false,
                  'speed': 1.0,
                  'damage': 0.0,
                  'custom': 'keep',
                },
              ],
            }),
      ),
      'props.json': utf8.encode(
        props ??
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
        objects ??
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
  }

  Map<String, List<int>> withManifest(
    Map<String, List<int>> files, {
    String? hash,
    int version = 1,
    List<Map<String, dynamic>> upgrades = const <Map<String, dynamic>>[],
  }) {
    final manifest = <String, dynamic>{
      'id': 'default',
      'version': version,
      'hash': hash ?? computeDefinitionsHash(files),
      'upgrades': upgrades,
    };
    return <String, List<int>>{
      ...files,
      'manifest.json': utf8.encode(jsonEncode(manifest)),
    };
  }

  test('定义包 hash 按三个文件的原始字节计算', () {
    final files = makeFiles();
    final expected = computeDefinitionsHash(files);
    expect(expected, startsWith('sha256:'));
    expect(expected.length, 7 + 64);

    final package = DefinitionPackage.fromFiles(withManifest(files));
    expect(package.filesHash, expected);
    expect(package.manifest.id, 'default');
    expect(package.terrain.tileSize, 20);
    expect(package.props.single.id, 'box');
    expect(package.objects.single.width, 1);
  });

  test('定义包 hash 不匹配时拒绝加载', () {
    final files = makeFiles();
    expect(
      () => DefinitionPackage.fromFiles(
        withManifest(files, hash: 'sha256:${'0' * 64}'),
      ),
      throwsFormatException,
    );
  });

  test('未知字段读取后保留', () {
    final files = makeFiles();
    final package = DefinitionPackage.fromFiles(withManifest(files));
    expect(package.terrain.types.single.toJson()['custom'], 'keep');
    expect(package.props.single.toJson()['name'], 'BOX');
    expect(package.objects.single.toJson()['width'], 1);
  });

  test('对象缺少宽高时拒绝加载', () {
    final files = makeFiles(
      objects: jsonEncode(<String, dynamic>{
        'version': 1,
        'types': <dynamic>[
          <String, dynamic>{'id': 'Obj_Froggit', 'name': 'Froggit'},
        ],
      }),
    );
    expect(
      () => DefinitionPackage.fromFiles(withManifest(files)),
      throwsFormatException,
    );
  });

  test('地形 code 必须是单个码点且不能是分号', () {
    final files = makeFiles(
      terrain: jsonEncode(<String, dynamic>{
        'version': 1,
        'tile_size': 20,
        'types': <dynamic>[
          <String, dynamic>{'code': '..', 'name': 'bad'},
        ],
      }),
    );
    expect(
      () => DefinitionPackage.fromFiles(withManifest(files)),
      throwsFormatException,
    );
  });
}
