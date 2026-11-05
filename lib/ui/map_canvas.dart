import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../models/obj.dart';
import '../models/prop.dart';
import '../models/line_portal.dart';
import '../models/solid.dart';
import '../models/terrain.dart';
import '../models/world.dart';

class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.world,
    required this.terrain,
    required this.selectedSegment,
    this.level = 0,
    this.paintEnabled = true,
    required this.selectedCode,
    required this.onPaint,
    required this.onStrokeStart,
    required this.onStrokeEnd,
    this.highlight,
    this.pickMode = false,
    this.onPickCell,
    this.placedProps = const <PlacedProp>[],
    this.propTypes = const <PropType>[],
    this.propMode = false,
    this.onPropCell,
    this.placedObjects = const <PlacedObject>[],
    this.objectMode = false,
    this.onObjectCell,
    this.worldStartCol,
    this.worldStartRow,
    this.startPickMode = false,
    this.onStartCell,
    this.solids = const <SolidShape>[],
    this.solidMode = false,
    this.onSolidCell,
    this.solidDraft = const <(int, int)>[],
    this.solidSelectMode = false,
    this.onSolidSelectCell,
    this.selectedSolid = -1,
    this.padMode = false,
    this.onPadCell,
    this.selectedPlane = -1,
    this.linePortalMode = false,
    this.onLinePortalCell,
    this.selectedLinePortal = -1,
    this.linePickStart,
    this.portalEraseMode = false,
    this.onPortalEraseCell,
    this.fitEpoch = 0,
    this.onViewChanged,
  });

  final World world;
  final TerrainSet terrain;
  final int selectedSegment;
  final int level;
  final bool paintEnabled;
  final String selectedCode;
  final void Function(int col, int row) onPaint;
  final VoidCallback onStrokeStart;
  final VoidCallback onStrokeEnd;

  /// 高亮的传送门平面（画布上用强调色画出来）。
  final PortalPlane? highlight;

  /// 拾取模式：点击只回报格子坐标，不画地形。
  final bool pickMode;
  final void Function(int col, int row)? onPickCell;

  /// 已放下的道具与类型表，用于画在格子上。
  final List<PlacedProp> placedProps;
  final List<PropType> propTypes;

  /// 道具模式：点击只回报格子，由外部放置/删除道具。
  final bool propMode;
  final void Function(int col, int row)? onPropCell;

  final List<PlacedObject> placedObjects;
  final bool objectMode;
  final void Function(int col, int row)? onObjectCell;

  final int? worldStartCol;
  final int? worldStartRow;
  final bool startPickMode;
  final void Function(int col, int row)? onStartCell;

  final List<SolidShape> solids;
  final bool solidMode;
  final void Function(int col, int row)? onSolidCell;
  final List<(int, int)> solidDraft;
  final bool solidSelectMode;
  final void Function(int col, int row)? onSolidSelectCell;
  final int selectedSolid;
  final bool padMode;
  final void Function(int col, int row)? onPadCell;

  /// 当前选中的传送门平面下标；-1 表示没有。
  final int selectedPlane;

  final bool linePortalMode;
  final void Function(int col, int row)? onLinePortalCell;
  final int selectedLinePortal;
  final (int, int)? linePickStart;
  final bool portalEraseMode;
  final void Function(int col, int row)? onPortalEraseCell;

  /// 外部递增这个值就会重新进入适应窗口模式。
  final int fitEpoch;
  final void Function(double scale, double fitScale, bool fit)? onViewChanged;

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> {

  double? _scale;
  Offset _pan = Offset.zero;
  bool _fit = true;

  Size _viewport = Size.zero;
  bool _stroking = false;
  int _strokeMode = 0; // 1 地形, 2 道具, 3 对象
  bool _lineDragging = false;
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;
  bool _panning = false;
  Offset _lastPointer = Offset.zero;
  (int, int)? _hoverCell;

  @override
  void didUpdateWidget(covariant MapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.world != widget.world ||
        oldWidget.fitEpoch != widget.fitEpoch) {
      _fit = true;
      _pan = Offset.zero;
    }
  }

  int get _worldW => widget.world.maxCol - widget.world.minCol;
  int get _worldH => widget.world.maxRow - widget.world.minRow;

  double _fitScale(Size viewport) {
    final w = _worldW;
    final h = _worldH;
    if (w <= 0 || h <= 0) return 16;
    final fit = math.min(viewport.width / w, viewport.height / h);
    return fit.clamp(2.0, 32.0);
  }

  double get _minZoom => math.min(4.0, _fitScale(_viewport));
  double get _maxZoom => _fitScale(_viewport) * 20;

  double get _effectiveScale => _fit
      ? _fitScale(_viewport)
      : (_scale ?? 16).clamp(_minZoom, _maxZoom);

  Offset get _baseOffset {
    final scale = _effectiveScale;
    return Offset(
      (_viewport.width - _worldW * scale) / 2 - widget.world.minCol * scale,
      (_viewport.height - _worldH * scale) / 2 - widget.world.minRow * scale,
    );
  }

  Offset get _offset => _baseOffset + _pan;

  (int, int) _cellAt(Offset local) {
    final scale = _effectiveScale;
    final offset = _offset;
    return (
      ((local.dx - offset.dx) / scale).floor(),
      ((local.dy - offset.dy) / scale).floor(),
    );
  }

  (int, int) _cornerAt(Offset local) {
    final double sc = _effectiveScale;
    final Offset off = _offset;
    return (
      ((local.dx - off.dx) / sc).round(),
      ((local.dy - off.dy) / sc).round(),
    );
  }

  void _paintAt(Offset local) {
    final (col, row) = _cellAt(local);
    widget.onPaint(col, row);
  }

  void _zoom(PointerScrollEvent event) {
    final scale = _effectiveScale;
    final pos = event.localPosition;
    final factor = event.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
    final next = (scale * factor).clamp(_minZoom, _maxZoom);
    if (next == scale) return;

    final world = (pos - _offset) / scale;
    final nextBase = Offset(
      (_viewport.width - _worldW * next) / 2 - widget.world.minCol * next,
      (_viewport.height - _worldH * next) / 2 - widget.world.minRow * next,
    );
    setState(() {
      _scale = next;
      _fit = false;
      _pan = pos - world * next - nextBase;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);
    if (widget.world.segments.isEmpty) {
      return Center(
        child: Text(
          '这个段没有数据',
          style: JoTheme.ui(context).copyWith(color: p.secondary),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = _effectiveScale;
        final offset = _offset;
        if (widget.onViewChanged != null) {
          final double fitScale = _fitScale(_viewport);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.onViewChanged?.call(scale, fitScale, _fit);
          });
        }

        return ClipRect(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _zoom(event);
            },
            onPointerDown: (event) {
              if (event.buttons &
                      (kMiddleMouseButton | kSecondaryMouseButton) !=
                  0) {
                _panning = true;
                _lastPointer = event.localPosition;
                return;
              }
              if (event.buttons & kPrimaryMouseButton != 0) {
                if (widget.pickMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onPickCell?.call(col, row);
                  return;
                }
                if (widget.propMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  _stroking = true;
                  _strokeMode = 2;
                  widget.onStrokeStart();
                  widget.onPropCell?.call(col, row);
                  return;
                }
                if (widget.objectMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  _stroking = true;
                  _strokeMode = 3;
                  widget.onStrokeStart();
                  widget.onObjectCell?.call(col, row);
                  return;
                }
                if (widget.startPickMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onStartCell?.call(col, row);
                  return;
                }
                if (widget.solidMode) {
                  final (int cx, int cy) = _cornerAt(event.localPosition);
                  widget.onSolidCell?.call(cx, cy);
                  return;
                }
                if (widget.solidSelectMode) {
                  final (int cc, int rr) = _cellAt(event.localPosition);
                  widget.onSolidSelectCell?.call(cc, rr);
                  return;
                }
                if (widget.padMode) {
                  final (int cc, int rr) = _cellAt(event.localPosition);
                  widget.onPadCell?.call(cc, rr);
                  return;
                }
                if (widget.portalEraseMode) {
                  final (int cc, int rr) = _cellAt(event.localPosition);
                  _stroking = true;
                  _strokeMode = 4;
                  widget.onStrokeStart();
                  widget.onPortalEraseCell?.call(cc, rr);
                  return;
                }
                if (widget.linePortalMode) {
                  final (int cc, int rr) = _cornerAt(event.localPosition);
                  _lineDragging = true;
                  widget.onLinePortalCell?.call(cc, rr);
                  return;
                }
                if (!widget.paintEnabled) {
                  _marqueeStart = event.localPosition;
                  _marqueeCurrent = event.localPosition;
                  setState(() {});
                  return;
                }
                _stroking = true;
                _strokeMode = 1;
                widget.onStrokeStart();
                _paintAt(event.localPosition);
              }
            },
            onPointerMove: (event) {
              if (_panning) {
                final delta = event.localPosition - _lastPointer;
                _lastPointer = event.localPosition;
                setState(() => _pan += delta);
                return;
              }
              if (_marqueeStart != null) {
                setState(() => _marqueeCurrent = event.localPosition);
                return;
              }
              if (_lineDragging) {
                final (int c, int r) = _cornerAt(event.localPosition);
                if (_hoverCell != (c, r)) {
                  setState(() => _hoverCell = (c, r));
                }
                return;
              }
              if (!_stroking) return;
              if (_strokeMode == 1) {
                _paintAt(event.localPosition);
              } else if (_strokeMode == 2) {
                final (int c, int r) = _cellAt(event.localPosition);
                widget.onPropCell?.call(c, r);
              } else if (_strokeMode == 3) {
                final (int c, int r) = _cellAt(event.localPosition);
                widget.onObjectCell?.call(c, r);
              } else if (_strokeMode == 4) {
                final (int c, int r) = _cellAt(event.localPosition);
                widget.onPortalEraseCell?.call(c, r);
              }
            },
            onPointerUp: (event) {
              if (_marqueeStart != null) {
                setState(() {
                  _marqueeStart = null;
                  _marqueeCurrent = null;
                });
              }
              if (_lineDragging) {
                _lineDragging = false;
                final (int cc, int rr) = _cornerAt(event.localPosition);
                widget.onLinePortalCell?.call(cc, rr);
              }
              if (_stroking) {
                _stroking = false;
                widget.onStrokeEnd();
              }
              _panning = false;
            },
            onPointerCancel: (event) {
              if (_marqueeStart != null) {
                setState(() {
                  _marqueeStart = null;
                  _marqueeCurrent = null;
                });
              }
              if (_stroking) {
                _stroking = false;
                widget.onStrokeEnd();
              }
              _panning = false;
            },
            child: MouseRegion(
              cursor: widget.paintEnabled
                  ? SystemMouseCursors.precise
                  : SystemMouseCursors.basic,
              onHover: (event) {
                if (!widget.solidMode && !widget.linePortalMode) return;
                final (int c, int r) =
                    (widget.solidMode || widget.linePortalMode)
                        ? _cornerAt(event.localPosition)
                        : _cellAt(event.localPosition);
                if (_hoverCell != (c, r)) {
                  setState(() => _hoverCell = (c, r));
                }
              },
              onExit: (_) {
                if (_hoverCell != null) {
                  setState(() => _hoverCell = null);
                }
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: _WorldPainter(
                  world: widget.world,
                  terrain: widget.terrain,
                  scale: scale,
                  offset: offset,
                  background: p.bg,
                  grid: p.border,
                  border: p.border,
                  accent: p.accent,
                  selectedSegment: widget.selectedSegment,
                  level: widget.level,
                  selectedPlane: widget.selectedPlane,
                  selectedLinePortal: widget.selectedLinePortal,
                  linePickStart: widget.linePickStart,
                  propTypes: widget.propTypes,
                  worldStartCol: widget.worldStartCol,
                  worldStartRow: widget.worldStartRow,
                  solidDraft: widget.solidDraft,
                  solidHoverCell: _hoverCell,
                  marquee: _marqueeStart == null || _marqueeCurrent == null
                      ? null
                      : Rect.fromPoints(_marqueeStart!, _marqueeCurrent!),
                  selectedSolid: widget.selectedSolid,
                  accentColor: p.accent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void _drawDashedGradient(
  Canvas canvas,
  Offset a,
  Offset b,
  Color from,
  Color to,
) {
  final double dx = b.dx - a.dx;
  final double dy = b.dy - a.dy;
  final double len = math.sqrt(dx * dx + dy * dy);
  if (len <= 0) return;

  const double dash = 6;
  const double gap = 4;
  final double ux = dx / len;
  final double uy = dy / len;
  final Paint paint = Paint()..strokeWidth = 1;

  double t = 0;
  while (t < len) {
    final double end = math.min(t + dash, len);
    paint.color = Color.lerp(from, to, (t / len).clamp(0.0, 1.0))!;
    canvas.drawLine(
      Offset(a.dx + ux * t, a.dy + uy * t),
      Offset(a.dx + ux * end, a.dy + uy * end),
      paint,
    );
    t = end + gap;
  }
}

void _drawDashed(Canvas canvas, Offset a, Offset b, Color color) {
  final double dx = b.dx - a.dx;
  final double dy = b.dy - a.dy;
  final double len = math.sqrt(dx * dx + dy * dy);
  if (len <= 0) return;

  const double dash = 6;
  const double gap = 4;
  final double ux = dx / len;
  final double uy = dy / len;
  final Paint paint = Paint()
    ..color = color
    ..strokeWidth = 1;

  double t = 0;
  while (t < len) {
    final double end = math.min(t + dash, len);
    canvas.drawLine(
      Offset(a.dx + ux * t, a.dy + uy * t),
      Offset(a.dx + ux * end, a.dy + uy * end),
      paint,
    );
    t = end + gap;
  }
}

const List<Color> _kPropColors = <Color>[
  Color(0xFFD9A441),
  Color(0xFF6FA8DC),
  Color(0xFF7FB069),
  Color(0xFFA98BD6),
  Color(0xFFD96C6C),
];

Color _propColor(int index, Color fallback) =>
    index >= 0 && index < _kPropColors.length ? _kPropColors[index] : fallback;

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.segment,
    required this.terrain,
    required this.scale,
    required this.offset,
    required this.background,
    required this.grid,
    required this.border,
    required this.accent,
    required this.highlight,
    required this.placedProps,
    required this.propTypes,
    required this.placedObjects,
    required this.worldStartCol,
    required this.worldStartRow,
    required this.solids,
    required this.solidDraft,
    required this.solidHoverCell,
    required this.selectedSolid,
    required this.accentColor,
    this.drawBackground = true,
  });

  final Segment segment;
  final TerrainSet terrain;
  final double scale;
  final Offset offset;
  final Color background;
  final Color grid;
  final Color border;
  final Color accent;
  final PortalPlane? highlight;
  final List<PlacedProp> placedProps;
  final List<PropType> propTypes;
  final List<PlacedObject> placedObjects;
  final int? worldStartCol;
  final int? worldStartRow;
  final List<SolidShape> solids;
  final List<(int, int)> solidDraft;
  final (int, int)? solidHoverCell;
  final int selectedSolid;
  final Color accentColor;
  final bool drawBackground;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawBackground) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background);
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    final paint = Paint();
    for (var row = 0; row < segment.height; row++) {
      for (var col = 0; col < segment.width; col++) {
        final code = segment.charAt(col, row);
        final type = terrain.byCode[code] ?? terrain.fallback;
        paint.color = Color(type.color);
        canvas.drawRect(
          Rect.fromLTWH(col * scale, row * scale, scale, scale),
          paint,
        );
      }
    }

    if (scale >= 6) {
      final gridPaint = Paint()
        ..color = grid
        ..strokeWidth = 1;
      for (var col = 0; col <= segment.width; col++) {
        canvas.drawLine(
          Offset(col * scale + 0.5, 0),
          Offset(col * scale + 0.5, segment.height * scale),
          gridPaint,
        );
      }
      for (var row = 0; row <= segment.height; row++) {
        canvas.drawLine(
          Offset(0, row * scale + 0.5),
          Offset(segment.width * scale, row * scale + 0.5),
          gridPaint,
        );
      }
    }

    for (final PlacedProp prop in placedProps) {
      final int index = propTypes.indexWhere((t) => t.id == prop.id);
      final Color color = _propColor(index < 0 ? 0 : index, accent);
      final Rect rect = Rect.fromLTWH(
        prop.col * scale + 1.5,
        prop.row * scale + 1.5,
        scale - 3,
        scale - 3,
      );
      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.85));
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      if (scale >= 12) {
        final TextPainter tp = TextPainter(
          text: TextSpan(
            text: prop.id.length > 2 ? prop.id.substring(0, 2) : prop.id,
            style: TextStyle(
              color: const Color(0xFF111111),
              fontSize: (scale * 0.4).clamp(7.0, 14.0),
              fontFamily: 'packages/jo_draftui/NotoSansSC',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          rect.center - Offset(tp.width / 2, tp.height / 2),
        );
      }
    }

    for (final PlacedObject obj in placedObjects) {
      final Offset center = Offset(
        (obj.col + 0.5) * scale,
        (obj.row + 0.5) * scale,
      );
      final double r = (scale - 6).clamp(2.0, 20.0);
      final Path diamond = Path()
        ..moveTo(center.dx, center.dy - r)
        ..lineTo(center.dx + r, center.dy)
        ..lineTo(center.dx, center.dy + r)
        ..lineTo(center.dx - r, center.dy)
        ..close();
      canvas.drawPath(diamond, Paint()..color = const Color(0xFF7FB069).withValues(alpha: 0.9));
      canvas.drawPath(
        diamond,
        Paint()
          ..color = const Color(0xFF3F7A3A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (scale >= 14) {
        final TextPainter tp = TextPainter(
          text: TextSpan(
            text: obj.id.length > 2 ? obj.id.substring(0, 2) : obj.id,
            style: TextStyle(
              color: const Color(0xFF111111),
              fontSize: (scale * 0.32).clamp(6.0, 11.0),
              fontFamily: 'packages/jo_draftui/NotoSansSC',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
      }
    }

    if (solidDraft.isNotEmpty) {
      final Paint draftPaint = Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final Path draftPath = Path();
      for (int i = 0; i < solidDraft.length; i++) {
        final Offset o = Offset(
          solidDraft[i].$1 * scale,
          solidDraft[i].$2 * scale,
        );
        if (i == 0) {
          draftPath.moveTo(o.dx, o.dy);
        } else {
          draftPath.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(draftPath, draftPaint);

      for (final (int px, int py) in solidDraft) {
        final Offset o = Offset(px * scale, py * scale);
        canvas.drawRect(
          Rect.fromCenter(center: o, width: 6, height: 6),
          Paint()..color = accentColor,
        );
      }

      final (int, int)? hoverLocal = solidHoverCell == null
          ? null
          : (
              solidHoverCell!.$1 - segment.spec.originCol,
              solidHoverCell!.$2 - segment.spec.originRow,
            );
      if (hoverLocal != null) {
        final (int hc, int hr) = hoverLocal;
        final Offset hover = Offset(hc * scale, hr * scale);
        final Offset last = Offset(
          solidDraft.last.$1 * scale,
          solidDraft.last.$2 * scale,
        );
        canvas.drawLine(last, hover, draftPaint);
        if (solidDraft.length >= 3) {
          final Offset first = Offset(
            solidDraft.first.$1 * scale,
            solidDraft.first.$2 * scale,
          );
          canvas.drawLine(
            hover,
            first,
            Paint()
              ..color = accentColor.withValues(alpha: 0.4)
              ..strokeWidth = 1,
          );
        }
      }
    }

    for (int si = 0; si < solids.length; si++) {
      final SolidShape solid = solids[si];
      final bool sel = si == selectedSolid;
      final Paint line = Paint()
        ..color = sel ? accentColor : const Color(0xFFD96C6C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = sel ? 3 : 2;
      final Path path = Path();
      for (int i = 0; i < solid.points.length; i++) {
        final (int px, int py) = solid.points[i];
        final Offset o = Offset(px * scale, py * scale);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();
      canvas.drawPath(path, line);
    }

    final int? sc = worldStartCol;
    final int? sr = worldStartRow;
    if (sc != null && sr != null) {
      final int lc = sc - segment.spec.originCol;
      final int lr = sr - segment.spec.originRow;
      if (lc >= 0 && lc < segment.width && lr >= 0 && lr < segment.height) {
        final Offset c = Offset((lc + 0.5) * scale, (lr + 0.5) * scale);
        final Paint ring = Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawCircle(c, (scale * 0.32).clamp(4.0, 12.0), ring);
        final double r = (scale * 0.12).clamp(2.0, 5.0);
        canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), ring);
        canvas.drawLine(c - Offset(0, r), c + Offset(0, r), ring);
      }
    }

    canvas.drawRect(
      Rect.fromLTWH(0, 0, segment.width * scale, segment.height * scale),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final plane = highlight;
    if (plane != null) {
      final linePaint = Paint()
        ..color = accent
        ..strokeWidth = 2;
      final bool horizontal = plane.axis == 'x';
      final Offset a = horizontal
          ? Offset(plane.at * scale, plane.from * scale)
          : Offset(plane.from * scale, plane.at * scale);
      final Offset b = horizontal
          ? Offset(plane.at * scale, plane.to * scale)
          : Offset(plane.to * scale, plane.at * scale);
      canvas.drawLine(a, b, linePaint);

      // 方向箭头：画在线的中点。
      final Offset mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final bool positive = plane.direction == '+';
      final double sign = positive ? 1 : -1;
      final Path arrow = Path();
      const double s6 = 6;
      if (horizontal) {
        arrow.moveTo(mid.dx + sign * s6, mid.dy);
        arrow.lineTo(mid.dx - sign * s6, mid.dy - s6);
        arrow.lineTo(mid.dx - sign * s6, mid.dy + s6);
      } else {
        arrow.moveTo(mid.dx, mid.dy + sign * s6);
        arrow.lineTo(mid.dx - s6, mid.dy - sign * s6);
        arrow.lineTo(mid.dx + s6, mid.dy - sign * s6);
      }
      arrow.close();
      canvas.drawPath(arrow, Paint()..color = accent);

      // 出口：目标位置的那条线，虚线画。
      final Offset dstA = horizontal
          ? Offset(
              (plane.at + plane.dx) * scale,
              (plane.from + plane.dy) * scale,
            )
          : Offset(
              (plane.from + plane.dx) * scale,
              (plane.at + plane.dy) * scale,
            );
      final Offset dstB = horizontal
          ? Offset((plane.at + plane.dx) * scale, (plane.to + plane.dy) * scale)
          : Offset(
              (plane.to + plane.dx) * scale,
              (plane.at + plane.dy) * scale,
            );

      _drawDashed(canvas, dstA, dstB, accent.withValues(alpha: 0.55));
      _drawDashed(
        canvas,
        mid,
        Offset((dstA.dx + dstB.dx) / 2, (dstA.dy + dstB.dy) / 2),
        accent.withValues(alpha: 0.25),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => true;
}


/// 多段合成：每段用原来的单段画笔按自己的 origin 平移绘制。
class _WorldPainter extends CustomPainter {
  _WorldPainter({
    required this.world,
    required this.terrain,
    required this.scale,
    required this.offset,
    required this.background,
    required this.grid,
    required this.border,
    required this.accent,
    required this.selectedSegment,
    required this.level,
    required this.selectedPlane,
    required this.selectedLinePortal,
    required this.linePickStart,
    required this.propTypes,
    required this.worldStartCol,
    required this.worldStartRow,
    required this.solidDraft,
    required this.solidHoverCell,
    required this.marquee,
    required this.selectedSolid,
    required this.accentColor,
  });

  final World world;
  final TerrainSet terrain;
  final double scale;
  final Offset offset;
  final Color background;
  final Color grid;
  final Color border;
  final Color accent;
  final int selectedSegment;
  final int level;
  final int selectedPlane;
  final int selectedLinePortal;
  final (int, int)? linePickStart;
  final List<PropType> propTypes;
  final int? worldStartCol;
  final int? worldStartRow;
  final List<(int, int)> solidDraft;
  final (int, int)? solidHoverCell;
  final Rect? marquee;
  final int selectedSolid;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    // 按 z 从小到大绘制：-1 在下，1 在上。
    final List<(Segment, int)> ordered = <(Segment, int)>[
      for (int i = 0; i < world.segments.length; i++)
        (world.segments[i], i),
    ]..sort((a, b) => a.$1.spec.originZ.compareTo(b.$1.spec.originZ));

    for (final (Segment seg, int i) in ordered) {
      if (seg.spec.originZ == level) {
        _paintSegment(canvas, size, seg, i == selectedSegment);
      } else {
        canvas.saveLayer(
          Offset.zero & size,
          Paint()..color = const Color(0x33FFFFFF),
        );
        _paintSegment(canvas, size, seg, false);
        canvas.restore();
      }
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    _paintLinePortals(canvas);
    _paintPortalLinks(canvas);
    _paintLineDraft(canvas);
    canvas.restore();

    final Rect? box = marquee;
    if (box != null) {
      canvas.drawRect(
        box,
        Paint()..color = accentColor.withValues(alpha: 0.15),
      );
      canvas.drawRect(
        box,
        Paint()
          ..color = accentColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _paintSegment(Canvas canvas, Size size, Segment seg, bool selected) {
    _MapPainter(
      segment: seg,
      terrain: terrain,
      scale: scale,
      offset: offset +
          Offset(seg.spec.originCol * scale, seg.spec.originRow * scale),
      background: background,
      grid: grid,
      border: border,
      accent: accent,
      highlight: null,
      placedProps: parsePlacedProps(seg.instructions),
      propTypes: propTypes,
      placedObjects: parsePlacedObjects(seg.instructions),
      worldStartCol: worldStartCol,
      worldStartRow: worldStartRow,
      solids: parseSolids(seg.instructions),
      solidDraft: selected ? solidDraft : const <(int, int)>[],
      solidHoverCell: selected ? solidHoverCell : null,
      selectedSolid: selected ? selectedSolid : -1,
      accentColor: accentColor,
      drawBackground: false,
    ).paint(canvas, size);
  }

  void _paintLineDraft(Canvas canvas) {
    final (int, int)? start = linePickStart;
    final (int, int)? hover = solidHoverCell;
    if (start == null || hover == null) return;
    if (selectedSegment < 0 || selectedSegment >= world.segments.length) return;
    final Segment seg = world.segments[selectedSegment];
    final int sc = seg.spec.originCol + start.$1;
    final int sr = seg.spec.originRow + start.$2;
    final int hc = hover.$1;
    final int hr = hover.$2;
    final int dc = hc - sc;
    final int dr = hr - sr;
    final int x1;
    final int y1;
    final int x2;
    final int y2;
    if (dc.abs() >= dr.abs()) {
      x1 = sc < hc ? sc : hc;
      y1 = sr;
      x2 = sc > hc ? sc : hc;
      y2 = sr;
    } else {
      x1 = sc;
      y1 = sr < hr ? sr : hr;
      x2 = sc;
      y2 = sr > hr ? sr : hr;
    }
    final bool valid = x2 <= seg.spec.originCol + seg.width &&
        y2 <= seg.spec.originRow + seg.height &&
        (x2 != x1 || y2 != y1);
    final Offset a = Offset(x1 * scale, y1 * scale);
    final Offset b = Offset(x2 * scale, y2 * scale);
    _drawDashed(
      canvas,
      a,
      b,
      valid
          ? const Color(0xFFFFFFFF).withValues(alpha: 0.6)
          : const Color(0xFFD96C6C),
    );
  }

  void _paintLinePortals(Canvas canvas) {
    for (int i = 0; i < world.segments.length; i++) {
      final Segment seg = world.segments[i];
      final List<LinePortal> portals = parseLinePortals(seg.instructions);
      for (int j = 0; j < portals.length; j++) {
        final LinePortal portal = portals[j];
        final bool selected = i == selectedSegment && j == selectedLinePortal;
        final double x1 = (seg.spec.originCol + portal.x) * scale;
        final double y1 = (seg.spec.originRow + portal.y) * scale;
        final double x2 = (seg.spec.originCol + portal.endX) * scale;
        final double y2 = (seg.spec.originRow + portal.endY) * scale;
        canvas.drawLine(
          Offset(x1, y1),
          Offset(x2, y2),
          Paint()
            ..color = selected
                ? const Color(0xFFFFFFFF)
                : const Color(0xFF8ECAE6)
            ..strokeWidth = selected ? 3 : 2,
        );
      }
    }
  }

  (LinePortal, Segment)? _findPortal(String ref) {
    final int slash = ref.indexOf('/');
    if (slash <= 0) return null;
    final String segId = ref.substring(0, slash);
    final String portalId = ref.substring(slash + 1);
    for (final Segment seg in world.segments) {
      if (seg.spec.id != segId) continue;
      for (final LinePortal p in parseLinePortals(seg.instructions)) {
        if (p.id == portalId) return (p, seg);
      }
    }
    return null;
  }

  /// 起点侧：A 面 = 左/上，B 面 = 右/下。
  Offset _portalFace(LinePortal p, Segment seg, bool aFace) {
    final double x = p.horizontal
        ? (seg.spec.originCol + (aFace ? p.x : p.endX)) * scale
        : (seg.spec.originCol + p.x) * scale;
    final double y = p.horizontal
        ? (seg.spec.originRow + p.y) * scale
        : (seg.spec.originRow + (aFace ? p.y : p.endY)) * scale;
    return Offset(x, y);
  }

  /// 终点侧：A 面 = 右/下，B 面 = 左/上。
  Offset _portalEndFace(LinePortal p, Segment seg, bool aFace) {
    final double x = p.horizontal
        ? (seg.spec.originCol + (aFace ? p.endX : p.x)) * scale
        : (seg.spec.originCol + p.x) * scale;
    final double y = p.horizontal
        ? (seg.spec.originRow + p.y) * scale
        : (seg.spec.originRow + (aFace ? p.endY : p.y)) * scale;
    return Offset(x, y);
  }

  void _paintPortalLinks(Canvas canvas) {
    for (final dynamic raw in (world.raw['portal_links'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final String? from = raw['from']?.toString();
      final String? to = raw['to']?.toString();
      if (from == null || to == null) continue;
      final (LinePortal, Segment)? a = _findPortal(from);
      final (LinePortal, Segment)? b = _findPortal(to);
      if (a == null || b == null) continue;
      final String face = raw['face']?.toString() ?? 'A';
      final List<bool> sides = switch (face) {
        'B' => const [false],
        'both' => const [true, false],
        _ => const [true],
      };
      for (final bool aSide in sides) {
        final Offset from = _portalFace(a.$1, a.$2, aSide);
        final Offset to = _portalEndFace(b.$1, b.$2, !aSide);
        final Color blue = const Color(0xFF6FA8DC).withValues(alpha: 0.7);
        final Color yellow = const Color(0xFFDCC06E).withValues(alpha: 0.7);
        _drawDashedGradient(canvas, from, to, blue, yellow);
        final Offset d = to - from;
        if (d.distance > 20) {
          final Offset mid = (from + to) / 2;
          final Offset u = d / d.distance;
          _drawArrowHead(
            canvas,
            mid - u * 20,
            mid,
            Color.lerp(blue, yellow, 0.5)!,
          );
        }
        _drawFaceArrow(canvas, a.$1, a.$2, aSide, blue);
        _drawExitFaceArrow(
          canvas,
          b.$1,
          b.$2,
          !aSide,
          const Color(0xFFDCC06E).withValues(alpha: 0.7),
        );
      }
    }
  }

  /// 起点箭头：A 面在左/上端点外侧，B 面在右/下端点外侧，箭头指向端点。
  void _drawFaceArrow(
    Canvas canvas,
    LinePortal p,
    Segment seg,
    bool aFace,
    Color color,
  ) {
    final Offset tip = _portalFace(p, seg, aFace);
    const double gap = 20;
    final Offset from = p.horizontal
        ? tip + Offset(0, aFace ? -gap : gap)
        : tip + Offset(aFace ? -gap : gap, 0);
    canvas.drawLine(
      from,
      tip,
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
    _drawArrowHead(canvas, from, tip, color);
  }

  /// 出口箭头：起点箭头的反面，指向传送门外面。
  void _drawExitFaceArrow(
    Canvas canvas,
    LinePortal p,
    Segment seg,
    bool aFace,
    Color color,
  ) {
    final Offset tip = _portalEndFace(p, seg, aFace);
    const double gap = 20;
    final Offset out = p.horizontal
        ? Offset(0, aFace ? -1 : 1)
        : Offset(aFace ? -1 : 1, 0);
    final Offset start = tip;
    final Offset end = tip + out * gap;
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
    _drawArrowHead(canvas, start, end, color);
  }

  void _drawArrowHead(Canvas canvas, Offset from, Offset to, Color color) {
    final Offset d = to - from;
    final double len = d.distance;
    if (len < 10) return;
    final Offset u = d / len;
    final Offset tip = to - u * 2;
    const double size = 8;
    final Offset left = tip -
        u * size +
        Offset(-u.dy, u.dx) * (size * 0.55);
    final Offset right = tip -
        u * size -
        Offset(-u.dy, u.dx) * (size * 0.55);
    final Paint stroke = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(tip, left, stroke);
    canvas.drawLine(tip, right, stroke);
  }

  @override
  bool shouldRepaint(covariant _WorldPainter old) => true;
}
