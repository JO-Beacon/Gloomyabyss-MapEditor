/// 旧世界目录 → 新格式世界目录的迁移转换。
///
/// 只读源目录；正式迁移写入新的输出目录。dry-run 只在内存中生成结果。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'chunk_file.dart';
import 'gmap_container.dart';
import 'definitions.dart';
import 'geometry.dart';
import 'polygon.dart';
import 'old_format.dart';
import 'world_index.dart';
import 'world_index_builder.dart';
import 'world_meta.dart';

class OldMigrationException implements Exception {
  const OldMigrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OldMigrationOptions {
  const OldMigrationOptions({
    required this.sourcePath,
    required this.outputPath,
    required this.oldDefinitions,
    required this.targetDefinitions,
    this.name,
    this.dryRun = false,
    this.keepUnknown = false,
  });

  final String sourcePath;
  final String outputPath;
  final DefinitionPackage oldDefinitions;
  final DefinitionPackage targetDefinitions;
  final String? name;
  final bool dryRun;
  final bool keepUnknown;
}

class OldMigrationReport {
  OldMigrationReport({
    required this.sourcePath,
    required this.outputPath,
    required this.dryRun,
    required this.segmentCount,
    required this.repeatCopies,
    required this.chunkCount,
    required this.segmentNames,
    required this.seams,
    required this.portalMapping,
    required this.padMapping,
    required this.unknownInstructions,
    required this.definitions,
    required this.warnings,
  });

  final String sourcePath;
  final String outputPath;
  final bool dryRun;
  final int segmentCount;
  final int repeatCopies;
  final int chunkCount;
  final List<String> segmentNames;
  final List<dynamic> seams;
  final Map<String, String> portalMapping;
  final Map<String, String> padMapping;
  final List<String> unknownInstructions;
  final DefinitionRef definitions;
  final List<String> warnings;

  OldMigrationReport copyWith({
    String? sourcePath,
    String? outputPath,
    bool? dryRun,
  }) {
    return OldMigrationReport(
      sourcePath: sourcePath ?? this.sourcePath,
      outputPath: outputPath ?? this.outputPath,
      dryRun: dryRun ?? this.dryRun,
      segmentCount: segmentCount,
      repeatCopies: repeatCopies,
      chunkCount: chunkCount,
      segmentNames: segmentNames,
      seams: seams,
      portalMapping: portalMapping,
      padMapping: padMapping,
      unknownInstructions: unknownInstructions,
      definitions: definitions,
      warnings: warnings,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source': sourcePath,
    'output': outputPath,
    'dry_run': dryRun,
    'segments': segmentCount,
    'repeat_copies': repeatCopies,
    'chunks': chunkCount,
    'segment_names': segmentNames,
    'seams': seams,
    'portals': portalMapping,
    'pads': padMapping,
    'unknown_instructions': unknownInstructions,
    'definitions': <String, dynamic>{
      'id': definitions.id,
      'version': definitions.version,
      'hash': definitions.hash,
    },
    'warnings': warnings,
  };
}

class OldMigrationResult {
  OldMigrationResult({
    required this.meta,
    required this.index,
    required this.chunks,
    required this.report,
    required this.written,
  });

  final WorldMeta meta;
  final WorldIndex index;
  final Map<ChunkCoord, ChunkFile> chunks;
  final OldMigrationReport report;
  final bool written;

  OldMigrationResult copyWith({OldMigrationReport? report, bool? written}) {
    return OldMigrationResult(
      meta: meta,
      index: index,
      chunks: chunks,
      report: report ?? this.report,
      written: written ?? this.written,
    );
  }
}

class OldMigration {
  OldMigration._();

  static OldMigrationResult migrateDirectory(OldMigrationOptions options) {
    final source = OldWorldData.loadDirectory(
      options.sourcePath,
      keepUnknown: options.keepUnknown,
    );
    return migrate(source, options);
  }

