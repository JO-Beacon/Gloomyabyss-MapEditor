/// 块文件格式：`chunks/<z>/<cx>_<cy>.chunk`。
///
/// 解析严格按白皮书第 5 章执行；未知指令按原始行保留。
library;

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _decimalPattern = RegExp(
  r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,4})?$',
);

/// 块文件内部的空列占位符，不是地形表代码。
const String emptyTerrainPadding = '\u0000';

/// 块文件里的指令。
sealed class ChunkInstruction {
  const ChunkInstruction();

  String toLine();
}

/// `; prop=<z>,<type>,<col>,<row>`。
class PropInstruction extends ChunkInstruction {
  const PropInstruction({
    required this.z,
    required this.type,
    required this.col,
    required this.row,
  });

  final int z;
  final String type;
  final int col;
  final int row;

  @override
  String toLine() => '; prop=$z,$type,$col,$row';
}

/// `; spawn=<z>,<object>,<col>,<row>`。
class SpawnInstruction extends ChunkInstruction {
  const SpawnInstruction({
    required this.z,
    required this.type,
    required this.col,
    required this.row,
  });

  final int z;
  final String type;
  final int col;
  final int row;

  @override
  String toLine() => '; spawn=$z,$type,$col,$row';
}

/// `; solid=<z>,<group>,<x1>,<y1>,...`。
class SolidInstruction extends ChunkInstruction {
  const SolidInstruction({
    required this.z,
    required this.group,
    required this.points,
  });

  final int z;
  final String group;
  final List<(double, double)> points;

  @override
  String toLine() {
    final coords = <String>[];
    for (final (x, y) in points) {
      coords
        ..add(formatSolidNumber(x))
        ..add(formatSolidNumber(y));
    }
    return '; solid=$z,$group,${coords.join(',')}';
  }
}

/// `; portal=<id>,<dir>,<x>,<y>,<length>,<z>`。
class PortalInstruction extends ChunkInstruction {
  const PortalInstruction({
    required this.id,
    required this.dir,
    required this.x,
    required this.y,
    required this.length,
    required this.z,
  });

  final String id;
  final String dir;
  final int x;
  final int y;
  final int length;
  final int z;

  @override
  String toLine() => '; portal=$id,$dir,$x,$y,$length,$z';
}

/// 不能识别但必须原样保留的指令行。
class UnknownInstruction extends ChunkInstruction {
  const UnknownInstruction(this.line);

  final String line;

  @override
  String toLine() => line;
}

/// 一个块文件的完整内容。
class ChunkFile {
  ChunkFile({
    required this.z,
    required this.cx,
    required this.cy,
    required this.blockSize,
    required this.instructions,
    required this.terrainRows,
  });

  final int z;
  final int cx;
  final int cy;
  final int blockSize;
  final List<ChunkInstruction> instructions;
  final List<String> terrainRows;

  /// 块内没有任何地形和指令时为真；未知指令也算非空。
  bool get isEmpty =>
      instructions.isEmpty && terrainRows.every(_isPaddingOnlyRow);

  /// 相对世界根目录的块路径。
  String get relativePath => chunkRelativePath(z, cx, cy);

  /// 解析块文件。
  ///
  /// [terrainCodes] 不为空时，会同时校验每个地形字符是否已定义。
  static ChunkFile parse({
    required String content,
    required int z,
    required int cx,
    required int cy,
    required int blockSize,
    Set<String>? terrainCodes,
  }) {
    if (blockSize <= 0) {
      throw ArgumentError.value(blockSize, 'blockSize', '必须大于 0');
    }
    var text = content;
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    text = text.replaceAll('\r\n', '\n');
    final lines = text.split('\n');
    if (text.endsWith('\n')) {
      lines.removeLast();
    }

    var markerIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] == '; terrain') {
        if (markerIndex >= 0) {
          throw FormatException('; terrain 只能出现一次（第 ${i + 1} 行）');
        }
        markerIndex = i;
      }
    }
    if (markerIndex < 0) {
      throw const FormatException('缺少 ; terrain 行');
    }

    final instructions = <ChunkInstruction>[];
    for (var i = 0; i < markerIndex; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      if (!line.startsWith(';')) {
        throw FormatException('指令区出现非指令行（第 ${i + 1} 行）');
      }
      instructions.add(_parseInstruction(line, z, cx, cy, blockSize));
    }

    final terrainRows = <String>[];
    final terrainStart = markerIndex + 1;
    final terrainLineCount = lines.length - terrainStart;
    if (terrainLineCount > blockSize) {
      throw FormatException('地形行数 $terrainLineCount 超过 $blockSize');
    }
    for (var i = 0; i < terrainLineCount; i++) {
      final line = lines[terrainStart + i];
      if (line.startsWith(';')) {
        throw FormatException('地形区不能出现 ; 开头的行（第 ${terrainStart + i + 1} 行）');
      }
      final runes = line.runes.toList(growable: false);
      if (runes.length > blockSize) {
        throw FormatException(
          '地形行超过 $blockSize 个字符（第 ${terrainStart + i + 1} 行）',
        );
      }
      if (terrainCodes != null) {
        for (var c = 0; c < runes.length; c++) {
          final code = String.fromCharCodes(<int>[runes[c]]);
          if (code == emptyTerrainPadding) continue;
          if (!terrainCodes.contains(code)) {
            throw FormatException(
              '未知地形字符 ${_displayCode(code)}（第 ${terrainStart + i + 1} 行第 ${c + 1} 列）',
            );
          }
        }
      }
      terrainRows.add(line);
    }

    return ChunkFile(
      z: z,
      cx: cx,
      cy: cy,
      blockSize: blockSize,
      instructions: instructions,
      terrainRows: terrainRows,
    );
  }

  /// 写回块文件内容，使用 LF。
  String encode() {
    final out = StringBuffer();
    for (final instruction in instructions) {
      out
        ..write(instruction.toLine())
        ..write('\n');
    }
    out.write('; terrain\n');
    for (final rawRow in terrainRows) {
      final row = _trimTrailingPadding(rawRow);
      out
        ..write(row)
        ..write('\n');
    }
    return out.toString();
  }
}

