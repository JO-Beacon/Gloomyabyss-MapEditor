import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

import '../io/gmap.dart';
import '../models/obj.dart';
import '../models/prop.dart';
import '../models/terrain.dart';
import '../models/world.dart';

class _CellChange {
  _CellChange(this.segment, this.col, this.row, this.before, this.after);

  final int segment;
  final int col;
  final int row;
  final String before;
  final String after;
}

class _Action {
  _Action({required this.undo, required this.redo, this.tag, this.label = ''});

  final VoidCallback undo;
  final VoidCallback redo;
  final String? tag;
  final String label;
}

/// 可变的“新值”容器，给重命名合并用。
class _Pending {
  _Pending(this.value);
  String value;
}

class EditorState extends ChangeNotifier {
  TerrainSet? terrain;
  String? rootPath;
  List<String> worlds = [];
  World? world;
  int selectedSegment = 0;
  String selectedCode = '.';
  List<String> errors = [];
  String? notice;

  /// 有没有未保存的改动。
  bool dirty = false;

  /// 当前编辑的是 .gmap 时的文件路径；为 null 表示文件夹模式。
  String? gmapPath;

  List<PropType> propTypes = [];
  String? selectedPropId;

  List<ObjectType> objectTypes = [];
  String? selectedObjectId;

  int selectedPlane = -1;
  bool pickPlane = false;
  int? _pickStart;

  _Pending? _renamePending;
  int _renameIndex = -1;

  final List<_Action> _undo = [];
  final List<_Action> _redo = [];
  final List<_CellChange> _stroke = [];
  bool _inStroke = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// 最近的撤销项在前面。
  List<String> get undoHistory =>
      _undo.reversed.map((a) => a.label).toList(growable: false);

  int get undoDepth => _undo.length;

  /// 撤销到只剩 [keep] 步（0 = 全部撤销）。
  void undoTo(int keep) {
    final target = keep.clamp(0, _undo.length);
    while (_undo.length > target) {
      undo();
    }
  }

  Segment? get segment {
    final w = world;
    if (w == null || w.segments.isEmpty) return null;
    if (selectedSegment < 0 || selectedSegment >= w.segments.length) return null;
    return w.segments[selectedSegment];
  }

  List<PortalPlane> get planes => world?.portalPlanes ?? const [];

  Future<TerrainSet> _loadDefaultTerrain() async {
    final content = await rootBundle.loadString('assets/default/terrain.json');
    return TerrainSet.fromJsonString(content);
  }

  Future<List<PropType>> _loadDefaultProps() async {
    final content = await rootBundle.loadString('assets/default/props.json');
    return PropType.parse(content);
  }

  Future<List<ObjectType>> _loadDefaultObjects() async {
    final content = await rootBundle.loadString('assets/default/objects.json');
    return ObjectType.parse(content);
  }

  Future<void> newWorld(String name, {int width = 32, int height = 24}) async {
    final t = await _loadDefaultTerrain();
    final props = await _loadDefaultProps();
    final objects = await _loadDefaultObjects();
    final first = t.types.first.code;
    final cols = width.clamp(4, 1024);
    final lineCount = height.clamp(4, 1024);
    final rows = List.generate(lineCount, (_) => first * cols);

    final spec = SegmentSpec(id: 'main', file: 'main.seg');
    final w = World(
      dirPath: '',
      name: name,
      segments: [Segment(spec, rows)],
      portalPlanes: [],
      raw: <String, dynamic>{
        'version': 1,
        'segments': <dynamic>[],
        'portals': <dynamic>[],
        'links': <dynamic>[],
        'seams': <dynamic>[],
        'portal_planes': <dynamic>[],
        'start': {'col': 2.clamp(1, cols - 1), 'row': 2.clamp(1, lineCount - 1)},
      },
    );

    terrain = t;
    propTypes = props;
    selectedPropId = props.isEmpty ? null : props.first.id;
    objectTypes = objects;
    selectedObjectId = objects.isEmpty ? null : objects.first.id;
    world = w;
    selectedCode = first;
    selectedSegment = 0;
    selectedPlane = -1;
    rootPath = null;
    worlds = [];
    gmapPath = null;
    errors = [];
    notice = '新建世界：$name';
    dirty = false;
    _clearHistory();
    notifyListeners();
  }

