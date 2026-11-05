import 'dart:convert';
import 'dart:io';

class SegmentSpec {
  String id;
  String file;
  int originCol;
  int originRow;
  String repeat; // "" / "x" / "y" / "xy"
  int repeatCount; // 0 = infinite

  SegmentSpec({
    required this.id,
    required this.file,
    this.originCol = 0,
    this.originRow = 0,
    this.repeat = '',
    this.repeatCount = 0,
  });

  static SegmentSpec fromJson(Map<String, dynamic> json) {
    final origin = (json['origin'] as List?)?.cast<num>() ?? const [0, 0];
    return SegmentSpec(
      id: json['id'] as String,
      file: json['file'] as String,
      originCol: origin[0].toInt(),
      originRow: origin[1].toInt(),
      repeat: (json['repeat'] as String?) ?? '',
      repeatCount: ((json['repeat_count'] as num?) ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'file': file,
        'origin': [originCol, originRow],
        if (repeat.isNotEmpty) 'repeat': repeat,
        if (repeat.isNotEmpty) 'repeat_count': repeatCount,
      };
}

class Segment {
  final SegmentSpec spec;
  List<String> rows;

  /// 行首以 `;` 开头的指令（prop / spawn / pad / solid / name…）。
  /// 编辑器不解释它们，只保证原样读写，不丢失。
  List<String> instructions;

  Segment(this.spec, this.rows, {List<String>? instructions})
      : instructions = instructions ?? <String>[];

  int get width => rows.isEmpty ? 0 : rows.first.length;
  int get height => rows.length;

  String charAt(int col, int row) {
    if (row < 0 || row >= height || col < 0 || col >= width) return '';
    return rows[row][col];
  }

  void setChar(int col, int row, String code) {
    if (row < 0 || row >= height || col < 0 || col >= width) return;
    final line = rows[row];
    rows[row] = line.substring(0, col) + code + line.substring(col + 1);
  }

  static Segment load(String dirPath, SegmentSpec spec) {
    final file = File('$dirPath${Platform.pathSeparator}${spec.file}');
    return Segment.fromText(spec, file.readAsStringSync());
  }

  static Segment fromText(SegmentSpec spec, String text) {
    final rows = <String>[];
    final instructions = <String>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith(';')) {
        instructions.add(line.trimRight());
        continue;
      }
      rows.add(line.trimRight());
    }
    return Segment(spec, rows, instructions: instructions);
  }
}

class PortalPlane {
  String axis; // "x" / "y"
  int at;
  int from;
  int to;
  String direction; // "+" / "-"
  int dx;
  int dy;

  PortalPlane({
    required this.axis,
    required this.at,
    required this.from,
    required this.to,
    required this.direction,
    required this.dx,
    required this.dy,
  });

  static PortalPlane fromJson(Map<String, dynamic> json) {
    final target = (json['target'] as List?)?.cast<num>() ?? const [0, 0];
    return PortalPlane(
      axis: (json['axis'] as String?) ?? 'x',
      at: ((json['at'] as num?) ?? 0).toInt(),
      from: ((json['from'] as num?) ?? 0).toInt(),
      to: ((json['to'] as num?) ?? 0).toInt(),
      direction: (json['direction'] as String?) ?? '+',
      dx: target[0].toInt(),
      dy: target[1].toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'axis': axis,
        'at': at,
        'from': from,
        'to': to,
        'direction': direction,
        'target': [dx, dy],
      };
}

class World {
  final String dirPath;
  String name;
  final List<Segment> segments;
  final List<PortalPlane> portalPlanes;
  final Map<String, dynamic> raw;

  World({
    required this.dirPath,
    required this.name,
    required this.segments,
    required this.portalPlanes,
    required this.raw,
  });

