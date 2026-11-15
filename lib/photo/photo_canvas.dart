import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'develop_renderer.dart';
import 'develop_settings.dart';

enum CanvasMode { view, crop, mask, heal }

enum _CropHandle { none, move, tl, tr, bl, br, l, t, r, b }

/// The zoomable photo view plus the on-image editing overlays.
///
/// Interactive tools mutate [settings] in place and report through
/// [onLive] (while dragging) and [onCommit] (gesture finished).
class PhotoCanvas extends StatefulWidget {
  final DevelopAssets assets;
  final DevelopSettings settings;
  final ui.FragmentShader shader;
  final CanvasMode mode;
  final int maskIndex;
  final bool showMaskOverlay;
  final double brushRadius;
  final bool brushErase;
  final int spotIndex;
  final double spotRadius;
  final void Function(String what) onLive;
  final void Function(String what) onCommit;
  final ValueChanged<int> onSelectSpot;

  const PhotoCanvas({
    super.key,
    required this.assets,
    required this.settings,
    required this.shader,
    required this.mode,
    required this.onLive,
    required this.onCommit,
    required this.onSelectSpot,
    this.maskIndex = -1,
    this.showMaskOverlay = false,
    this.brushRadius = 0.05,
    this.brushErase = false,
    this.spotIndex = -1,
    this.spotRadius = 0.03,
  });

  @override
  State<PhotoCanvas> createState() => _PhotoCanvasState();
}

class _PhotoCanvasState extends State<PhotoCanvas> {
  final _zoom = TransformationController();
  final _pointers = <int>{};
  Size _view = Size.zero;

  // Active drag state.
  bool _dragging = false;
  _CropHandle _cropHandle = _CropHandle.none;
  Rect _cropStart = Rect.zero;
  Offset _dragStart = Offset.zero;
  int _maskHandle = -1; // linear: 0/1 = end points. radial: 0 centre, 1 rx, 2 ry
  List<double> _geoStart = const [];
  int _spotHandle = -1; // 0 = destination, 1 = source
  BrushStroke? _stroke;

  DevelopSettings get s => widget.settings;
  Size get _image =>
      Size(widget.assets.base.width.toDouble(), widget.assets.base.height.toDouble());