  /// 读取旧 `.gmap` v1 包并迁移为新的 `.gmap` v2 包。
  ///
  /// 源包只读；正式迁移在内存中转换，最后整包原子写入目标文件。
  static OldMigrationResult migrateGmapFile(OldMigrationOptions options) {
    final sourceFile = File(options.sourcePath);
    if (!sourceFile.existsSync()) {
      throw OldMigrationException('旧 .gmap 不存在：${options.sourcePath}');
    }
    final container = GmapContainer.decode(
      sourceFile.readAsBytesSync(),
      allowVersion1: true,
    );
    if (container.version != 1) {
      throw OldMigrationException('只迁移旧 .gmap v1 包');
    }
    final temp = Directory.systemTemp.createTempSync('gloomy_gmap_migrate_');
    try {
      for (final entry in container.entries.entries) {
        final file = File(
          '${temp.path}${Platform.pathSeparator}'
          '${entry.key.replaceAll('/', Platform.pathSeparator)}',
        );
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value, flush: true);
      }
      final name =
          options.name ?? _basenameWithoutExtension(options.sourcePath);
      final baseResult = migrateDirectory(
        OldMigrationOptions(
          sourcePath: temp.path,
          outputPath: options.outputPath,
          oldDefinitions: options.oldDefinitions,
          targetDefinitions: options.targetDefinitions,
          name: name,
          keepUnknown: options.keepUnknown,
          dryRun: true,
        ),
      );
      final report = baseResult.report.copyWith(
        sourcePath: options.sourcePath,
        outputPath: options.outputPath,
        dryRun: options.dryRun,
      );
      if (!options.dryRun) {
        final unknownEntries = <String, Uint8List>{};
        for (final entry in container.entries.entries) {
          if (_isOldKnownEntry(entry.key)) continue;
          unknownEntries[entry.key] = entry.value;
        }
        _writeGmapOutput(
          options.outputPath,
          baseResult.meta,
          baseResult.index,
          baseResult.chunks,
          unknownEntries,
        );
      }
      return baseResult.copyWith(report: report, written: !options.dryRun);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  }

