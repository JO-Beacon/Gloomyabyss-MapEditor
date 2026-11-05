/// 世界级传送格与连线，来自 world.json 的 pads / padLinks。
class Pad {
  const Pad({
    required this.id,
    required this.segment,
    required this.col,
    required this.row,
  });

  final String id;
  final String segment;
  final int col;
  final int row;

  String get label => '$id  $segment  $col,$row';
}

class PadLink {
  const PadLink({
    required this.from,
    required this.to,
    required this.bidirectional,
  });

  final String from;
  final String to;
  final bool bidirectional;

  String get label => bidirectional ? '$from ↔ $to（双向）' : '$from → $to';
}

List<Pad> parsePads(dynamic raw) {
  final out = <Pad>[];
  if (raw is! List) return out;
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id']?.toString();
    final segment = entry['segment']?.toString();
    final col = (entry['col'] as num?)?.toInt();
    final row = (entry['row'] as num?)?.toInt();
    if (id == null || segment == null || col == null || row == null) continue;
    out.add(Pad(id: id, segment: segment, col: col, row: row));
  }
  return out;
}

List<PadLink> parsePadLinks(dynamic raw) {
  final out = <PadLink>[];
  if (raw is! List) return out;
  for (final entry in raw) {
    if (entry is! Map) continue;
    final from = entry['from']?.toString();
    final to = entry['to']?.toString();
    if (from == null || to == null) continue;
    out.add(PadLink(
      from: from,
      to: to,
      bidirectional: entry['bidirectional'] == true,
    ));
  }
  return out;
}
