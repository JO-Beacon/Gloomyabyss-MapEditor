/// V4：把旧 UI 里的地形、道具、对象、传送门、传送格写回新格式世界。
library;

import '../models/line_portal.dart';
import '../models/obj.dart';
import '../models/prop.dart';
import '../models/solid.dart';
import '../models/world.dart';
import '../world/chunk_file.dart';
import '../world/geometry.dart';
import '../world/polygon.dart';
import '../world/save_transaction.dart';
import '../world/world_index_builder.dart';
import '../world/world_meta.dart';
import '../world/world_store.dart';
import 'preview_world.dart';

class NewWorldSaveSession {
  NewWorldSaveSession({required this.preview, required this.world})
      : _meta = preview.meta,
        _chunks = <ChunkCoord, ChunkFile>{
          for (final layer in preview.chunksByLayer.entries)
            for (final entry in layer.value.entries)
              ChunkCoord(layer.key, entry.key.cx, entry.key.cy): entry.value,
        };

  final PreviewWorld preview;
  final World world;

  WorldMeta _meta;
  Map<ChunkCoord, ChunkFile> _chunks;

  int get revision => _meta.indexRevision;

  WorldSaveResult save() {
    final blockSize = _meta.blockSize;
    final dirty = <ChunkCoord, ChunkFile>{};
    final deleted = <ChunkCoord>{};
    final allChunks = <ChunkCoord, ChunkFile>{..._chunks};
    final instructionsByChunk = <ChunkCoord, List<ChunkInstruction>>{};
    final originalPortalIds = <String>{
      for (final portal in preview.index.portals) portal.id,
    };
    final usedPortalIds = <String>{...originalPortalIds};
    final portalRefs = <String, String>{};
    final originalSolidGroups = <String>{
      for (final chunk in _chunks.values)
        for (final instruction in chunk.instructions)
          if (instruction is SolidInstruction) instruction.group,
    };
    final presentSolidGroups = <String>{};
    final newSolids = <(Segment, SolidShape)>[];
    final usedSolidGroups = <String>{...originalSolidGroups};
    for (final segment in world.segments) {
      for (final solid in parseSolids(segment.instructions)) {
        final group = solid.group;
        if (group == null || !originalSolidGroups.contains(group)) {
          newSolids.add((segment, solid));
        } else {
          presentSolidGroups.add(group);
        }
      }
    }

    void addInstruction(ChunkCoord coord, ChunkInstruction instruction) {
      instructionsByChunk
          .putIfAbsent(coord, () => <ChunkInstruction>[])
          .add(instruction);
    }

    for (final segment in world.segments) {
      final z = segment.spec.originZ;
      for (final prop in parsePlacedProps(segment.instructions)) {
        final col = segment.spec.originCol + prop.col;
        final row = segment.spec.originRow + prop.row;
        addInstruction(
          ChunkCoord(z, floorDiv(col, blockSize), floorDiv(row, blockSize)),
          PropInstruction(z: z, type: prop.id, col: col, row: row),
        );
      }
      for (final object in parsePlacedObjects(segment.instructions)) {
        final col = segment.spec.originCol + object.col;
        final row = segment.spec.originRow + object.row;
        addInstruction(
          ChunkCoord(z, floorDiv(col, blockSize), floorDiv(row, blockSize)),
          SpawnInstruction(z: z, type: object.id, col: col, row: row),
        );
      }
      for (final portal in parseLinePortals(segment.instructions)) {
        final x = segment.spec.originCol + portal.x;
        final y = segment.spec.originRow + portal.y;
        final globalId = _portalId(
          segment: segment,
          localId: portal.id,
          originalIds: originalPortalIds,
          usedIds: usedPortalIds,
        );
        portalRefs['${segment.spec.id}/${portal.id}'] = globalId;
        addInstruction(
          ChunkCoord(z, floorDiv(x, blockSize), floorDiv(y, blockSize)),
          PortalInstruction(
            id: globalId,
            dir: portal.dir,
            x: x,
            y: y,
            length: portal.length,
            z: z,
          ),
        );
      }
    }

    for (final (segment, solid) in newSolids) {
      final z = segment.spec.originZ;
      final points = <(double, double)>[
        for (final (x, y) in solid.points)
          (
            (segment.spec.originCol + x).toDouble(),
            (segment.spec.originRow + y).toDouble(),
          ),
      ];
      if (points.length < 3) continue;
      final group = solid.group ?? _uniqueSolidGroup(usedSolidGroups);
      usedSolidGroups.add(group);
      final bounds = polygonBounds(points);
      final startCx = floorDiv(bounds.x.floor(), blockSize);
      final endCx = floorDiv((bounds.x + bounds.w).ceil(), blockSize);
      final startCy = floorDiv(bounds.y.floor(), blockSize);
      final endCy = floorDiv((bounds.y + bounds.h).ceil(), blockSize);
      for (var cx = startCx; cx <= endCx; cx++) {
        for (var cy = startCy; cy <= endCy; cy++) {
          final clipped = clipPolygonToRect(
            points,
            (cx * blockSize).toDouble(),
            (cy * blockSize).toDouble(),
            blockSize.toDouble(),
            blockSize.toDouble(),
          );
          if (clipped.length < 3) continue;
          if (polygonSignedArea(clipped).abs() < 0.001) continue;
          addInstruction(
            ChunkCoord(z, cx, cy),
            SolidInstruction(z: z, group: group, points: clipped),
          );
        }
      }
    }

    for (final list in instructionsByChunk.values) {
      list.sort(_compareInstructions);
    }

    final pads = <WorldPad>[];
    for (final raw in (world.raw['pads'] as List? ?? const <dynamic>[])) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      final segment = world.segmentById(raw['segment']?.toString() ?? '');
      final col = (raw['col'] as num?)?.toInt();
      final row = (raw['row'] as num?)?.toInt();
      if (id == null || segment == null || col == null || row == null) {
        throw const WorldSaveException(
          '传送格数据不完整，无法保存',
          rolledBack: true,
        );
      }
      pads.add(
        WorldPad(
          id: id,
          col: segment.spec.originCol + col,
          row: segment.spec.originRow + row,
          z: segment.spec.originZ,
        ),
      );
    }
    final padLinks = <WorldPadLink>[];
    for (final raw in (world.raw['pad_links'] as List? ?? const <dynamic>[])) {
      if (raw is! Map) continue;
      final from = raw['from']?.toString();
      final to = raw['to']?.toString();
      if (from == null || to == null) continue;
      padLinks.add(
        WorldPadLink(
          from: from,
          to: to,
          bidirectional: raw['bidirectional'] == true,
        ),
      );
    }
    final portalLinks = <WorldPortalLink>[];
    for (final raw
        in (world.raw['portal_links'] as List? ?? const <dynamic>[])) {
      if (raw is! Map) continue;
      final oldFrom = raw['from']?.toString();
      final oldTo = raw['to']?.toString();
      if (oldFrom == null || oldTo == null) continue;
      final from = portalRefs[oldFrom];
      final to = portalRefs[oldTo];
      if (from == null || to == null) {
        throw WorldSaveException(
          '传送门连接引用了不存在的门：$oldFrom → $oldTo',
          rolledBack: true,
        );
      }
      portalLinks.add(
        WorldPortalLink(
          from: from,
          to: to,
          face: PortalFace.parse(raw['face']?.toString() ?? 'A'),
        ),
      );
    }

