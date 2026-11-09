/// 旧格式世界目录的解析与基础校验。
///
/// 对应白皮书附录 B：`world.json`、`*.seg`、旧 `terrain.json` / `props.json` /
/// `objects.json`。这里只读，不写源目录。
library;

import 'dart:convert';
import 'dart:io';

import 'definitions.dart';

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

class OldFormatException implements Exception {
  const OldFormatException(this.message, {this.file, this.line});

  final String message;
  final String? file;
  final int? line;

  @override
  String toString() {
    final where = <String>[?file, if (line != null) '第 $line 行'].join(' ');
    return where.isEmpty ? message : '$where：$message';
  }
}

class OldWorldData {
  OldWorldData({
    required this.version,
    required this.segments,
    required this.pads,
    required this.padLinks,
    required this.portalLinks,
    required this.seams,
    required this.startCol,
    required this.startRow,
    required this.raw,
    required this.warnings,
  });

  final int version;
  final List<OldSegment> segments;
  final List<OldPad> pads;
  final List<OldPadLink> padLinks;
  final List<OldPortalLink> portalLinks;
  final List<dynamic> seams;
  final int startCol;
  final int startRow;
  final Map<String, dynamic> raw;
  final List<String> warnings;

  /// 读取旧世界目录；不会写入源目录。
  static OldWorldData loadDirectory(String path, {bool keepUnknown = false}) {
    final root = Directory(path);
    final worldFile = File('${root.path}${Platform.pathSeparator}world.json');
    if (!worldFile.existsSync()) {
      throw OldFormatException('缺少 world.json', file: worldFile.path);
    }
    final raw = _jsonObject(worldFile.readAsStringSync(), worldFile.path);
    final version = raw['version'];
    if (version != 1) {
      throw OldFormatException(
        '旧 world.json version 必须是 1，实际为 $version',
        file: worldFile.path,
      );
    }
    final warnings = <String>[];
    final segments = <OldSegment>[];
    final rawSegments = raw['segments'];
    if (rawSegments is! List) {
      throw OldFormatException('segments 必须是数组', file: worldFile.path);
    }
    final segmentIds = <String>{};
    for (var i = 0; i < rawSegments.length; i++) {
      final entry = rawSegments[i];
      if (entry is! Map<String, dynamic>) {
        throw OldFormatException('segments[$i] 必须是对象', file: worldFile.path);
      }
      final segment = _parseSegment(
        root,
        entry,
        worldFile.path,
        warnings,
        keepUnknown,
      );
      if (!segmentIds.add(segment.id)) {
        throw OldFormatException('段 id 重复：${segment.id}', file: worldFile.path);
      }
      segments.add(segment);
      if (segment.name != null) {
        warnings.add('段 ${segment.id} 的旧名字：${segment.name}');
      }
    }

    final pads = <OldPad>[];
    final rawPads = raw['pads'];
    if (rawPads != null) {
      if (rawPads is! List) {
        throw OldFormatException('pads 必须是数组', file: worldFile.path);
      }
      for (var i = 0; i < rawPads.length; i++) {
        final entry = rawPads[i];
        if (entry is! Map<String, dynamic>) {
          throw OldFormatException('pads[$i] 必须是对象', file: worldFile.path);
        }
        pads.add(OldPad.fromJson(entry, worldFile.path, i));
      }
    }

    final padLinks = <OldPadLink>[];
    final rawPadLinks = raw['pad_links'];
    if (rawPadLinks != null) {
      if (rawPadLinks is! List) {
        throw OldFormatException('pad_links 必须是数组', file: worldFile.path);
      }
      for (var i = 0; i < rawPadLinks.length; i++) {
        final entry = rawPadLinks[i];
        if (entry is! Map<String, dynamic>) {
          throw OldFormatException('pad_links[$i] 必须是对象', file: worldFile.path);
        }
        padLinks.add(OldPadLink.fromJson(entry, worldFile.path, i));
      }
    }

    final rawPortalLinks = raw['portal_links'] ?? raw['links'];
    final rawOtherLinks = raw['portal_links'] != null && raw['links'] != null;
    if (rawOtherLinks &&
        jsonEncode(raw['portal_links']) != jsonEncode(raw['links'])) {
      throw OldFormatException(
        'portal_links 与 links 同时存在但内容不同',
        file: worldFile.path,
      );
    }
    final portalLinks = <OldPortalLink>[];
    if (rawPortalLinks != null) {
      if (rawPortalLinks is! List) {
        throw OldFormatException('portal_links 必须是数组', file: worldFile.path);
      }
      for (var i = 0; i < rawPortalLinks.length; i++) {
        final entry = rawPortalLinks[i];
        if (entry is! Map<String, dynamic>) {
          throw OldFormatException(
            'portal_links[$i] 必须是对象',
            file: worldFile.path,
          );
        }
        portalLinks.add(OldPortalLink.fromJson(entry, worldFile.path, i));
      }
    }

    final start = raw['start'];
    if (start is! Map<String, dynamic>) {
      throw OldFormatException('start 必须是对象', file: worldFile.path);
    }
    final startCol = start['col'];
    final startRow = start['row'];
    if (startCol is! int || startRow is! int) {
      throw OldFormatException('start 必须包含整数 col、row', file: worldFile.path);
    }

    final seams = raw['seams'];
    if (seams != null && seams is! List) {
      throw OldFormatException('seams 必须是数组', file: worldFile.path);
    }

    const knownKeys = <String>{
      'version',
      'segments',
      'pads',
      'pad_links',
      'portal_links',
      'links',
      'seams',
      'portal_planes',
      'start',
    };
    for (final key in raw.keys) {
      if (knownKeys.contains(key)) continue;
      final value = raw[key];
      if (value == null ||
          (value is List && value.isEmpty) ||
          (value is Map && value.isEmpty)) {
        warnings.add('忽略空顶层字段 $key');
        continue;
      }
      throw OldFormatException('不支持的旧顶层字段：$key', file: worldFile.path);
    }

    final world = OldWorldData(
      version: version as int,
      segments: segments,
      pads: pads,
      padLinks: padLinks,
      portalLinks: portalLinks,
      seams: seams as List? ?? const <dynamic>[],
      startCol: startCol,
      startRow: startRow,
      raw: raw,
      warnings: warnings,
    );
    world.validateGeometry();
    return world;
  }

