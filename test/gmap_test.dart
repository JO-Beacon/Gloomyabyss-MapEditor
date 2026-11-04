import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/io/gmap.dart';

void main() {
  test('.gmap 往返', () {
    final files = <String, Uint8List>{
      'world.json': Uint8List.fromList(utf8.encode('{"version":1}')),
      'main.map': Uint8List.fromList(utf8.encode('....\n####\n')),
    };

    final bytes = GmapFile.encode(files);
    expect(bytes.sublist(0, 4), GmapFile.magic);

    final out = GmapFile.decode(bytes);
    expect(out.keys.toSet(), files.keys.toSet());
    expect(utf8.decode(out['main.map']!), '....\n####\n');
  });

  test('拒绝非 .gmap', () {
    expect(
      () => GmapFile.decode(Uint8List.fromList(utf8.encode('NOPE1234'))),
      throwsFormatException,
    );
  });

  test('拒绝截断', () {
    final bytes = GmapFile.encode({
      'a.map': Uint8List.fromList([1, 2, 3, 4]),
    });
    expect(
      () => GmapFile.decode(Uint8List.sublistView(bytes, 0, bytes.length - 2)),
      throwsFormatException,
    );
  });
}