  Future<void> openGmap() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '打开 .gmap',
      type: FileType.custom,
      allowedExtensions: const <String>['gmap'],
    );
    final path = picked?.path;
    if (path == null) return;

    try {
      final bytes = File(path).readAsBytesSync();
      final entries = GmapFile.decode(bytes);
      final worldJson = entries['world.json'];
      if (worldJson == null) {
        throw const FormatException('缺少 world.json');
      }

      final files = <String, String>{
        for (final e in entries.entries) e.key: utf8.decode(e.value),
      };

      final base = path.split(Platform.pathSeparator).last;
      final name = base.toLowerCase().endsWith('.gmap')
          ? base.substring(0, base.length - 5)
          : base;

      final t = await _loadDefaultTerrain();
      final props = await _loadDefaultProps();
      final objects = await _loadDefaultObjects();
      final w = WorldIo.fromFiles(files, name: name);

      terrain = t;
      propTypes = props;
      selectedPropId = props.isEmpty ? null : props.first.id;
      objectTypes = objects;
      selectedObjectId = objects.isEmpty ? null : objects.first.id;
      world = w;
      selectedCode = t.types.first.code;
      selectedSegment = 0;
      selectedPlane = -1;
      rootPath = null;
      worlds = [];
      gmapPath = path;
      errors = [];
      notice = '已打开 $name.gmap';
      _clearHistory();
      notifyListeners();
    } on FormatException catch (e) {
      errors = ['打开失败：${e.message}'];
      notifyListeners();
    } on FileSystemException catch (e) {
      errors = ['打开失败：${e.message}'];
      notifyListeners();
    }
  }

  Future<void> openRoot() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择世界根目录，或某个世界文件夹',
    );
    if (dir == null) return;

    final sep = Platform.pathSeparator;
    final isWorldDir = File('$dir${sep}world.json').existsSync();
    final base = isWorldDir ? Directory(dir).parent.path : dir;

    rootPath = base;
    gmapPath = null;

    final terrainFile = File('$base${sep}terrain.json');
    terrain = terrainFile.existsSync()
        ? TerrainSet.load(terrainFile.path)
        : await _loadDefaultTerrain();

    final propsFile = File('$base${sep}props.json');
    propTypes = propsFile.existsSync()
        ? PropType.parse(propsFile.readAsStringSync())
        : await _loadDefaultProps();
    selectedPropId = propTypes.isEmpty ? null : propTypes.first.id;

    final objectsFile = File('$base${sep}objects.json');
    objectTypes = objectsFile.existsSync()
        ? ObjectType.parse(objectsFile.readAsStringSync())
        : await _loadDefaultObjects();
    selectedObjectId = objectTypes.isEmpty ? null : objectTypes.first.id;

    selectedCode = terrain?.types.first.code ?? '.';
    worlds = WorldIo.listWorlds(base);
    world = null;
    errors = [];
    _clearHistory();

    if (isWorldDir) {
      openWorld(dir.split(sep).last);
      return;
    }

    if (worlds.isNotEmpty) {
      openWorld(worlds.first);
      return;
    }

    errors = ['这个目录里没有世界'];
    notifyListeners();
  }

  void openWorld(String name) {
    if (rootPath == null) return;
    world = WorldIo.loadWorld('$rootPath/$name');
    dirty = false;
    selectedSegment = 0;
    selectedPlane = -1;
    pickPlane = false;
    _pickStart = null;
    errors = [];
    _clearHistory();
    notifyListeners();
  }

  bool segmentIdExists(String id) =>
      world?.segments.any((s) => s.spec.id == id) ?? false;

  /// 新建一段：只在内存里加，保存时写文件。
  void addSegment(
    String name, {
    int width = 16,
    int height = 16,
    int originCol = 0,
    int originRow = 0,
  }) {
    final w = world;
    if (w == null) return;
    final id = name.trim();
    if (id.isEmpty) {
      setError('段名不能为空');
      return;
    }
    if (segmentIdExists(id)) {
      setError('段名已存在：$id');
      return;
    }
    final code = terrain?.types.first.code ?? '.';
    final cols = width.clamp(4, 1024);
    final lines = height.clamp(4, 1024);

    final spec = SegmentSpec(
      id: id,
      file: '$id.seg',
      originCol: originCol,
      originRow: originRow,
    );
    w.segments.add(Segment(
      spec,
      List.generate(lines, (_) => code * cols),
    ));
    selectedSegment = w.segments.length - 1;
    dirty = true;
    notice = '已新建段 $id';
    notifyListeners();
  }

  void duplicateSegment() {
    final w = world;
    final s = segment;
    if (w == null || s == null) return;

    var id = '${s.spec.id}_copy';
    var n = 2;
    while (segmentIdExists(id)) {
      id = '${s.spec.id}_copy$n';
      n += 1;
    }

    final spec = SegmentSpec(
      id: id,
      file: '$id.seg',
      originCol: s.spec.originCol + s.width,
      originRow: s.spec.originRow,
      repeat: s.spec.repeat,
      repeatCount: s.spec.repeatCount,
    );
    w.segments.add(Segment(
      spec,
      List<String>.from(s.rows),
      instructions: List<String>.from(s.instructions),
    ));
    selectedSegment = w.segments.length - 1;
    dirty = true;
    notice = '已复制为 $id';
    notifyListeners();
  }

  void removeSegment() {
    final w = world;
    final s = segment;
    if (w == null || s == null) return;
    if (w.segments.length <= 1) {
      setError('至少要保留一段');
      return;
    }

    final List<dynamic> portals =
        (w.raw['portals'] as List<dynamic>?) ?? const <dynamic>[];
    for (final dynamic p in portals) {
      if (p is Map && p['segment'] == s.spec.id) {
        setError('有传送门引用这一段，先删传送门');
        return;
      }
    }

    if (w.dirPath.isNotEmpty) {
      final file = File('${w.dirPath}/${s.spec.file}');
      if (file.existsSync()) file.deleteSync();
    }

    final index = selectedSegment;
    w.segments.removeAt(index);
    if (selectedSegment >= w.segments.length) {
      selectedSegment = w.segments.length - 1;
    }
    dirty = true;
    notice = '已删除段 ${s.spec.id}';
    notifyListeners();
  }

  void selectSegment(int index) {
    selectedSegment = index;
    pickPlane = false;
    _pickStart = null;
    notifyListeners();
  }

  void selectCode(String code) {
    selectedCode = code;
    notifyListeners();
  }

  List<PlacedProp> get placedProps {
    final s = segment;
    if (s == null) return const <PlacedProp>[];
    return parsePlacedProps(s.instructions);
  }

  List<PlacedObject> get placedObjects {
    final s = segment;
    if (s == null) return const <PlacedObject>[];
    return parsePlacedObjects(s.instructions);
  }

  void selectObject(String id) {
    selectedObjectId = id;
    notifyListeners();
  }

  void toggleObjectAt(int col, int row) {
    final s = segment;
    final id = selectedObjectId;
    if (s == null || id == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final existing = placedObjects
        .where((o) => o.col == col && o.row == row && o.id == id)
        .toList();
    if (existing.isNotEmpty) {
      final o = existing.first;
      final line = s.instructions.removeAt(o.instructionIndex);
      _push(_Action(
        label: '删对象',
        undo: () => s.instructions.insert(o.instructionIndex, line),
        redo: () {
          final i = s.instructions.indexOf(line);
          if (i >= 0) s.instructions.removeAt(i);
        },
      ));
      notifyListeners();
      return;
    }

    final line = '; spawn=$id,$col,$row';
    final index = s.instructions.length;
    s.instructions.add(line);
    _push(_Action(
      label: '放对象',
      undo: () => s.instructions.removeAt(index),
      redo: () => s.instructions.add(line),
    ));
    notifyListeners();
  }

  void selectProp(String id) {
    selectedPropId = id;
    notifyListeners();
  }

  /// 点格子：已有同种道具就删掉，没有就放下。
  void togglePropAt(int col, int row) {
    final s = segment;
    final id = selectedPropId;
    if (s == null || id == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final existing = placedProps
        .where((p) => p.col == col && p.row == row && p.id == id)
        .toList();
    if (existing.isNotEmpty) {
      final p = existing.first;
      final line = s.instructions.removeAt(p.instructionIndex);
      _push(_Action(
        label: '删道具',
        undo: () => s.instructions.insert(p.instructionIndex, line),
        redo: () {
          final i = s.instructions.indexOf(line);
          if (i >= 0) s.instructions.removeAt(i);
        },
      ));
      notifyListeners();
      return;
    }

    final line = '; prop=$id,$col,$row';
    final index = s.instructions.length;
    s.instructions.add(line);
    _push(_Action(
      label: '放道具',
      undo: () => s.instructions.removeAt(index),
      redo: () => s.instructions.add(line),
    ));
    notifyListeners();
  }

  void setNotice(String? message) {
    notice = message;
    notifyListeners();
  }

  void setError(String message) {
    errors = [message];
    notifyListeners();
  }

  void _push(_Action action) {
    dirty = true;
    _undo.add(action);
    _redo.clear();
    if (action.tag != 'rename:$_renameIndex') {
      _renamePending = null;
      _renameIndex = -1;
    }
  }

  // —— 地形

  void beginStroke() {
    _stroke.clear();
    _inStroke = true;
  }

  void endStroke() {
    _inStroke = false;
    if (_stroke.isEmpty) return;
    final changes = List<_CellChange>.from(_stroke);
    _stroke.clear();
    _push(_Action(
      label: '刷地形 ${changes.length} 格',
      undo: () => _applyChanges(changes, reverse: true),
      redo: () => _applyChanges(changes, reverse: false),
    ));
    notifyListeners();
  }

  void _applyChanges(List<_CellChange> changes, {required bool reverse}) {
    final w = world;
    if (w == null) return;
    final ordered = reverse ? changes.reversed : changes;
    for (final c in ordered) {
      if (c.segment < w.segments.length) {
        w.segments[c.segment].setChar(c.col, c.row, reverse ? c.before : c.after);
      }
    }
  }

  void paint(int col, int row) {
    final s = segment;
    if (s == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final before = s.charAt(col, row);
    if (before == selectedCode) return;
    s.setChar(col, row, selectedCode);

    final change = _CellChange(selectedSegment, col, row, before, selectedCode);
    if (_inStroke) {
      _stroke.add(change);
    } else {
      _push(_Action(
        label: '刷一格',
        undo: () {
          s.setChar(col, row, before);
          notifyListeners();
        },
        redo: () {
          s.setChar(col, row, selectedCode);
          notifyListeners();
        },
      ));
    }
    notifyListeners();
  }

  // —— 撤销 / 重做

  void undo() {
    if (_undo.isEmpty) return;
    _renamePending = null;
    _renameIndex = -1;
    final action = _undo.removeLast();
    action.undo();
    _redo.add(action);
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _renamePending = null;
    _renameIndex = -1;
    final action = _redo.removeLast();
    action.redo();
    _undo.add(action);
    notifyListeners();
  }

  void _clearHistory() {
    _undo.clear();
    _redo.clear();
    _stroke.clear();
    _inStroke = false;
  }

  // —— 传送门

  void selectPlane(int index) {
    selectedPlane = index;
    pickPlane = false;
    _pickStart = null;
    notifyListeners();
  }

  void addPlane() {
    final w = world;
    final s = segment;
    if (w == null || s == null) return;
    final plane = PortalPlane(
      axis: 'x',
      at: s.width,
      from: 0,
      to: s.height,
      direction: '+',
      dx: 0,
      dy: 0,
    );
    w.portalPlanes.add(plane);
    selectedPlane = w.portalPlanes.length - 1;
    _push(_Action(
      label: '新建传送门',
      undo: () {
        w.portalPlanes.remove(plane);
        if (selectedPlane >= w.portalPlanes.length) {
          selectedPlane = w.portalPlanes.length - 1;
        }
        notifyListeners();
      },
      redo: () {
        w.portalPlanes.add(plane);
        selectedPlane = w.portalPlanes.length - 1;
        notifyListeners();
      },
    ));
    notifyListeners();
  }

  void removePlane() {
    final w = world;
    if (w == null || selectedPlane < 0 || selectedPlane >= w.portalPlanes.length) {
      return;
    }
    final index = selectedPlane;
    final plane = w.portalPlanes.removeAt(index);
    if (selectedPlane >= w.portalPlanes.length) {
      selectedPlane = w.portalPlanes.length - 1;
    }
    _push(_Action(
      label: '删除传送门',
      undo: () {
        w.portalPlanes.insert(index, plane);
        selectedPlane = index;
        notifyListeners();
      },
      redo: () {
        w.portalPlanes.remove(plane);
        if (selectedPlane >= w.portalPlanes.length) {
          selectedPlane = w.portalPlanes.length - 1;
        }
        notifyListeners();
      },
    ));
    notifyListeners();
  }

  /// 批量修改平面字段；一次调用记一步撤销。
  void updatePlane(
    PortalPlane plane, {
    String? axis,
    String? direction,
    int? at,
    int? from,
    int? to,
    int? dx,
    int? dy,
  }) {
    final before = (
      axis: plane.axis,
      direction: plane.direction,
      at: plane.at,
      from: plane.from,
      to: plane.to,
      dx: plane.dx,
      dy: plane.dy,
    );

    plane.axis = axis ?? plane.axis;
    plane.direction = direction ?? plane.direction;
    plane.at = at ?? plane.at;
    plane.from = from ?? plane.from;
    plane.to = to ?? plane.to;
    plane.dx = dx ?? plane.dx;
    plane.dy = dy ?? plane.dy;

    final after = (
      axis: plane.axis,
      direction: plane.direction,
      at: plane.at,
      from: plane.from,
      to: plane.to,
      dx: plane.dx,
      dy: plane.dy,
    );
    if (before == after) return;

    void apply(({String axis, String direction, int at, int from, int to, int dx, int dy}) v) {
      plane.axis = v.axis;
      plane.direction = v.direction;
      plane.at = v.at;
      plane.from = v.from;
      plane.to = v.to;
      plane.dx = v.dx;
      plane.dy = v.dy;
    }

    _push(_Action(
      label: '改传送门',
      undo: () => apply(before),
      redo: () => apply(after),
    ));
    notifyListeners();
  }

  void cancelPick() {
    pickPlane = false;
    _pickStart = null;
    notifyListeners();
  }

  void togglePick() {
    pickPlane = !pickPlane;
    _pickStart = null;
    notifyListeners();
  }

  /// 画布拾取：第一次点确定 at / from，第二次点确定 to。
  void pickCell(int col, int row) {
    if (!pickPlane) return;
    final plane = (selectedPlane >= 0 && selectedPlane < planes.length)
        ? planes[selectedPlane]
        : null;
    final s = segment;
    if (plane == null || s == null) return;

    final horizontal = plane.axis == 'x';
    final at = horizontal
        ? (col < 0 ? 0 : (col > s.width ? s.width : col))
        : (row < 0 ? 0 : (row > s.height ? s.height : row));
    final along = horizontal
        ? (row < 0 ? 0 : (row > s.height ? s.height : row))
        : (col < 0 ? 0 : (col > s.width ? s.width : col));

    if (_pickStart == null) {
      _pickStart = along;
      updatePlane(plane, at: at, from: along);
    } else {
      final a = _pickStart!;
      final lo = a <= along ? a : along;
      final hi = a <= along ? along : a;
      updatePlane(plane, at: at, from: lo, to: hi);
      pickPlane = false;
      _pickStart = null;
    }
    notifyListeners();
  }

  // —— 段属性

  void updateSegmentSpec(
    SegmentSpec spec, {
    int? originCol,
    int? originRow,
    String? repeat,
    int? repeatCount,
  }) {
    final before = (
      originCol: spec.originCol,
      originRow: spec.originRow,
      repeat: spec.repeat,
      repeatCount: spec.repeatCount,
    );

    spec.originCol = originCol ?? spec.originCol;
    spec.originRow = originRow ?? spec.originRow;
    spec.repeat = repeat ?? spec.repeat;
    spec.repeatCount = repeatCount ?? spec.repeatCount;

    final after = (
      originCol: spec.originCol,
      originRow: spec.originRow,
      repeat: spec.repeat,
      repeatCount: spec.repeatCount,
    );
    if (before == after) return;

    void apply(({int originCol, int originRow, String repeat, int repeatCount}) v) {
      spec.originCol = v.originCol;
      spec.originRow = v.originRow;
      spec.repeat = v.repeat;
      spec.repeatCount = v.repeatCount;
    }

    _push(_Action(
      label: '改段属性',
      undo: () => apply(before),
      redo: () => apply(after),
    ));
    notifyListeners();
  }

  /// 改名：连续输入合并成一步撤销。
  void renameSegment(int index, String value) {
    final w = world;
    if (w == null || index < 0 || index >= w.segments.length) return;
    final spec = w.segments[index].spec;
    if (spec.id == value) return;

    if (_renamePending != null && _renameIndex == index) {
      _renamePending!.value = value;
      spec.id = value;
      notifyListeners();
      return;
    }

    final before = spec.id;
    final holder = _Pending(value);
    _renamePending = holder;
    _renameIndex = index;
    spec.id = value;

    _push(_Action(
      tag: 'rename:$index',
      label: '段改名',
      undo: () => spec.id = before,
      redo: () => spec.id = holder.value,
    ));
    notifyListeners();
  }

  /// 把段文件改成 `<id>.seg`。
  void renameSegmentFile() {
    final w = world;
    final s = segment;
    if (w == null || s == null || rootPath == null) return;
    final spec = s.spec;
    final id = spec.id.trim();
    if (id.isEmpty || id.contains('/') || id.contains(r'\')) {
      errors = ['段名不能用作文件名'];
      notifyListeners();
      return;
    }
    final target = '$id.seg';
    if (spec.file == target) return;

    final from = File('$rootPath/${w.name}/${spec.file}');
    final to = File('$rootPath/${w.name}/$target');
    if (!from.existsSync()) {
      errors = ['找不到 ${spec.file}'];
      notifyListeners();
      return;
    }
    if (to.existsSync()) {
      errors = ['目标文件已存在：$target'];
      notifyListeners();
      return;
    }
    from.renameSync(to.path);
    spec.file = target;
    dirty = true;
    errors = [];
    notifyListeners();
  }

  // —— 导入 / 导出 .gmap

  Future<void> importGmap() async {
    final root = rootPath;
    if (root == null) {
      errors = ['先打开世界根目录'];
      notifyListeners();
      return;
    }

    final picked = await FilePicker.pickFile(
      dialogTitle: '导入 .gmap',
      type: FileType.custom,
      allowedExtensions: const <String>['gmap'],
    );
    final path = picked?.path;
    if (path == null) return;

    try {
      final files = GmapFile.decode(File(path).readAsBytesSync());
      if (!files.containsKey('world.json')) {
        throw const FormatException('缺少 world.json');
      }

      final base = path.split(Platform.pathSeparator).last;
      final rawName = base.toLowerCase().endsWith('.gmap')
          ? base.substring(0, base.length - 5)
          : base;
      var name = rawName.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
      if (name.isEmpty) name = 'imported';

      var dir = Directory('$root/$name');
      var i = 2;
      while (dir.existsSync()) {
        dir = Directory('$root/${name}_$i');
        i++;
      }
      dir.createSync(recursive: true);

      for (final entry in files.entries) {
        final safe = entry.key.split(RegExp(r'[\/]')).last;
        if (safe.isEmpty || safe == '..') continue;
        File('${dir.path}/$safe').writeAsBytesSync(entry.value);
      }

      worlds = WorldIo.listWorlds(root);
      openWorld(dir.path.split(Platform.pathSeparator).last);
      notice = '已导入 ${files.length} 个文件';
      notifyListeners();
    } on FormatException catch (e) {
      errors = ['导入失败：${e.message}'];
      notifyListeners();
    } on FileSystemException catch (e) {
      errors = ['导入失败：${e.message}'];
      notifyListeners();
    }
  }

  Future<void> exportGmap() => saveAsGmap();

  // —— 校验 / 保存

  void validate() {
    final t = terrain;
    final w = world;
    if (t == null || w == null) return;
    errors = WorldIo.validate(w, t.byCode.keys.toSet());
    notifyListeners();
  }

  Future<void> save() async {
    final w = world;
    if (w == null) return;

    if (gmapPath != null) {
      final snapshot = WorldIo.snapshot(w);
      final bytes = GmapFile.encode(<String, Uint8List>{
        for (final e in snapshot.entries)
          e.key: Uint8List.fromList(utf8.encode(e.value)),
      });
      File(gmapPath!).writeAsBytesSync(bytes);
      dirty = false;
      notice = '已保存 ${w.name}.gmap';
      notifyListeners();
      return;
    }

    if (w.dirPath.isNotEmpty) {
      WorldIo.saveWorld(w);
      dirty = false;
      notice = '已保存';
      validate();
      return;
    }

    await saveAsGmap();
  }

  Future<void> saveAsGmap() async {
    final w = world;
    if (w == null) return;

    final snapshot = WorldIo.snapshot(w);
    final bytes = GmapFile.encode(<String, Uint8List>{
      for (final e in snapshot.entries)
        e.key: Uint8List.fromList(utf8.encode(e.value)),
    });

    final uri = await FilePicker.saveFile(
      fileName: '${w.name}.gmap',
      bytes: bytes,
      dialogTitle: '保存 .gmap',
    );
    if (uri == null) return;
    gmapPath = uri.toFilePath();
    dirty = false;
    notice = '已保存 ${w.name}.gmap';
    notifyListeners();
  }
}
