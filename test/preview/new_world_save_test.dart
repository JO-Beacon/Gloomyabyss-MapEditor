import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gloomyabyss_map_editor/preview/gmap_export.dart';
import 'package:gloomyabyss_map_editor/preview/legacy_world_adapter.dart';
import 'package:gloomyabyss_map_editor/preview/new_world_edit_session.dart';
import 'package:gloomyabyss_map_editor/preview/new_world_save.dart';
import 'package:gloomyabyss_map_editor/preview/preview_world.dart';
import 'package:gloomyabyss_map_editor/state/editor_state.dart';
import 'package:gloomyabyss_map_editor/world/definitions.dart';
import 'package:gloomyabyss_map_editor/world/gmap_container.dart';

void main() {
  late Directory source;

  setUp(() {
    source = Directory.systemTemp.createTempSync('gloomy_save_test_');
  });

  tearDown(() {
    if (source.existsSync()) source.deleteSync(recursive: true);
  });

  DefinitionPackage makeDefinitions() {
    final files = <String, List<int>>{
      'terrain.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'tile_size': 20,
          'types': <dynamic>[
            <String, dynamic>{'code': '.', 'name': 'floor'},
            <String, dynamic>{'code': '#', 'name': 'wall'},
            <String, dynamic>{'code': '~', 'name': 'water'},
          ],
        }),
      ),
      'props.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'types': <dynamic>[
            <String, dynamic>{
              'id': 'box',
              'name': 'BOX',
              'width': 1,
              'height': 1,
            },
          ],
        }),
      ),
      'objects.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'types': <dynamic>[
            <String, dynamic>{
              'id': 'Obj_Froggit',
              'name': 'Froggit',
              'width': 1,
              'height': 1,
            },
          ],
        }),
      ),
    };
    final hash = computeDefinitionsHash(files);
    return DefinitionPackage.fromFiles(<String, List<int>>{
      ...files,
      'manifest.json': utf8.encode(
        jsonEncode(<String, dynamic>{
          'id': 'default',
          'version': 1,
          'hash': hash,
          'upgrades': <dynamic>[],
        }),
      ),
    });
  }

  void writeOldWorld() {
    File('${source.path}/world.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
          },
        ],
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 1, 'row': 1},
      }),
    );
    File('${source.path}/main.seg').writeAsStringSync(
      '; prop=box,2,2\n'
      '; spawn=Obj_Froggit,3,1\n'
      '; portal=door1,right,1,3,2\n'
      '..#.\n'
      '.#..\n'
      '....\n'
      '....\n',
    );
  }

  void writeWideWorld() {
    File('${source.path}/world.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
          },
        ],
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 2, 'row': 2},
      }),
    );
    final row = '.' * 260;
    File('${source.path}/main.seg').writeAsStringSync(
      '$row\n$row\n$row\n$row\n',
    );
  }

  test('V2 地形编辑保存后重新打开还在，实体和传送门保留', () {
    writeOldWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final segment = data.world.segments.first;
    segment.setChar(0, 0, '~');
    segment.setChar(1, 1, '#');

    final session = NewWorldSaveSession(preview: preview, world: data.world);
    final result = session.save();
    expect(result.revision, 2);

    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.terrainCodeAt(0, 0, 0), '~');
    expect(reopened.terrainCodeAt(0, 1, 1), '#');
    expect(reopened.terrainCodeAt(0, 2, 0), '#');
    expect(reopened.index.propsObjects.length, 2);
    expect(reopened.index.portals.length, 1);
    expect(reopened.meta.indexRevision, 2);

    preview.dispose();
  });

  test('EditorState 的保存入口走新格式保存事务', () async {
    writeOldWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..propTypes = data.propTypes
      ..objectTypes = data.objectTypes
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '~'
      ..selectedSegment = 0;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    state.paintWorld(0, 0);
    expect(state.dirty, isTrue);
    await state.save();
    expect(state.dirty, isFalse);

    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.terrainCodeAt(0, 0, 0), '~');
    expect(reopened.meta.indexRevision, 2);
    preview.dispose();
  });

  test('V3 道具/对象编辑保存后重新打开还在', () async {
    writeOldWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..propTypes = data.propTypes
      ..objectTypes = data.objectTypes
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '.'
      ..selectedSegment = 0
      ..selectedPropId = 'box'
      ..selectedObjectId = 'Obj_Froggit';
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    state.placePropAt(0, 0);
    state.placeObjectAt(1, 1);
    await state.save();
    expect(state.dirty, isFalse);

    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    final props = reopened.index.propsObjects
        .where((e) => e.kind == 'prop')
        .toList(growable: false);
    final objects = reopened.index.propsObjects
        .where((e) => e.kind == 'object')
        .toList(growable: false);
    expect(props.any((e) => e.type == 'box' && e.col == 0 && e.row == 0), isTrue);
    expect(
      objects.any((e) => e.type == 'Obj_Froggit' && e.col == 1 && e.row == 1),
      isTrue,
    );
    expect(props.any((e) => e.type == 'box' && e.col == 2 && e.row == 2), isTrue);
    expect(
      objects.any((e) => e.type == 'Obj_Froggit' && e.col == 3 && e.row == 1),
      isTrue,
    );
    expect(reopened.index.portals.length, 1);
    preview.dispose();
  });

  test('V4 传送门和传送格编辑保存后重新打开还在', () async {
    writeOldWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..propTypes = data.propTypes
      ..objectTypes = data.objectTypes
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '.'
      ..selectedSegment = 0;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    final segment = data.world.segments.first;
    segment.instructions.add('; portal=lp1,right,0,0,2');
    final portalLinks = state.world!.raw['portal_links'] as List;
    portalLinks.add(<String, dynamic>{
      'from': '${segment.spec.id}/lp1',
      'to': '${segment.spec.id}/main__door1',
      'face': 'A',
    });
    final pads = state.world!.raw['pads'] as List;
    pads.add(<String, dynamic>{
      'id': 'p1',
      'segment': segment.spec.id,
      'col': 1,
      'row': 1,
    });
    pads.add(<String, dynamic>{
      'id': 'p2',
      'segment': segment.spec.id,
      'col': 2,
      'row': 1,
    });
    final padLinks = state.world!.raw['pad_links'] as List;
    padLinks.add(<String, dynamic>{'from': 'p1', 'to': 'p2'});

    state.dirty = true;
    await state.save();
    expect(state.dirty, isFalse);

    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.index.portals.length, 2);
    expect(
      reopened.index.portals.any(
        (p) => p.id == 'lp1' && p.x == 0 && p.y == 0 && p.length == 2,
      ),
      isTrue,
    );
    expect(reopened.meta.pads.length, 2);
    expect(reopened.meta.padLinks.length, 1);
    expect(reopened.meta.portalLinks.length, 1);
    preview.dispose();
  });

  test('V5 新画的碰撞保存后重新打开还在', () async {
    writeOldWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '.'
      ..selectedSegment = 0
      ..newFormatEditing = true;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    state.toggleSolidPick();
    state.pickSolidCell(0, 0);
    state.pickSolidCell(2, 0);
    state.pickSolidCell(2, 2);
    state.pickSolidCell(0, 2);
    state.finishSolid();
    expect(state.solids.length, 1);
    expect(state.solids.single.group, isNotNull);

    await state.save();
    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.index.solidGroups.length, 1);
    expect(reopened.index.solidGroups.single.pieces.length, 1);
    preview.dispose();
  });

  test('V5 跨块碰撞组删除会删掉所有片段', () async {
    File('${source.path}/world.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'segments': <dynamic>[
          <String, dynamic>{
            'id': 'main',
            'file': 'main.seg',
            'origin': <int>[0, 0, 0],
          },
        ],
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
        'portal_links': <dynamic>[],
        'start': <String, dynamic>{'col': 0, 'row': 0},
      }),
    );
    final terrain = '.' * 260;
    File('${source.path}/main.seg').writeAsStringSync(
      '; solid=0,0, 260,0, 260,4, 0,4\n'
      '$terrain\n$terrain\n$terrain\n$terrain\n',
    );

    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '.'
      ..selectedSegment = 0
      ..newFormatEditing = true;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    expect(state.solids.length, greaterThanOrEqualTo(2));
    final group = state.solids.first.group;
    expect(group, isNotNull);
    expect(state.solids.every((s) => s.group == group), isTrue);

    state.removeSolid(state.solids.first.instructionIndex);
    expect(state.solids, isEmpty);
    await state.save();

    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.index.solidGroups, isEmpty);
    preview.dispose();
  });

  test('打开 .gmap v2 保存会写回原包', () async {
    writeOldWorld();
    final defs = makeDefinitions();
    final directory = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final gmap = File('${source.path}/roundtrip.gmap')
      ..writeAsBytesSync(GmapExport.encodeDirectory(directory.worldPath));
    final preview = PreviewWorld.loadGmapFile(
      path: gmap.path,
      definitions: defs,
    );

    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..propTypes = data.propTypes
      ..objectTypes = data.objectTypes
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '~'
      ..selectedSegment = 0;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    state.paintWorld(0, 0);
    await state.save();

    final container = GmapContainer.decode(gmap.readAsBytesSync());
    expect(container.version, 2);
    final reopened = PreviewWorld.loadGmapFile(
      path: gmap.path,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.terrainCodeAt(0, 0, 0), '~');
    expect(reopened.index.portals.length, 1);

    preview.dispose();
    directory.dispose();
  });

  test('V5 新画的跨块碰撞会被切分', () async {
    writeWideWorld();
    final defs = makeDefinitions();
    final preview = PreviewWorld.loadOrMigrate(
      path: source.path,
      definitions: defs,
    );
    final data = LegacyWorldAdapter.fromPreview(preview);
    final state = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..selectedLevel = data.selectedLevel
      ..selectedCode = '.'
      ..selectedSegment = 0
      ..newFormatEditing = true;
    state.newFormatSaveHandler = NewWorldEditSession(
      preview: preview,
      state: state,
    ).save;

    state.toggleSolidPick();
    state.pickSolidCell(120, 0);
    state.pickSolidCell(140, 0);
    state.pickSolidCell(140, 2);
    state.pickSolidCell(120, 2);
    state.finishSolid();
    expect(state.solids.length, 1);
    final group = state.solids.single.group;
    expect(group, isNotNull);

    await state.save();
    expect(state.solids.length, 2);
    expect(state.solids.every((solid) => solid.group == group), isTrue);
    final reopened = PreviewWorld.loadOrMigrate(
      path: preview.worldPath,
      definitions: defs,
    );
    addTearDown(reopened.dispose);
    expect(reopened.index.solidGroups.length, 1);
    expect(reopened.index.solidGroups.single.pieces.length, 2);
    preview.dispose();
  });
}
