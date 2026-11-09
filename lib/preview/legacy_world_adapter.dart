/// 把新格式世界转换成旧编辑器 UI 认识的 [World] 内存模型。
///
/// 这是一层只读适配：生成的 Segment 只用于显示，不写回磁盘。
library;

import '../models/obj.dart';
import '../models/prop.dart';
import '../models/terrain.dart';
import '../models/world.dart';
import '../world/chunk_file.dart';
import 'preview_world.dart';

class LegacyPreviewData {
  const LegacyPreviewData({
    required this.world,
    required this.terrain,
    required this.propTypes,
    required this.objectTypes,
    required this.selectedLevel,
  });

  final World world;
  final TerrainSet terrain;
  final List<PropType> propTypes;
  final List<ObjectType> objectTypes;
  final int selectedLevel;
}

class LegacyWorldAdapter {
  LegacyWorldAdapter._();

  /// 新格式 → 旧 UI 的 World/Segment 形状。
  static LegacyPreviewData fromPreview(PreviewWorld preview) {
    final layers = preview.layers.isEmpty ? <int>[0] : preview.layers;
    final segmentIdByZ = <int, String>{
      for (final z in layers) z: z == 0 ? '层 0' : '层 $z',
    };
    final segmentOriginByZ = <int, (int, int)>{
      for (final z in layers)
        z: (preview.boundsFor(z).minCol, preview.boundsFor(z).minRow),
    };
    final segments = <Segment>[];
    for (final z in layers) {
      final bounds = preview.boundsFor(z);
      final rows = <String>[];
      for (var row = bounds.minRow; row <= bounds.maxRow; row++) {
        final line = StringBuffer();
        for (var col = bounds.minCol; col <= bounds.maxCol; col++) {
          final code = preview.terrainCodeAt(z, col, row);
          line.write(code ?? ' ');
        }
        rows.add(line.toString());
      }

      final instructions = <String>[];
      for (final item in preview.index.propsObjects) {
        if (item.z != z) continue;
        final col = item.col - bounds.minCol;
        final row = item.row - bounds.minRow;
        if (item.kind == 'prop') {
          instructions.add('; prop=${item.type},$col,$row');
        } else {
          instructions.add('; spawn=${item.type},$col,$row');
        }
      }
      for (final portal in preview.index.portals) {
        if (portal.z != z) continue;
        instructions.add(
          '; portal=${portal.id},${portal.dir},'
          '${portal.x - bounds.minCol},${portal.y - bounds.minRow},${portal.length}',
        );
      }
      for (final chunk
          in preview.chunksByLayer[z]?.values ?? const <ChunkFile>[]) {
        for (final instruction in chunk.instructions) {
          if (instruction is! SolidInstruction) continue;
          final nums = <String>[];
          for (final (x, y) in instruction.points) {
            nums
              ..add('${(x - bounds.minCol).round()}')
              ..add('${(y - bounds.minRow).round()}');
          }
          if (nums.length >= 6) {
            instructions.add('; solid=@${instruction.group},${nums.join(',')}');
          }
        }
      }

      segments.add(
        Segment(
          SegmentSpec(
            id: segmentIdByZ[z]!,
            file: '',
            originCol: bounds.minCol,
            originRow: bounds.minRow,
            originZ: z,
          ),
          rows,
          instructions: instructions,
        ),
      );
    }

    final portalRefs = <String, String>{};
    for (final portal in preview.index.portals) {
      final segmentId = segmentIdByZ[portal.z];
      if (segmentId != null) {
        portalRefs[portal.id] = '$segmentId/${portal.id}';
      }
    }

    final pads = <Map<String, dynamic>>[];
    for (final pad in preview.meta.pads) {
      final segmentId = segmentIdByZ[pad.z];
      final origin = segmentOriginByZ[pad.z];
      if (segmentId == null || origin == null) continue;
      pads.add(<String, dynamic>{
        'id': pad.id,
        'segment': segmentId,
        'col': pad.col - origin.$1,
        'row': pad.row - origin.$2,
      });
    }
    final padLinks = <Map<String, dynamic>>[
      for (final link in preview.meta.padLinks)
        <String, dynamic>{
          'from': link.from,
          'to': link.to,
          'bidirectional': link.bidirectional,
        },
    ];
    final portalLinks = <Map<String, dynamic>>[];
    for (final link in preview.meta.portalLinks) {
      final from = portalRefs[link.from];
      final to = portalRefs[link.to];
      if (from == null || to == null) continue;
      portalLinks.add(<String, dynamic>{
        'from': from,
        'to': to,
        'face': link.face.value,
      });
    }

    final raw = <String, dynamic>{
      'version': 1,
      'segments': <dynamic>[
        for (final segment in segments) segment.spec.toJson(),
      ],
      'pads': pads,
      'pad_links': padLinks,
      'portal_links': portalLinks,
      'start': <String, dynamic>{
        'col': preview.meta.start.col,
        'row': preview.meta.start.row,
      },
    };
    final world = World(
      dirPath: preview.worldPath,
      name: preview.meta.name,
      segments: segments,
      portalPlanes: const <PortalPlane>[],
      raw: raw,
    );

    final terrain = _terrainFrom(preview);
    final propTypes = <PropType>[
      for (final prop in preview.definitions.props)
        PropType(
          id: prop.id,
          name: prop.name,
          sprite: prop.sprite,
          block: prop.block,
          width: prop.width,
          height: prop.height,
          interaction: prop.interaction,
        ),
    ];
    final objectTypes = <ObjectType>[
      for (final object in preview.definitions.objects)
        ObjectType(id: object.id, name: object.name),
    ];

    return LegacyPreviewData(
      world: world,
      terrain: terrain,
      propTypes: propTypes,
      objectTypes: objectTypes,
      selectedLevel: preview.meta.start.z,
    );
  }

  static TerrainSet _terrainFrom(PreviewWorld preview) {
    final types = <TerrainType>[
      for (final type in preview.definitions.terrain.types)
        TerrainType(
          code: type.code,
          name: type.name,
          color: 0xFF000000 |
              ((type.color[0] & 0xFF) << 16) |
              ((type.color[1] & 0xFF) << 8) |
              (type.color[2] & 0xFF),
          block: type.block,
          speed: type.speed,
          damage: type.damage,
        ),
      // 新格式没有地形的地方，旧 UI 需要一个“空”地形来显示背景。
      const TerrainType(
        code: ' ',
        name: '空',
        color: 0xFF0E0F12,
        block: false,
        speed: 1,
        damage: 0,
      ),
    ];
    return TerrainSet(
      tileSize: preview.definitions.terrain.tileSize,
      types: types,
    );
  }
}