  static OldMigrationResult migrate(
    OldWorldData source,
    OldMigrationOptions options,
  ) {
    source.validateDefinitions(options.oldDefinitions);
    final upgrade = _upgradeFor(
      options.oldDefinitions,
      options.targetDefinitions,
    );
    final warnings = <String>[];
    if (upgrade != null) {
      warnings.add(
        '应用定义升级：${options.oldDefinitions.manifest.version} → '
        '${options.targetDefinitions.manifest.version}',
      );
      warnings.addAll(upgrade.changed);
      warnings.addAll(upgrade.notes);
    }
    final segmentNames = <String>[];
    final unknownInstructions = <String>[];
    final drafts = <ChunkCoord, _ChunkDraft>{};
    var repeatCopies = 0;

    // 1. 地形：每个段和 repeat 副本都只写地形。
    for (final segment in source.segments) {
      final offsets = segment.expandedOffsets();
      repeatCopies += offsets.length;
      if (segment.name != null) {
        segmentNames.add('${segment.id}: ${segment.name}');
      }
      for (final (dc, dr) in offsets) {
        for (var row = 0; row < segment.rows.length; row++) {
          final runes = segment.rows[row].runes.toList(growable: false);
          for (var col = 0; col < runes.length; col++) {
            final code = _mapTerrain(
              String.fromCharCodes(<int>[runes[col]]),
              upgrade,
              options.targetDefinitions,
            );
            final globalCol = segment.originCol + dc + col;
            final globalRow = segment.originRow + dr + row;
            final draft = _draftAt(
              drafts,
              segment.originZ,
              globalCol,
              globalRow,
            );
            draft.setCell(globalCol, globalRow, code);
          }
        }
      }
    }

    // 2. 传送门 id 映射，按旧段顺序和段内指令顺序分配。
    final portalMapping = <String, String>{};
    final usedPortalIds = <String>{};
    for (final segment in source.segments) {
      for (final instruction in segment.instructions) {
        if (instruction is! OldPortalInstruction) continue;
        final oldRef = '${segment.id}/${instruction.id}';
        if (portalMapping.containsKey(oldRef)) {
          throw OldMigrationException('旧传送门引用重复：$oldRef');
        }
        final base =
            '${_cleanId(segment.id, 'segment')}__'
            '${_cleanId(instruction.id, 'portal')}';
        final newId = _uniqueId(base, usedPortalIds);
        portalMapping[oldRef] = newId;
      }
    }

    // 3. 传送格：合并 world.json 和段内 ; pad=，再分配新 id。
    //
    // 旧引擎的段内写法有两种：
    //   ; pad=<id>,<col>,<row>
    //   ; pad=<col>,<row>,<target_col>,<target_row>   （真实旧世界常见）
    // 后者没有 id，需要拆成两个传送格和一条单向连接。
    final padValues = <String, _PadValue>{};
    final padByPosition = <String, String>{};
    void addPad(String key, _PadValue value) {
      _addPad(padValues, key, value);
      padByPosition.putIfAbsent(_padPositionKey(value), () => key);
    }

    for (final pad in source.pads) {
      final segment = _segmentById(source, pad.segment);
      if (segment == null) {
        throw OldMigrationException('传送格 ${pad.id} 引用了不存在的段 ${pad.segment}');
      }
      addPad(
        pad.id,
        _PadValue(
          col: segment.originCol + pad.col,
          row: segment.originRow + pad.row,
          z: segment.originZ,
        ),
      );
    }

    final directPadLinks = <(String, String)>[];
    var directPadCounter = 0;
    for (final segment in source.segments) {
      for (final instruction in segment.instructions) {
        if (instruction is! OldPadInstruction) continue;
        final start = _PadValue(
          col: segment.originCol + instruction.col,
          row: segment.originRow + instruction.row,
          z: segment.originZ,
        );
        if (instruction.isDirect) {
          final target = _PadValue(
            col: segment.originCol + instruction.targetCol!,
            row: segment.originRow + instruction.targetRow!,
            z: segment.originZ,
          );
          final base = 'pad_${segment.id}_$directPadCounter';
          final startKey = _ensurePadAtPosition(
            padValues,
            padByPosition,
            '${base}_from',
            start,
          );
          final targetKey = _ensurePadAtPosition(
            padValues,
            padByPosition,
            '${base}_to',
            target,
          );
          if (startKey != targetKey) {
            directPadLinks.add((startKey, targetKey));
          }
          directPadCounter++;
        } else {
          addPad(instruction.id!, start);
        }
      }
    }

    final padMapping = <String, String>{};
    final usedPadIds = <String>{};
    final pads = <WorldPad>[];
    for (final entry in padValues.entries) {
      final newId = _uniqueId(_cleanId(entry.key, 'pad'), usedPadIds);
      padMapping[entry.key] = newId;
      pads.add(
        WorldPad(
          id: newId,
          col: entry.value.col,
          row: entry.value.row,
          z: entry.value.z,
        ),
      );
    }

    final padLinks = _padLinks(source, padMapping);
    for (final (fromKey, toKey) in directPadLinks) {
      final from = padMapping[fromKey];
      final to = padMapping[toKey];
      if (from == null || to == null) {
        throw OldMigrationException('段内 pad 连接映射失败：$fromKey → $toKey');
      }
      if (from == to) continue;
      padLinks.add(
        WorldPadLink(from: from, to: to, bidirectional: false),
      );
    }

    // 4. 段内指令：道具、对象、传送门、碰撞、未知指令。
    var solidCounter = 0;
    for (final segment in source.segments) {
      for (final instruction in segment.instructions) {
        switch (instruction) {
          case OldPropInstruction():
            final col = segment.originCol + instruction.col;
            final row = segment.originRow + instruction.row;
            final type = _mapProp(
              instruction.type,
              upgrade,
              options.targetDefinitions,
            );
            _draftAt(drafts, segment.originZ, col, row).instructions.add(
              PropInstruction(
                z: segment.originZ,
                type: type,
                col: col,
                row: row,
              ),
            );
          case OldSpawnInstruction():
            final col = segment.originCol + instruction.col;
            final row = segment.originRow + instruction.row;
            final type = _mapObject(
              instruction.type,
              upgrade,
              options.targetDefinitions,
            );
            _draftAt(drafts, segment.originZ, col, row).instructions.add(
              SpawnInstruction(
                z: segment.originZ,
                type: type,
                col: col,
                row: row,
              ),
            );
          case OldPortalInstruction():
            final oldRef = '${segment.id}/${instruction.id}';
            final newId = portalMapping[oldRef];
            if (newId == null) {
              throw OldMigrationException('传送门映射缺失：$oldRef');
            }
            final x = segment.originCol + instruction.x;
            final y = segment.originRow + instruction.y;
            _draftAt(drafts, segment.originZ, x, y).instructions.add(
              PortalInstruction(
                id: newId,
                dir: instruction.dir,
                x: x,
                y: y,
                length: instruction.length,
                z: segment.originZ,
              ),
            );
          case OldSolidInstruction():
            solidCounter++;
            _addSolid(drafts, segment, instruction, 'solid_$solidCounter');
          case OldPadInstruction():
            // 已合并到 world.meta.json。
            break;
          case OldNameInstruction():
            break;
          case OldUnknownInstruction():
            unknownInstructions.add(instruction.line);
            warnings.add('保留未知旧指令：${instruction.line}');
            _draftAt(
              drafts,
              segment.originZ,
              segment.originCol,
              segment.originRow,
            ).instructions.add(UnknownInstruction(instruction.line));
        }
      }
    }

    // 5. 生成块文件和索引。
    final chunks = <ChunkCoord, ChunkFile>{
      for (final entry in drafts.entries) entry.key: entry.value.build(),
    };
    final indexBuild = buildWorldIndex(
      chunks: chunks,
      definitions: options.targetDefinitions,
      revision: 1,
      fullCheckedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final indexErrors = indexBuild.index.validate();
    if (indexErrors.isNotEmpty) {
      throw OldMigrationException('迁移索引校验失败：${indexErrors.join('；')}');
    }
    warnings.addAll(indexBuild.warnings);

    final startZ = _startZ(source);
    final meta = WorldMeta(
      version: 2,
      name: options.name ?? _basename(options.sourcePath),
      blockSize: 128,
      chunkFormatVersion: 1,
      definitions: DefinitionRef(
        id: options.targetDefinitions.manifest.id,
        version: options.targetDefinitions.manifest.version,
        hash: options.targetDefinitions.manifest.hash,
      ),
      indexRevision: 1,
      start: WorldStart(col: source.startCol, row: source.startRow, z: startZ),
      pads: pads,
      padLinks: padLinks,
      portalLinks: _portalLinks(source, portalMapping),
    );
    final metaErrors = meta.validate();
    if (metaErrors.isNotEmpty) {
      throw OldMigrationException('迁移 world.meta 校验失败：${metaErrors.join('；')}');
    }

    final report = OldMigrationReport(
      sourcePath: options.sourcePath,
      outputPath: options.outputPath,
      dryRun: options.dryRun,
      segmentCount: source.segments.length,
      repeatCopies: repeatCopies,
      chunkCount: chunks.length,
      segmentNames: segmentNames,
      seams: source.seams,
      portalMapping: portalMapping,
      padMapping: padMapping,
      unknownInstructions: unknownInstructions,
      definitions: meta.definitions,
      warnings: warnings,
    );

    if (!options.dryRun) {
      try {
        _writeOutput(
          options.sourcePath,
          options.outputPath,
          meta,
          indexBuild.index,
          chunks,
        );
      } catch (_) {
        final output = Directory(options.outputPath);
        if (output.existsSync()) output.deleteSync(recursive: true);
        rethrow;
      }
    }
    return OldMigrationResult(
      meta: meta,
      index: indexBuild.index,
      chunks: chunks,
      report: report,
      written: !options.dryRun,
    );
  }

  static DefinitionUpgrade? _upgradeFor(
    DefinitionPackage oldDefinitions,
    DefinitionPackage targetDefinitions,
  ) {
    final oldVersion = oldDefinitions.manifest.version;
    final targetVersion = targetDefinitions.manifest.version;
    if (targetVersion == oldVersion) return null;
    if (targetVersion < oldVersion) {
      throw OldMigrationException('目标定义版本低于旧定义版本：$oldVersion → $targetVersion');
    }
    for (final upgrade in targetDefinitions.manifest.upgrades) {
      if (upgrade.from == oldVersion) return upgrade;
    }
    throw OldMigrationException('缺少定义升级条目：$oldVersion → $targetVersion');
  }

  static String _mapTerrain(
    String code,
    DefinitionUpgrade? upgrade,
    DefinitionPackage target,
  ) {
    final mapped = upgrade?.terrain[code] ?? code;
    if (mapped.runes.length != 1 ||
        !target.terrain.byCode.containsKey(mapped)) {
      throw OldMigrationException('地形代码无法映射到目标定义：$code → $mapped');
    }
    return mapped;
  }

  static String _mapProp(
    String type,
    DefinitionUpgrade? upgrade,
    DefinitionPackage target,
  ) {
    final mapped = upgrade?.props[type] ?? type;
    if (!target.propsById.containsKey(mapped)) {
      throw OldMigrationException('道具类型无法映射到目标定义：$type → $mapped');
    }
    return mapped;
  }

  static String _mapObject(
    String type,
    DefinitionUpgrade? upgrade,
    DefinitionPackage target,
  ) {
    final mapped = upgrade?.objects[type] ?? type;
    if (!target.objectsById.containsKey(mapped)) {
      throw OldMigrationException('对象类型无法映射到目标定义：$type → $mapped');
    }
    return mapped;
  }

  static void _addSolid(
    Map<ChunkCoord, _ChunkDraft> drafts,
    OldSegment segment,
    OldSolidInstruction instruction,
    String group,
  ) {
    final points = <(double, double)>[
      for (final (x, y) in instruction.points)
        (
          (segment.originCol + x).toDouble(),
          (segment.originRow + y).toDouble(),
        ),
    ];
    if (!_isConvex(points)) {
      throw OldMigrationException('旧 solid 不是凸多边形，迁移暂不支持：${segment.id}');
    }
    final minX = points.map((p) => p.$1).reduce((a, b) => a < b ? a : b);
    final maxX = points.map((p) => p.$1).reduce((a, b) => a > b ? a : b);
    final minY = points.map((p) => p.$2).reduce((a, b) => a < b ? a : b);
    final maxY = points.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
    final minCx = floorDiv(minX.floor(), 128);
    final maxCx = floorDiv(maxX.floor(), 128);
    final minCy = floorDiv(minY.floor(), 128);
    final maxCy = floorDiv(maxY.floor(), 128);
    for (var cx = minCx; cx <= maxCx; cx++) {
      for (var cy = minCy; cy <= maxCy; cy++) {
        final clipped = _clipToBlock(
          points,
          cx * 128.0,
          cy * 128.0,
          128.0,
          128.0,
        );
        if (clipped.length < 3 || isDegeneratePolygon(clipped)) continue;
        final oriented = polygonSignedArea(clipped) < 0
            ? clipped.reversed.toList(growable: false)
            : clipped;
        final centerX =
            oriented.map((p) => p.$1).reduce((a, b) => a + b) / oriented.length;
        final centerY =
            oriented.map((p) => p.$2).reduce((a, b) => a + b) / oriented.length;
        final draft = _draftAt(
          drafts,
          segment.originZ,
          centerX.floor(),
          centerY.floor(),
        );
        draft.instructions.add(
          SolidInstruction(z: segment.originZ, group: group, points: oriented),
        );
      }
    }
  }

  static List<(double, double)> _clipToBlock(
    List<(double, double)> points,
    double left,
    double top,
    double width,
    double height,
  ) {
    final right = left + width;
    final bottom = top + height;
    var poly = points;
    poly = _clipEdge(poly, (p) => p.$1 >= left, (a, b) {
      final t = (left - a.$1) / (b.$1 - a.$1);
      return (left, a.$2 + (b.$2 - a.$2) * t);
    });
    if (poly.isEmpty) return poly;
    poly = _clipEdge(poly, (p) => p.$1 <= right, (a, b) {
      final t = (right - a.$1) / (b.$1 - a.$1);
      return (right, a.$2 + (b.$2 - a.$2) * t);
    });
    if (poly.isEmpty) return poly;
    poly = _clipEdge(poly, (p) => p.$2 >= top, (a, b) {
      final t = (top - a.$2) / (b.$2 - a.$2);
      return (a.$1 + (b.$1 - a.$1) * t, top);
    });
    if (poly.isEmpty) return poly;
    poly = _clipEdge(poly, (p) => p.$2 <= bottom, (a, b) {
      final t = (bottom - a.$2) / (b.$2 - a.$2);
      return (a.$1 + (b.$1 - a.$1) * t, bottom);
    });
    return _dedupe(poly);
  }

  static List<(double, double)> _clipEdge(
    List<(double, double)> points,
    bool Function((double, double)) inside,
    (double, double) Function((double, double), (double, double)) intersect,
  ) {
    if (points.isEmpty) return const <(double, double)>[];
    final out = <(double, double)>[];
    var previous = points.last;
    var previousInside = inside(previous);
    for (final current in points) {
      final currentInside = inside(current);
      if (currentInside) {
        if (!previousInside) out.add(intersect(previous, current));
        out.add(current);
      } else if (previousInside) {
        out.add(intersect(previous, current));
      }
      previous = current;
      previousInside = currentInside;
    }
    return out;
  }

  static List<(double, double)> _dedupe(List<(double, double)> points) {
    final out = <(double, double)>[];
    for (final point in points) {
      if (out.isEmpty || out.last != point) out.add(point);
    }
    if (out.length > 1 && out.first == out.last) out.removeLast();
    return out;
  }

  static bool _isConvex(List<(double, double)> points) {
    if (points.length < 3) return false;
    var sign = 0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      final c = points[(i + 2) % points.length];
      final cross =
          (b.$1 - a.$1) * (c.$2 - b.$2) - (b.$2 - a.$2) * (c.$1 - b.$1);
      if (cross.abs() < 1e-9) continue;
      final current = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = current;
      } else if (sign != current) {
        return false;
      }
    }
    return true;
  }