  @override
  void didUpdateWidget(PhotoCanvas old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode && widget.mode == CanvasMode.crop) {
      _zoom.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- layout

  Size get _content => widget.mode == CanvasMode.crop
      ? Geo.oriented(_image, s.turns)
      : Geo.outputSize(_image, s);

  double get _pad => widget.mode == CanvasMode.crop ? 30 : 10;

  double get _fit {
    final c = _content;
    return math.min((_view.width - _pad * 2) / c.width, (_view.height - _pad * 2) / c.height);
  }

  Offset get _origin {
    final c = _content, f = _fit;
    return Offset((_view.width - c.width * f) / 2, (_view.height - c.height * f) / 2);
  }

  double get _zoomScale => _zoom.value.getMaxScaleOnAxis();

  /// View position → image-normalised coordinates.
  Offset _toImage(Offset local) {
    final content = (local - _origin) / _fit;
    final m = widget.mode == CanvasMode.crop
        ? Geo.imageToFrame(_image, s)
        : Geo.imageToOutput(_image, s);
    final p = MatrixUtils.transformPoint(Matrix4.inverted(m), content);
    return Offset(p.dx / _image.width, p.dy / _image.height);
  }

  Offset _toView(Offset imageNorm) {
    final m = widget.mode == CanvasMode.crop
        ? Geo.imageToFrame(_image, s)
        : Geo.imageToOutput(_image, s);
    final p = MatrixUtils.transformPoint(
        m, Offset(imageNorm.dx * _image.width, imageNorm.dy * _image.height));
    return _origin + p * _fit;
  }

  /// Image px → view px scale (uniform).
  double get _pxScale => _fit * Geo.coverScale(Geo.oriented(_image, s.turns), s.straighten);

  // ---------------------------------------------------------------- pointer

  void _down(PointerDownEvent e) {
    _pointers.add(e.pointer);
    if (_pointers.length > 1) {
      _cancel();
      return;
    }
    final p = e.localPosition;
    _dragStart = p;
    switch (widget.mode) {
      case CanvasMode.view:
        break;
      case CanvasMode.crop:
        _cropHandle = _hitCrop(p);
        _cropStart = s.crop;
        _dragging = _cropHandle != _CropHandle.none;
      case CanvasMode.mask:
        _maskDown(p);
      case CanvasMode.heal:
        _healDown(p);
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_dragging || _pointers.length != 1) return;
    final p = e.localPosition;
    switch (widget.mode) {
      case CanvasMode.view:
        break;
      case CanvasMode.crop:
        _cropMove(p);
        widget.onLive('crop');
      case CanvasMode.mask:
        _maskMove(p);
      case CanvasMode.heal:
        _healMove(p);
    }
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (!_dragging) return;
    _dragging = false;
    switch (widget.mode) {
      case CanvasMode.view:
        break;
      case CanvasMode.crop:
        widget.onCommit('crop');
      case CanvasMode.mask:
        widget.onCommit(_stroke != null ? 'stroke' : 'mask');
        _stroke = null;
      case CanvasMode.heal:
        widget.onCommit('spots');
    }
  }

  /// A second finger landed: abandon the one-finger edit so pinch can zoom.
  void _cancel() {
    if (!_dragging) return;
    _dragging = false;
    if (widget.mode == CanvasMode.crop) {
      s.crop = _cropStart;
      widget.onLive('crop');
    } else if (_stroke != null) {
      s.masks[widget.maskIndex].strokes.remove(_stroke);
      _stroke = null;
      widget.onLive('stroke');
    }
  }

  // ---------------------------------------------------------------- crop

  Offset _frameNorm(Offset local) {
    final f = Geo.oriented(_image, s.turns);
    final c = (local - _origin) / _fit;
    return Offset(c.dx / f.width, c.dy / f.height);
  }

  _CropHandle _hitCrop(Offset p) {
    final f = Geo.oriented(_image, s.turns);
    Offset v(double x, double y) => _origin + Offset(x * f.width, y * f.height) * _fit;
    final c = s.crop;
    const reach = 30.0;
    final corners = {
      _CropHandle.tl: v(c.left, c.top),
      _CropHandle.tr: v(c.right, c.top),
      _CropHandle.bl: v(c.left, c.bottom),
      _CropHandle.br: v(c.right, c.bottom),
    };
    for (final e in corners.entries) {
      if ((e.value - p).distance < reach) return e.key;
    }
    final rect = Rect.fromPoints(v(c.left, c.top), v(c.right, c.bottom));
    if (!rect.inflate(reach).contains(p)) return _CropHandle.none;
    if ((p.dx - rect.left).abs() < reach * 0.7) return _CropHandle.l;
    if ((p.dx - rect.right).abs() < reach * 0.7) return _CropHandle.r;
    if ((p.dy - rect.top).abs() < reach * 0.7) return _CropHandle.t;
    if ((p.dy - rect.bottom).abs() < reach * 0.7) return _CropHandle.b;
    return rect.contains(p) ? _CropHandle.move : _CropHandle.none;
  }

  void _cropMove(Offset local) {
    const minSize = 0.06;
    final f = Geo.oriented(_image, s.turns);
    final p = _frameNorm(local);
    final st = _cropStart;
    final h = _cropHandle;
    if (h == _CropHandle.move) {
      final d = p - _frameNorm(_dragStart);
      final dx = d.dx.clamp(-st.left, 1 - st.right);
      final dy = d.dy.clamp(-st.top, 1 - st.bottom);
      s.crop = st.shift(Offset(dx, dy));
      return;
    }
    final px = p.dx.clamp(0.0, 1.0), py = p.dy.clamp(0.0, 1.0);
    final left = h == _CropHandle.tl || h == _CropHandle.bl || h == _CropHandle.l;
    final right = h == _CropHandle.tr || h == _CropHandle.br || h == _CropHandle.r;
    final top = h == _CropHandle.tl || h == _CropHandle.tr || h == _CropHandle.t;
    final bottom = h == _CropHandle.bl || h == _CropHandle.br || h == _CropHandle.b;
    final aspect = s.aspect;
    if (aspect == null) {
      var l = st.left, t = st.top, r = st.right, b = st.bottom;
      if (left) l = math.min(px, r - minSize);
      if (right) r = math.max(px, l + minSize);
      if (top) t = math.min(py, b - minSize);
      if (bottom) b = math.max(py, t + minSize);
      s.crop = Rect.fromLTRB(l, t, r, b);
      return;
    }
    // Locked ratio, expressed in normalised units.
    final an = aspect * f.height / f.width;
    if ((left || right) && (top || bottom)) {
      final ax = left ? st.right : st.left, ay = top ? st.bottom : st.top;
      var w = math.max((px - ax).abs(), (py - ay).abs() * an);
      w = math.max(w, minSize);
      var hgt = w / an;
      final maxW = left ? ax : 1 - ax, maxH = top ? ay : 1 - ay;
      final k = math.min(1.0, math.min(maxW / w, maxH / hgt));
      w *= k;
      hgt *= k;
      s.crop = Rect.fromLTRB(left ? ax - w : ax, top ? ay - hgt : ay, left ? ax : ax + w, top ? ay : ay + hgt);
    } else if (left || right) {
      final ax = left ? st.right : st.left, cy = st.center.dy;
      var w = math.max((px - ax).abs(), minSize);
      var hgt = w / an;
      final k = math.min(1.0, 2 * math.min(cy, 1 - cy) / hgt);
      w *= k;
      hgt *= k;
      s.crop = Rect.fromLTRB(left ? ax - w : ax, cy - hgt / 2, left ? ax : ax + w, cy + hgt / 2);
    } else {
      final ay = top ? st.bottom : st.top, cx = st.center.dx;
      var hgt = math.max((py - ay).abs(), minSize);
      var w = hgt * an;
      final k = math.min(1.0, 2 * math.min(cx, 1 - cx) / w);
      w *= k;
      hgt *= k;
      s.crop = Rect.fromLTRB(cx - w / 2, top ? ay - hgt : ay, cx + w / 2, top ? ay : ay + hgt);
    }
  }

  // ---------------------------------------------------------------- masks

  PhotoMask? get _mask =>
      widget.maskIndex >= 0 && widget.maskIndex < s.masks.length ? s.masks[widget.maskIndex] : null;

  List<Offset> _maskHandles(PhotoMask m) {
    final g = m.geo;
    if (m.type == MaskType.linear) {
      return [_toView(Offset(g[0], g[1])), _toView(Offset(g[2], g[3]))];
    }
    final ar = _image.width / _image.height;
    return [
      _toView(Offset(g[0], g[1])),
      _toView(Offset(g[0] + g[2], g[1])),
      _toView(Offset(g[0], g[1] + g[3] * ar)),
    ];
  }

  void _maskDown(Offset p) {
    final m = _mask;
    if (m == null) return;
    if (m.usesTexture) {
      final q = _toImage(p);
      _stroke = BrushStroke([q.dx, q.dy], widget.brushRadius, widget.brushErase);
      m.strokes.add(_stroke!);
      _dragging = true;
      widget.onLive('stroke');
      return;
    }
    final handles = _maskHandles(m);
    _maskHandle = -1;
    var best = 36.0 / _zoomScale;
    for (var i = 0; i < handles.length; i++) {
      final d = (handles[i] - p).distance;
      if (d < best) {
        best = d;
        _maskHandle = i;
      }
    }
    _geoStart = [...m.geo];
    // Dragging anywhere else moves the whole mask.
    _dragging = true;
  }

  void _maskMove(Offset p) {
    final m = _mask;
    if (m == null) return;
    final q = _toImage(p);
    if (_stroke != null) {
      final pts = _stroke!.pts;
      final last = Offset(pts[pts.length - 2], pts[pts.length - 1]);
      if ((q - last).distance > 0.003) {
        pts
          ..add(q.dx)
          ..add(q.dy);
        widget.onLive('stroke');
      }
      return;
    }
    final g = m.geo;
    if (m.type == MaskType.linear) {
      if (_maskHandle == 0) {
        g[0] = q.dx;
        g[1] = q.dy;
      } else if (_maskHandle == 1) {
        g[2] = q.dx;
        g[3] = q.dy;
      } else {
        final d = q - _toImage(_dragStart);
        g[0] = _geoStart[0] + d.dx;
        g[1] = _geoStart[1] + d.dy;
        g[2] = _geoStart[2] + d.dx;
        g[3] = _geoStart[3] + d.dy;
      }
    } else {
      final ar = _image.width / _image.height;
      if (_maskHandle == 1) {
        g[2] = math.max(0.02, (q - Offset(g[0], g[1])).dx.abs());
      } else if (_maskHandle == 2) {
        g[3] = math.max(0.02, (q.dy - g[1]).abs() / ar);
      } else {
        final d = q - _toImage(_dragStart);
        g[0] = _geoStart[0] + d.dx;
        g[1] = _geoStart[1] + d.dy;
      }
    }
    widget.onLive('mask');
  }

  // ---------------------------------------------------------------- healing

  void _healDown(Offset p) {
    final reach = 30.0 / _zoomScale;
    _spotHandle = -1;
    for (var i = s.spots.length - 1; i >= 0; i--) {
      final sp = s.spots[i];
      final rv = math.max(sp.r * _image.width * _pxScale, reach);
      if ((_toView(Offset(sp.sx, sp.sy)) - p).distance < rv) {
        widget.onSelectSpot(i);
        _spotHandle = 1;
        _dragging = true;
        return;
      }
      if ((_toView(Offset(sp.dx, sp.dy)) - p).distance < rv) {
        widget.onSelectSpot(i);
        _spotHandle = 0;
        _dragging = true;
        return;
      }
    }
    final q = _toImage(p);
    if (q.dx < 0 || q.dx > 1 || q.dy < 0 || q.dy > 1) return;
    // New spot: sample from just beside it, staying inside the image.
    final r = widget.spotRadius;
    final ar = _image.width / _image.height;
    var sx = q.dx + r * 2.4;
    if (sx + r > 1) sx = q.dx - r * 2.4;
    final sy = q.dy.clamp(r * ar, 1 - r * ar);
    s.spots.add(HealSpot(q.dx, q.dy, sx, sy, r));
    widget.onSelectSpot(s.spots.length - 1);
    _spotHandle = 0;
    _dragging = true;
    widget.onLive('spots');
  }

  void _healMove(Offset p) {
    final i = widget.spotIndex;
    if (i < 0 || i >= s.spots.length) return;
    final sp = s.spots[i];
    final q = _toImage(p);
    final x = q.dx.clamp(0.0, 1.0), y = q.dy.clamp(0.0, 1.0);
    if (_spotHandle == 1) {
      sp.sx = x;
      sp.sy = y;
    } else {
      sp.sx += x - sp.dx;
      sp.sy += y - sp.dy;
      sp.dx = x;
      sp.dy = y;
    }
    widget.onLive('spots');
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _view = box.biggest;
      final viewing = widget.mode == CanvasMode.view;
      return ClipRect(
        child: InteractiveViewer(
          transformationController: _zoom,
          minScale: 1,
          maxScale: 8,
          panEnabled: viewing,
          scaleEnabled: widget.mode != CanvasMode.crop,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: AnimatedBuilder(
              animation: _zoom,
              builder: (context, _) => CustomPaint(
                size: _view,
                painter: _CanvasPainter(this),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _CanvasPainter extends CustomPainter {
  final _PhotoCanvasState st;
  _CanvasPainter(this.st);

  @override
  void paint(Canvas canvas, Size size) {
    final w = st.widget;
    final s = st.s;
    final image = st._image;
    final crop = w.mode == CanvasMode.crop;
    final content = st._content;
    final origin = st._origin, fit = st._fit;

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(fit);
    canvas.clipRect(Rect.fromLTWH(0, 0, content.width, content.height));
    canvas.transform((crop ? Geo.imageToFrame(image, s) : Geo.imageToOutput(image, s)).storage);
    final overlay = w.mode == CanvasMode.mask && w.showMaskOverlay && w.maskIndex >= 0;
    DevelopRenderer.paint(canvas, w.shader, w.assets, s, showMask: overlay ? w.maskIndex + 1 : 0);
    canvas.restore();

    final z = st._zoomScale;
    switch (w.mode) {
      case CanvasMode.view:
        break;
      case CanvasMode.crop:
        _paintCrop(canvas, size, origin, fit, content);
      case CanvasMode.mask:
        _paintMask(canvas, z);
      case CanvasMode.heal:
        _paintSpots(canvas, z);
    }
  }

  void _paintCrop(Canvas canvas, Size size, Offset origin, double fit, Size frame) {
    final c = st.s.crop;
    final r = Rect.fromLTRB(
      origin.dx + c.left * frame.width * fit,
      origin.dy + c.top * frame.height * fit,
      origin.dx + c.right * frame.width * fit,
      origin.dy + c.bottom * frame.height * fit,
    );
    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(dim, Paint()..color = const Color(0xB0000000));
    final thin = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3, y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), thin);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), thin);
    }
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..strokeWidth = 1.2,
    );
    final bold = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.square;
    const k = 18.0;
    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final sx = corner.dx == r.left ? 1.0 : -1.0, sy = corner.dy == r.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(k * sx, 0), bold);
      canvas.drawLine(corner, corner + Offset(0, k * sy), bold);
    }
  }

  void _handle(Canvas canvas, Offset p, double z, {bool filled = true}) {
    canvas.drawCircle(p, 9 / z, Paint()..color = const Color(0x66000000));
    canvas.drawCircle(
      p,
      7 / z,
      Paint()
        ..color = filled ? AppColors.accent : Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      p,
      7 / z,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / z,
    );
  }

  void _paintMask(Canvas canvas, double z) {
    final m = st._mask;
    if (m == null || m.usesTexture) return;
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3 / z;
    final h = st._maskHandles(m);
    if (m.type == MaskType.linear) {
      final d = h[1] - h[0];
      final len = d.distance;
      if (len > 1) {
        final n = Offset(-d.dy, d.dx) / len * 2000;
        canvas.drawLine(h[0] - n, h[0] + n, line);
        canvas.drawLine(h[1] - n, h[1] + n, line..color = Colors.white54);
        canvas.drawLine(h[0], h[1], line..color = Colors.white70);
      }
      _handle(canvas, h[0], z);
      _handle(canvas, h[1], z, filled: false);
    } else {
      final centre = h[0];
      final rx = (h[1] - centre).distance, ry = (h[2] - centre).distance;
      final ang = math.atan2((h[1] - centre).dy, (h[1] - centre).dx);
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(ang);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2), line);
      canvas.restore();
      _handle(canvas, centre, z);
      _handle(canvas, h[1], z, filled: false);
      _handle(canvas, h[2], z, filled: false);
    }
  }

  void _paintSpots(Canvas canvas, double z) {
    final s = st.s;
    final imgW = st._image.width;
    for (var i = 0; i < s.spots.length; i++) {
      final sp = s.spots[i];
      final sel = i == st.widget.spotIndex;
      final r = sp.r * imgW * st._pxScale;
      final d = st._toView(Offset(sp.dx, sp.dy)), src = st._toView(Offset(sp.sx, sp.sy));
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (sel ? 2.0 : 1.2) / z
        ..color = sel ? AppColors.accent : Colors.white;
      canvas.drawCircle(d, r, ring);
      if (sel) {
        canvas.drawLine(d, src, Paint()
          ..color = Colors.white70
          ..strokeWidth = 1 / z);
        canvas.drawCircle(src, r, ring..color = AppColors.accent2);
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}