  Segment? segmentById(String id) {
    for (final s in segments) {
      if (s.spec.id == id) return s;
    }
    return null;
  }
}

class WorldIo {
  /// 列出世界根目录下的所有世界（含 world.json 的子目录）
  static List<String> listWorlds(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) return [];
    final names = <String>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final manifest = File('${entity.path}${Platform.pathSeparator}world.json');
      if (manifest.existsSync()) {
        names.add(entity.path.split(Platform.pathSeparator).last);
      }
    }
    names.sort();
    return names;
  }

  static World fromFiles(Map<String, String> files, {required String name, String dirPath = ''}) {
    final raw = Map<String, dynamic>.from(
      jsonDecode(files['world.json'] ?? '{}') as Map,
    );

    final segments = <Segment>[];
    for (final s in (raw['segments'] as List? ?? const [])) {
      final spec = SegmentSpec.fromJson(s as Map<String, dynamic>);
      segments.add(Segment.fromText(spec, files[spec.file] ?? ''));
    }

    final planes = <PortalPlane>[];
    for (final p in (raw['portal_planes'] as List? ?? const [])) {
      planes.add(PortalPlane.fromJson(p as Map<String, dynamic>));
    }

    return World(
      dirPath: dirPath,
      name: name,
      segments: segments,
      portalPlanes: planes,
      raw: raw,
    );
  }

  static World loadWorld(String dirPath) {
    final sep = Platform.pathSeparator;
    final manifestFile = File('$dirPath${sep}world.json');
    final raw = Map<String, dynamic>.from(
      jsonDecode(manifestFile.readAsStringSync()) as Map,
    );

    final segments = <Segment>[];
    for (final s in (raw['segments'] as List)) {
      final spec = SegmentSpec.fromJson(s as Map<String, dynamic>);
      segments.add(Segment.load(dirPath, spec));
    }

    final planes = <PortalPlane>[];
    for (final p in (raw['portal_planes'] as List? ?? const [])) {
      planes.add(PortalPlane.fromJson(p as Map<String, dynamic>));
    }

    return World(
      dirPath: dirPath,
      name: dirPath.split(sep).last,
      segments: segments,
      portalPlanes: planes,
      raw: raw,
    );
  }

  static Map<String, String> snapshot(World world) {
    final out = <String, String>{};

    for (final segment in world.segments) {
      final List<String> lines = <String>[
        ...segment.instructions,
        ...segment.rows,
      ];
      out[segment.spec.file] = '${lines.join('\n')}\n';
    }

    world.raw['segments'] =
        world.segments.map((s) => s.spec.toJson()).toList(growable: false);
    world.raw['portal_planes'] =
        world.portalPlanes.map((p) => p.toJson()).toList(growable: false);

    const encoder = JsonEncoder.withIndent('  ');
    out['world.json'] = '${encoder.convert(world.raw)}\n';
    return out;
  }

  static void saveWorld(World world) {
    final sep = Platform.pathSeparator;
    final files = snapshot(world);
    for (final entry in files.entries) {
      File('${world.dirPath}$sep${entry.key}').writeAsStringSync(entry.value);
    }
  }

  /// 校验：行宽一致、字符都在地形表里
  static List<String> validate(World world, Set<String> codes) {
    final errors = <String>[];

    // 段之间不允许重叠：同一坐标被两个段覆盖时，引擎取先命中的那个。
    for (int i = 0; i < world.segments.length; i++) {
      final Segment a = world.segments[i];
      final int ax1 = a.spec.originCol;
      final int ay1 = a.spec.originRow;
      final int ax2 = ax1 + a.width;
      final int ay2 = ay1 + a.height;

      for (int j = i + 1; j < world.segments.length; j++) {
        final Segment b = world.segments[j];
        final int bx1 = b.spec.originCol;
        final int by1 = b.spec.originRow;
        final int bx2 = bx1 + b.width;
        final int by2 = by1 + b.height;

        final bool overlapX = ax1 < bx2 && bx1 < ax2;
        final bool overlapY = ay1 < by2 && by1 < ay2;
        if (overlapX && overlapY) {
          errors.add('段 ${a.spec.id} 与 ${b.spec.id} 重叠');
        }
      }
    }

    for (final segment in world.segments) {
      final width = segment.width;
      for (var r = 0; r < segment.height; r++) {
        if (segment.rows[r].length != width) {
          errors.add('${segment.spec.id} 第 $r 行宽度 ${segment.rows[r].length}，应为 $width');
        }
        for (var c = 0; c < segment.rows[r].length; c++) {
          final code = segment.rows[r][c];
          if (!codes.contains(code)) {
            errors.add('${segment.spec.id} ($c,$r) 未知地形 "$code"');
          }
        }
      }
    }
    return errors;
  }
}