  static OldSegment _parseSegment(
    Directory root,
    Map<String, dynamic> json,
    String worldFile,
    List<String> warnings,
    bool keepUnknown,
  ) {
    final id = json['id'];
    final file = json['file'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw OldFormatException('段 id 缺失或字符非法', file: worldFile);
    }
    if (file is! String || file.isEmpty) {
      throw OldFormatException('段 $id 缺少 file', file: worldFile);
    }
    if (file.startsWith('/') || file.contains('..') || file.contains('\\')) {
      throw OldFormatException('段文件路径非法：$file', file: worldFile);
    }
    final origin = json['origin'];
    if (origin is! List || (origin.length != 2 && origin.length != 3)) {
      throw OldFormatException(
        '段 $id 的 origin 必须是 [col,row] 或 [col,row,z]',
        file: worldFile,
      );
    }
    final originNums = <int>[];
    for (final value in origin) {
      if (value is! num) {
        throw OldFormatException('段 $id 的 origin 必须是数字', file: worldFile);
      }
      originNums.add(value.toInt());
    }
    final repeat = json['repeat'];
    if (repeat != null &&
        repeat != '' &&
        repeat != 'x' &&
        repeat != 'y' &&
        repeat != 'xy') {
      throw OldFormatException('段 $id 的 repeat 只能是空、x、y、xy', file: worldFile);
    }
    final repeatCount = json['repeat_count'];
    if (repeatCount != null && (repeatCount is! int || repeatCount < 0)) {
      throw OldFormatException('段 $id 的 repeat_count 必须是非负整数', file: worldFile);
    }
    final segmentFile = File('${root.path}${Platform.pathSeparator}$file');
    if (!segmentFile.existsSync()) {
      throw OldFormatException('段文件不存在', file: segmentFile.path);
    }
    final text = _readText(segmentFile.path);
    final rows = <String>[];
    final rawInstructions = <(int, String)>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      if (line.trim().startsWith(';')) {
        rawInstructions.add((i + 1, line.trimRight()));
      } else {
        rows.add(line.trimRight());
      }
    }
    final width = rows.isEmpty ? 0 : rows.first.runes.length;
    final height = rows.length;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].runes.length != width) {
        throw OldFormatException(
          '段 $id 的地形行长度不一致',
          file: segmentFile.path,
          line: i + 1,
        );
      }
      if (rows[i].codeUnits.any((u) => u >= 0xD800 && u <= 0xDFFF)) {
        throw OldFormatException(
          '段 $id 含非 BMP 字符，旧格式不支持',
          file: segmentFile.path,
          line: i + 1,
        );
      }
    }
    if (width == 0 && height == 0 && (repeat != null && repeat != '')) {
      throw OldFormatException('空段不能有 repeat', file: worldFile);
    }

    final instructions = <OldInstruction>[];
    String? name;
    for (final (lineNumber, rawLine) in rawInstructions) {
      final parsed = _parseInstruction(
        rawLine,
        width,
        height,
        segmentFile.path,
        lineNumber,
      );
      if (parsed == null) {
        if (!keepUnknown) {
          throw OldFormatException(
            '未知旧指令：$rawLine',
            file: segmentFile.path,
            line: lineNumber,
          );
        }
        instructions.add(OldUnknownInstruction(rawLine));
        warnings.add('保留未知旧指令：$rawLine');
      } else if (parsed is OldNameInstruction) {
        name = parsed.text;
      } else {
        instructions.add(parsed);
      }
    }

    return OldSegment(
      id: id,
      file: file,
      originCol: originNums[0],
      originRow: originNums[1],
      originZ: originNums.length > 2 ? originNums[2] : 0,
      repeat: repeat as String? ?? '',
      repeatCount: repeatCount as int? ?? 0,
      rows: rows,
      instructions: instructions,
      name: name,
    );
  }

  static OldInstruction? _parseInstruction(
    String line,
    int width,
    int height,
    String file,
    int lineNumber,
  ) {
    final text = line.trim();
    if (text == ';') return null;
    final body = text.substring(1).trimLeft();
    final eq = body.indexOf('=');
    if (eq < 0) return null;
    final keyword = body.substring(0, eq);
    final value = body.substring(eq + 1);
    final fields = value.split(',').map((e) => e.trim()).toList();
    switch (keyword) {
      case 'name':
        return OldNameInstruction(value);
      case 'prop':
      case 'spawn':
        if (fields.length != 3) {
          throw OldFormatException(
            '$keyword 必须有 3 个字段',
            file: file,
            line: lineNumber,
          );
        }
        final type = fields[0];
        if (!_idPattern.hasMatch(type)) {
          throw OldFormatException(
            '$keyword 类型字符非法',
            file: file,
            line: lineNumber,
          );
        }
        final col = _oldInt(fields[1], file, lineNumber);
        final row = _oldInt(fields[2], file, lineNumber);
        return keyword == 'prop'
            ? OldPropInstruction(type: type, col: col, row: row)
            : OldSpawnInstruction(type: type, col: col, row: row);
      case 'pad':
        if (fields.length == 3) {
          final id = fields[0];
          if (!_idPattern.hasMatch(id)) {
            throw OldFormatException(
              'pad id 字符非法',
              file: file,
              line: lineNumber,
            );
          }
          return OldPadInstruction(
            id: id,
            col: _oldInt(fields[1], file, lineNumber),
            row: _oldInt(fields[2], file, lineNumber),
          );
        }
        if (fields.length == 4) {
          // 游戏旧引擎的写法：; pad=<col>,<row>,<target_col>,<target_row>
          return OldPadInstruction(
            id: null,
            col: _oldInt(fields[0], file, lineNumber),
            row: _oldInt(fields[1], file, lineNumber),
            targetCol: _oldInt(fields[2], file, lineNumber),
            targetRow: _oldInt(fields[3], file, lineNumber),
          );
        }
        throw OldFormatException(
          'pad 必须是 3 个字段（id,col,row）或 4 个字段'
          '（col,row,target_col,target_row）',
          file: file,
          line: lineNumber,
        );
      case 'solid':
        if (fields.length < 6 || fields.length.isOdd) {
          throw OldFormatException(
            'solid 至少 3 个顶点且坐标数必须为偶数',
            file: file,
            line: lineNumber,
          );
        }
        final points = <(int, int)>[];
        for (var i = 0; i < fields.length; i += 2) {
          points.add((
            _oldInt(fields[i], file, lineNumber),
            _oldInt(fields[i + 1], file, lineNumber),
          ));
        }
        return OldSolidInstruction(points);
      case 'portal':
        if (fields.length != 5) {
          throw OldFormatException(
            'portal 必须有 5 个字段',
            file: file,
            line: lineNumber,
          );
        }
        final id = fields[0];
        final dir = fields[1];
        if (!_idPattern.hasMatch(id)) {
          throw OldFormatException(
            'portal id 字符非法',
            file: file,
            line: lineNumber,
          );
        }
        if (dir != 'right' && dir != 'down') {
          throw OldFormatException(
            'portal.dir 只能是 right 或 down',
            file: file,
            line: lineNumber,
          );
        }
        final x = _oldInt(fields[2], file, lineNumber);
        final y = _oldInt(fields[3], file, lineNumber);
        final length = _oldInt(fields[4], file, lineNumber);
        if (length <= 0) {
          throw OldFormatException(
            'portal.length 必须是正整数',
            file: file,
            line: lineNumber,
          );
        }
        if (x < 0 || x > width || y < 0 || y > height) {
          throw OldFormatException(
            'portal 起点超出段范围',
            file: file,
            line: lineNumber,
          );
        }
        if (dir == 'right' && x + length > width) {
          throw OldFormatException('portal 超出段宽', file: file, line: lineNumber);
        }
        if (dir == 'down' && y + length > height) {
          throw OldFormatException('portal 超出段高', file: file, line: lineNumber);
        }
        return OldPortalInstruction(
          id: id,
          dir: dir,
          x: x,
          y: y,
          length: length,
        );
      default:
        return null;
    }
  }

  /// 段 id 唯一、同层地形不重叠、repeat 可展开。
  void validateGeometry() {
    final ids = <String>{};
    final rectangles = <String, List<_OldRect>>{};
    for (final segment in segments) {
      if (!ids.add(segment.id)) {
        throw OldFormatException('段 id 重复：${segment.id}');
      }
      final copies = segment.expandedOffsets();
      for (final (dc, dr) in copies) {
        final rect = _OldRect(
          segment.originCol + dc,
          segment.originRow + dr,
          segment.width,
          segment.height,
        );
        final layer = segment.originZ;
        final list = rectangles.putIfAbsent('$layer', () => <_OldRect>[]);
        for (final other in list) {
          if (rect.intersects(other)) {
            throw OldFormatException('段 ${segment.id} 在层 $layer 与另一段地形重叠');
          }
        }
        list.add(rect);
      }
    }
  }

  /// 校验地形、道具和对象类型都在旧定义包中。
  void validateDefinitions(DefinitionPackage definitions) {
    for (final segment in segments) {
      for (var row = 0; row < segment.rows.length; row++) {
        for (final code in segment.rows[row].runes) {
          final text = String.fromCharCodes(<int>[code]);
          if (!definitions.terrain.byCode.containsKey(text)) {
            throw OldFormatException(
              '段 ${segment.id} 引用了未定义地形：$text',
              line: row + 1,
            );
          }
        }
      }
      for (final instruction in segment.instructions) {
        if (instruction is OldPropInstruction &&
            !definitions.propsById.containsKey(instruction.type)) {
          throw OldFormatException(
            '段 ${segment.id} 引用了不存在的道具：${instruction.type}',
          );
        }
        if (instruction is OldSpawnInstruction &&
            !definitions.objectsById.containsKey(instruction.type)) {
          throw OldFormatException(
            '段 ${segment.id} 引用了不存在的对象：${instruction.type}',
          );
        }
      }
    }
  }
}

