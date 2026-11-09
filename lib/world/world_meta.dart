/// `world.meta.json` 的格式模型。
///
/// 这里只负责解析、序列化和字段级校验；跨文件的连接完整性在更高层完成。
library;

import 'dart:convert';

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// 传送门连接允许的入口面。
enum PortalFace {
  a('A'),
  b('B'),
  both('both');

  const PortalFace(this.value);

  final String value;

  static PortalFace parse(String text) {
    for (final face in values) {
      if (face.value == text) return face;
    }
    throw FormatException('face 只能是 A、B、both，实际为 $text');
  }
}

/// 地图引用的定义包版本。
class DefinitionRef {
  const DefinitionRef({
    required this.id,
    required this.version,
    required this.hash,
  });

  final String id;
  final int version;
  final String hash;

  static DefinitionRef fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final version = json['version'];
    final hash = json['hash'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('definitions.id 缺失或字符非法');
    }
    if (version is! int || version <= 0) {
      throw const FormatException('definitions.version 必须是正整数');
    }
    if (hash is! String || hash.isEmpty) {
      throw const FormatException('definitions.hash 缺失');
    }
    return DefinitionRef(id: id, version: version, hash: hash);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'version': version,
    'hash': hash,
  };
}

/// 世界起点。
class WorldStart {
  const WorldStart({required this.col, required this.row, required this.z});

  final int col;
  final int row;
  final int z;

  static WorldStart fromJson(Map<String, dynamic> json) {
    final col = json['col'];
    final row = json['row'];
    final z = json['z'];
    if (col is! int || row is! int || z is! int) {
      throw const FormatException('start 必须包含整数 col、row、z');
    }
    return WorldStart(col: col, row: row, z: z);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'col': col,
    'row': row,
    'z': z,
  };
}

