/// 从块文件生成 `world.index.json` 的派生索引。
library;

import 'chunk_file.dart';
import 'definitions.dart';
import 'geometry.dart';
import 'polygon.dart';
import 'world_index.dart';

/// 生成索引时发现的问题。索引仍然会返回，调用方决定是否接受。
class IndexBuildResult {
  const IndexBuildResult(this.index, this.warnings);

  final WorldIndex index;
  final List<String> warnings;
}

/// 从块文件重建完整索引。
IndexBuildResult buildWorldIndex({
  required Map<ChunkCoord, ChunkFile> chunks,
  required DefinitionPackage definitions,
  required int revision,
  String fullCheckedAt = '',
}) {
  final portals = <IndexPortal>[];
  final propsObjects = <IndexPropsObject>[];
  final solidGroups = <String, _MutableSolidGroup>{};
  final warnings = <String>[];

  final sortedChunks = chunks.entries.toList()
    ..sort((a, b) {
      final z = a.key.z.compareTo(b.key.z);
      if (z != 0) return z;
      final x = a.key.cx.compareTo(b.key.cx);
      if (x != 0) return x;
      return a.key.cy.compareTo(b.key.cy);
    });

  for (final entry in sortedChunks) {
    final key = entry.key;
    final chunk = entry.value;
    final perGroupIndex = <String, int>{};
    for (final instruction in chunk.instructions) {
      switch (instruction) {
        case PortalInstruction():
          portals.add(
            IndexPortal(
              id: instruction.id,
              z: instruction.z,
              x: instruction.x,
              y: instruction.y,
              dir: instruction.dir,
              length: instruction.length,
              chunk: BlockCoord(key.cx, key.cy),
            ),
          );
        case PropInstruction():
          final definition = definitions.propsById[instruction.type];
          if (definition == null) {
            throw FormatException(
              '块 ${key.z}/${key.cx}_${key.cy} 引用了不存在的道具类型：${instruction.type}',
            );
          }
          propsObjects.add(
            IndexPropsObject(
              kind: 'prop',
              type: instruction.type,
              z: instruction.z,
              col: instruction.col,
              row: instruction.row,
              w: definition.width,
              h: definition.height,
              chunk: blockIndexOf(
                instruction.col,
                instruction.row,
                chunk.blockSize,
              ),
            ),
          );
        case SpawnInstruction():
          final definition = definitions.objectsById[instruction.type];
          if (definition == null) {
            throw FormatException(
              '块 ${key.z}/${key.cx}_${key.cy} 引用了不存在的对象类型：${instruction.type}',
            );
          }
          propsObjects.add(
            IndexPropsObject(
              kind: 'object',
              type: instruction.type,
              z: instruction.z,
              col: instruction.col,
              row: instruction.row,
              w: definition.width,
              h: definition.height,
              chunk: blockIndexOf(
                instruction.col,
                instruction.row,
                chunk.blockSize,
              ),
            ),
          );
        case SolidInstruction():
          final groupKey = '${instruction.z}/${instruction.group}';
          final pieceIndex = perGroupIndex[groupKey] ?? 0;
          perGroupIndex[groupKey] = pieceIndex + 1;
          if (instruction.points.length < 3 ||
              isDegeneratePolygon(instruction.points)) {
            warnings.add(
              '忽略退化碰撞片段：块 ${key.z}/${key.cx}_${key.cy} 组 ${instruction.group}',
            );
            continue;
          }
          final pieceBbox = boundsOfPoints(instruction.points);
          final group = solidGroups.putIfAbsent(
            groupKey,
            () => _MutableSolidGroup(
              group: instruction.group,
              z: instruction.z,
              bbox: pieceBbox,
              pieces: <IndexSolidPiece>[],
            ),
          );
          group.bbox = _union(group.bbox, pieceBbox);
          group.pieces.add(
            IndexSolidPiece(
              chunk: BlockCoord(key.cx, key.cy),
              index: pieceIndex,
              bbox: pieceBbox,
            ),
          );
        case UnknownInstruction():
          warnings.add(
            '块 ${key.z}/${key.cx}_${key.cy} 含未知指令：${instruction.line}',
          );
      }
    }
  }

  portals.sort((a, b) => a.id.compareTo(b.id));
  propsObjects.sort((a, b) {
    final z = a.z.compareTo(b.z);
    if (z != 0) return z;
    final kind = a.kind.compareTo(b.kind);
    if (kind != 0) return kind;
    final type = a.type.compareTo(b.type);
    if (type != 0) return type;
    final col = a.col.compareTo(b.col);
    if (col != 0) return col;
    return a.row.compareTo(b.row);
  });
  final groups = solidGroups.values.toList()
    ..sort((a, b) {
      final z = a.z.compareTo(b.z);
      return z != 0 ? z : a.group.compareTo(b.group);
    });
  for (final group in groups) {
    group.pieces.sort((a, b) {
      final chunk = _compareChunk(a.chunk, b.chunk);
      return chunk != 0 ? chunk : a.index.compareTo(b.index);
    });
  }

  final index = WorldIndex(
    revision: revision,
    fullCheckedAt: fullCheckedAt,
    portals: portals,
    propsObjects: propsObjects,
    solidGroups: groups
        .map(
          (group) => IndexSolidGroup(
            group: group.group,
            z: group.z,
            bbox: group.bbox,
            pieces: group.pieces,
          ),
        )
        .toList(growable: false),
  );
  warnings.addAll(index.validate());
  return IndexBuildResult(index, warnings);
}

class _MutableSolidGroup {
  _MutableSolidGroup({
    required this.group,
    required this.z,
    required this.bbox,
    required this.pieces,
  });

  final String group;
  final int z;
  FloatRect bbox;
  final List<IndexSolidPiece> pieces;
}

FloatRect _union(FloatRect a, FloatRect b) {
  final left = a.x < b.x ? a.x : b.x;
  final top = a.y < b.y ? a.y : b.y;
  final right = a.right > b.right ? a.right : b.right;
  final bottom = a.bottom > b.bottom ? a.bottom : b.bottom;
  return FloatRect(left, top, right - left, bottom - top);
}

int _compareChunk(BlockCoord a, BlockCoord b) {
  final x = a.cx.compareTo(b.cx);
  return x != 0 ? x : a.cy.compareTo(b.cy);
}