  static _ChunkDraft _draftAt(
    Map<ChunkCoord, _ChunkDraft> drafts,
    int z,
    int col,
    int row,
  ) {
    final block = blockIndexOf(col, row, 128);
    final key = ChunkCoord(z, block.cx, block.cy);
    return drafts.putIfAbsent(
      key,
      () => _ChunkDraft(z: z, cx: block.cx, cy: block.cy),
    );
  }

  static OldSegment? _segmentById(OldWorldData source, String id) {
    for (final segment in source.segments) {
      if (segment.id == id) return segment;
    }
    return null;
  }

  static String _padPositionKey(_PadValue value) =>
      '${value.z}:${value.col}:${value.row}';

  static String _ensurePadAtPosition(
    Map<String, _PadValue> pads,
    Map<String, String> byPosition,
    String preferredKey,
    _PadValue value,
  ) {
    final position = _padPositionKey(value);
    final existing = byPosition[position];
    if (existing != null) return existing;
    var key = preferredKey;
    var suffix = 2;
    while (pads.containsKey(key)) {
      key = '${preferredKey}__$suffix';
      suffix++;
    }
    pads[key] = value;
    byPosition[position] = key;
    return key;
  }

  static void _addPad(Map<String, _PadValue> pads, String id, _PadValue value) {
    final existing = pads[id];
    if (existing == null) {
      pads[id] = value;
      return;
    }
    if (existing != value) {
      throw OldMigrationException('传送格 $id 在 world.json 和块内的坐标不一致');
    }
  }

