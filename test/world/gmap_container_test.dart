import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/gmap_container.dart';

void main() {
  test('v2 容器往返并按名字排序', () {
    final container = GmapContainer(
      version: 2,
      entries: <String, Uint8List>{
        'world.meta.json': Uint8List.fromList(<int>[1, 2, 3]),
        'chunks/0/0_0.chunk': Uint8List.fromList(<int>[4, 5]),
      },
    );
    final bytes = container.encode();
    final decoded = GmapContainer.decode(bytes);
    expect(decoded.version, 2);
    expect(decoded.entries.keys.toList(), <String>[
      'chunks/0/0_0.chunk',
      'world.meta.json',
    ]);
    expect(decoded.entries['world.meta.json'], <int>[1, 2, 3]);
  });

  test('旧 v1 容器可读取但默认拒绝', () {
    final bytes = GmapContainer(
      version: 1,
      entries: <String, Uint8List>{
        'world.json': Uint8List.fromList(<int>[123]),
      },
    ).encode();
    expect(() => GmapContainer.decode(bytes), throwsA(isA<GmapException>()));
    final decoded = GmapContainer.decode(bytes, allowVersion1: true);
    expect(decoded.version, 1);
    expect(decoded.entries['world.json'], <int>[123]);
  });

  test('拒绝路径穿越和重复条目', () {
    expect(
      () => GmapContainer(
        version: 2,
        entries: <String, Uint8List>{'../world.json': Uint8List(0)},
      ).encode(),
      throwsA(isA<GmapException>()),
    );
    expect(
      () => GmapContainer(
        version: 2,
        entries: <String, Uint8List>{'a/b': Uint8List(0), 'a\\b': Uint8List(0)},
      ).encode(),
      throwsA(isA<GmapException>()),
    );
  });
}
