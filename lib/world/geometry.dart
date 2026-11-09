/// 世界坐标、块坐标和格子矩形的基础几何。
///
/// 坐标单位是格；块坐标用 [blockIndexOf] 计算，负数按向下取整。
library;

import 'dart:math' as math;

/// 向下取整的整数除法。
int floorDiv(int value, int divisor) {
  if (divisor <= 0) {
    throw ArgumentError.value(divisor, 'divisor', '必须大于 0');
  }
  final remainder = value % divisor;
  return (value - remainder) ~/ divisor;
}

/// 非负余数，结果在 [0, divisor)。
int positiveMod(int value, int divisor) {
  if (divisor <= 0) {
    throw ArgumentError.value(divisor, 'divisor', '必须大于 0');
  }
  return value % divisor;
}

/// 一个带层的块坐标。
class ChunkCoord {
  const ChunkCoord(this.z, this.cx, this.cy);

  final int z;
  final int cx;
  final int cy;

  @override
  bool operator ==(Object other) =>
      other is ChunkCoord && other.z == z && other.cx == cx && other.cy == cy;

  @override
  int get hashCode => Object.hash(z, cx, cy);

  @override
  String toString() => 'ChunkCoord($z, $cx, $cy)';
}

/// 某个世界坐标所在的块坐标。
class BlockCoord {
  const BlockCoord(this.cx, this.cy);

  final int cx;
  final int cy;

  @override
  bool operator ==(Object other) =>
      other is BlockCoord && other.cx == cx && other.cy == cy;

  @override
  int get hashCode => Object.hash(cx, cy);

  @override
  String toString() => 'BlockCoord($cx, $cy)';
}

/// 计算世界坐标 (col, row) 所在的块。
BlockCoord blockIndexOf(int col, int row, int blockSize) {
  return BlockCoord(floorDiv(col, blockSize), floorDiv(row, blockSize));
}

/// 块覆盖的世界坐标范围：左闭右开。
class CellSpan {
  const CellSpan(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  bool contains(int value) => value >= start && value < end;

  @override
  bool operator ==(Object other) =>
      other is CellSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CellSpan[$start, $end)';
}

/// 块在某一轴上的覆盖范围。
CellSpan blockSpan(int blockIndex, int blockSize) {
  final start = blockIndex * blockSize;
  return CellSpan(start, start + blockSize);
}

/// 整数格子矩形，左闭右开。
class CellRect {
  const CellRect(this.x, this.y, this.w, this.h);

  final int x;
  final int y;
  final int w;
  final int h;

  int get right => x + w;
  int get bottom => y + h;

  bool get isEmpty => w <= 0 || h <= 0;

  bool intersects(CellRect other) {
    return x < other.x + other.w &&
        other.x < x + w &&
        y < other.y + other.h &&
        other.y < y + h;
  }

  bool containsCell(int col, int row) {
    return col >= x && col < right && row >= y && row < bottom;
  }

  CellRect translated(int dc, int dr) => CellRect(x + dc, y + dr, w, h);

  @override
  bool operator ==(Object other) =>
      other is CellRect &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'CellRect($x, $y, $w, $h)';
}

/// 浮点矩形，碰撞顶点和碰撞包围盒使用；左闭右开。
class FloatRect {
  const FloatRect(this.x, this.y, this.w, this.h);

  final double x;
  final double y;
  final double w;
  final double h;

  double get right => x + w;
  double get bottom => y + h;

  bool get isEmpty => w <= 0 || h <= 0;

  bool containsPoint(double px, double py) {
    return px >= x && px < right && py >= y && py < bottom;
  }

  bool intersects(FloatRect other) {
    return x < other.x + other.w &&
        other.x < x + w &&
        y < other.y + other.h &&
        other.y < y + h;
  }

  @override
  bool operator ==(Object other) =>
      other is FloatRect &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'FloatRect($x, $y, $w, $h)';
}

/// 计算一组点的最小外接矩形。
FloatRect boundsOfPoints(Iterable<(double, double)> points) {
  final iterator = points.iterator;
  if (!iterator.moveNext()) {
    throw ArgumentError('至少需要一个点');
  }
  var minX = iterator.current.$1;
  var maxX = minX;
  var minY = iterator.current.$2;
  var maxY = minY;
  while (iterator.moveNext()) {
    final (x, y) = iterator.current;
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return FloatRect(minX, minY, maxX - minX, maxY - minY);
}