  static List<WorldPadLink> _padLinks(
    OldWorldData source,
    Map<String, String> mapping,
  ) {
    final out = <WorldPadLink>[];
    for (final link in source.padLinks) {
      final from = mapping[link.from];
      final to = mapping[link.to];
      if (from == null || to == null) {
        throw OldMigrationException(
          '传送格连接引用了不存在的传送格：${link.from} → ${link.to}',
        );
      }
      if (from == to) {
        throw OldMigrationException('传送格连接不能自环：${link.from}');
      }
      out.add(
        WorldPadLink(from: from, to: to, bidirectional: link.bidirectional),
      );
    }
    return out;
  }

  static List<WorldPortalLink> _portalLinks(
    OldWorldData source,
    Map<String, String> mapping,
  ) {
    final out = <WorldPortalLink>[];
    for (final link in source.portalLinks) {
      final from = mapping[link.from];
      final to = mapping[link.to];
      if (from == null || to == null) {
        throw OldMigrationException('传送门连接引用了不存在的门：${link.from} → ${link.to}');
      }
      if (from == to) {
        throw OldMigrationException('传送门连接不能自环：${link.from}');
      }
      out.add(
        WorldPortalLink(from: from, to: to, face: PortalFace.parse(link.face)),
      );
    }
    return out;
  }

