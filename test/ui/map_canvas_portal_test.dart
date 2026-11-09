import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/models/terrain.dart';
import 'package:gloomyabyss_map_editor/models/world.dart';
import 'package:gloomyabyss_map_editor/ui/map_canvas.dart';
import 'package:jo_draftui/jo_draftui.dart';

void main() {
  testWidgets('传送门模式一次点击只上报一次落点', (WidgetTester tester) async {
    final Segment segment = Segment(
      SegmentSpec(id: 'main', file: '', originCol: 0, originRow: 0, originZ: 0),
      <String>['....', '....', '....', '....'],
      instructions: <String>[],
    );
    final World world = World(
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
    final TerrainSet terrain = TerrainSet(
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
    );
    var calls = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 300)),
          child: JoTheme(
            settings: const JoSettings(),
            palette: JoPalette.dark,
            child: SizedBox(
              width: 400,
              height: 300,
              child: MapCanvas(
                world: world,
                terrain: terrain,
                selectedSegment: 0,
                selectedCode: '.',
                paintEnabled: false,
                onPaint: (_, _) {},
                onStrokeStart: () {},
                onStrokeEnd: () {},
                linePortalMode: true,
                onLinePortalCell: (_, _) => calls++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(200, 150));
    await tester.pump();

    expect(calls, 1);
  });
}