class OldSegment {
  OldSegment({
    required this.id,
    required this.file,
    required this.originCol,
    required this.originRow,
    required this.originZ,
    required this.repeat,
    required this.repeatCount,
    required this.rows,
    required this.instructions,
    required this.name,
  });

  final String id;
  final String file;
  final int originCol;
  final int originRow;
  final int originZ;
  final String repeat;
  final int repeatCount;
  final List<String> rows;
  final List<OldInstruction> instructions;
  final String? name;

  int get width => rows.isEmpty ? 0 : rows.first.runes.length;
  int get height => rows.length;

  /// 返回每个 repeat 副本的偏移；无限 repeat 直接报错。
  List<(int, int)> expandedOffsets() {
    if (repeat.isEmpty) return const <(int, int)>[(0, 0)];
    if (repeatCount == 0) {
      throw OldFormatException('段 $id 使用无限 repeat，无法迁移');
    }
    final offsets = <(int, int)>[];
    for (var k = 0; k < repeatCount; k++) {
      final dc = repeat.contains('x') ? k * width : 0;
      final dr = repeat.contains('y') ? k * height : 0;
      offsets.add((dc, dr));
    }
    return offsets;
  }
}

sealed class OldInstruction {
  const OldInstruction();
}

class OldPropInstruction extends OldInstruction {
  const OldPropInstruction({
    required this.type,
    required this.col,
    required this.row,
  });

