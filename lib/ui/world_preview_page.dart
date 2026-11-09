import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../preview/bundled_definitions.dart';
import '../preview/preview_world.dart';
import '../world/chunk_file.dart';
import '../world/definitions.dart';

/// V1：新格式世界的只读预览页。
///
/// 不编辑、不保存；旧格式目录会先迁移到系统临时目录再显示。
class WorldPreviewPage extends StatefulWidget {
  const WorldPreviewPage({
    super.key,
    required this.onClose,
    this.initialPath,
  });

  final VoidCallback onClose;

  /// 仅用于测试/调试：启动后直接打开这个目录。
  final String? initialPath;

  @override
  State<WorldPreviewPage> createState() => _WorldPreviewPageState();
}

class _WorldPreviewPageState extends State<WorldPreviewPage> {
  DefinitionPackage? _definitions;
  PreviewWorld? _world;
  bool _loading = true;
  String? _error;
  String? _notice;
  int _layer = 0;
  double? _zoom;
  Offset? _pan;
  bool _dragging = false;
  Offset _lastPointer = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadDefinitions().then((_) {
      final path = widget.initialPath;
      if (path != null && path.isNotEmpty && mounted) {
        _openPath(path);
      }
    });
  }

  @override
  void dispose() {
    _world?.dispose();
    super.dispose();
  }

  Future<void> _loadDefinitions() async {
    try {
      final defs = await loadBundledDefaultDefinitions();
      if (!mounted) return;
      setState(() {
        _definitions = defs;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '加载内置定义包失败：$error';
        _loading = false;
      });
    }
  }

  Future<void> _openWorld() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择世界目录（旧格式或新格式）',
    );
    if (path == null || path.isEmpty) return;
    await _openPath(path);
  }

  Future<void> _openPath(String path) async {
    final defs = _definitions;
    if (defs == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    PreviewWorld? next;
    try {
      next = PreviewWorld.loadOrMigrate(path: path, definitions: defs);
      if (!mounted) {
        next.dispose();
        return;
      }
      final old = _world;
      setState(() {
        _world = next;
        _layer = next!.layers.contains(next.meta.start.z)
            ? next.meta.start.z
            : (next.layers.isEmpty ? 0 : next.layers.first);
        _zoom = null;
        _pan = null;
        _loading = false;
        _notice = next.migrationReport;
      });
      old?.dispose();
    } catch (error) {
      next?.dispose();
      if (!mounted) return;
      setState(() {
        _error = '打开失败：$error';
        _loading = false;
      });
    }
  }

  void _close() {
    _world?.dispose();
    _world = null;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);
    return ColoredBox(
      color: p.bg,
      child: Column(
        children: <Widget>[
          _topBar(p),
          Container(height: 1, color: p.border),
          Expanded(
            child: Row(
              children: <Widget>[
                _sidebar(p),
                Container(width: 1, color: p.border),
                Expanded(child: _canvas(p)),
              ],
            ),
          ),
          JoStatusBar(
            left: _statusLeft(),
            right: _statusRight(),
            error: _error != null,
          ),
        ],
      ),
    );
  }

  Widget _topBar(JoPalette p) {
    final world = _world;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s3),
      color: p.surface,
      child: Row(
        children: <Widget>[
          Text(
            '新格式世界预览',
            style: JoTheme.ui(context).copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: p.text,
            ),
          ),
          const SizedBox(width: JoSpace.s2),
          Text(
            '只读',
            style: JoTheme.meta(context).copyWith(color: p.accent),
          ),
          const SizedBox(width: JoSpace.s5),
          JoButton(
            text: '打开世界目录…',
            onTap: _loading || _definitions == null ? null : _openWorld,
          ),
          const SizedBox(width: JoSpace.s2),
          JoButton(
            text: '适应窗口',
            onTap: world == null ? null : () => setState(() {
              _zoom = null;
              _pan = null;
            }),
          ),
          const Spacer(),
          if (world != null) ...<Widget>[
            Text(
              world.meta.name,
              style: JoTheme.meta(context).copyWith(color: p.text),
            ),
            const SizedBox(width: JoSpace.s4),
          ],
          JoButton(text: '关闭预览', onTap: _close),
        ],
      ),
    );
  }

  Widget _sidebar(JoPalette p) {
    final world = _world;
    return Container(
      width: 264,
      color: p.surface,
      child: ListView(
        padding: const EdgeInsets.all(JoSpace.s3),
        children: <Widget>[
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(JoSpace.s4),
              child: Text(
                '正在加载…',
                style: JoTheme.meta(context).copyWith(color: p.secondary),
              ),
            ),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: JoSpace.s3),
              padding: const EdgeInsets.all(JoSpace.s3),
              decoration: BoxDecoration(
                color: const Color(0x22C42B1C),
                border: JoShape.border(const Color(0x55C42B1C)),
                borderRadius: JoShape.br,
              ),
              child: Text(
                _error!,
                style: JoTheme.meta(context).copyWith(
                  color: const Color(0xFFC42B1C),
                ),
              ),
            ),
          if (_notice != null)
            Container(
              margin: const EdgeInsets.only(bottom: JoSpace.s3),
              padding: const EdgeInsets.all(JoSpace.s3),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.08),
                border: JoShape.border(p.border),
                borderRadius: JoShape.br,
              ),
              child: Text(
                _notice!,
                style: JoTheme.meta(context).copyWith(color: p.secondary),
              ),
            ),
          if (world == null) ...<Widget>[
            Text(
              '打开一个旧世界目录或新格式世界目录。',
              style: JoTheme.ui(context).copyWith(color: p.text, fontSize: 14),
            ),
            const SizedBox(height: JoSpace.s2),
            Text(
              '旧格式会先复制并迁移到系统临时目录，源目录不会被修改。',
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
            const SizedBox(height: JoSpace.s4),
            Text(
              'V1 只显示，不编辑。',
              style: JoTheme.meta(context).copyWith(color: p.accent),
            ),
          ] else ...<Widget>[
            _sectionTitle(p, '世界'),
            Text(
              world.meta.name,
              style: JoTheme.ui(context).copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: p.text,
              ),
            ),
            const SizedBox(height: JoSpace.s2),
            _infoRow(p, '来源', world.sourcePath ?? world.worldPath),
            _infoRow(
              p,
              '定义包',
              '${world.definitions.manifest.id} '
                  'v${world.definitions.manifest.version}',
            ),
            _infoRow(p, '块大小', '${world.meta.blockSize}'),
            _infoRow(
              p,
              '预览数据',
              world.temporaryDirectory == null ? '新格式目录' : '旧格式临时副本',
            ),
            const SizedBox(height: JoSpace.s4),
            _sectionTitle(p, '层'),
            for (final z in world.layers)
              JoListRow(
                title: '层 $z',
                subtitle: '${world.chunksByLayer[z]?.length ?? 0} 个块',
                selected: z == _layer,
                onTap: () => setState(() {
                  _layer = z;
                  _zoom = null;
                  _pan = null;
                }),
              ),
            const SizedBox(height: JoSpace.s4),
            _sectionTitle(p, '统计'),
            _infoRow(
              p,
              '块',
              '${world.chunksByLayer.values.fold<int>(0, (sum, m) => sum + m.length)}',
            ),
            _infoRow(
              p,
              '道具',
              '${world.index.propsObjects.where((e) => e.kind == 'prop').length}',
            ),
            _infoRow(
              p,
              '对象',
              '${world.index.propsObjects.where((e) => e.kind == 'object').length}',
            ),
            _infoRow(p, '传送门', '${world.index.portals.length}'),
            _infoRow(p, '传送格', '${world.meta.pads.length}'),
            _infoRow(p, '碰撞组', '${world.index.solidGroups.length}'),
            const SizedBox(height: JoSpace.s3),
            Text(
              '滚轮缩放 · 左/中/右键拖动平移',
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(JoPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: Text(
        text,
        style: JoTheme.meta(context).copyWith(
          color: p.secondary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _infoRow(JoPalette p, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: JoTheme.meta(context).copyWith(color: p.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvas(JoPalette p) {
    final world = _world;
    if (world == null) {
      return ColoredBox(
        color: p.bg,
        child: Center(
          child: Text(
            _loading ? '正在加载…' : '先打开一个世界目录',
            style: JoTheme.ui(context).copyWith(color: p.secondary),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final bounds = world.boundsFor(_layer);
        final fitScale = math
            .min(
              viewport.width / math.max(1, bounds.width + 2),
              viewport.height / math.max(1, bounds.height + 2),
            )
            .clamp(2.0, 40.0)
            .toDouble();
        final scale = _zoom ?? fitScale;
        final defaultPan = Offset(
          (viewport.width - bounds.width * scale) / 2 - bounds.minCol * scale,
          (viewport.height - bounds.height * scale) / 2 - bounds.minRow * scale,
        );
        final pan = _pan ?? defaultPan;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (PointerSignalEvent event) {
            if (event is! PointerScrollEvent) return;
            final factor = math.exp(-event.scrollDelta.dy * 0.0015);
            final newScale = (scale * factor).clamp(2.0, 120.0).toDouble();
            final cursor = event.localPosition;
            final newPan = cursor - (cursor - pan) * (newScale / scale);
            setState(() {
              _zoom = newScale;
              _pan = newPan;
            });
          },
          onPointerDown: (PointerDownEvent event) {
            if (event.buttons &
                    (kPrimaryMouseButton |
                        kMiddleMouseButton |
                        kSecondaryMouseButton) !=
                0) {
              setState(() => _dragging = true);
              _lastPointer = event.localPosition;
            }
          },
          onPointerMove: (PointerMoveEvent event) {
            if (!_dragging) return;
            final delta = event.localPosition - _lastPointer;
            _lastPointer = event.localPosition;
            setState(() => _pan = pan + delta);
          },
          onPointerUp: (PointerUpEvent event) {
            if (_dragging) setState(() => _dragging = false);
          },
          onPointerCancel: (PointerCancelEvent event) {
            if (_dragging) setState(() => _dragging = false);
          },
          child: MouseRegion(
            cursor: _dragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab,
            child: CustomPaint(
              painter: _PreviewPainter(
                world: world,
                layer: _layer,
                scale: scale,
                offset: pan,
                palette: p,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }

  String _statusLeft() {
    final world = _world;
    if (world == null) return _loading ? '正在加载…' : '未打开世界';
    final bounds = world.boundsFor(_layer);
    return '只读预览 · 层 $_layer · ${bounds.width}×${bounds.height} 格';
  }

  String _statusRight() {
    final world = _world;
    if (world == null) return 'V1';
    return '块 ${world.chunksByLayer.values.fold<int>(0, (sum, m) => sum + m.length)}'
        ' · 实体 ${world.index.propsObjects.length}'
        ' · 传送门 ${world.index.portals.length}'
        ' · 传送格 ${world.meta.pads.length}';
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.world,
    required this.layer,
    required this.scale,
    required this.offset,
    required this.palette,
  });

  final PreviewWorld world;
  final int layer;
  final double scale;
  final Offset offset;
  final JoPalette palette;

  static const List<Color> _propColors = <Color>[
    Color(0xFFD9A441),
    Color(0xFF6FA8DC),
    Color(0xFF7FB069),
    Color(0xFFA98BD6),
    Color(0xFFD96C6C),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.bg);
    final bounds = world.boundsFor(layer);
    final worldRect = Rect.fromLTWH(
      bounds.minCol * scale + offset.dx,
      bounds.minRow * scale + offset.dy,
      bounds.width * scale,
      bounds.height * scale,
    );
    canvas.drawRect(worldRect, Paint()..color = palette.surface);

    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    final terrain = world.definitions.terrain;
    final startCol = math.max(
      bounds.minCol,
      ((-offset.dx) / scale).floor() - 1,
    );
    final endCol = math.min(
      bounds.maxCol,
      ((size.width - offset.dx) / scale).ceil() + 1,
    );
    final startRow = math.max(
      bounds.minRow,
      ((-offset.dy) / scale).floor() - 1,
    );
    final endRow = math.min(
      bounds.maxRow,
      ((size.height - offset.dy) / scale).ceil() + 1,
    );

    final cellPaint = Paint();
    for (var row = startRow; row <= endRow; row++) {
      for (var col = startCol; col <= endCol; col++) {
        final code = world.terrainCodeAt(layer, col, row);
        if (code == null) continue;
        final type = terrain.byCode[code];
        if (type == null) {
          cellPaint.color = const Color(0xFF333333);
        } else {
          cellPaint.color = Color.fromARGB(
            255,
            type.color[0],
            type.color[1],
            type.color[2],
          );
        }
        canvas.drawRect(
          Rect.fromLTWH(
            col * scale,
            row * scale,
            scale + 0.5,
            scale + 0.5,
          ),
          cellPaint,
        );
      }
    }

    if (scale >= 8) {
      final gridPaint = Paint()
        ..color = palette.border.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (var col = startCol; col <= endCol + 1; col++) {
        canvas.drawLine(
          Offset(col * scale + 0.5, startRow * scale),
          Offset(col * scale + 0.5, (endRow + 1) * scale),
          gridPaint,
        );
      }
      for (var row = startRow; row <= endRow + 1; row++) {
        canvas.drawLine(
          Offset(startCol * scale, row * scale + 0.5),
          Offset((endCol + 1) * scale, row * scale + 0.5),
          gridPaint,
        );
      }
    }

    _drawSolids(canvas);
    _drawEntities(canvas);
    _drawPortals(canvas);
    _drawPads(canvas);
    _drawStart(canvas);

    canvas.restore();

    canvas.drawRect(
      worldRect,
      Paint()
        ..color = palette.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _drawSolids(Canvas canvas) {
    final fill = Paint()..color = const Color(0x33E06C75);
    final stroke = Paint()
      ..color = const Color(0xFFE06C75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final chunk in world.chunksByLayer[layer]?.values ?? const <ChunkFile>[]) {
      for (final instruction in chunk.instructions) {
        if (instruction is! SolidInstruction) continue;
        if (instruction.points.length < 3) continue;
        final path = Path();
        final first = instruction.points.first;
        path.moveTo(first.$1 * scale, first.$2 * scale);
        for (var i = 1; i < instruction.points.length; i++) {
          final point = instruction.points[i];
          path.lineTo(point.$1 * scale, point.$2 * scale);
        }
        path.close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      }
    }
  }

  void _drawEntities(Canvas canvas) {
    for (final item in world.index.propsObjects) {
      if (item.z != layer) continue;
      final Rect rect = Rect.fromLTWH(
        item.col * scale + 1.5,
        item.row * scale + 1.5,
        item.w * scale - 3,
        item.h * scale - 3,
      );
      if (item.kind == 'prop') {
        final index = world.definitions.props.indexWhere(
          (definition) => definition.id == item.type,
        );
        final color = _propColors[index < 0 ? 0 : index % _propColors.length];
        canvas.drawRect(
          rect,
          Paint()..color = color.withValues(alpha: 0.88),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      } else {
        final center = rect.center;
        final radius = math.max(2.0, math.min(rect.width, rect.height) / 2);
        final path = Path()
          ..moveTo(center.dx, center.dy - radius)
          ..lineTo(center.dx + radius, center.dy)
          ..lineTo(center.dx, center.dy + radius)
          ..lineTo(center.dx - radius, center.dy)
          ..close();
        canvas.drawPath(
          path,
          Paint()..color = const Color(0xFF7FB069).withValues(alpha: 0.9),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFF3F7A3A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      if (scale >= 12) {
        _label(
          canvas,
          item.type.length > 6 ? item.type.substring(0, 6) : item.type,
          rect.center,
          const Color(0xFF111111),
          (scale * 0.34).clamp(7.0, 12.0),
        );
      }
    }
  }

  void _drawPortals(Canvas canvas) {
    final paint = Paint()
      ..color = const Color(0xFF58B6E8)
      ..strokeWidth = math.max(2.0, scale * 0.12)
      ..strokeCap = StrokeCap.round;
    for (final portal in world.index.portals) {
      if (portal.z != layer) continue;
      final Offset start = Offset(portal.x * scale, portal.y * scale);
      final Offset end = portal.dir == 'right'
          ? Offset((portal.x + portal.length) * scale, portal.y * scale)
          : Offset(portal.x * scale, (portal.y + portal.length) * scale);
      canvas.drawLine(start, end, paint);
      canvas.drawCircle(
        start,
        math.max(2.0, scale * 0.15),
        Paint()..color = const Color(0xFF58B6E8),
      );
      if (scale >= 12) {
        _label(
          canvas,
          portal.id,
          Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2 - 8),
          const Color(0xFF58B6E8),
          (scale * 0.3).clamp(7.0, 11.0),
        );
      }
    }
  }

  void _drawPads(Canvas canvas) {
    final fill = Paint()..color = const Color(0xFFD9A441).withValues(alpha: 0.9);
    final stroke = Paint()
      ..color = const Color(0xFF8A5A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final pad in world.meta.pads) {
      if (pad.z != layer) continue;
      final center = Offset((pad.col + 0.5) * scale, (pad.row + 0.5) * scale);
      final radius = (scale * 0.32).clamp(2.0, 14.0);
      canvas.drawCircle(center, radius, fill);
      canvas.drawCircle(center, radius, stroke);
      if (scale >= 12) {
        _label(
          canvas,
          pad.id,
          center - Offset(0, radius + 7),
          const Color(0xFFD9A441),
          (scale * 0.3).clamp(7.0, 11.0),
        );
      }
    }
  }

  void _drawStart(Canvas canvas) {
    if (world.meta.start.z != layer) return;
    final center = Offset(
      (world.meta.start.col + 0.5) * scale,
      (world.meta.start.row + 0.5) * scale,
    );
    final radius = (scale * 0.45).clamp(3.0, 18.0);
    final paint = Paint()
      ..color = const Color(0xFF7FB069)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, scale * 0.12);
    canvas.drawCircle(center, radius, paint);
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      paint,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      paint,
    );
    if (scale >= 12) {
      _label(
        canvas,
        'start',
        center - Offset(0, radius + 9),
        const Color(0xFF7FB069),
        (scale * 0.3).clamp(7.0, 11.0),
      );
    }
  }

  void _label(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter oldDelegate) {
    return oldDelegate.world != world ||
        oldDelegate.layer != layer ||
        oldDelegate.scale != scale ||
        oldDelegate.offset != offset ||
        oldDelegate.palette != palette;
  }
}
