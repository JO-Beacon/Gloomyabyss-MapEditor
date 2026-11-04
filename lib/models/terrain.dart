import 'dart:convert';
import 'dart:io';

class TerrainType {
  final String code;
  final String name;
  final int color;
  final bool block;
  final double speed;
  final double damage;

  const TerrainType({
    required this.code,
    required this.name,
    required this.color,
    required this.block,
    required this.speed,
    required this.damage,
  });

  static TerrainType fromJson(Map<String, dynamic> json) {
    final rgb = (json['color'] as List?)?.cast<num>() ?? const [255, 255, 255];
    final color = 0xFF000000 |
        ((rgb[0].toInt() & 0xFF) << 16) |
        ((rgb[1].toInt() & 0xFF) << 8) |
        (rgb[2].toInt() & 0xFF);
    return TerrainType(
      code: json['code'] as String,
      name: (json['name'] as String?) ?? json['code'] as String,
      color: color,
      block: (json['block'] as bool?) ?? false,
      speed: ((json['speed'] as num?) ?? 1).toDouble(),
      damage: ((json['damage'] as num?) ?? 0).toDouble(),
    );
  }
}

class TerrainSet {
  final int tileSize;
  final List<TerrainType> types;
  final Map<String, TerrainType> byCode = {};

  TerrainSet({required this.tileSize, required this.types}) {
    for (final t in types) {
      byCode[t.code] = t;
    }
  }

  static TerrainSet load(String path) =>
      TerrainSet.fromJsonString(File(path).readAsStringSync());

  static TerrainSet fromJsonString(String content) {
    final json = jsonDecode(content) as Map<String, dynamic>;
    final types = (json['types'] as List)
        .map((e) => TerrainType.fromJson(e as Map<String, dynamic>))
        .toList();
    return TerrainSet(
      tileSize: ((json['tile_size'] as num?) ?? 20).toInt(),
      types: types,
    );
  }

  TerrainType get fallback => types.first;
}
