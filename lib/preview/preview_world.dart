/// V1 只读预览使用的世界加载器。
///
/// 只读取世界，不写源目录。v1 世界会先迁移到系统临时目录的副本。
library;

import 'dart:io';
import 'dart:typed_data';

import '../world/chunk_file.dart';
import '../world/gmap_container.dart';
import '../world/definitions.dart';
import '../world/geometry.dart';
import '../world/old_migration.dart';
import '../world/world_index.dart';
import '../world/world_index_builder.dart';
import '../world/world_meta.dart';
import '../world/world_store.dart';

/// 一层世界的可视范围，单位是格。
class PreviewBounds {
  PreviewBounds({
    required this.minCol,
    required this.minRow,
    required this.maxCol,
    required this.maxRow,
  });

  final int minCol;
  final int minRow;
  final int maxCol;
  final int maxRow;

  int get width => maxCol - minCol + 1;
  int get height => maxRow - minRow + 1;

  static PreviewBounds? fromPoints(Iterable<(int, int)> points) {
    int? minCol;
    int? minRow;
    int? maxCol;
    int? maxRow;
    for (final (col, row) in points) {
      minCol = minCol == null || col < minCol ? col : minCol;
      minRow = minRow == null || row < minRow ? row : minRow;
      maxCol = maxCol == null || col > maxCol ? col : maxCol;
      maxRow = maxRow == null || row > maxRow ? row : maxRow;
    }
    if (minCol == null || minRow == null || maxCol == null || maxRow == null) {
      return null;
    }
    return PreviewBounds(
      minCol: minCol,
      minRow: minRow,
      maxCol: maxCol,
      maxRow: maxRow,
    );
  }
}

/// 一个已经加载到内存的预览世界。
class PreviewWorld {
  PreviewWorld({
    required this.worldPath,
    required this.meta,
    required this.index,
    required this.definitions,
    required this.chunksByLayer,
    required this.boundsByLayer,
    this.sourcePath,
    this.temporaryDirectory,
    this.migrationReport,
    this.gmapPath,
    this.gmapExtraEntries = const <String, Uint8List>{},
  });

  final String worldPath;
  final WorldMeta meta;
  final WorldIndex index;
  final DefinitionPackage definitions;
  final Map<int, Map<BlockCoord, ChunkFile>> chunksByLayer;
  final Map<int, PreviewBounds> boundsByLayer;
  final String? sourcePath;

  /// 迁移旧世界时创建的临时目录；预览关闭时由页面删除。
  final Directory? temporaryDirectory;
  final String? migrationReport;

  /// 如果世界来自 `.gmap`，这里是源包路径；保存时写回这个包。
  final String? gmapPath;

  /// `.gmap` 里除世界文件以外的条目（如 definitions 快照），保存时原样带回。
  final Map<String, Uint8List> gmapExtraEntries;

  List<int> get layers {
    final values = <int>{...chunksByLayer.keys, ...boundsByLayer.keys}.toList();
    values.sort();
    return values;
  }

  PreviewBounds boundsFor(int z) =>
      boundsByLayer[z] ??
      PreviewBounds(minCol: 0, minRow: 0, maxCol: 1, maxRow: 1);

  /// 取某一格的地形代码；没有地形返回 null。
  String? terrainCodeAt(int z, int col, int row) {
    final chunk = chunkAt(z, col, row);
    if (chunk == null) return null;
    final localCol = positiveMod(col, meta.blockSize);
    final localRow = positiveMod(row, meta.blockSize);
    if (localRow >= chunk.terrainRows.length) return null;
    final line = chunk.terrainRows[localRow];
    final runes = line.runes.toList(growable: false);
    if (localCol >= runes.length) return null;
    final code = String.fromCharCode(runes[localCol]);
    if (code == emptyTerrainPadding) return null;
    return code;
  }

  ChunkFile? chunkAt(int z, int col, int row) {
    final coord = blockIndexOf(col, row, meta.blockSize);
    return chunksByLayer[z]?[coord];
  }

