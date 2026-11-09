/// `world.index.json` 的格式模型。
library;

import 'dart:convert';

import 'geometry.dart';

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// 传送门索引项。
class IndexPortal {
  IndexPortal({
    required this.id,
    required this.z,
    required this.x,
    required this.y,
    required this.dir,
    required this.length,
    required this.chunk,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String id;
  final int z;
  final int x;
  final int y;
  final String dir;
  final int length;
  final BlockCoord chunk;
  final Map<String, dynamic> raw;

  static IndexPortal fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final z = json['z'];
    final x = json['x'];
    final y = json['y'];
    final dir = json['dir'];
    final length = json['length'];
    final chunk = json['chunk'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('portal 索引 id 缺失或字符非法');
    }
    if (z is! int || x is! int || y is! int) {
      throw const FormatException('portal 索引必须包含整数 z、x、y');
    }
    if (dir != 'right' && dir != 'down') {
      throw const FormatException('portal 索引 dir 只能是 right 或 down');
    }
    if (length is! int || length <= 0) {
      throw const FormatException('portal 索引 length 必须是正整数');
    }
    return IndexPortal(
      id: id,
      z: z,
      x: x,
      y: y,
      dir: dir,
      length: length,
      chunk: _chunkFromJson(chunk, 'portal.chunk'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['id'] = id;
    json['z'] = z;
    json['x'] = x;
    json['y'] = y;
    json['dir'] = dir;
    json['length'] = length;
    json['chunk'] = <int>[chunk.cx, chunk.cy];
    return json;
  }
}

/// 道具/对象索引项。
class IndexPropsObject {
  IndexPropsObject({
    required this.kind,
    required this.type,
    required this.z,
    required this.col,
    required this.row,
    required this.w,
    required this.h,
    required this.chunk,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String kind;
  final String type;
  final int z;
  final int col;
  final int row;
  final int w;
  final int h;
  final BlockCoord chunk;
  final Map<String, dynamic> raw;

  static IndexPropsObject fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final type = json['type'];
    final z = json['z'];
    final col = json['col'];
    final row = json['row'];
    final w = json['w'];
    final h = json['h'];
    final chunk = json['chunk'];
    if (kind != 'prop' && kind != 'object') {
      throw const FormatException('props_objects.kind 只能是 prop 或 object');
    }
    if (type is! String || !_idPattern.hasMatch(type)) {
      throw const FormatException('props_objects.type 缺失或字符非法');
    }
    if (z is! int || col is! int || row is! int) {
      throw const FormatException('props_objects 必须包含整数 z、col、row');
    }
    if (w is! int || w <= 0 || h is! int || h <= 0) {
      throw const FormatException('props_objects.w/h 必须是正整数');
    }
    return IndexPropsObject(
      kind: kind as String,
      type: type,
      z: z,
      col: col,
      row: row,
      w: w,
      h: h,
      chunk: _chunkFromJson(chunk, 'props_objects.chunk'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['kind'] = kind;
    json['type'] = type;
    json['z'] = z;
    json['col'] = col;
    json['row'] = row;
    json['w'] = w;
    json['h'] = h;
    json['chunk'] = <int>[chunk.cx, chunk.cy];
    return json;
  }
}

/// 碰撞组里的一个片段。
class IndexSolidPiece {
  IndexSolidPiece({
    required this.chunk,
    required this.index,
    required this.bbox,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final BlockCoord chunk;
  final int index;
  final FloatRect bbox;
  final Map<String, dynamic> raw;

  static IndexSolidPiece fromJson(Map<String, dynamic> json) {
    final index = json['index'];
    if (index is! int || index < 0) {
      throw const FormatException('solid piece index 必须是非负整数');
    }
    return IndexSolidPiece(
      chunk: _chunkFromJson(json['chunk'], 'solid piece.chunk'),
      index: index,
      bbox: _rectFromJson(json['bbox'], 'solid piece.bbox'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['chunk'] = <int>[chunk.cx, chunk.cy];
    json['index'] = index;
    json['bbox'] = <num>[bbox.x, bbox.y, bbox.w, bbox.h];
    return json;
  }
}

/// 一个碰撞组（同一层内以 group 区分）。
class IndexSolidGroup {
  IndexSolidGroup({
    required this.group,
    required this.z,
    required this.bbox,
    required this.pieces,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final String group;
  final int z;
  final FloatRect bbox;
  final List<IndexSolidPiece> pieces;
  final Map<String, dynamic> raw;

  static IndexSolidGroup fromJson(Map<String, dynamic> json) {
    final group = json['group'];
    final z = json['z'];
    if (group is! String || !_idPattern.hasMatch(group)) {
      throw const FormatException('solid group 缺失或字符非法');
    }
    if (z is! int) {
      throw const FormatException('solid group 必须包含整数 z');
    }
    final rawPieces = json['pieces'];
    if (rawPieces is! List) {
      throw const FormatException('solid group pieces 必须是数组');
    }
    final pieces = <IndexSolidPiece>[];
    for (var i = 0; i < rawPieces.length; i++) {
      final entry = rawPieces[i];
      if (entry is! Map<String, dynamic>) {
        throw FormatException('solid group pieces[$i] 必须是对象');
      }
      pieces.add(IndexSolidPiece.fromJson(entry));
    }
    return IndexSolidGroup(
      group: group,
      z: z,
      bbox: _rectFromJson(json['bbox'], 'solid group.bbox'),
      pieces: pieces,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['group'] = group;
    json['z'] = z;
    json['bbox'] = <num>[bbox.x, bbox.y, bbox.w, bbox.h];
    json['pieces'] = pieces.map((e) => e.toJson()).toList(growable: false);
    return json;
  }
}

/// 一个 `world.index.json` 文档。
class WorldIndex {
  WorldIndex({
    required this.revision,
    required this.fullCheckedAt,
    required this.portals,
    required this.propsObjects,
    required this.solidGroups,
    Map<String, dynamic>? raw,
  }) : raw = raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);

  final int revision;
  final String fullCheckedAt;
  final List<IndexPortal> portals;
  final List<IndexPropsObject> propsObjects;
  final List<IndexSolidGroup> solidGroups;
  final Map<String, dynamic> raw;

  static WorldIndex parse(String text) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('world.index.json 必须是 JSON 对象');
    }
    return fromJson(value);
  }

  static WorldIndex fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    final fullCheckedAt = json['full_checked_at'];
    if (revision is! int || revision < 0) {
      throw const FormatException('world.index.json revision 必须是非负整数');
    }
    if (fullCheckedAt != null && fullCheckedAt is! String) {
      throw const FormatException('full_checked_at 必须是字符串');
    }

    final portals = <IndexPortal>[];
    final rawPortals = json['portals'];
    if (rawPortals != null) {
      if (rawPortals is! List) {
        throw const FormatException('portals 必须是数组');
      }
      for (var i = 0; i < rawPortals.length; i++) {
        final entry = rawPortals[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('portals[$i] 必须是对象');
        }
        portals.add(IndexPortal.fromJson(entry));
      }
    }

    final propsObjects = <IndexPropsObject>[];
    final rawPropsObjects = json['props_objects'];
    if (rawPropsObjects != null) {
      if (rawPropsObjects is! List) {
        throw const FormatException('props_objects 必须是数组');
      }
      for (var i = 0; i < rawPropsObjects.length; i++) {
        final entry = rawPropsObjects[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('props_objects[$i] 必须是对象');
        }
        propsObjects.add(IndexPropsObject.fromJson(entry));
      }
    }

    final solidGroups = <IndexSolidGroup>[];
    final rawSolidGroups = json['solid_groups'];
    if (rawSolidGroups != null) {
      if (rawSolidGroups is! List) {
        throw const FormatException('solid_groups 必须是数组');
      }
      for (var i = 0; i < rawSolidGroups.length; i++) {
        final entry = rawSolidGroups[i];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('solid_groups[$i] 必须是对象');
        }
        solidGroups.add(IndexSolidGroup.fromJson(entry));
      }
    }

    return WorldIndex(
      revision: revision,
      fullCheckedAt: (fullCheckedAt as String?) ?? '',
      portals: portals,
      propsObjects: propsObjects,
      solidGroups: solidGroups,
      raw: json,
    );
  }

  /// 只替换 revision，其他字段和未知字段保持不变。
  WorldIndex withRevision(int revision) {
    return WorldIndex(
      revision: revision,
      fullCheckedAt: fullCheckedAt,
      portals: portals,
      propsObjects: propsObjects,
      solidGroups: solidGroups,
      raw: raw,
    );
  }

  Map<String, dynamic> toJson() {
    final json = Map<String, dynamic>.from(raw);
    json['revision'] = revision;
    json['full_checked_at'] = fullCheckedAt;
    json['portals'] = portals.map((e) => e.toJson()).toList(growable: false);
    json['props_objects'] = propsObjects
        .map((e) => e.toJson())
        .toList(growable: false);
    json['solid_groups'] = solidGroups
        .map((e) => e.toJson())
        .toList(growable: false);
    return json;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 基本的重复和交叉校验；块内本体校验由加载器完成。
  List<String> validate() {
    final errors = <String>[];
    final portalIds = <String>{};
    for (var i = 0; i < portals.length; i++) {
      final portal = portals[i];
      if (!portalIds.add(portal.id)) {
        errors.add('portals[$i].id 重复：${portal.id}');
      }
    }
    final propsObjectKeys = <String>{};
    for (var i = 0; i < propsObjects.length; i++) {
      final item = propsObjects[i];
      final key = '${item.z}/${item.kind}/${item.type}/${item.col}/${item.row}';
      if (!propsObjectKeys.add(key)) {
        errors.add('props_objects[$i] 重复：$key');
      }
    }
    final groupKeys = <String>{};
    for (var i = 0; i < solidGroups.length; i++) {
      final group = solidGroups[i];
      final key = '${group.z}/${group.group}';
      if (!groupKeys.add(key)) {
        errors.add('solid_groups[$i] 重复：$key');
      }
    }
    return errors;
  }
}

BlockCoord _chunkFromJson(dynamic value, String label) {
  if (value is! List || value.length != 2) {
    throw FormatException('$label 必须是 [cx, cy]');
  }
  final cx = value[0];
  final cy = value[1];
  if (cx is! int || cy is! int) {
    throw FormatException('$label 必须是两个整数');
  }
  return BlockCoord(cx, cy);
}

FloatRect _rectFromJson(dynamic value, String label) {
  if (value is! List || value.length != 4) {
    throw FormatException('$label 必须是 [x, y, w, h]');
  }
  final nums = <double>[];
  for (final item in value) {
    if (item is! num) {
      throw FormatException('$label 必须由数字组成');
    }
    nums.add(item.toDouble());
  }
  if (nums[2] < 0 || nums[3] < 0) {
    throw FormatException('$label 的 w/h 不能为负');
  }
  return FloatRect(nums[0], nums[1], nums[2], nums[3]);
}
