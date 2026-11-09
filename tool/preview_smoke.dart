import 'dart:io';

import 'package:gloomyabyss_map_editor/preview/preview_world.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';

void main(List<String> args) {
  final definitions = DefinitionPackage.loadDirectory(
    'assets/default/versions/1',
  );
  for (final path in args) {
    final world = PreviewWorld.loadOrMigrate(
      path: path,
      definitions: definitions,
    );
    final bounds = world.boundsFor(world.meta.start.z);
    stdout.writeln('=== ${world.meta.name} ===');
    stdout.writeln('source: ${world.sourcePath}');
    stdout.writeln('preview: ${world.worldPath}');
    stdout.writeln('layers: ${world.layers.join(', ')}');
    stdout.writeln('bounds: ${bounds.width}x${bounds.height}');
    stdout.writeln('chunks: ${world.chunksByLayer.values.fold<int>(0, (n, m) => n + m.length)}');
    stdout.writeln('props: ${world.index.propsObjects.where((e) => e.kind == 'prop').length}');
    stdout.writeln('objects: ${world.index.propsObjects.where((e) => e.kind == 'object').length}');
    stdout.writeln('portals: ${world.index.portals.length}');
    stdout.writeln('pads: ${world.meta.pads.length}');
    stdout.writeln('solids: ${world.index.solidGroups.length}');
    final rows = <String>[];
    for (var row = bounds.minRow; row <= bounds.maxRow; row++) {
      final line = StringBuffer();
      for (var col = bounds.minCol; col <= bounds.maxCol; col++) {
        line.write(world.terrainCodeAt(world.meta.start.z, col, row) ?? ' ');
      }
      rows.add(line.toString());
    }
    stdout.writeln(rows.join('\n'));
    world.dispose();
  }
}