    final newMeta = WorldMeta(
      version: _meta.version,
      name: _meta.name,
      blockSize: _meta.blockSize,
      chunkFormatVersion: _meta.chunkFormatVersion,
      definitions: _meta.definitions,
      indexRevision: _meta.indexRevision,
      start: _meta.start,
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
    );
    final metaErrors = newMeta.validate();
    if (metaErrors.isNotEmpty) {
      throw WorldSaveException(
        '保存前 meta 校验失败：${metaErrors.join('；')}',
        rolledBack: true,
      );
    }

    for (final segment in world.segments) {
      final z = segment.spec.originZ;
      if (segment.width <= 0 || segment.height <= 0) continue;
      final startCx = floorDiv(segment.spec.originCol, blockSize);
      final endCx = floorDiv(
        segment.spec.originCol + segment.width - 1,
        blockSize,
      );
      final startCy = floorDiv(segment.spec.originRow, blockSize);
      final endCy = floorDiv(
        segment.spec.originRow + segment.height - 1,
        blockSize,
      );
      for (var cx = startCx; cx <= endCx; cx++) {
        for (var cy = startCy; cy <= endCy; cy++) {
          final coord = ChunkCoord(z, cx, cy);
          final existing = _chunks[coord];
          final rows = <String>[];
          var maxCol = -1;
          for (var localRow = 0; localRow < blockSize; localRow++) {
            final globalRow = cy * blockSize + localRow;
            final localSegmentRow = globalRow - segment.spec.originRow;
            final line = StringBuffer();
            if (localSegmentRow >= 0 && localSegmentRow < segment.height) {
              for (var localCol = 0; localCol < blockSize; localCol++) {
                final globalCol = cx * blockSize + localCol;
                final localSegmentCol = globalCol - segment.spec.originCol;
                String code = emptyTerrainPadding;
                if (localSegmentCol >= 0 && localSegmentCol < segment.width) {
                  code = segment.charAt(localSegmentCol, localSegmentRow);
                  if (code == ' ') code = emptyTerrainPadding;
                }
                line.write(code);
                if (code != emptyTerrainPadding) {
                  maxCol = localCol > maxCol ? localCol : maxCol;
                }
              }
            }
            rows.add(line.toString());
          }
          if (maxCol < 0) {
            rows.clear();
          } else {
            for (var i = 0; i < rows.length; i++) {
              if (rows[i].length > maxCol + 1) {
                rows[i] = rows[i].substring(0, maxCol + 1);
              }
            }
          }
          final baseInstructions = <ChunkInstruction>[
            if (existing != null)
              for (final instruction in existing.instructions)
                if (instruction is! PropInstruction &&
                    instruction is! SpawnInstruction &&
                    instruction is! PortalInstruction &&
                    (instruction is! SolidInstruction ||
                        presentSolidGroups.contains(instruction.group)))
                  instruction,
          ];
          final chunk = ChunkFile(
            z: z,
            cx: cx,
            cy: cy,
            blockSize: blockSize,
            instructions: <ChunkInstruction>[
              ...baseInstructions,
              ...?instructionsByChunk[coord],
            ],
            terrainRows: rows,
          );
          if (chunk.isEmpty) {
            if (existing != null) {
              deleted.add(coord);
              allChunks.remove(coord);
            }
          } else {
            dirty[coord] = chunk;
            allChunks[coord] = chunk;
          }
        }
      }
    }

