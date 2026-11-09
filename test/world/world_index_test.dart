import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';
import 'package:gloomyabyss_map_editor/world/world_index.dart';

void main() {
  Map<String, dynamic> sampleJson() => <String, dynamic>{
    'revision': 12,
    'full_checked_at': '',
    'portals': <dynamic>[
      <String, dynamic>{
        'id': 'lp1',
        'z': 0,
        'x': 11,
        'y': 5,
        'dir': 'right',
        'length': 3,
        'chunk': <int>[0, 0],
      },
    ],
    'props_objects': <dynamic>[
      <String, dynamic>{
        'kind': 'object',
        'type': 'Obj_Froggit',
        'z': 0,
        'col': 22,
        'row': 3,
        'w': 1,
        'h': 1,
        'chunk': <int>[0, 0],
      },
    ],
    'solid_groups': <dynamic>[
      <String, dynamic>{
        'group': 's1',
        'z': 0,
        'bbox': <num>[10, 20, 40, 50],
        'pieces': <dynamic>[
          <String, dynamic>{
            'chunk': <int>[0, 0],
            'index': 0,
            'bbox': <num>[10, 20, 20, 50],
          },
          <String, dynamic>{
            'chunk': <int>[0, 0],
            'index': 1,
            'bbox': <num>[30, 20, 20, 50],
          },
        ],
      },
    ],
    'custom': 'keep',
  };

  test('解析 world.index.json', () {
    final index = WorldIndex.fromJson(sampleJson());
    expect(index.revision, 12);
    expect(index.portals.single.chunk, const BlockCoord(0, 0));
    expect(index.propsObjects.single.type, 'Obj_Froggit');
    expect(index.solidGroups.single.bbox, const FloatRect(10, 20, 40, 50));
    expect(index.solidGroups.single.pieces, hasLength(2));
    expect(index.toJson()['custom'], 'keep');
    expect(index.validate(), isEmpty);
  });

  test('重复的道具对象身份被报告', () {
    final json = sampleJson();
    final item = (json['props_objects'] as List).first;
    json['props_objects'] = <dynamic>[item, Map<String, dynamic>.from(item)];
    final errors = WorldIndex.fromJson(json).validate();
    expect(errors.any((e) => e.contains('重复')), isTrue);
  });

  test('重复的 portal id 和 group 被报告', () {
    final json = sampleJson();
    final portal = (json['portals'] as List).first;
    json['portals'] = <dynamic>[portal, Map<String, dynamic>.from(portal)];
    final group = (json['solid_groups'] as List).first;
    json['solid_groups'] = <dynamic>[group, Map<String, dynamic>.from(group)];
    final errors = WorldIndex.fromJson(json).validate();
    expect(errors.where((e) => e.contains('重复')).length, 2);
  });

  test('kind 只允许 prop 或 object', () {
    final json = sampleJson();
    (json['props_objects'] as List).first['kind'] = 'npc';
    expect(() => WorldIndex.fromJson(json), throwsFormatException);
  });

  test('encode 使用 props_objects 键', () {
    final index = WorldIndex.fromJson(sampleJson());
    final decoded = jsonDecode(index.encode()) as Map<String, dynamic>;
    expect(decoded.containsKey('props_objects'), isTrue);
    expect(decoded.containsKey('entities'), isFalse);
  });
}
