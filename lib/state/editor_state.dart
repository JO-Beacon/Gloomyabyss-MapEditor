import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

import '../io/gmap.dart';
import '../models/obj.dart';
import '../models/prop.dart';
import '../models/solid.dart';
import '../models/pad.dart';
import '../models/line_portal.dart';
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
  int selectedLevel = 0;
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

  bool linePortalPick = false;
  int selectedLinePortal = -1;
  (int, int)? _linePickStart;
  int? _linePickSegment;

  List<LinePortal> get linePortals {
    final s = segment;
    if (s == null) return const <LinePortal>[];
    return parseLinePortals(s.instructions);
  }

  void toggleLinePortalPick() {
    linePortalPick = !linePortalPick;
    _linePickStart = null;
    _linePickSegment = null;
    if (linePortalPick) {
      startPick = false;
      solidPick = false;
      padPick = false;
    }
    notifyListeners();
  }

  void pickLinePortalCell(int col, int row) {
    final s = segment;
    if (s == null || !linePortalPick) return;
    if (_linePickStart == null) {
      _linePickStart = (col, row);
      _linePickSegment = selectedSegment;
      notice = '再点另一端';
      notifyListeners();
      return;
    }
    final (int c0, int r0) = _linePickStart!;
    final int dc = col - c0;
    final int dr = row - r0;
    String dir;
    int sx;
    int sy;
    int length;
    if (dc.abs() >= dr.abs()) {
      // 向右
      dir = 'right';
      sx = c0 < col ? c0 : col;
      sy = r0;
      length = dc.abs();
    } else {
      // 向下
      dir = 'down';
      sx = c0;
      sy = r0 < row ? r0 : row;
      length = dr.abs();
    }
    final String? err = linePortalError(dir, sx, sy, length, s.width, s.height);
    if (err != null) {
      setError(err);
      return;
    }
    final String id = _nextLinePortalId(s);
    final String line = linePortalInstruction(id, dir, sx, sy, length);
    s.instructions.add(line);
    _push(_Action(
      label: '加传送门',
      undo: () => s.instructions.remove(line),
      redo: () => s.instructions.add(line),
    ));
    _linePickStart = null;
    _linePickSegment = null;
    linePortalPick = false;
    selectedLinePortal = linePortals.length - 1;
    notice = '已添加传送门';
    notifyListeners();
  }

  String _nextLinePortalId(Segment s) {
    final ids = parseLinePortals(s.instructions).map((p) => p.id).toSet();
    int n = 1;
    while (ids.contains('lp$n')) {
      n++;
    }
    return 'lp$n';
  }

  (int, int)? get linePickStart => _linePickStart;

  void pickLinePortalWorld(int col, int row) {
    final int i = segmentIndexAtWorld(col, row);
    if (i < 0) return;
    // 传送门属于段，画到一半不能跑到别的段。
    if (_linePickStart != null && i != _linePickSegment) {
      setError('传送门不能跨段');
      return;
    }
    selectedSegment = i;
    final Segment s = segment!;
    pickLinePortalCell(col - s.spec.originCol, row - s.spec.originRow);
  }

  List<({String segment, LinePortal portal})> get allLinePortals {
    final w = world;
    if (w == null) return const <({String segment, LinePortal portal})>[];
    final out = <({String segment, LinePortal portal})>[];
    for (final s in w.segments) {
      for (final p in parseLinePortals(s.instructions)) {
        out.add((segment: s.spec.id, portal: p));
      }
    }
    return out;
  }

  List<PortalLink> get portalLinks => parsePortalLinks(world?.raw['portal_links']);

  String? _linkError(String from, String to) {
    if (from == to) return '不能连自己';
    LinePortal? find(String ref) {
      final int slash = ref.indexOf('/');
      if (slash <= 0) return null;
      final String segId = ref.substring(0, slash);
      final String portalId = ref.substring(slash + 1);
      final World? w = world;
      if (w == null) return null;
      for (final s in w.segments) {
        if (s.spec.id != segId) continue;
        for (final p in parseLinePortals(s.instructions)) {
          if (p.id == portalId) return p;
        }
      }
      return null;
    }

    final LinePortal? a = find(from);
    final LinePortal? b = find(to);
    if (a == null || b == null) return '找不到传送门';
    if (a.dir != b.dir) return '两条线方向不同';
    if (a.length != b.length) return '两条线长度不同';
    return null;
  }

  void addPortalLink(String from, String to, {String face = 'A'}) {
    final String? err = _linkError(from, to);
    if (err != null) {
      setError(err);
      return;
    }
    final before = _rawList('portal_links');
    final after = _rawList('portal_links')
      ..add(<String, dynamic>{'from': from, 'to': to, 'face': face});
    _setRawList('portal_links', after);
    _push(_Action(
      label: '加传送门连接',
      undo: () => _setRawList('portal_links', before),
      redo: () => _setRawList('portal_links', after),
    ));
    notifyListeners();
  }

  void removePortalLink(int index) {
    final list = portalLinks;
    if (index < 0 || index >= list.length) return;
    final before = _rawList('portal_links');
    final after = _rawList('portal_links')..removeAt(index);
    _setRawList('portal_links', after);
    _push(_Action(
      label: '删传送门连接',
      undo: () => _setRawList('portal_links', before),
      redo: () => _setRawList('portal_links', after),
    ));
    notifyListeners();
  }

  (LinePortal, Segment)? _findPortalRef(String ref) {
    final int slash = ref.indexOf('/');
    if (slash <= 0) return null;
    final String segId = ref.substring(0, slash);
    final String portalId = ref.substring(slash + 1);
    final World? w = world;
    if (w == null) return null;
    for (final Segment seg in w.segments) {
      if (seg.spec.id != segId) continue;
      for (final LinePortal p in parseLinePortals(seg.instructions)) {
        if (p.id == portalId) return (p, seg);
      }
    }
    return null;
  }

  void updateLinePortal(
    int index, {
    String? dir,
    int? x,
    int? y,
    int? length,
  }) {
    final list = linePortals;
    if (index < 0 || index >= list.length) return;
    final s = segment;
    if (s == null) return;
    final LinePortal p = list[index];
    final String nd = dir ?? p.dir;
    final int nx = x ?? p.x;
    final int ny = y ?? p.y;
    final int nl = length ?? p.length;
    final String? err = linePortalError(nd, nx, ny, nl, s.width, s.height);
    if (err != null) {
      setError(err);
      return;
    }

    // 收集联动对象：所有直接连接到的传送门。
    final String selfRef = '${s.spec.id}/${p.id}';
    final Set<String> refs = <String>{selfRef};
    for (final link in portalLinks) {
      if (link.from == selfRef) refs.add(link.to);
      if (link.to == selfRef) refs.add(link.from);
    }

    final List<({Segment seg, int index, String before, String after})> edits = [];
    for (final String ref in refs) {
      final (LinePortal, Segment)? found = _findPortalRef(ref);
      if (found == null) continue;
      final LinePortal other = found.$1;
      final Segment seg = found.$2;
      final bool isSelf = ref == selfRef;
      final int ox = isSelf ? nx : other.x;
      final int oy = isSelf ? ny : other.y;
      final String? e2 = linePortalError(nd, ox, oy, nl, seg.width, seg.height);
      if (e2 != null) {
        setError('联动失败：${seg.spec.id}/${other.id} $e2');
        return;
      }
      edits.add((
        seg: seg,
        index: other.instructionIndex,
        before: seg.instructions[other.instructionIndex],
        after: linePortalInstruction(other.id, nd, ox, oy, nl),
      ));
    }

    for (final e in edits) {
      e.seg.instructions[e.index] = e.after;
    }
    _push(_Action(
      label: '改传送门',
      undo: () {
        for (final e in edits) {
          e.seg.instructions[e.index] = e.before;
        }
        notifyListeners();
      },
      redo: () {
        for (final e in edits) {
          e.seg.instructions[e.index] = e.after;
        }
        notifyListeners();
      },
    ));
    notifyListeners();
  }

  void renameLinePortal(int index, String value) {
    final list = linePortals;
    if (index < 0 || index >= list.length) return;
    final s = segment;
    if (s == null) return;
    final LinePortal p = list[index];
    final String name = value.trim();
    if (name.isEmpty || name == p.id) return;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
      setError('名字只能用字母、数字、下划线、短横线');
      return;
    }
    if (list.any((e) => e.id == name)) {
      setError('这个段里已经有同名传送门');
      return;
    }
    final String oldRef = '${s.spec.id}/${p.id}';
    final String newRef = '${s.spec.id}/$name';
    final String beforeLine = s.instructions[p.instructionIndex];
    final String afterLine =
        linePortalInstruction(name, p.dir, p.x, p.y, p.length);
    final beforeLinks = _rawList('portal_links');
    final afterLinks = _rawList('portal_links')
      ..replaceRange(0, 0, const <Map<String, dynamic>>[]);
    for (final l in afterLinks) {
      if (l['from'] == oldRef) l['from'] = newRef;
      if (l['to'] == oldRef) l['to'] = newRef;
    }
    s.instructions[p.instructionIndex] = afterLine;
    _setRawList('portal_links', afterLinks);
    _push(_Action(
      label: '传送门改名',
      undo: () {
        s.instructions[p.instructionIndex] = beforeLine;
        _setRawList('portal_links', beforeLinks);
        notifyListeners();
      },
      redo: () {
        s.instructions[p.instructionIndex] = afterLine;
        _setRawList('portal_links', afterLinks);
        notifyListeners();
      },
    ));
    notifyListeners();
  }

  void eraseLinePortalWorld(int col, int row) {
    final World? w = world;
    if (w == null) return;
    int bestSeg = -1;
    int bestIndex = -1;
    double bestDist = 1.0;
    for (int i = 0; i < w.segments.length; i++) {
      final Segment seg = w.segments[i];
      if (seg.spec.originZ != selectedLevel) continue;
      final List<LinePortal> list = parseLinePortals(seg.instructions);
      for (int j = 0; j < list.length; j++) {
        final LinePortal p = list[j];
        final double x1 = (seg.spec.originCol + p.x).toDouble();
        final double y1 = (seg.spec.originRow + p.y).toDouble();
        final double x2 = seg.spec.originCol + p.endX.toDouble();
        final double y2 = seg.spec.originRow + p.endY.toDouble();
        final double d = _pointSegmentDistance(
          col + 0.5,
          row + 0.5,
          x1,
          y1,
          x2,
          y2,
        );
        if (d < bestDist) {
          bestDist = d;
          bestSeg = i;
          bestIndex = j;
        }
      }
    }
    if (bestSeg < 0) return;
    selectedSegment = bestSeg;
    removeLinePortal(bestIndex);
  }

  static double _pointSegmentDistance(
    double px,
    double py,
    double x1,
    double y1,
    double x2,
    double y2,
  ) {
    final double dx = x2 - x1;
    final double dy = y2 - y1;
    final double len2 = dx * dx + dy * dy;
    if (len2 == 0) {
      final double ex = px - x1;
      final double ey = py - y1;
      return (ex * ex + ey * ey);
    }
    double t = ((px - x1) * dx + (py - y1) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final double ex = px - (x1 + t * dx);
    final double ey = py - (y1 + t * dy);
    return (ex * ex + ey * ey);
  }

  void removeLinePortal(int index) {
    final list = linePortals;
    if (index < 0 || index >= list.length) return;
    final s = segment;
    if (s == null) return;
    final LinePortal portal = list[index];
    final String ref = '${s.spec.id}/${portal.id}';
    final line = s.instructions[portal.instructionIndex];
    final beforeLinks = _rawList('portal_links');
    final afterLinks = _rawList('portal_links')
      ..removeWhere((l) => l['from'] == ref || l['to'] == ref);

    s.instructions.remove(line);
    _setRawList('portal_links', afterLinks);
    _push(_Action(
      label: '删传送门',
      undo: () {
        s.instructions.add(line);
        _setRawList('portal_links', beforeLinks);
        notifyListeners();
      },
      redo: () {
        s.instructions.remove(line);
        _setRawList('portal_links', afterLinks);
        notifyListeners();
      },
    ));
    selectedLinePortal = -1;
    notifyListeners();
  }

  bool startPick = false;
  bool padPick = false;
  int selectedPad = -1;
  int selectedPadLink = -1;

  List<Pad> get pads => parsePads(world?.raw['pads']);
  List<PadLink> get padLinks => parsePadLinks(world?.raw['pad_links']);

  bool solidPick = false;
  int selectedSolid = -1;
  final List<(int, int)> _solidDraft = [];

  List<(int, int)> get solidDraft => List<(int, int)>.unmodifiable(_solidDraft);

  int? get worldStartCol {
    final s = world?.raw['start'];
    if (s is Map) return (s['col'] as num?)?.toInt();
    return null;
  }

  int? get worldStartRow {
    final s = world?.raw['start'];
    if (s is Map) return (s['row'] as num?)?.toInt();
    return null;
  }

  _Pending? _renamePending;
  int _renameIndex = -1;

  final List<_Action> _undo = [];
  final List<_Action> _redo = [];
  final List<_CellChange> _stroke = [];
  final List<_Action> _strokeOps = <_Action>[];
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
        'pads': <dynamic>[],
        'pad_links': <dynamic>[],
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

    final List<dynamic> pads =
        (w.raw['pads'] as List<dynamic>?) ?? const <dynamic>[];
    for (final dynamic p in pads) {
      if (p is Map && p['segment'] == s.spec.id) {
        setError('有传送格引用这一段，先删传送格');
        return;
      }
    }

    final index = selectedSegment;
    w.segments.removeAt(index);
    if (selectedSegment >= w.segments.length) {
      selectedSegment = w.segments.length - 1;
    }
    _push(_Action(
      label: '删段',
      undo: () {
        w.segments.insert(index, s);
        notifyListeners();
      },
      redo: () {
        w.segments.remove(s);
        notifyListeners();
      },
    ));
    dirty = true;
    notice = '已删除段 ${s.spec.id}';
    notifyListeners();
  }

  void selectSegment(int index) {
    selectedSegment = index;
    pickPlane = false;
    _pickStart = null;
    startPick = false;
    solidPick = false;
    selectedSolid = -1;
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

  void toggleObjectAt(int col, int row) => _objectAt(col, row, 0);
  void placeObjectAt(int col, int row) => _objectAt(col, row, 1);
  void eraseObjectAt(int col, int row) => _objectAt(col, row, 2);

  void _objectAt(int col, int row, int mode) {
    final s = segment;
    final id = selectedObjectId;
    if (s == null || id == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final existing = placedObjects
        .where((o) => o.col == col && o.row == row && o.id == id)
        .toList();
    if (existing.isNotEmpty) {
      if (mode == 1) return;
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

    if (mode == 2) return;
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
  void togglePropAt(int col, int row) => _propAt(col, row, 0);
  void placePropAt(int col, int row) => _propAt(col, row, 1);
  void erasePropAt(int col, int row) => _propAt(col, row, 2);

  void _propAt(int col, int row, int mode) {
    final s = segment;
    final id = selectedPropId;
    if (s == null || id == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final existing = placedProps
        .where((p) => p.col == col && p.row == row && p.id == id)
        .toList();
    if (existing.isNotEmpty) {
      if (mode == 1) return;
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

    if (mode == 2) return;
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
    if (_inStroke) {
      _strokeOps.add(action);
      return;
    }
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
    _strokeOps.clear();
    _inStroke = true;
  }

  void endStroke() {
    _inStroke = false;
    if (_stroke.isEmpty && _strokeOps.isEmpty) return;
    final changes = List<_CellChange>.from(_stroke);
    final ops = List<_Action>.from(_strokeOps);
    _stroke.clear();
    _strokeOps.clear();
    final String label = changes.isNotEmpty && ops.isEmpty
        ? '刷地形 ${changes.length} 格'
        : ops.isNotEmpty && changes.isEmpty
            ? '${ops.first.label} ${ops.length} 处'
            : '一次笔画';
    _push(_Action(
      label: label,
      undo: () {
        _applyChanges(changes, reverse: true);
        for (final a in ops.reversed) {
          a.undo();
        }
      },
      redo: () {
        _applyChanges(changes, reverse: false);
        for (final a in ops) {
          a.redo();
        }
      },
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

  void paint(int col, int row) => _paintCode(col, row, selectedCode);

  void erase(int col, int row) => _paintCode(col, row, '.');

  void _paintCode(int col, int row, String code) {
    final s = segment;
    if (s == null) return;
    if (col < 0 || row < 0 || col >= s.width || row >= s.height) return;

    final before = s.charAt(col, row);
    if (before == code) return;
    s.setChar(col, row, code);

    final change = _CellChange(selectedSegment, col, row, before, code);
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
          s.setChar(col, row, code);
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
      at: w.maxCol,
      from: w.minRow,
      to: w.maxRow,
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
      label: '删除传送格',
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
      label: '改传送格',
      undo: () => apply(before),
      redo: () => apply(after),
    ));
    notifyListeners();
  }

  List<int> get levels {
    final w = world;
    if (w == null) return const <int>[];
    final set = <int>{for (final s in w.segments) s.spec.originZ};
    final list = set.toList()..sort();
    return list;
  }

  void setLevel(int z) {
    selectedLevel = z;
    final w = world;
    if (w != null) {
      final int i = w.segments.indexWhere((s) => s.spec.originZ == z);
      selectedSegment = i < 0 ? 0 : i;
    }
    notifyListeners();
  }

  Segment? segmentAtWorld(int col, int row) {
    final w = world;
    if (w == null) return null;
    for (final s in w.segments) {
      if (s.spec.originZ != selectedLevel) continue;
      if (col >= s.spec.originCol &&
          col < s.spec.originCol + s.width &&
          row >= s.spec.originRow &&
          row < s.spec.originRow + s.height) {
        return s;
      }
    }
    return null;
  }

  int segmentIndexAtWorld(int col, int row) {
    final w = world;
    if (w == null) return -1;
    for (int i = 0; i < w.segments.length; i++) {
      final s = w.segments[i];
      if (s.spec.originZ != selectedLevel) continue;
      if (col >= s.spec.originCol &&
          col < s.spec.originCol + s.width &&
          row >= s.spec.originRow &&
          row < s.spec.originRow + s.height) {
        return i;
      }
    }
    return -1;
  }

  bool _activateWorldCell(int col, int row) {
    final int i = segmentIndexAtWorld(col, row);
    if (i < 0) return false;
    selectedSegment = i;
    return true;
  }

  void paintWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    paint(col - s.spec.originCol, row - s.spec.originRow);
  }

  void eraseWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    erase(col - s.spec.originCol, row - s.spec.originRow);
  }

  void togglePropWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    togglePropAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void placePropWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    placePropAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void erasePropWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    erasePropAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void toggleObjectWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    toggleObjectAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void placeObjectWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    placeObjectAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void eraseObjectWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    eraseObjectAt(col - s.spec.originCol, row - s.spec.originRow);
  }

  void pickSolidWorld(int col, int row) {
    final int i = segmentIndexAtWorld(col, row);
    if (i < 0) return;
    if (_solidDraft.isNotEmpty && i != selectedSegment) return;
    selectedSegment = i;
    final Segment s = segment!;
    pickSolidCell(col - s.spec.originCol, row - s.spec.originRow);
  }

  void selectSolidWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    selectSolidAtCell(col - s.spec.originCol, row - s.spec.originRow);
  }

  void addPadWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    addPadAtCell(col - s.spec.originCol, row - s.spec.originRow);
  }

  void placePadWorld(int col, int row) {
    if (!_activateWorldCell(col, row)) return;
    final Segment s = segment!;
    placePadAtCell(col - s.spec.originCol, row - s.spec.originRow);
  }

  void removePadWorld(int col, int row) {
    final int i = segmentIndexAtWorld(col, row);
    if (i < 0) return;
    final Segment s = world!.segments[i];
    final int lc = col - s.spec.originCol;
    final int lr = row - s.spec.originRow;
    final int idx = pads.indexWhere(
      (p) => p.segment == s.spec.id && p.col == lc && p.row == lr,
    );
    if (idx >= 0) removePad(idx);
  }

  void pickPlaneWorld(int col, int row) {
    pickCell(col, row);
  }

  void setStartWorld(int col, int row) {
    final w = world;
    if (w == null || !startPick) return;
    final before = w.raw['start'] == null
        ? null
        : Map<String, dynamic>.from(w.raw['start'] as Map);
    w.raw['start'] = <String, dynamic>{'col': col, 'row': row};
    _push(_Action(
      label: '改世界起点',
      undo: () {
        if (before == null) {
          w.raw.remove('start');
        } else {
          w.raw['start'] = Map<String, dynamic>.from(before);
        }
        notifyListeners();
      },
      redo: () {
        w.raw['start'] = <String, dynamic>{'col': col, 'row': row};
        notifyListeners();
      },
    ));
    startPick = false;
    notifyListeners();
  }

  List<Map<String, dynamic>> _rawList(String key) {
    final v = world?.raw[key];
    if (v is! List) return <Map<String, dynamic>>[];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  void _setRawList(String key, List<Map<String, dynamic>> list) {
    world?.raw[key] = list.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  void _editLists(
    String label,
    void Function(List<Map<String, dynamic>> pads, List<Map<String, dynamic>> padLinks) fn,
  ) {
    final beforeP = _rawList('pads');
    final beforeL = _rawList('pad_links');
    final afterP = _rawList('pads');
    final afterL = _rawList('pad_links');
    fn(afterP, afterL);
    _setRawList('pads', afterP);
    _setRawList('pad_links', afterL);

    _push(_Action(
      label: label,
      undo: () {
        _setRawList('pads', beforeP);
        _setRawList('pad_links', beforeL);
        notifyListeners();
      },
      redo: () {
        _setRawList('pads', afterP);
        _setRawList('pad_links', afterL);
        notifyListeners();
      },
    ));
    notifyListeners();
  }

  String _nextPadId() {
    final ids = pads.map((p) => p.id).toSet();
    int n = 1;
    while (ids.contains('p$n')) {
      n++;
    }
    return 'p$n';
  }

  void togglePadPick() {
    padPick = !padPick;
    if (padPick) {
      startPick = false;
      solidPick = false;
      pickPlane = false;
    }
    notifyListeners();
  }

  void addPadAtCell(int col, int row) {
    if (!padPick) return;
    _addPadAt(col, row);
  }

  void placePadAtCell(int col, int row) => _addPadAt(col, row);

  void _addPadAt(int col, int row) {
    final s = segment;
    if (s == null) return;
    final id = _nextPadId();
    _editLists('加传送格', (pads, padLinks) {
      pads.add(<String, dynamic>{
        'id': id,
        'segment': s.spec.id,
        'col': col,
        'row': row,
      });
    });
    padPick = false;
    selectedPad = pads.length - 1;
    notifyListeners();
  }

  void removePad(int index) {
    final list = pads;
    if (index < 0 || index >= list.length) return;
    final id = list[index].id;
    _editLists('删传送格', (pads, padLinks) {
      pads.removeWhere((p) => p['id'] == id);
      padLinks.removeWhere((l) => l['from'] == id || l['to'] == id);
    });
    selectedPad = -1;
    notifyListeners();
  }

  void addPadLink(String from, String to, {bool bidirectional = false}) {
    if (from == to) return;
    _editLists('加连线', (pads, padLinks) {
      padLinks.add(<String, dynamic>{
        'from': from,
        'to': to,
        if (bidirectional) 'bidirectional': true,
      });
    });
  }

  void removePadLink(int index) {
    if (index < 0 || index >= padLinks.length) return;
    _editLists('删连线', (pads, padLinks) {
      padLinks.removeAt(index);
    });
    selectedPadLink = -1;
    notifyListeners();
  }

  List<SolidShape> get solids {
    final s = segment;
    if (s == null) return const <SolidShape>[];
    return parseSolids(s.instructions);
  }

  void selectSolid(int index) {
    selectedSolid = index;
    notifyListeners();
  }

  static bool _pointInPolygon(double x, double y, List<(int, int)> pts) {
    bool inside = false;
    for (int i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      final (int xi, int yi) = pts[i];
      final (int xj, int yj) = pts[j];
      final bool cross = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
      if (cross) inside = !inside;
    }
    return inside;
  }

  /// 画布上点碰撞内部 → 选中它。
  void selectSolidAtCell(int col, int row) {
    final list = solids;
    for (int i = 0; i < list.length; i++) {
      if (_pointInPolygon(col + 0.5, row + 0.5, list[i].points)) {
        selectedSolid = i;
        notifyListeners();
        return;
      }
    }
  }

  void toggleSolidPick() {
    if (solidPick) {
      _solidDraft.clear();
      solidPick = false;
    } else {
      _solidDraft.clear();
      solidPick = true;
      startPick = false;
      pickPlane = false;
    }
    notifyListeners();
  }

  void cancelSolid() {
    _solidDraft.clear();
    solidPick = false;
    notifyListeners();
  }

  /// 点一个顶点；点回第一个点时闭合。
  void pickSolidCell(int col, int row) {
    if (!solidPick) return;

    if (_solidDraft.length >= 3 && _solidDraft.first == (col, row)) {
      finishSolid();
      return;
    }
    if (_solidDraft.isNotEmpty && _solidDraft.last == (col, row)) return;

    _solidDraft.add((col, row));
    notice = '已点 ${_solidDraft.length} 个点';
    notifyListeners();
  }

  /// 引擎用 SAT，只支持凸多边形；凹的在这里拆成三角形。
  bool _isConvex(List<(int, int)> pts) {
    int? sign;
    for (int i = 0; i < pts.length; i++) {
      final (int ax, int ay) = pts[i];
      final (int bx, int by) = pts[(i + 1) % pts.length];
      final (int cx, int cy) = pts[(i + 2) % pts.length];
      final int cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx);
      if (cross == 0) continue;
      final int s = cross > 0 ? 1 : -1;
      if (sign == null) {
        sign = s;
      } else if (sign != s) {
        return false;
      }
    }
    return true;
  }

  static bool _pointInTriangle(
    (int, int) p,
    (int, int) a,
    (int, int) b,
    (int, int) c,
  ) {
    int cross((int, int) o, (int, int) u, (int, int) v) =>
        (u.$1 - o.$1) * (v.$2 - o.$2) - (u.$2 - o.$2) * (v.$1 - o.$1);

    final int d1 = cross(a, b, p);
    final int d2 = cross(b, c, p);
    final int d3 = cross(c, a, p);
    final bool hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final bool hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }

  /// 耳切法。失败（自交、退化）返回 null。
  List<List<(int, int)>>? _triangulate(List<(int, int)> input) {
    final pts = <(int, int)>[];
    for (int i = 0; i < input.length; i++) {
      final (int ax, int ay) = input[i];
      final (int bx, int by) = input[(i + 1) % input.length];
      final (int cx, int cy) = input[(i + 2) % input.length];
      final int cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx);
      if (cross != 0) pts.add(input[i]);
    }
    if (pts.length < 3) return null;

    double area2 = 0;
    for (int i = 0; i < pts.length; i++) {
      final (int x1, int y1) = pts[i];
      final (int x2, int y2) = pts[(i + 1) % pts.length];
      area2 += (x1 * y2 - x2 * y1).toDouble();
    }
    if (area2 == 0) return null;
    final bool ccw = area2 > 0;

    final out = <List<(int, int)>>[];
    final work = List<(int, int)>.from(pts);
    int guard = 0;

    while (work.length > 3 && guard++ < 4096) {
      bool found = false;
      for (int i = 0; i < work.length; i++) {
        final (int ax, int ay) = work[(i + work.length - 1) % work.length];
        final (int bx, int by) = work[i];
        final (int cx, int cy) = work[(i + 1) % work.length];
        final int cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx);
        if (ccw ? cross <= 0 : cross >= 0) continue;

        bool blocked = false;
        for (int j = 0; j < work.length; j++) {
          if (j == i ||
              j == (i + work.length - 1) % work.length ||
              j == (i + 1) % work.length) {
            continue;
          }
          if (_pointInTriangle(work[j], work[(i + work.length - 1) % work.length],
              work[i], work[(i + 1) % work.length])) {
            blocked = true;
            break;
          }
        }
        if (blocked) continue;

        if (cross != 0) out.add([(ax, ay), (bx, by), (cx, cy)]);
        work.removeAt(i);
        found = true;
        break;
      }
      if (!found) return null;
    }

    if (work.length == 3) out.add([work[0], work[1], work[2]]);
    return out.isEmpty ? null : out;
  }

  void finishSolid() {
    final s = segment;
    if (s == null || _solidDraft.length < 3) return;

    final pieces = _isConvex(_solidDraft)
        ? <List<(int, int)>>[List<(int, int)>.from(_solidDraft)]
        : _triangulate(_solidDraft);
    if (pieces == null) {
      setError('多边形无法拆分（可能自交），请重画');
      return;
    }

    final lines = pieces
        .map((poly) => '; solid=${poly.map((p) => '${p.$1},${p.$2}').join(', ')}')
        .toList(growable: false);
    final index = s.instructions.length;
    s.instructions.addAll(lines);

    _push(_Action(
      label: '加碰撞',
      undo: () {
        for (int i = 0; i < lines.length; i++) {
          if (index < s.instructions.length) s.instructions.removeAt(index);
        }
      },
      redo: () => s.instructions.addAll(lines),
    ));

    final bool split = lines.length > 1;
    _solidDraft.clear();
    solidPick = false;
    notice = split ? '凹多边形已拆成 ${lines.length} 个三角形' : '已添加碰撞';
    notifyListeners();
  }

  void removeSolid(int instructionIndex) {
    final s = segment;
    if (s == null || instructionIndex < 0 || instructionIndex >= s.instructions.length) {
      return;
    }
    final line = s.instructions.removeAt(instructionIndex);
    _push(_Action(
      label: '删碰撞',
      undo: () => s.instructions.insert(instructionIndex, line),
      redo: () {
        final i = s.instructions.indexOf(line);
        if (i >= 0) s.instructions.removeAt(i);
      },
    ));
    notifyListeners();
  }

  void toggleStartPick() {
    startPick = !startPick;
    if (startPick) {
      solidPick = false;
      pickPlane = false;
    }
    notifyListeners();
  }

  /// 画布点格子 → 换算成世界坐标写入 world.json 的 start。
  void setStartFromCell(int col, int row) {
    final w = world;
    final s = segment;
    if (w == null || s == null || !startPick) return;

    final before = w.raw['start'] == null
        ? null
        : Map<String, dynamic>.from(w.raw['start'] as Map);
    final wc = s.spec.originCol + col;
    final wr = s.spec.originRow + row;
    w.raw['start'] = <String, dynamic>{'col': wc, 'row': wr};

    _push(_Action(
      label: '改世界起点',
      undo: () {
        if (before == null) {
          w.raw.remove('start');
        } else {
          w.raw['start'] = Map<String, dynamic>.from(before);
        }
        notifyListeners();
      },
      redo: () {
        w.raw['start'] = <String, dynamic>{'col': wc, 'row': wr};
        notifyListeners();
      },
    ));
    startPick = false;
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
  /// 平面坐标是整张世界的坐标，不是段内坐标。
  void pickCell(int col, int row) {
    if (!pickPlane) return;
    final plane = (selectedPlane >= 0 && selectedPlane < planes.length)
        ? planes[selectedPlane]
        : null;
    final w = world;
    if (plane == null || w == null) return;

    final horizontal = plane.axis == 'x';
    final at = horizontal
        ? col.clamp(w.minCol, w.maxCol)
        : row.clamp(w.minRow, w.maxRow);
    final along = horizontal
        ? row.clamp(w.minRow, w.maxRow)
        : col.clamp(w.minCol, w.maxCol);

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
    int? originZ,
    String? repeat,
    int? repeatCount,
  }) {
    final before = (
      originCol: spec.originCol,
      originRow: spec.originRow,
      originZ: spec.originZ,
      repeat: spec.repeat,
      repeatCount: spec.repeatCount,
    );

    spec.originCol = originCol ?? spec.originCol;
    spec.originRow = originRow ?? spec.originRow;
    spec.originZ = originZ ?? spec.originZ;
    spec.repeat = repeat ?? spec.repeat;
    spec.repeatCount = repeatCount ?? spec.repeatCount;

    final after = (
      originCol: spec.originCol,
      originRow: spec.originRow,
      originZ: spec.originZ,
      repeat: spec.repeat,
      repeatCount: spec.repeatCount,
    );
    if (before == after) return;

    void apply(({int originCol, int originRow, int originZ, String repeat, int repeatCount}) v) {
      spec.originCol = v.originCol;
      spec.originRow = v.originRow;
      spec.originZ = v.originZ;
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

    // 只改内存里的引用，文件在保存时统一写入，旧文件在保存时清理。
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