/// 世界级传送格。
class WorldPad {
  WorldPad({
    required this.id,
    required this.col,
    required this.row,
    required this.z,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String id;
  final int col;
  final int row;
  final int z;
  final Map<String, dynamic> raw;

  static WorldPad fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final col = json['col'];
    final row = json['row'];
    final z = json['z'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('传送格 id 缺失或字符非法');
    }
    if (col is! int || row is! int || z is! int) {
      throw const FormatException('传送格必须包含整数 col、row、z');
    }
    return WorldPad(id: id, col: col, row: row, z: z, raw: json);
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['id'] = id;
    json['col'] = col;
    json['row'] = row;
    json['z'] = z;
    return json;
  }
}

/// 传送格连接。
class WorldPadLink {
  WorldPadLink({
    required this.from,
    required this.to,
    required this.bidirectional,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String from;
  final String to;
  final bool bidirectional;
  final Map<String, dynamic> raw;

  static WorldPadLink fromJson(Map<String, dynamic> json) {
    final from = json['from'];
    final to = json['to'];
    if (from is! String || !_idPattern.hasMatch(from)) {
      throw const FormatException('pad_links.from 缺失或字符非法');
    }
    if (to is! String || !_idPattern.hasMatch(to)) {
      throw const FormatException('pad_links.to 缺失或字符非法');
    }
    final bidirectional = json['bidirectional'];
    if (bidirectional != null && bidirectional is! bool) {
      throw const FormatException('pad_links.bidirectional 必须是布尔值');
    }
    return WorldPadLink(
      from: from,
      to: to,
      bidirectional: bidirectional == true,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['from'] = from;
    json['to'] = to;
    json['bidirectional'] = bidirectional;
    return json;
  }
}

/// 传送门连接。
class WorldPortalLink {
  WorldPortalLink({
    required this.from,
    required this.to,
    required this.face,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String from;
  final String to;
  final PortalFace face;
  final Map<String, dynamic> raw;

  static WorldPortalLink fromJson(Map<String, dynamic> json) {
    final from = json['from'];
    final to = json['to'];
    final face = json['face'];
    if (from is! String || !_idPattern.hasMatch(from)) {
      throw const FormatException('portal_links.from 缺失或字符非法');
    }
    if (to is! String || !_idPattern.hasMatch(to)) {
      throw const FormatException('portal_links.to 缺失或字符非法');
    }
    if (face is! String) {
      throw const FormatException('portal_links.face 必须显式写 A、B 或 both');
    }
    return WorldPortalLink(
      from: from,
      to: to,
      face: PortalFace.parse(face),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['from'] = from;
    json['to'] = to;
    json['face'] = face.value;
    return json;
  }
}

/// 一个 `world.meta.json` 文档。
class WorldMeta {
  WorldMeta({
    required this.version,
    required this.name,
    required this.blockSize,
    required this.chunkFormatVersion,
    required this.definitions,
    required this.indexRevision,
    required this.start,
    required this.pads,
    required this.padLinks,
    required this.portalLinks,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final int version;
  final String name;
  final int blockSize;
  final int chunkFormatVersion;
  final DefinitionRef definitions;
  final int indexRevision;
  final WorldStart start;
  final List<WorldPad> pads;
  final List<WorldPadLink> padLinks;
  final List<WorldPortalLink> portalLinks;
  final Map<String, dynamic> raw;

  static WorldMeta parse(String text) {
    final json = _parseObject(text, 'world.meta.json');
    return fromJson(json);
  }

  static WorldMeta fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final name = json['name'];
    final blockSize = json['block_size'];
    final chunkFormatVersion = json['chunk_format_version'];
    final definitions = json['definitions'];
    final indexRevision = json['index_revision'];
    final start = json['start'];
    if (version is! int || version <= 0) {
      throw const FormatException('world.meta.json version 必须是正整数');
    }
    if (name is! String) {
      throw const FormatException('world.meta.json name 必须是字符串');
    }
    if (blockSize is! int || blockSize <= 0) {
      throw const FormatException('block_size 必须是正整数');
    }
    if (chunkFormatVersion is! int || chunkFormatVersion <= 0) {
      throw const FormatException('chunk_format_version 必须是正整数');
    }
    if (definitions is! Map<String, dynamic>) {
      throw const FormatException('definitions 必须是对象');
    }
    if (indexRevision is! int || indexRevision < 0) {
      throw const FormatException('index_revision 必须是非负整数');
    }
    if (start is! Map<String, dynamic>) {
      throw const FormatException('start 必须是对象');
    }

    final pads = <WorldPad>[];
    final rawPads = json['pads'];
    if (rawPads != null) {
      if (rawPads is! List) {
        throw const FormatException('pads 必须是数组');
      }
      for (var i = 0; i < rawPads.length; i++) {
        final entry = rawPads[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('pads[$i] 必须是对象');
        }
        pads.add(WorldPad.fromJson(entry));
      }
    }

    final padLinks = <WorldPadLink>[];
    final rawPadLinks = json['pad_links'];
    if (rawPadLinks != null) {
      if (rawPadLinks is! List) {
        throw const FormatException('pad_links 必须是数组');
      }
      for (var i = 0; i < rawPadLinks.length; i++) {
        final entry = rawPadLinks[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('pad_links[$i] 必须是对象');
        }
        padLinks.add(WorldPadLink.fromJson(entry));
      }
    }

    final portalLinks = <WorldPortalLink>[];
    final rawPortalLinks = json['portal_links'];
    if (rawPortalLinks != null) {
      if (rawPortalLinks is! List) {
        throw const FormatException('portal_links 必须是数组');
      }
      for (var i = 0; i < rawPortalLinks.length; i++) {
        final entry = rawPortalLinks[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('portal_links[$i] 必须是对象');
        }
        portalLinks.add(WorldPortalLink.fromJson(entry));
      }
    }

    return WorldMeta(
      version: version,
      name: name,
      blockSize: blockSize,
      chunkFormatVersion: chunkFormatVersion,
      definitions: DefinitionRef.fromJson(definitions),
      indexRevision: indexRevision,
      start: WorldStart.fromJson(start),
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
      raw: json,
    );
  }

  WorldMeta withName(String value) {
    return WorldMeta(
      version: version,
      name: value,
      blockSize: blockSize,
      chunkFormatVersion: chunkFormatVersion,
      definitions: definitions,
      indexRevision: indexRevision,
      start: start,
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
      raw: raw,
    );
  }

  WorldMeta withStart(WorldStart value) {
    return WorldMeta(
      version: version,
      name: name,
      blockSize: blockSize,
      chunkFormatVersion: chunkFormatVersion,
      definitions: definitions,
      indexRevision: indexRevision,
      start: value,
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
      raw: raw,
    );
  }

  /// 只替换 index_revision，其他字段和未知字段保持不变。
  WorldMeta withIndexRevision(int revision) {
    return WorldMeta(
      version: version,
      name: name,
      blockSize: blockSize,
      chunkFormatVersion: chunkFormatVersion,
      definitions: definitions,
      indexRevision: revision,
      start: start,
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
      raw: raw,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['version'] = version;
    json['name'] = name;
    json['block_size'] = blockSize;
    json['chunk_format_version'] = chunkFormatVersion;
    json['definitions'] = definitions.toJson();
    json['index_revision'] = indexRevision;
    json['start'] = start.toJson();
    json['pads'] = pads.map((e) => e.toJson()).toList(growable: false);
    json['pad_links'] = padLinks.map((e) => e.toJson()).toList(growable: false);
    json['portal_links'] = portalLinks
        .map((e) => e.toJson())
        .toList(growable: false);
    return json;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 字段级校验；跨文件引用（传送门/传送格是否存在）由调用方校验。
  List<String> validate() {
    final errors = <String>[];
    if (version != 2) {
      errors.add('world.meta.json version 必须是 2，实际为 $version');
    }
    if (blockSize != 128) {
      errors.add('block_size 必须是 128，实际为 $blockSize');
    }
    if (chunkFormatVersion != 1) {
      errors.add('chunk_format_version 必须是 1，实际为 $chunkFormatVersion');
    }
    final padIds = <String>{};
    final padCells = <String>{};
    for (var i = 0; i < pads.length; i++) {
      final pad = pads[i];
      if (!padIds.add(pad.id)) {
        errors.add('pads[$i].id 重复：${pad.id}');
      }
      final cell = '${pad.z}:${pad.col}:${pad.row}';
      if (!padCells.add(cell)) {
        errors.add(
          'pads[$i] 与另一传送格在同一格（z=${pad.z}, '
          '${pad.col},${pad.row}）',
        );
      }
    }
    for (var i = 0; i < padLinks.length; i++) {
      final link = padLinks[i];
      if (!padIds.contains(link.from)) {
        errors.add('pad_links[$i].from 引用了不存在的传送格：${link.from}');
      }
      if (!padIds.contains(link.to)) {
        errors.add('pad_links[$i].to 引用了不存在的传送格：${link.to}');
      }
      if (link.from == link.to) {
        errors.add('pad_links[$i] 不能自环');
      }
    }
    for (var i = 0; i < portalLinks.length; i++) {
      final link = portalLinks[i];
      if (link.from == link.to) {
        errors.add('portal_links[$i] 不能自环');
      }
    }
    return errors;
  }
}

Map<String, dynamic> _parseObject(String text, String label) {
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw FormatException('$label 必须是 JSON 对象');
  }
  return value;
}
