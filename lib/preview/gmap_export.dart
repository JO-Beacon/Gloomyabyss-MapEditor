/// 把新格式世界目录编码为 GMAP v2 容器。
library;

import 'dart:io';
import 'dart:typed_data';

import '../world/gmap_container.dart';
import '../world/world_store.dart';

class GmapExport {
  GmapExport._();

  static Uint8List encodeDirectory(
    String root, {
    Map<String, Uint8List> extraEntries = const <String, Uint8List>{},
  }) {
    final entries = <String, Uint8List>{...extraEntries};
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

  /// 把目录重新打包并写回已有 `.gmap`。
  ///
  /// 先写同目录临时文件，再备份原包、替换；失败时恢复原包。
  static void saveDirectoryToGmap({
    required String root,
    required String gmapPath,
    Map<String, Uint8List> extraEntries = const <String, Uint8List>{},
  }) {
    final bytes = encodeDirectory(root, extraEntries: extraEntries);
    final target = File(gmapPath);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final temp = File('$gmapPath.tmp.$stamp');
    final backup = File('$gmapPath.bak.$stamp');
    temp.writeAsBytesSync(bytes, flush: true);
    var hadOriginal = false;
    try {
      if (target.existsSync()) {
        target.copySync(backup.path);
        hadOriginal = true;
        target.deleteSync();
      }
      temp.renameSync(gmapPath);
      if (hadOriginal && backup.existsSync()) backup.deleteSync();
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync();
      if (hadOriginal && backup.existsSync()) {
        if (target.existsSync()) target.deleteSync();
        backup.renameSync(gmapPath);
      }
      rethrow;
    }
  }
}