  final String type;
  final int col;
  final int row;
}

class OldSpawnInstruction extends OldInstruction {
  const OldSpawnInstruction({
    required this.type,
    required this.col,
    required this.row,
  });

  final String type;
  final int col;
  final int row;
}

class OldSolidInstruction extends OldInstruction {
  const OldSolidInstruction(this.points);

  final List<(int, int)> points;
}

class OldPortalInstruction extends OldInstruction {
  const OldPortalInstruction({
    required this.id,
    required this.dir,
    required this.x,
    required this.y,
    required this.length,
  });

  final String id;
  final String dir;
  final int x;
  final int y;
  final int length;
}

class OldPadInstruction extends OldInstruction {
  const OldPadInstruction({
    required this.id,
    required this.col,
    required this.row,
    this.targetCol,
    this.targetRow,
  });

  /// 三字段旧写法的 id；四字段旧写法没有 id，由迁移器生成。
  final String? id;
  final int col;
  final int row;

  /// 四字段旧写法的目标格；三字段写法为 null。
  final int? targetCol;
  final int? targetRow;

  bool get isDirect => targetCol != null && targetRow != null;
}

class OldNameInstruction extends OldInstruction {
  const OldNameInstruction(this.text);

  final String text;
}

class OldUnknownInstruction extends OldInstruction {
  const OldUnknownInstruction(this.line);

