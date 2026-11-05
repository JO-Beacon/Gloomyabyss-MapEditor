/// 段内线传送门：`; portal=id,dir,x,y,length`。
///
/// 起点是段内坐标，方向只有 right（向右）和 down（向下）。
class LinePortal {
  const LinePortal({
    required this.id,
    required this.dir,
    required this.x,
    required this.y,
    required this.length,
    required this.instructionIndex,
  });

  final String id;
  final String dir; // right / down
  final int x;
  final int y;
  final int length;
  final int instructionIndex;

  bool get horizontal => dir == 'right';
  int get endX => horizontal ? x + length : x;
  int get endY => horizontal ? y : y + length;

  String get label => '$id  ${horizontal ? '水平' : '竖直'}  $x,$y  长 $length';
}

final RegExp _linePortalPattern = RegExp(
  r'^\s*;\s*portal\s*=\s*([^,]+?)\s*,\s*(right|down)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*$',
  caseSensitive: false,
);

List<LinePortal> parseLinePortals(List<String> instructions) {
  final out = <LinePortal>[];
  for (int i = 0; i < instructions.length; i++) {
    final Match? m = _linePortalPattern.firstMatch(instructions[i]);
    if (m == null) continue;
    out.add(LinePortal(
      id: m.group(1)!.trim(),
      dir: m.group(2)!.toLowerCase(),
      x: int.parse(m.group(3)!),
      y: int.parse(m.group(4)!),
      length: int.parse(m.group(5)!),
      instructionIndex: i,
    ));
  }
  return out;
}

String linePortalInstruction(
  String id,
  String dir,
  int x,
  int y,
  int length,
) =>
    '; portal=$id,$dir,$x,$y,$length';

/// 越界检查；返回错误文本，合法返回 null。
String? linePortalError(
  String dir,
  int x,
  int y,
  int length,
  int width,
  int height,
) {
  if (dir != 'right' && dir != 'down') return '方向只能是 right 或 down';
  if (x < 0 || x > width) return '起点 x 超出段范围（0–$width）';
  if (y < 0 || y > height) return '起点 y 超出段范围（0–$height）';
  if (length <= 0) return '长度必须大于 0';
  if (dir == 'right' && x + length > width) {
    return '起点加长度超出段宽（0–$width）';
  }
  if (dir == 'down' && y + length > height) {
    return '起点加长度超出段高（0–$height）';
  }
  return null;
}

/// 两条段内传送门的连接：`segmentId/portalId`。
class PortalLink {
  const PortalLink({
    required this.from,
    required this.to,
    required this.face,
    required this.index,
  });

  final String from;
  final String to;
  final String face;
  final int index;

  String get faceLabel => face == 'both' ? '双面' : '$face 面';

  String get label => '$from ($faceLabel) → $to';
}

List<PortalLink> parsePortalLinks(dynamic raw) {
  final out = <PortalLink>[];
  if (raw is! List) return out;
  for (int i = 0; i < raw.length; i++) {
    final entry = raw[i];
    if (entry is! Map) continue;
    final from = entry['from']?.toString();
    final to = entry['to']?.toString();
    if (from == null || to == null) continue;
    out.add(PortalLink(
      from: from,
      to: to,
      face: entry['face']?.toString() ?? 'A',
      index: i,
    ));
  }
  return out;
}
