import 'dart:convert';

/// 可放置对象（来自 objects.json，由游戏侧维护）。
class ObjectType {
  const ObjectType({required this.id, required this.name});

  final String id;
  final String name;

  static ObjectType fromJson(Map<String, dynamic> json) => ObjectType(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? json['id'] as String,
      );

  static List<ObjectType> parse(String content) {
    final json = jsonDecode(content) as Map<String, dynamic>;
    return (json['types'] as List)
        .map((e) => ObjectType.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// 地图里已经放下的对象（来自 `; spawn=id,col,row[,w,h]`）。
class PlacedObject {
  const PlacedObject({
    required this.id,
    required this.col,
    required this.row,
    required this.instructionIndex,
  });

  final String id;
  final int col;
  final int row;
  final int instructionIndex;
}

final RegExp _spawnLine = RegExp(
  r'^\s*;\s*spawn\s*=\s*([^,]+?)\s*,\s*(-?\d+)\s*,\s*(-?\d+)',
  caseSensitive: false,
);

List<PlacedObject> parsePlacedObjects(List<String> instructions) {
  final out = <PlacedObject>[];
  for (int i = 0; i < instructions.length; i++) {
    final m = _spawnLine.firstMatch(instructions[i]);
    if (m == null) continue;
    out.add(PlacedObject(
      id: m.group(1)!.trim(),
      col: int.parse(m.group(2)!),
      row: int.parse(m.group(3)!),
      instructionIndex: i,
    ));
  }
  return out;
}