  final String line;
}

class OldPad {
  const OldPad({
    required this.id,
    required this.segment,
    required this.col,
    required this.row,
  });

  final String id;
  final String segment;
  final int col;
  final int row;

  static OldPad fromJson(Map<String, dynamic> json, String file, int index) {
    final id = json['id'];
    final segment = json['segment'];
    final col = json['col'];
    final row = json['row'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw OldFormatException('pads[$index].id 字符非法', file: file);
    }
    if (segment is! String) {
      throw OldFormatException('pads[$index].segment 缺失', file: file);
    }
    if (col is! int || row is! int) {
      throw OldFormatException('pads[$index] 必须包含整数 col、row', file: file);
    }
    return OldPad(id: id, segment: segment, col: col, row: row);
  }
}

class OldPadLink {
  const OldPadLink({
    required this.from,
    required this.to,
    required this.bidirectional,
  });

  final String from;
  final String to;
  final bool bidirectional;

  static OldPadLink fromJson(
    Map<String, dynamic> json,
    String file,
    int index,
  ) {
    final from = json['from'];
    final to = json['to'];
    final bidirectional = json['bidirectional'];
    if (from is! String || to is! String) {
      throw OldFormatException('pad_links[$index] 缺少 from/to', file: file);
    }
    if (bidirectional != null && bidirectional is! bool) {
      throw OldFormatException(
        'pad_links[$index].bidirectional 必须是布尔值',
        file: file,
      );
    }
    return OldPadLink(from: from, to: to, bidirectional: bidirectional == true);
  }
}

class OldPortalLink {
  const OldPortalLink({
    required this.from,
    required this.to,
    required this.face,
  });

  final String from;
  final String to;
  final String face;

  static OldPortalLink fromJson(
    Map<String, dynamic> json,
    String file,
    int index,
  ) {
    final from = json['from'];
    final to = json['to'];
    final face = json['face'] ?? 'A';
    if (from is! String || to is! String) {
      throw OldFormatException('portal_links[$index] 缺少 from/to', file: file);
    }
    if (face != 'A' && face != 'B' && face != 'both') {
      throw OldFormatException('portal_links[$index].face 非法', file: file);
    }
    return OldPortalLink(from: from, to: to, face: face as String);
  }
}

class _OldRect {
  const _OldRect(this.x, this.y, this.w, this.h);

  final int x;
  final int y;
  final int w;
  final int h;

  bool intersects(_OldRect other) {
    return x < other.x + other.w &&
        other.x < x + w &&
        y < other.y + other.h &&
        other.y < y + h;
  }
}

int _oldInt(String text, String file, int line) {
  final value = int.tryParse(text);
  if (value == null) {
    throw OldFormatException('不是整数：$text', file: file, line: line);
  }
  return value;
}

Map<String, dynamic> _jsonObject(String text, String file) {
  final value = jsonDecode(text);
  if (value is! Map<String, dynamic>) {
    throw OldFormatException('JSON 必须是对象', file: file);
  }
  return value;
}

String _readText(String path) {
  var text = File(path).readAsStringSync();
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  return text.replaceAll('\r\n', '\n');
}