    final built = buildWorldIndex(
      chunks: allChunks,
      definitions: preview.definitions,
      revision: newMeta.indexRevision,
      fullCheckedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final errors = built.index.validate();
    if (errors.isNotEmpty) {
      throw WorldSaveException(
        '保存前索引校验失败：${errors.join('；')}',
        rolledBack: true,
      );
    }

    final result = WorldSave.commit(
      store: WorldStore(preview.worldPath),
      meta: newMeta,
      index: built.index,
      dirtyChunks: dirty,
      deleteChunks: deleted,
    );
    _meta = newMeta.withIndexRevision(result.revision);
    _chunks = allChunks;
    return result;
  }

  /// 保存完成后，把最终 chunk 里的碰撞片段同步回旧 UI 的内存模型，
  /// 这样画布会立刻显示按块切分后的样子，而不是保存前的一整条线。
  void syncWorldSolids() {
    for (final segment in world.segments) {
      final z = segment.spec.originZ;
      segment.instructions.removeWhere(
        (line) => line.trimLeft().startsWith('; solid=') ||
            line.trimLeft().startsWith(';solid='),
      );
      final chunks = _chunks.entries
          .where((entry) => entry.key.z == z)
          .toList()
        ..sort((a, b) {
          final x = a.key.cx.compareTo(b.key.cx);
          return x != 0 ? x : a.key.cy.compareTo(b.key.cy);
        });
      for (final entry in chunks) {
        for (final instruction in entry.value.instructions) {
          if (instruction is! SolidInstruction) continue;
          final points = <String>[];
          for (final (x, y) in instruction.points) {
            points
              ..add('${(x - segment.spec.originCol).round()}')
              ..add('${(y - segment.spec.originRow).round()}');
          }
          if (points.length >= 6) {
            segment.instructions.add(
              '; solid=@${instruction.group},${points.join(',')}',
            );
          }
        }
      }
    }
  }

  static String _portalId({
    required Segment segment,
    required String localId,
    required Set<String> originalIds,
    required Set<String> usedIds,
  }) {
    if (!usedIds.contains(localId) || originalIds.contains(localId)) {
      usedIds.add(localId);
      return localId;
    }
    final prefix = segment.spec.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    var candidate = '${prefix}__$localId';
    var suffix = 2;
    while (usedIds.contains(candidate)) {
      candidate = '${prefix}__${localId}__$suffix';
      suffix++;
    }
    usedIds.add(candidate);
    return candidate;
  }

  static String _uniqueSolidGroup(Set<String> used) {
    var n = 1;
    while (used.contains('solid_$n')) {
      n++;
    }
    return 'solid_$n';
  }

  static int _compareInstructions(ChunkInstruction a, ChunkInstruction b) {
    int compareInt(int x, int y) => x.compareTo(y);
    if (a is PropInstruction && b is PropInstruction) {
      return compareInt(a.col, b.col) != 0
          ? compareInt(a.col, b.col)
          : (compareInt(a.row, b.row) != 0
              ? compareInt(a.row, b.row)
              : a.type.compareTo(b.type));
    }
    if (a is SpawnInstruction && b is SpawnInstruction) {
      return compareInt(a.col, b.col) != 0
          ? compareInt(a.col, b.col)
          : (compareInt(a.row, b.row) != 0
              ? compareInt(a.row, b.row)
              : a.type.compareTo(b.type));
    }
    if (a is PortalInstruction && b is PortalInstruction) {
      return compareInt(a.x, b.x) != 0
          ? compareInt(a.x, b.x)
          : (compareInt(a.y, b.y) != 0
              ? compareInt(a.y, b.y)
              : a.id.compareTo(b.id));
    }
    return 0;
  }
}