  static int _startZ(OldWorldData source) {
    var found = false;
    int? z;
    for (final segment in source.segments) {
      for (final (dc, dr) in segment.expandedOffsets()) {
        final left = segment.originCol + dc;
        final top = segment.originRow + dr;
        if (source.startCol >= left &&
            source.startCol < left + segment.width &&
            source.startRow >= top &&
            source.startRow < top + segment.height) {
          if (found && z != segment.originZ) {
            throw OldMigrationException('旧起点落在多个不同层的段中');
          }
          found = true;
          z = segment.originZ;
        }
      }
    }
    return z ?? 0;
  }

  static void _writeGmapOutput(
    String outputPath,
    WorldMeta meta,
    WorldIndex index,
    Map<ChunkCoord, ChunkFile> chunks,
    Map<String, Uint8List> unknownEntries,
  ) {
    final output = File(outputPath);
    if (output.existsSync() || Directory(outputPath).existsSync()) {
      throw OldMigrationException('输出文件已存在：$outputPath');
    }
    final entries = <String, Uint8List>{
      ...unknownEntries,
      'world.meta.json': Uint8List.fromList(utf8.encode(meta.encode())),
      'world.index.json': Uint8List.fromList(utf8.encode(index.encode())),
    };
    for (final chunk in chunks.values) {
      entries[chunk.relativePath] = Uint8List.fromList(
        utf8.encode(chunk.encode()),
      );
    }
    final bytes = GmapContainer(version: 2, entries: entries).encode();
    output.parent.createSync(recursive: true);
    final temp = File(
      '${output.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(output.path);
  }

  static void _writeOutput(
    String optionsSourcePath,
    String outputPath,
    WorldMeta meta,
    WorldIndex index,
    Map<ChunkCoord, ChunkFile> chunks,
  ) {
    final output = Directory(outputPath);
    if (output.existsSync()) {
      throw OldMigrationException('输出目录已存在：$outputPath');
    }
    final sourceRoot = Directory(optionsSourcePath).absolute.path;
    final targetRoot = output.absolute.path;
    if (targetRoot == sourceRoot ||
        targetRoot.startsWith('$sourceRoot${Platform.pathSeparator}')) {
      throw OldMigrationException('输出目录不能位于源目录内部');
    }
    output.createSync(recursive: true);
    _copyUnknownFiles(optionsSourcePath, output.path);
    File('${output.path}${Platform.pathSeparator}world.meta.json')
        .writeAsStringSync(meta.encode(), flush: true);
    File('${output.path}${Platform.pathSeparator}world.index.json')
        .writeAsStringSync(index.encode(), flush: true);
    for (final chunk in chunks.values) {
      final file = File(
        '${output.path}${Platform.pathSeparator}chunks'
        '${Platform.pathSeparator}${chunk.z}'
        '${Platform.pathSeparator}${chunk.cx}_${chunk.cy}.chunk',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(chunk.encode(), flush: true);
    }
  }
}

class _ChunkDraft {
  _ChunkDraft({required this.z, required this.cx, required this.cy});

  final int z;
  final int cx;
  final int cy;
  final Map<int, Map<int, String>> cells = <int, Map<int, String>>{};
  final List<ChunkInstruction> instructions = <ChunkInstruction>[];

  void setCell(int globalCol, int globalRow, String code) {
    final localCol = positiveMod(globalCol, 128);
    final localRow = positiveMod(globalRow, 128);
    final row = cells.putIfAbsent(localRow, () => <int, String>{});
    final old = row[localCol];
    if (old != null && old != code) {
      throw OldMigrationException(
        '地形重叠：块 z=$z cx=$cx cy=$cy 的格 $localCol,$localRow 同时有 $old 和 $code',
      );
    }
    row[localCol] = code;
  }

  ChunkFile build() {
    final maxRow = cells.isEmpty
        ? -1
        : cells.keys.reduce((a, b) => a > b ? a : b);
    final maxCol = cells.isEmpty
        ? -1
        : cells.values
              .expand((row) => row.keys)
              .reduce((a, b) => a > b ? a : b);
    final rows = <String>[];
    for (var row = 0; row <= maxRow; row++) {
      final buffer = StringBuffer();
      for (var col = 0; col <= maxCol; col++) {
        buffer.write(cells[row]?[col] ?? emptyTerrainPadding);
      }
      rows.add(buffer.toString());
    }
    return ChunkFile(
      z: z,
      cx: cx,
      cy: cy,
      blockSize: 128,
      instructions: instructions,
      terrainRows: rows,
    );
  }
}

class _PadValue {
  const _PadValue({required this.col, required this.row, required this.z});

  final int col;
  final int row;
  final int z;

  @override
  bool operator ==(Object other) =>
      other is _PadValue &&
      other.col == col &&
      other.row == row &&
      other.z == z;

  @override
  int get hashCode => Object.hash(col, row, z);
}

String _cleanId(String value, String fallback) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return cleaned.isEmpty ? fallback : cleaned;
}

String _uniqueId(String base, Set<String> used) {
  var candidate = base;
  var suffix = 2;
  while (used.contains(candidate)) {
    candidate = '${base}__$suffix';
    suffix++;
  }
  used.add(candidate);
  return candidate;
}

bool _isOldKnownEntry(String relative) {
  final normalized = relative.replaceAll('\\', '/');
  final first = normalized.split('/').first;
  if (first == '.save' || first == 'chunks') return true;
  if (first == 'world.json' ||
      first == 'terrain.json' ||
      first == 'props.json' ||
      first == 'objects.json' ||
      first == 'world.meta.json' ||
      first == 'world.index.json') {
    return true;
  }
  return first.endsWith('.seg');
}

void _copyUnknownFiles(String sourceRoot, String outputRoot) {
  final source = Directory(sourceRoot);
  if (!source.existsSync()) return;
  for (final entry in source.listSync(recursive: true, followLinks: false)) {
    if (entry is! File) continue;
    final relative = entry.path
        .substring(source.path.length)
        .replaceAll(RegExp(r'^[\\/]+'), '')
        .replaceAll('\\', '/');
    if (_isOldKnownEntry(relative)) continue;
    final target = File(
      '$outputRoot${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    target.parent.createSync(recursive: true);
    entry.copySync(target.path);
  }
}

String _basenameWithoutExtension(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}
