/// 把新格式世界目录编码为 GMAP v2 容器。
library;

import 'dart:io';
import 'dart:typed_data';

import '../world/gmap_container.dart';
import '../world/world_store.dart';

class GmapExport {
  GmapExport._();

  static Uint8List encodeDirectory(String root) {
    final entries = <String, Uint8List>{};
    for (final name in <String>['world.meta.json', 'world.index.json']) {
      final file = File('$root${Platform.pathSeparator}$name');
      if (!file.existsSync()) {
        throw FormatException('缺少 $name，无法导出 .gmap');
      }
      entries[name] = Uint8List.fromList(file.readAsBytesSync());
    }
    final store = WorldStore(root);
    for (final coord in store.scanChunks().chunks) {
      final relative = 'chunks/${coord.z}/${coord.cx}_${coord.cy}.chunk';
      final file = File('$root${Platform.pathSeparator}'
          '${relative.replaceAll('/', Platform.pathSeparator)}');
      if (!file.existsSync()) continue;
      entries[relative] = Uint8List.fromList(file.readAsBytesSync());
    }
    return GmapContainer(version: 2, entries: entries).encode();
  }
}
