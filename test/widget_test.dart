import 'package:flutter_test/flutter_test.dart';

import 'package:gloomyabyss_map_editor/main.dart';

void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const MapEditorApp());
    expect(find.text('先打开一个世界根目录'), findsOneWidget);
  });
}
