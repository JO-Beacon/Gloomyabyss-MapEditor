import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/models/world.dart';
import 'package:gloomyabyss_map_editor/state/editor_state.dart';
import 'package:gloomyabyss_map_editor/world/geometry.dart';

void main() {
  EditorState makeState() {
    final segment = Segment(
      SegmentSpec(id: '层 0', file: '', originCol: 0, originRow: 0, originZ: 0),
      <String>['.#..', '....', '....', '....'],
      instructions: <String>['; prop=box,1,1'],
    );
    final world = World(
      dirPath: '',
      name: 'test',
      segments: <Segment>[segment],
      portalPlanes: const <PortalPlane>[],
      raw: <String, dynamic>{
        'version': 1,
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 0, 'row': 0},
      },
    );
    return EditorState()
      ..world = world
      ..selectedSegment = 0
      ..selectedLevel = 0;
  }

  test('地形复制、粘贴、删除不碰道具', () {
    final state = makeState();
    final segment = state.segment!;
    state.copyRegion(const CellRect(0, 0, 2, 2));
    expect(state.clipboard!.kind, EditKind.terrain);
    expect(state.clipboard!.width, 2);
    expect(state.clipboard!.rows[0], '.#');
    expect(state.clipboard!.entities, isEmpty);

    state.pasteClipboard(const CellRect(2, 0, 2, 2));
    expect(segment.rows[0], '.#.#');
    expect(segment.instructions, contains('; prop=box,1,1'));
    expect(segment.instructions.where((line) => line.contains('box,3,1')), isEmpty);

    state.deleteRegion(const CellRect(2, 0, 2, 2));
    expect(segment.rows[0][2], ' ');
    expect(segment.instructions, contains('; prop=box,1,1'));
  });

  test('道具复制、粘贴、删除不碰地形', () {
    final state = makeState();
    final segment = state.segment!;
    state.copyRegion(const CellRect(0, 0, 2, 2), kind: EditKind.prop);
    expect(state.clipboard!.kind, EditKind.prop);
    expect(state.clipboard!.rows, isEmpty);
    expect(state.clipboard!.entities.length, 1);

    state.pasteClipboard(const CellRect(2, 0, 2, 2), kind: EditKind.prop);
    expect(segment.rows, <String>['.#..', '....', '....', '....']);
    expect(segment.instructions, contains('; prop=box,3,1'));

    state.deleteRegion(const CellRect(2, 0, 2, 2), kind: EditKind.prop);
    expect(segment.instructions, contains('; prop=box,1,1'));
    expect(segment.instructions.where((line) => line.contains('box,3,1')), isEmpty);
  });

  test('移动选区只产生一步撤销并恢复选区', () {
    final state = makeState();
    final segment = state.segment!;
    state.moveRegion(const CellRect(0, 0, 2, 2), 2, 0, kind: EditKind.terrain);
    expect(segment.rows[0][0], ' ');
    expect(segment.rows[0][2], '.');
    expect(state.selection, const CellRect(2, 0, 2, 2));
    expect(state.undoDepth, 1);
    state.undo();
    expect(segment.rows, <String>['.#..', '....', '....', '....']);
    expect(state.selection, const CellRect(0, 0, 2, 2));
    expect(segment.instructions, contains('; prop=box,1,1'));
  });
}
