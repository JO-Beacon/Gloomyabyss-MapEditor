/// 碰撞多边形，来自段里的 `; solid=x1,y1, x2,y2, ...`（单位是格）。
class SolidShape {
  const SolidShape({
    required this.points,
    required this.instructionIndex,
    this.group,
  });

  final List<(int, int)> points;
  final int instructionIndex;

  /// 新格式里的碰撞组 id；旧格式的单条 solid 为 null。
  final String? group;

  String get label => '${points.length} 个点';
}

final RegExp _solidLine = RegExp(
  r'^\s*;\s*solid\s*=\s*(.+)$',
  caseSensitive: false,
);

List<SolidShape> parseSolids(List<String> instructions) {
  final out = <SolidShape>[];
  for (int i = 0; i < instructions.length; i++) {
    final m = _solidLine.firstMatch(instructions[i]);
    if (m == null) continue;

    var body = m.group(1)!.trim();
    String? group;
    if (body.startsWith('@')) {
      final comma = body.indexOf(',');
      if (comma <= 1) continue;
      group = body.substring(1, comma).trim();
      body = body.substring(comma + 1);
    }
    final parts = body.split(',');
    final nums = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null) {
        nums.clear();
        break;
      }
      nums.add(v);
    }
    if (nums.length < 6 || nums.length.isOdd) continue;

    final pts = <(int, int)>[];
    for (int k = 0; k < nums.length; k += 2) {
      pts.add((nums[k], nums[k + 1]));
    }
    out.add(SolidShape(points: pts, instructionIndex: i, group: group));
  }
  return out;
}
