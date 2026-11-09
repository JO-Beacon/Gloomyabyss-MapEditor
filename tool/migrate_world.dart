import 'dart:io';

import 'package:gloomyabyss_map_editor/world/definitions.dart';
import 'package:gloomyabyss_map_editor/world/old_migration.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('用法: dart run tool/migrate_world.dart <旧世界目录> <新世界目录>');
    exit(2);
  }
  final definitions = DefinitionPackage.loadDirectory(
    'assets/default/versions/1',
  );
  final result = OldMigration.migrateDirectory(
    OldMigrationOptions(
      sourcePath: args[0],
      outputPath: args[1],
      oldDefinitions: definitions,
      targetDefinitions: definitions,
      name: args[0].split(Platform.pathSeparator).last,
      keepUnknown: true,
    ),
  );
  stdout.writeln('迁移完成：${result.report.sourcePath} -> ${result.report.outputPath}');
  stdout.writeln('段: ${result.report.segmentCount}  块: ${result.report.chunkCount}');
  stdout.writeln('传送门: ${result.report.portalMapping.length}  传送格: ${result.report.padMapping.length}');
}
