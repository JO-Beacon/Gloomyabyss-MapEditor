/// 世界目录布局和块文件扫描。
///
/// 负责 `world.meta.json`、`world.index.json` 和 `chunks/<z>/<cx>_<cy>.chunk`
/// 的路径解析；保存事务在更高层实现。
library;

import 'dart:convert';
import 'dart:io';

import 'chunk_file.dart';
import 'geometry.dart';
import 'world_index.dart';
import 'world_meta.dart';

final RegExp _canonicalIntPattern = RegExp(r'^(?:0|-?[1-9][0-9]*)$');
final RegExp _chunkFileNamePattern = RegExp(
  r'^((?:0|-?[1-9][0-9]*))_((?:0|-?[1-9][0-9]*))\.chunk$',
);

/// 扫描块目录时发现的问题；不合法路径不会进入块列表。
class ChunkScanIssue {
  const ChunkScanIssue(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => '$path：$message';
}

/// 块目录扫描结果。
class ChunkScanResult {
  const ChunkScanResult(this.chunks, this.issues);

  final List<ChunkCoord> chunks;
  final List<ChunkScanIssue> issues;
}

/// 一个世界目录的格式层访问器。
class WorldStore {
  WorldStore(this.rootPath);

  final String rootPath;

  String get metaPath => _join(rootPath, 'world.meta.json');
  String get indexPath => _join(rootPath, 'world.index.json');
  String get chunksPath => _join(rootPath, 'chunks');

  WorldMeta loadMeta() {
    final file = File(metaPath);
    if (!file.existsSync()) {
      throw FormatException('缺少 world.meta.json：$metaPath');
    }
    return WorldMeta.parse(file.readAsStringSync());
  }

  WorldIndex loadIndex() {
    final file = File(indexPath);
    if (!file.existsSync()) {
      throw FormatException('缺少 world.index.json：$indexPath');
    }
    return WorldIndex.parse(file.readAsStringSync());
  }

  WorldIndex? tryLoadIndex() {
    final file = File(indexPath);
    if (!file.existsSync()) return null;
    return WorldIndex.parse(file.readAsStringSync());
  }

  /// 读取块；不存在返回 null，按空块处理。
  ChunkFile? readChunk(int z, int cx, int cy, {Set<String>? terrainCodes}) {
    final file = File(chunkPath(rootPath, z, cx, cy));
    if (!file.existsSync()) return null;
    return ChunkFile.parse(
      content: file.readAsStringSync(),
      z: z,
      cx: cx,
      cy: cy,
      blockSize: 128,
      terrainCodes: terrainCodes,
    );
  }

  /// 写入块文件；会创建层目录。时间戳和事务由保存层负责。
  void writeChunk(ChunkFile chunk) {
    final file = File(chunkPath(rootPath, chunk.z, chunk.cx, chunk.cy));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(chunk.encode(), flush: true);
  }

  /// 删除块文件；父目录留空不主动删除。
  bool deleteChunk(int z, int cx, int cy) {
    final file = File(chunkPath(rootPath, z, cx, cy));
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  /// 扫描 `chunks` 目录，只接受规范层目录名和规范块文件名。
  ChunkScanResult scanChunks() {
    final root = Directory(chunksPath);
    if (!root.existsSync()) {
      return const ChunkScanResult(<ChunkCoord>[], <ChunkScanIssue>[]);
    }
    final chunks = <ChunkCoord>[];
    final issues = <ChunkScanIssue>[];
    for (final layerEntry in root.listSync(followLinks: false)) {
      final layerName = _basename(layerEntry.path);
      if (layerEntry is! Directory) {
        issues.add(ChunkScanIssue(layerEntry.path, '不是层目录'));
        continue;
      }
      if (!_canonicalIntPattern.hasMatch(layerName)) {
        issues.add(ChunkScanIssue(layerEntry.path, '层目录名不是规范整数'));
        continue;
      }
      final z = int.parse(layerName);
      for (final fileEntry in layerEntry.listSync(followLinks: false)) {
        final name = _basename(fileEntry.path);
        if (fileEntry is! File) {
          issues.add(ChunkScanIssue(fileEntry.path, '不是块文件'));
          continue;
        }
        final match = _chunkFileNamePattern.firstMatch(name);
        if (match == null) {
          issues.add(ChunkScanIssue(fileEntry.path, '块文件名不是规范整数'));
          continue;
        }
        final cx = int.parse(match.group(1)!);
        final cy = int.parse(match.group(2)!);
        chunks.add(ChunkCoord(z, cx, cy));
      }
    }
    chunks.sort((a, b) {
      final z = a.z.compareTo(b.z);
      if (z != 0) return z;
      final x = a.cx.compareTo(b.cx);
      if (x != 0) return x;
      return a.cy.compareTo(b.cy);
    });
    issues.sort((a, b) => a.path.compareTo(b.path));
    return ChunkScanResult(chunks, issues);
  }

  List<int> listLayers() {
    final layers = <int>{for (final chunk in scanChunks().chunks) chunk.z}
        .toList();
    layers.sort();
    return layers;
  }
}

String chunkPath(String worldRoot, int z, int cx, int cy) {
  return _join(_join(_join(worldRoot, 'chunks'), '$z'), '${cx}_$cy.chunk');
}

String _join(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) return '$left$right';
  return '$left${Platform.pathSeparator}$right';
}

String _basename(String path) {
  final index = path.lastIndexOf(Platform.pathSeparator);
  return index < 0 ? path : path.substring(index + 1);
}

/// 读取/写入 `world.meta.json` 的便捷方法；保存事务另行处理。
String encodeMeta(WorldMeta meta) => meta.encode();

/// 读取/写入 `world.index.json` 的便捷方法；保存事务另行处理。
String encodeIndex(WorldIndex index) => index.encode();

/// 解析器辅助：把 JSON 字符串写入文件时统一用 UTF-8 + LF。
List<int> utf8Lines(String text) => utf8.encode(text.replaceAll('\r\n', '\n'));
