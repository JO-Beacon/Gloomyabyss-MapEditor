import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/world/chunk_file.dart';

void main() {
  ChunkFile parse(String content, {int z = 0, int cx = 0, int cy = 0}) {
    return ChunkFile.parse(
      content: content,
      z: z,
      cx: cx,
      cy: cy,
      blockSize: 128,
      terrainCodes: <String>{'.', '#', '~', '!'},
    );
  }

  test('解析指令和地形', () {
    final chunk = parse(
      '; prop=0,box,19,3\n'
      '; spawn=0,Obj_Froggit,22,3\n'
      '; solid=0,s1,20,7,19,4,20,4\n'
      '; portal=lp1,right,11,5,3,0\n'
      '; terrain\n'
      '..#\n'
      '\n'
      '..\n',
    );
    expect(chunk.instructions, hasLength(4));
    expect(chunk.instructions[0], isA<PropInstruction>());
    final prop = chunk.instructions[0] as PropInstruction;
    expect(prop.type, 'box');
    expect(prop.col, 19);
    final solid = chunk.instructions[2] as SolidInstruction;
    expect(solid.group, 's1');
    expect(solid.points, hasLength(3));
    expect(solid.points[0], (20.0, 7.0));
    final portal = chunk.instructions[3] as PortalInstruction;
    expect(portal.id, 'lp1');
    expect(portal.length, 3);
    expect(chunk.terrainRows, <String>['..#', '', '..']);
  });

  test('未知指令原样保留', () {
    final chunk = parse('; pad=p1,3,4\n; name=old\n; terrain\n');
    expect(chunk.instructions, hasLength(2));
    expect(chunk.instructions[0], isA<UnknownInstruction>());
    expect((chunk.instructions[0] as UnknownInstruction).line, '; pad=p1,3,4');
    expect(chunk.encode(), '; pad=p1,3,4\n; name=old\n; terrain\n');
  });

  test('空地形行按一行计算', () {
    final chunk = parse('; terrain\n\n');
    expect(chunk.terrainRows, hasLength(1));
    expect(chunk.terrainRows.single, '');
    expect(chunk.encode(), '; terrain\n\n');
    expect(chunk.isEmpty, isTrue);
  });

  test('没有地形数据时只写 ; terrain', () {
    final chunk = parse('; terrain\n');
    expect(chunk.terrainRows, isEmpty);
    expect(chunk.encode(), '; terrain\n');
    expect(chunk.isEmpty, isTrue);
  });

  test('BOM 和 CRLF 兼容', () {
    final chunk = parse('\uFEFF; prop=0,box,1,2\r\n; terrain\r\n..\r\n');
    expect(chunk.instructions, hasLength(1));
    expect(chunk.terrainRows, <String>['..']);
    expect(chunk.encode(), '; prop=0,box,1,2\n; terrain\n..\n');
  });

  test('U+0000 作为行首空列占位符', () {
    final chunk = parse('; terrain\n\u0000\u0000..\n');
    expect(chunk.terrainRows.single, '\u0000\u0000..');
    expect(chunk.encode(), '; terrain\n\u0000\u0000..\n');
  });

  test('全 U+0000 行按空块处理且写盘去掉尾部占位符', () {
    final chunk = parse('; terrain\n\u0000\u0000\n');
    expect(chunk.isEmpty, isTrue);
    expect(chunk.encode(), '; terrain\n\n');
  });

  test('缺少 ; terrain 报错', () {
    expect(() => parse('; prop=0,box,1,2\n'), throwsFormatException);
  });

  test('重复 ; terrain 报错', () {
    expect(() => parse('; terrain\n; terrain\n'), throwsFormatException);
  });

  test('; terrain 尾随空白不是标记', () {
    expect(() => parse('; terrain \n'), throwsFormatException);
  });

  test('地形区出现指令行报错', () {
    expect(() => parse('; terrain\n; prop=0,box,1,2\n'), throwsFormatException);
  });

  test('未知地形字符报错', () {
    expect(() => parse('; terrain\n? \n'), throwsFormatException);
  });

  test('指令 z 必须和路径一致', () {
    expect(
      () => parse('; prop=1,box,1,2\n; terrain\n', z: 0),
      throwsFormatException,
    );
  });

  test('传送门起点必须在所属块内', () {
    expect(
      () => parse('; portal=p1,right,128,1,3,0\n; terrain\n', cx: 0),
      throwsFormatException,
    );
    final chunk = parse('; portal=p1,right,128,1,3,0\n; terrain\n', cx: 1);
    expect((chunk.instructions.single as PortalInstruction).x, 128);
  });

  test('solid 坐标最多 4 位小数并按远离零舍入', () {
    expect(formatSolidNumber(1.23455), '1.2346');
    expect(formatSolidNumber(-1.23455), '-1.2346');
    expect(formatSolidNumber(1.23454), '1.2345');
    expect(formatSolidNumber(20), '20');
    expect(formatSolidNumber(19.4), '19.4');

    final chunk = parse('; solid=0,s1,1.2345,-1.2345,2,25,3,4\n; terrain\n');
    final solid = chunk.instructions.single as SolidInstruction;
    expect(solid.points, <(double, double)>[
      (1.2345, -1.2345),
      (2.0, 25.0),
      (3.0, 4.0),
    ]);
    expect(chunk.encode(), '; solid=0,s1,1.2345,-1.2345,2,25,3,4\n; terrain\n');
  });

  test('路径使用规范十进制', () {
    expect(chunkRelativePath(-1, -2, 0), 'chunks/-1/-2_0.chunk');
    expect(chunkRelativePath(0, 0, 0), 'chunks/0/0_0.chunk');
  });
}