  void dispose() {
    final temp = temporaryDirectory;
    if (temp != null && temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }

  /// 打开 GMAP v2 包：解包到临时目录后按新格式读取。
  static PreviewWorld loadGmapFile({
    required String path,
    required DefinitionPackage definitions,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw const FormatException('.gmap 不存在');
    }
    final container = GmapContainer.decode(file.readAsBytesSync());
    if (container.version != 2) {
      throw const FormatException('只打开 GMAP v2 包；v1 请先用迁移功能');
    }
    final temp = Directory.systemTemp.createTempSync('gloomy_gmap_open_');
    try {
      final extraEntries = <String, Uint8List>{};
      for (final entry in container.entries.entries) {
        if (entry.key != 'world.meta.json' &&
            entry.key != 'world.index.json' &&
            !entry.key.startsWith('chunks/')) {
          extraEntries[entry.key] = entry.value;
        }
        final target = File(
          '${temp.path}${Platform.pathSeparator}'
          '${entry.key.replaceAll('/', Platform.pathSeparator)}',
        );
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(entry.value, flush: true);
      }
      if (!File('${temp.path}${Platform.pathSeparator}world.meta.json')
          .existsSync()) {
        throw const FormatException('.gmap 内缺少 world.meta.json');
      }
      return _loadNewFormat(
        worldPath: temp.path,
        definitions: definitions,
        sourcePath: path,
        temporaryDirectory: temp,
        gmapPath: path,
        gmapExtraEntries: extraEntries,
      );
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// 打开目录：有 `world.meta.json` 按新格式读取，有 `world.json` 先迁移。
  static PreviewWorld loadOrMigrate({
    required String path,
    required DefinitionPackage definitions,
    bool keepUnknown = true,
  }) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw const FormatException('目录不存在');
    }
    if (File(_join(path, 'world.meta.json')).existsSync()) {
      return _loadNewFormat(
        worldPath: path,
        definitions: definitions,
        sourcePath: path,
      );
    }
    if (!File(_join(path, 'world.json')).existsSync()) {
      throw const FormatException('目录里既没有 world.meta.json，也没有 world.json');
    }
    return _migrateOldWorld(
      sourcePath: path,
      definitions: definitions,
      keepUnknown: keepUnknown,
    );
  }

  static PreviewWorld _migrateOldWorld({
    required String sourcePath,
    required DefinitionPackage definitions,
    required bool keepUnknown,
  }) {
    final temp = Directory.systemTemp.createTempSync('gloomy_preview_');
    final outputPath = _join(temp.path, 'world');
    try {
      final result = OldMigration.migrateDirectory(
        OldMigrationOptions(
          sourcePath: sourcePath,
          outputPath: outputPath,
          oldDefinitions: definitions,
          targetDefinitions: definitions,
          name: _basename(sourcePath),
          keepUnknown: keepUnknown,
        ),
      );
      return _loadNewFormat(
        worldPath: outputPath,
        definitions: definitions,
        sourcePath: sourcePath,
        temporaryDirectory: temp,
        migrationReport:
            '已从 v1 迁移：${result.report.segmentCount} 个段，'
            '${result.report.chunkCount} 个块；'
            '传送门 ${result.report.portalMapping.length} 个，'
            '传送格 ${result.report.padMapping.length} 个',
      );
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
      rethrow;
    }
  }

  static PreviewWorld _loadNewFormat({
    required String worldPath,
    required DefinitionPackage definitions,
    required String sourcePath,
    Directory? temporaryDirectory,
    String? migrationReport,
    String? gmapPath,
    Map<String, Uint8List> gmapExtraEntries = const <String, Uint8List>{},
  }) {
    final store = WorldStore(worldPath);
    final meta = store.loadMeta();
    if (meta.definitions.id != definitions.manifest.id ||
        meta.definitions.version != definitions.manifest.version ||
        meta.definitions.hash != definitions.manifest.hash) {
      throw FormatException(
        '这个世界引用的定义包是 '
        '${meta.definitions.id} v${meta.definitions.version} '
        '${meta.definitions.hash}，'
        '当前预览只内置了 '
        '${definitions.manifest.id} v${definitions.manifest.version}',
      );
    }
    final scan = store.scanChunks();
    final chunks = <ChunkCoord, ChunkFile>{};
    final chunksByLayer = <int, Map<BlockCoord, ChunkFile>>{};
    final terrainCodes = definitions.terrain.byCode.keys.toSet();
    for (final coord in scan.chunks) {
      final file = File(chunkPath(worldPath, coord.z, coord.cx, coord.cy));
      if (!file.existsSync()) continue;
      final chunk = ChunkFile.parse(
        content: file.readAsStringSync(),
        z: coord.z,
        cx: coord.cx,
        cy: coord.cy,
        blockSize: meta.blockSize,
        terrainCodes: terrainCodes,
      );
      chunks[coord] = chunk;
      chunksByLayer
          .putIfAbsent(coord.z, () => <BlockCoord, ChunkFile>{})
          .putIfAbsent(BlockCoord(coord.cx, coord.cy), () => chunk);
    }

    WorldIndex index;
    if (store.tryLoadIndex() != null) {
      index = store.loadIndex();
      if (index.revision != meta.indexRevision) {
        throw FormatException(
          'world.index.json revision ${index.revision} 与 meta.index_revision '
          '${meta.indexRevision} 不一致',
        );
      }
    } else {
      index = buildWorldIndex(
        chunks: chunks,
        definitions: definitions,
        revision: meta.indexRevision,
        fullCheckedAt: '',
      ).index;
    }

    final boundsByLayer = _computeBounds(
      meta: meta,
      index: index,
      chunksByLayer: chunksByLayer,
      definitions: definitions,
    );

    return PreviewWorld(
      worldPath: worldPath,
      meta: meta,
      index: index,
      definitions: definitions,
      chunksByLayer: chunksByLayer,
      boundsByLayer: boundsByLayer,
      sourcePath: sourcePath,
      temporaryDirectory: temporaryDirectory,
      migrationReport: migrationReport,
      gmapPath: gmapPath,
      gmapExtraEntries: gmapExtraEntries,
    );
  }

  static Map<int, PreviewBounds> _computeBounds({
    required WorldMeta meta,
    required WorldIndex index,
    required Map<int, Map<BlockCoord, ChunkFile>> chunksByLayer,
    required DefinitionPackage definitions,
  }) {
    final pointsByLayer = <int, List<(int, int)>>{};

    for (final entry in chunksByLayer.entries) {
      final z = entry.key;
      final points = pointsByLayer.putIfAbsent(z, () => <(int, int)>[]);
      for (final chunk in entry.value.values) {
        final baseCol = chunk.cx * meta.blockSize;
        final baseRow = chunk.cy * meta.blockSize;
        for (var row = 0; row < chunk.terrainRows.length; row++) {
          final runes = chunk.terrainRows[row].runes.toList(growable: false);
          for (var col = 0; col < runes.length; col++) {
            if (String.fromCharCode(runes[col]) == emptyTerrainPadding) {
              continue;
            }
            points.add((baseCol + col, baseRow + row));
          }
        }
        for (final instruction in chunk.instructions) {
          switch (instruction) {
            case PropInstruction():
              final def = definitions.propsById[instruction.type];
              final w = def?.width ?? 1;
              final h = def?.height ?? 1;
              points
                ..add((instruction.col, instruction.row))
                ..add((instruction.col + w - 1, instruction.row + h - 1));
            case SpawnInstruction():
              final def = definitions.objectsById[instruction.type];
              final w = def?.width ?? 1;
              final h = def?.height ?? 1;
              points
                ..add((instruction.col, instruction.row))
                ..add((instruction.col + w - 1, instruction.row + h - 1));
            case PortalInstruction():
              if (instruction.dir == 'right') {
                points
                  ..add((instruction.x, instruction.y))
                  ..add((instruction.x + instruction.length - 1, instruction.y));
              } else {
                points
                  ..add((instruction.x, instruction.y))
                  ..add((instruction.x, instruction.y + instruction.length - 1));
              }
            case SolidInstruction():
              for (final (x, y) in instruction.points) {
                points
                  ..add((x.floor(), y.floor()))
                  ..add((x.ceil(), y.ceil()));
              }
            case UnknownInstruction():
              break;
          }
        }
      }
    }

    for (final portal in index.portals) {
      final points = pointsByLayer.putIfAbsent(portal.z, () => <(int, int)>[]);
      if (portal.dir == 'right') {
        points
          ..add((portal.x, portal.y))
          ..add((portal.x + portal.length - 1, portal.y));
      } else {
        points
          ..add((portal.x, portal.y))
          ..add((portal.x, portal.y + portal.length - 1));
      }
    }
    for (final item in index.propsObjects) {
      final points = pointsByLayer.putIfAbsent(item.z, () => <(int, int)>[]);
      points
        ..add((item.col, item.row))
        ..add((item.col + item.w - 1, item.row + item.h - 1));
    }
    for (final pad in meta.pads) {
      pointsByLayer.putIfAbsent(pad.z, () => <(int, int)>[]).add((pad.col, pad.row));
    }
    for (final group in index.solidGroups) {
      final points = pointsByLayer.putIfAbsent(group.z, () => <(int, int)>[]);
      points
        ..add((group.bbox.x.floor(), group.bbox.y.floor()))
        ..add((
          (group.bbox.x + group.bbox.w).ceil(),
          (group.bbox.y + group.bbox.h).ceil(),
        ));
    }
    pointsByLayer
        .putIfAbsent(meta.start.z, () => <(int, int)>[])
        .add((meta.start.col, meta.start.row));

    final result = <int, PreviewBounds>{};
    for (final entry in pointsByLayer.entries) {
      final bounds = PreviewBounds.fromPoints(entry.value);
      if (bounds != null) result[entry.key] = bounds;
    }
    return result;
  }
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) return '$left$right';
  return '$left${Platform.pathSeparator}$right';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}
