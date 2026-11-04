import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/models/obj.dart';
import 'package:gloomyabyss_map_editor/models/prop.dart';
import 'package:gloomyabyss_map_editor/models/solid.dart';
import 'package:gloomyabyss_map_editor/models/world.dart';
import 'package:gloomyabyss_map_editor/state/editor_state.dart';

World makeWorld() {
  final spec = SegmentSpec(id: 's', file: 's.seg');
  final segment = Segment(spec, ['....', '....']);
  return World(
    dirPath: '',
    name: 'w',
    segments: [segment],
    portalPlanes: [],
    raw: <String, dynamic>{},
  );
}

void main() {
  test('一次笔画整体撤销，重做恢复', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedCode = '#';

    state.beginStroke();
    state.paint(0, 0);
    state.paint(1, 0);
    state.paint(0, 0); // 同一格不重复记录
    state.endStroke();

    final segment = world.segments.first;
    expect(segment.charAt(0, 0), '#');
    expect(segment.charAt(1, 0), '#');
    expect(state.canUndo, isTrue);

    state.undo();
    expect(segment.charAt(0, 0), '.');
    expect(segment.charAt(1, 0), '.');
    expect(state.canRedo, isTrue);

    state.redo();
    expect(segment.charAt(0, 0), '#');
    expect(segment.charAt(1, 0), '#');
  });

  test('没有 beginStroke 的单次涂抹也能撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedCode = '#';

    state.paint(2, 1);
    expect(world.segments.first.charAt(2, 1), '#');
    state.undo();
    expect(world.segments.first.charAt(2, 1), '.');
  });

  test('新笔画清空重做栈', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedCode = '#';

    state.paint(0, 0);
    state.undo();
    expect(state.canRedo, isTrue);

    state.paint(1, 1);
    expect(state.canRedo, isFalse);
  });

  test('越界坐标不记录', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedCode = '#';

    state.beginStroke();
    state.paint(-1, 0);
    state.paint(0, 9);
    state.endStroke();

    expect(state.canUndo, isFalse);
  });

  test('传送门字段可撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;

    final plane = PortalPlane(
      axis: 'x',
      at: 2,
      from: 0,
      to: 2,
      direction: '+',
      dx: 0,
      dy: 0,
    );
    world.portalPlanes.add(plane);

    state.updatePlane(plane, at: 1);
    expect(plane.at, 1);
    state.undo();
    expect(plane.at, 2);
    state.redo();
    expect(plane.at, 1);
  });

  test('新建与删除传送门可撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;

    state.addPlane();
    expect(world.portalPlanes.length, 1);
    state.undo();
    expect(world.portalPlanes.isEmpty, isTrue);
    state.redo();
    expect(world.portalPlanes.length, 1);

    state.removePlane();
    expect(world.portalPlanes.isEmpty, isTrue);
    state.undo();
    expect(world.portalPlanes.length, 1);
  });

  test('段属性可撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    final spec = world.segments.first.spec;

    state.updateSegmentSpec(spec, originCol: 5, repeat: 'x');
    expect(spec.originCol, 5);
    expect(spec.repeat, 'x');
    state.undo();
    expect(spec.originCol, 0);
    expect(spec.repeat, '');
  });

  test('连续改名合并为一步撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    final spec = world.segments.first.spec;

    state.renameSegment(0, 'a');
    state.renameSegment(0, 'ab');
    state.renameSegment(0, 'abc');
    expect(spec.id, 'abc');

    state.undo();
    expect(spec.id, 's');
    state.redo();
    expect(spec.id, 'abc');
  });

  test('文件随 id 重命名', () {
    final dir = Directory.systemTemp.createTempSync('gloomy_editor_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final worldDir = Directory('${dir.path}/w')..createSync();
    File('${worldDir.path}/s.seg').writeAsStringSync('....\n....\n');

    final spec = SegmentSpec(id: 's', file: 's.seg');
    final world = World(
      dirPath: worldDir.path,
      name: 'w',
      segments: [
        Segment(spec, ['....', '....']),
      ],
      portalPlanes: [],
      raw: <String, dynamic>{},
    );

    final state = EditorState();
    state.rootPath = dir.path;
    state.world = world;
    state.selectedSegment = 0;

    state.renameSegment(0, 'new');
    state.renameSegmentFile();

    expect(spec.file, 'new.seg');
    expect(File('${worldDir.path}/new.seg').existsSync(), isTrue);
    expect(File('${worldDir.path}/s.seg').existsSync(), isFalse);
  });

  test('.gmap 解出的文件能直接组成世界', () {
    final files = <String, String>{
      'world.json': '{"version":1,"segments":[{"id":"main","file":"main.seg","origin":[0,0]}],'
          '"portal_planes":[{"axis":"x","at":4,"from":0,"to":2,"direction":"+","target":[0,0]}],'
          '"start":{"col":1,"row":1}}',
      'main.seg': '....\n####\n',
    };

    final world = WorldIo.fromFiles(files, name: 'demo');
    expect(world.name, 'demo');
    expect(world.segments.length, 1);
    expect(world.segments.first.width, 4);
    expect(world.segments.first.charAt(0, 1), '#');
    expect(world.portalPlanes.length, 1);
  });

  test('读写保留 ; 指令行', () {
    const text = '''; prop=box,1,1
; player=3,4
....
####
''';
    final spec = SegmentSpec(id: 's', file: 's.seg');
    final segment = Segment.fromText(spec, text);

    expect(segment.instructions, ['; prop=box,1,1', '; player=3,4']);
    expect(segment.rows, ['....', '####']);

    final world = World(
      dirPath: '',
      name: 'w',
      segments: [segment],
      portalPlanes: [],
      raw: <String, dynamic>{},
    );
    expect(WorldIo.snapshot(world)['s.seg'], text);
  });

  test('放置与删除道具，可撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;
    state.propTypes = const [
      PropType(
        id: 'box',
        name: 'BOX',
        sprite: 'Spr_Box_Normal',
        block: true,
        width: 1,
        height: 1,
        interaction: 'box',
      ),
    ];
    state.selectedPropId = 'box';

    final segment = world.segments.first;

    state.togglePropAt(1, 1);
    expect(segment.instructions, ['; prop=box,1,1']);

    state.undo();
    expect(segment.instructions, isEmpty);

    state.redo();
    expect(segment.instructions, ['; prop=box,1,1']);

    // 同一格再点一次 = 删除
    state.togglePropAt(1, 1);
    expect(segment.instructions, isEmpty);

    state.undo();
    expect(segment.instructions, ['; prop=box,1,1']);
  });

  test('新建段与复制段', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;

    state.addSegment('forest', width: 8, height: 6, originCol: 4, originRow: 2);
    expect(world.segments.length, 2);
    final forest = world.segments.last;
    expect(forest.spec.id, 'forest');
    expect(forest.spec.file, 'forest.seg');
    expect(forest.width, 8);
    expect(forest.height, 6);
    expect(forest.spec.originCol, 4);
    expect(forest.spec.originRow, 2);

    state.duplicateSegment();
    expect(world.segments.length, 3);
    final copy = world.segments.last;
    expect(copy.spec.id, 'forest_copy');
    expect(copy.spec.originCol, 12);
    expect(copy.rows.length, 6);
  });

  test('只剩一段时不能删除', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;

    state.removeSegment();
    expect(world.segments.length, 1);
    expect(state.errors, isNotEmpty);
  });

  test('放置与删除对象，可撤销', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;
    state.objectTypes = const [ObjectType(id: 'Obj_Froggit', name: 'Froggit')];
    state.selectedObjectId = 'Obj_Froggit';

    final segment = world.segments.first;

    state.toggleObjectAt(1, 1);
    expect(segment.instructions, ['; spawn=Obj_Froggit,1,1']);

    state.undo();
    expect(segment.instructions, isEmpty);

    state.redo();
    expect(segment.instructions, ['; spawn=Obj_Froggit,1,1']);

    state.toggleObjectAt(1, 1);
    expect(segment.instructions, isEmpty);

    state.undo();
    expect(segment.instructions, ['; spawn=Obj_Froggit,1,1']);
  });

  test('凹多边形闭合时自动拆成三角形', () {
    final state = EditorState();
    final world = makeWorld();
    state.world = world;
    state.selectedSegment = 0;

    // L 形，6 个顶点，凹
    const pts = <(int, int)>[
      (0, 0),
      (4, 0),
      (4, 2),
      (2, 2),
      (2, 4),
      (0, 4),
    ];

    state.toggleSolidPick();
    for (final p in pts) {
      state.pickSolidCell(p.$1, p.$2);
    }
    state.finishSolid();

    final solids = parseSolids(world.segments.first.instructions);
    expect(solids.length, 4);
    expect(solids.every((s) => s.points.length == 3), isTrue);
  });

  test('重叠的段会被校验出来', () {
    final a = Segment(
      SegmentSpec(id: 'a', file: 'a.seg', originCol: 0, originRow: 0),
      ['....', '....'],
    );
    final b = Segment(
      SegmentSpec(id: 'b', file: 'b.seg', originCol: 2, originRow: 1),
      ['....', '....'],
    );
    final world = World(
      dirPath: '',
      name: 'w',
      segments: [a, b],
      portalPlanes: [],
      raw: <String, dynamic>{},
    );

    final errors = WorldIo.validate(world, {'.'});
    expect(errors.any((e) => e.contains('重叠')), isTrue);
  });
}
