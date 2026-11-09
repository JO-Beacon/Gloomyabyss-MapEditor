import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/models/terrain.dart';
import 'package:gloomyabyss_map_editor/models/world.dart';
import 'package:gloomyabyss_map_editor/state/editor_state.dart';

void main() {
  test('编辑器中同一格不能重复放传送格', () {
    final segment = Segment(
      SegmentSpec(id: '层 0', file: '', originCol: 0, originRow: 0, originZ: 0),
      <String>['....', '....'],
      instructions: <String>[],
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
    final state = EditorState()
      ..world = world
      ..terrain = TerrainSet(
        tileSize: 20,
        types: const <TerrainType>[
          TerrainType(
            code: '.',
            name: 'floor',
            color: 0xFF74A642,
            block: false,
            speed: 1,
            damage: 0,
          ),
        ],
      )
      ..selectedSegment = 0
      ..selectedLevel = 0;

    state.placePadAtCell(1, 1);
    expect(state.pads.length, 1);

    state.placePadAtCell(1, 1);
    expect(state.pads.length, 1);
    expect(state.errors.any((e) => e.contains('已经有传送格')), isTrue);
  });
}
