import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/world_meta.dart';

void main() {
  Map<String, dynamic> sampleJson() => <String, dynamic>{
    'version': 2,
    'name': 'corridor',
    'block_size': 128,
    'chunk_format_version': 1,
    'definitions': <String, dynamic>{
      'id': 'default',
      'version': 1,
      'hash': 'sha256:${'a' * 64}',
    },
    'index_revision': 12,
    'start': <String, dynamic>{'col': 2, 'row': 6, 'z': 0},
    'pads': <dynamic>[
      <String, dynamic>{'id': 'p1', 'col': 3, 'row': 4, 'z': 0},
      <String, dynamic>{'id': 'p2', 'col': 8, 'row': 4, 'z': 0},
    ],
    'pad_links': <dynamic>[
      <String, dynamic>{'from': 'p1', 'to': 'p2'},
    ],
    'portal_links': <dynamic>[
      <String, dynamic>{'from': 'lp1', 'to': 'lp2', 'face': 'B'},
    ],
    'custom_field': 'keep',
  };

  test('解析 world.meta.json', () {
    final meta = WorldMeta.fromJson(sampleJson());
    expect(meta.version, 2);
    expect(meta.blockSize, 128);
    expect(meta.pads, hasLength(2));
    expect(meta.padLinks.single.bidirectional, isFalse);
    expect(meta.portalLinks.single.face, PortalFace.b);
    expect(meta.toJson()['custom_field'], 'keep');
    expect(meta.validate(), isEmpty);
  });

  test('pads 和连接缺失时按空数组处理', () {
    final json = sampleJson()
      ..remove('pads')
      ..remove('pad_links')
      ..remove('portal_links');
    final meta = WorldMeta.fromJson(json);
    expect(meta.pads, isEmpty);
    expect(meta.padLinks, isEmpty);
    expect(meta.portalLinks, isEmpty);
  });

  test('face 区分大小写且必须显式写', () {
    for (final face in <String>['a', 'AB', 'both ']) {
      final json = sampleJson();
      json['portal_links'] = <dynamic>[
        <String, dynamic>{'from': 'lp1', 'to': 'lp2', 'face': face},
      ];
      expect(() => WorldMeta.fromJson(json), throwsFormatException);
    }
    final json = sampleJson();
    json['portal_links'] = <dynamic>[
      <String, dynamic>{'from': 'lp1', 'to': 'lp2'},
    ];
    expect(() => WorldMeta.fromJson(json), throwsFormatException);
  });

  test('重复传送格和自环连接被报告', () {
    final json = sampleJson();
    json['pads'] = <dynamic>[
      <String, dynamic>{'id': 'p1', 'col': 3, 'row': 4, 'z': 0},
      <String, dynamic>{'id': 'p1', 'col': 5, 'row': 6, 'z': 0},
    ];
    json['pad_links'] = <dynamic>[
      <String, dynamic>{'from': 'p1', 'to': 'p1'},
    ];
    final errors = WorldMeta.fromJson(json).validate();
    expect(errors.any((e) => e.contains('重复')), isTrue);
    expect(errors.any((e) => e.contains('自环')), isTrue);
  });

  test('同一格不能放多个传送格', () {
    final json = sampleJson();
    json['pads'] = <dynamic>[
      <String, dynamic>{'id': 'p1', 'col': 3, 'row': 4, 'z': 0},
      <String, dynamic>{'id': 'p2', 'col': 3, 'row': 4, 'z': 0},
    ];
    json['pad_links'] = <dynamic>[];
    final errors = WorldMeta.fromJson(json).validate();
    expect(errors.any((e) => e.contains('同一格')), isTrue);
  });

  test('encode 保留未知字段', () {
    final meta = WorldMeta.fromJson(sampleJson());
    final decoded = jsonDecode(meta.encode()) as Map<String, dynamic>;
    expect(decoded['custom_field'], 'keep');
    expect(decoded['start'], <String, dynamic>{'col': 2, 'row': 6, 'z': 0});
  });
}
