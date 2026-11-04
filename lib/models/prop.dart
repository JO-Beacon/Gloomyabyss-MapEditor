import 'dart:convert';

/// 道具类型（来自 props.json）。
class PropType {
  const PropType({
    required this.id,
    required this.name,
    required this.sprite,
    required this.block,
    required this.width,
    required this.height,
    required this.interaction,
  });

  final String id;
  final String name;
  final String sprite;
  final bool block;
  final int width;
  final int height;
  final String interaction;

  static PropType fromJson(Map<String, dynamic> json) {
    return PropType(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? json['id'] as String,
      sprite: (json['sprite'] as String?) ?? '',
      block: (json['block'] as bool?) ?? true,
      width: ((json['width'] as num?) ?? 1).toInt(),
      height: ((json['height'] as num?) ?? 1).toInt(),
      interaction: (json['interaction'] as String?) ?? '',
    );
  }

  static List<PropType> parse(String content) {
    final json = jsonDecode(content) as Map<String, dynamic>;
    return (json['types'] as List)
        .map((e) => PropType.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// 地图里已经放下的一个道具（从 `; prop=id,col,row` 指令解析而来）。
class PlacedProp {
  const PlacedProp({
    required this.id,
    required this.col,
    required this.row,
    required this.instructionIndex,
  });

  final String id;
  final int col;
  final int row;

  /// 对应 segment.instructions 里的下标，删除时用。
  final int instructionIndex;
}

final RegExp _propLine = RegExp(
  r'^\s*;\s*prop\s*=\s*([^,]+?)\s*,\s*(-?\d+)\s*,\s*(-?\d+)',
  caseSensitive: false,
);

/// 从段里的 `;` 指令解析出已经放下的道具。
List<PlacedProp> parsePlacedProps(List<String> instructions) {
  final out = <PlacedProp>[];
  for (int i = 0; i < instructions.length; i++) {
    final m = _propLine.firstMatch(instructions[i]);
    if (m == null) continue;
    out.add(PlacedProp(
      id: m.group(1)!.trim(),
      col: int.parse(m.group(2)!),
      row: int.parse(m.group(3)!),
      instructionIndex: i,
    ));
  }
  return out;
}
