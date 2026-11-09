/// 碰撞多边形的几何工具。
library;

import 'dart:math' as math;

/// 有符号面积。
double polygonSignedArea(List<(double, double)> points) {
  if (points.length < 3) return 0;
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final (x1, y1) = points[i];
    final (x2, y2) = points[(i + 1) % points.length];
    sum += x1 * y2 - x2 * y1;
  }
  return sum / 2;
}

bool isDegeneratePolygon(List<(double, double)> points) {
  if (points.length < 3) return true;
  return polygonSignedArea(points).abs() < 0.001;
}

/// 只接受凸多边形；允许共线边。
bool isConvexPolygon(List<(double, double)> points) {
  if (points.length < 3) return false;
  var sign = 0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    final c = points[(i + 2) % points.length];
    final cross = (b.$1 - a.$1) * (c.$2 - b.$2) - (b.$2 - a.$2) * (c.$1 - b.$1);
    if (cross.abs() < 1e-9) continue;
    final current = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = current;
    } else if (sign != current) {
      return false;
    }
  }
  return true;
}

/// 用块矩形裁剪凸多边形，返回裁剪后的顶点。
List<(double, double)> clipPolygonToRect(
  List<(double, double)> points,
  double left,
  double top,
  double width,
  double height,
) {
  final right = left + width;
  final bottom = top + height;
  var poly = points;
  poly = _clipEdge(poly, (p) => p.$1 >= left, (a, b) {
    final t = (left - a.$1) / (b.$1 - a.$1);
    return (left, a.$2 + (b.$2 - a.$2) * t);
  });
  if (poly.isEmpty) return poly;
  poly = _clipEdge(poly, (p) => p.$1 <= right, (a, b) {
    final t = (right - a.$1) / (b.$1 - a.$1);
    return (right, a.$2 + (b.$2 - a.$2) * t);
  });
  if (poly.isEmpty) return poly;
  poly = _clipEdge(poly, (p) => p.$2 >= top, (a, b) {
    final t = (top - a.$2) / (b.$2 - a.$2);
    return (a.$1 + (b.$1 - a.$1) * t, top);
  });
  if (poly.isEmpty) return poly;
  poly = _clipEdge(poly, (p) => p.$2 <= bottom, (a, b) {
    final t = (bottom - a.$2) / (b.$2 - a.$2);
    return (a.$1 + (b.$1 - a.$1) * t, bottom);
  });
  return _dedupe(poly);
}

List<(double, double)> _clipEdge(
  List<(double, double)> points,
  bool Function((double, double)) inside,
  (double, double) Function((double, double), (double, double)) intersect,
) {
  if (points.isEmpty) return const <(double, double)>[];
  final out = <(double, double)>[];
  var previous = points.last;
  var previousInside = inside(previous);
  for (final current in points) {
    final currentInside = inside(current);
    if (currentInside) {
      if (!previousInside) out.add(intersect(previous, current));
      out.add(current);
    } else if (previousInside) {
      out.add(intersect(previous, current));
    }
    previous = current;
    previousInside = currentInside;
  }
  return out;
}

List<(double, double)> _dedupe(List<(double, double)> points) {
  final out = <(double, double)>[];
  for (final point in points) {
    if (out.isEmpty || out.last != point) out.add(point);
  }
  if (out.length > 1 && out.first == out.last) out.removeLast();
  return out;
}

/// 最小外接矩形。
({double x, double y, double w, double h}) polygonBounds(
  List<(double, double)> points,
) {
  var minX = points.first.$1;
  var maxX = minX;
  var minY = points.first.$2;
  var maxY = minY;
  for (final (x, y) in points.skip(1)) {
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return (x: minX, y: minY, w: maxX - minX, h: maxY - minY);
}

/// 去掉连续重复点和闭合重复点。
List<(double, double)> normalizePolygon(List<(double, double)> points) {
  final out = <(double, double)>[];
  for (final point in points) {
    if (out.isEmpty || out.last != point) out.add(point);
  }
  if (out.length > 1 && out.first == out.last) out.removeLast();
  return out;
}

/// 非相邻边相交、零长度边时返回 true。
bool hasSelfIntersection(List<(double, double)> points) {
  final p = normalizePolygon(points);
  if (p.length < 3) return true;
  for (var i = 0; i < p.length; i++) {
    final a = p[i];
    final b = p[(i + 1) % p.length];
    if (a == b) return true;
    for (var j = i + 1; j < p.length; j++) {
      if (j == i || j == (i + 1) % p.length) continue;
      if (i == 0 && j == p.length - 1) continue;
      final c = p[j];
      final d = p[(j + 1) % p.length];
      if (_segmentsIntersect(a, b, c, d)) return true;
    }
  }
  return false;
}

bool _segmentsIntersect(
  (double, double) a,
  (double, double) b,
  (double, double) c,
  (double, double) d,
) {
  final o1 = _cross(a, b, c);
  final o2 = _cross(a, b, d);
  final o3 = _cross(c, d, a);
  final o4 = _cross(c, d, b);
  if (o1 == 0 && _onSegment(a, b, c)) return true;
  if (o2 == 0 && _onSegment(a, b, d)) return true;
  if (o3 == 0 && _onSegment(c, d, a)) return true;
  if (o4 == 0 && _onSegment(c, d, b)) return true;
  return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0);
}

double _cross((double, double) a, (double, double) b, (double, double) c) {
  return (b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1);
}

bool _onSegment((double, double) a, (double, double) b, (double, double) p) {
  return p.$1 >= math.min(a.$1, b.$1) &&
      p.$1 <= math.max(a.$1, b.$1) &&
      p.$2 >= math.min(a.$2, b.$2) &&
      p.$2 <= math.max(a.$2, b.$2);
}

/// 耳切三角化；输入必须是简单多边形。
List<List<(double, double)>> earClipPolygon(List<(double, double)> points) {
  var p = normalizePolygon(points);
  if (p.length < 3) throw ArgumentError('多边形顶点不足');
  if (polygonSignedArea(p) < 0) p = p.reversed.toList(growable: false);
  final indices = List<int>.generate(p.length, (i) => i);
  final triangles = <List<(double, double)>>[];
  var guard = 0;
  while (indices.length > 3) {
    if (guard++ > p.length * p.length * 2) {
      throw ArgumentError('无法三角化多边形');
    }
    var earFound = false;
    for (var i = 0; i < indices.length; i++) {
      final prev = indices[(i - 1 + indices.length) % indices.length];
      final curr = indices[i];
      final next = indices[(i + 1) % indices.length];
      final a = p[prev];
      final b = p[curr];
      final c = p[next];
      if (_cross(a, b, c) <= 0) continue;
      var contains = false;
      for (final index in indices) {
        if (index == prev || index == curr || index == next) continue;
        if (_pointInTriangle(p[index], a, b, c)) {
          contains = true;
          break;
        }
      }
      if (contains) continue;
      triangles.add(<(double, double)>[a, b, c]);
      indices.removeAt(i);
      earFound = true;
      break;
    }
    if (!earFound) throw ArgumentError('无法三角化多边形');
  }
  triangles.add(<(double, double)>[
    p[indices[0]],
    p[indices[1]],
    p[indices[2]],
  ]);
  return triangles;
}

bool _pointInTriangle(
  (double, double) p,
  (double, double) a,
  (double, double) b,
  (double, double) c,
) {
  final d1 = _cross(a, b, p);
  final d2 = _cross(b, c, p);
  final d3 = _cross(c, a, p);
  final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNeg && hasPos);
}