String chunkRelativePath(int z, int cx, int cy) {
  return 'chunks/$z/${cx}_$cy.chunk';
}

ChunkInstruction _parseInstruction(
  String line,
  int pathZ,
  int cx,
  int cy,
  int blockSize,
) {
  var body = line.substring(1);
  body = body.replaceFirst(RegExp(r'^[ \t]+'), '');
  final eq = body.indexOf('=');
  if (eq < 0) {
    return UnknownInstruction(line);
  }
  final keyword = body.substring(0, eq);
  final value = body.substring(eq + 1);
  final parts = value.split(',').map((part) => part.trim()).toList();
  switch (keyword) {
    case 'prop':
      if (parts.length != 4) {
        throw const FormatException('prop 必须有 4 个字段');
      }
      final z = _int(parts[0], 'prop.z');
      final type = _id(parts[1], 'prop.type');
      final col = _int(parts[2], 'prop.col');
      final row = _int(parts[3], 'prop.row');
      _checkZ(z, pathZ);
      return PropInstruction(z: z, type: type, col: col, row: row);
    case 'spawn':
      if (parts.length != 4) {
        throw const FormatException('spawn 必须有 4 个字段');
      }
      final z = _int(parts[0], 'spawn.z');
      final type = _id(parts[1], 'spawn.type');
      final col = _int(parts[2], 'spawn.col');
      final row = _int(parts[3], 'spawn.row');
      _checkZ(z, pathZ);
      return SpawnInstruction(z: z, type: type, col: col, row: row);
    case 'solid':
      if (parts.length < 8 || parts.length.isOdd) {
        throw const FormatException('solid 至少 3 个顶点，且坐标字段数必须为偶数');
      }
      final z = _int(parts[0], 'solid.z');
      final group = _id(parts[1], 'solid.group');
      final coords = <(double, double)>[];
      for (var i = 2; i < parts.length; i += 2) {
        coords.add((
          _decimal(parts[i], 'solid.x'),
          _decimal(parts[i + 1], 'solid.y'),
        ));
      }
      _checkZ(z, pathZ);
      return SolidInstruction(z: z, group: group, points: coords);
    case 'portal':
      if (parts.length != 6) {
        throw const FormatException('portal 必须有 6 个字段');
      }
      final id = _id(parts[0], 'portal.id');
      final dir = parts[1];
      if (dir != 'right' && dir != 'down') {
        throw const FormatException('portal.dir 只能是 right 或 down');
      }
      final x = _int(parts[2], 'portal.x');
      final y = _int(parts[3], 'portal.y');
      final length = _int(parts[4], 'portal.length');
      final z = _int(parts[5], 'portal.z');
      if (length <= 0) {
        throw const FormatException('portal.length 必须是正整数');
      }
      _checkZ(z, pathZ);
      final left = cx * blockSize;
      final top = cy * blockSize;
      if (x < left ||
          x >= left + blockSize ||
          y < top ||
          y >= top + blockSize) {
        throw const FormatException('portal 起点不在所属块内');
      }
      return PortalInstruction(
        id: id,
        dir: dir,
        x: x,
        y: y,
        length: length,
        z: z,
      );
    default:
      return UnknownInstruction(line);
  }
}

int _int(String text, String label) {
  final value = int.tryParse(text);
  if (value == null) {
    throw FormatException('$label 必须是整数：$text');
  }
  return value;
}

double _decimal(String text, String label) {
  if (!_decimalPattern.hasMatch(text)) {
    throw FormatException('$label 不是合法的最多 4 位小数：$text');
  }
  final value = double.tryParse(text);
  if (value == null) {
    throw FormatException('$label 不是合法数字：$text');
  }
  return value;
}

String _id(String text, String label) {
  if (!_idPattern.hasMatch(text)) {
    throw FormatException('$label 缺失或字符非法：$text');
  }
  return text;
}

void _checkZ(int value, int pathZ) {
  if (value != pathZ) {
    throw FormatException('指令 z=$value 与块路径 z=$pathZ 不一致');
  }
}

bool _isPaddingOnlyRow(String row) {
  return row.runes.every((code) => code == 0);
}

String _trimTrailingPadding(String row) {
  var end = row.length;
  while (end > 0 && row.codeUnitAt(end - 1) == 0) {
    end--;
  }
  return row.substring(0, end);
}

String _displayCode(String code) {
  if (code == ' ') return '空格';
  if (code == '\t') return '制表符';
  return '“$code”';
}

/// 按白皮书要求把 solid 坐标写成最多 4 位小数，舍入远离零，去掉尾随 0。
String formatSolidNumber(double value) {
  if (value.isNaN || value.isInfinite) {
    throw ArgumentError.value(value, 'value', '不能是 NaN 或无穷');
  }
  var text = value.toStringAsFixed(4);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  if (text == '-0') return '0';
  return text;
}
