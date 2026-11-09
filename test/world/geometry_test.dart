import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';

void main() {
  group('坐标换算', () {
    test('负数向下取整', () {
      expect(floorDiv(-1, 128), -1);
      expect(floorDiv(-128, 128), -1);
      expect(floorDiv(-129, 128), -2);
      expect(floorDiv(127, 128), 0);
      expect(floorDiv(128, 128), 1);
    });

    test('块坐标和块范围', () {
      expect(blockIndexOf(-1, -1, 128), const BlockCoord(-1, -1));
      expect(blockIndexOf(0, 0, 128), const BlockCoord(0, 0));
      expect(blockIndexOf(128, 256, 128), const BlockCoord(1, 2));
      expect(blockSpan(-1, 128), const CellSpan(-128, 0));
      expect(blockSpan(0, 128), const CellSpan(0, 128));
    });
  });

  group('矩形相交', () {
    test('相邻不算相交', () {
      const a = CellRect(0, 0, 10, 10);
      const b = CellRect(10, 0, 10, 10);
      const c = CellRect(0, 10, 10, 10);
      expect(a.intersects(b), isFalse);
      expect(a.intersects(c), isFalse);
      expect(a.intersects(const CellRect(9, 9, 2, 2)), isTrue);
    });

    test('浮点包围盒', () {
      const rect = FloatRect(10, 20, 40, 50);
      expect(rect.right, 50);
      expect(rect.bottom, 70);
      expect(rect.intersects(const FloatRect(49, 69, 2, 2)), isTrue);
      expect(rect.intersects(const FloatRect(50, 70, 2, 2)), isFalse);
    });

    test('点集最小外接矩形', () {
      final bounds = boundsOfPoints(const <(double, double)>[
        (10, 20),
        (30, 20),
        (10, 70),
        (50, 40),
      ]);
      expect(bounds, const FloatRect(10, 20, 40, 50));
    });
  });
}
