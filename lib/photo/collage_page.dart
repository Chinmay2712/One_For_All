import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../core/media.dart';
import '../core/save.dart';
import '../core/widgets.dart';
import 'photo_library.dart';

/// One arrangement of photos. [cells] are in unit coordinates (0..1) and the
/// spacing slider is applied on top, so every layout works at any aspect.
class CollageLayout {
  final List<Rect> cells;

  /// Soft shadow under each photo (photo-frame look).
  final bool shadow;

  /// A thin line drawn just outside each photo.
  final bool outline;
  const CollageLayout(this.cells, {this.shadow = false, this.outline = false});
}

/// How a photo sits in its cell: [zoom] >= 1 on top of "fill the cell", and
/// the point of the photo ([cx], [cy] in 0..1) that is centred in the cell.
class CellXf {
  double zoom = 1, cx = 0.5, cy = 0.5;
  void reset() {
    zoom = 1;
    cx = cy = 0.5;
  }
}

Rect _u(double l, double t, double r, double b) => Rect.fromLTRB(l, t, r, b);

CollageLayout _grid(List<int> rows, bool vertical) {
  final out = <Rect>[];
  for (var r = 0; r < rows.length; r++) {
    for (var c = 0; c < rows[r]; c++) {
      final a0 = r / rows.length, a1 = (r + 1) / rows.length;
      final b0 = c / rows[r], b1 = (c + 1) / rows[r];
      out.add(vertical ? _u(a0, b0, a1, b1) : _u(b0, a0, b1, a1));
    }
  }
  return CollageLayout(out);
}

/// One big photo plus the rest in a strip on [side] (0 left, 1 right, 2 top, 3 bottom).
CollageLayout _hero(int n, int side, double share) {
  final rest = n - 1;
  final cells = <Rect>[
    switch (side) {
      0 => _u(0, 0, share, 1),
      1 => _u(1 - share, 0, 1, 1),
      2 => _u(0, 0, 1, share),
      _ => _u(0, 1 - share, 1, 1),
    },
  ];
  for (var i = 0; i < rest; i++) {
    final a = i / rest, b = (i + 1) / rest;
    cells.add(switch (side) {
      0 => _u(share, a, 1, b),
      1 => _u(0, a, 1 - share, b),
      2 => _u(a, share, b, 1),
      _ => _u(a, 0, b, 1 - share),
    });
  }
  return CollageLayout(cells);
}

/// Random-looking but repeatable mosaic made by cutting rectangles in two.
CollageLayout _mosaic(int n, int seed) {
  final rnd = math.Random(seed * 7919 + n);
  final cells = <Rect>[const Rect.fromLTWH(0, 0, 1, 1)];
  while (cells.length < n) {
    // Mostly cut the biggest piece, sometimes a random one.
    var idx = 0;
    if (rnd.nextDouble() < 0.7) {
      for (var i = 1; i < cells.length; i++) {
        if (cells[i].width * cells[i].height > cells[idx].width * cells[idx].height) idx = i;
      }
    } else {
      idx = rnd.nextInt(cells.length);
    }
    final r = cells.removeAt(idx);
    final t = 0.35 + rnd.nextDouble() * 0.3;
    final vertical = r.width > r.height * (0.8 + rnd.nextDouble() * 0.5);
    if (vertical) {
      final x = r.left + r.width * t;
      cells.insert(idx, _u(r.left, r.top, x, r.bottom));
      cells.insert(idx + 1, _u(x, r.top, r.right, r.bottom));
    } else {
      final y = r.top + r.height * t;
      cells.insert(idx, _u(r.left, r.top, r.right, y));
      cells.insert(idx + 1, _u(r.left, y, r.right, r.bottom));
    }
  }
  return CollageLayout(cells);
}

/// A full-size photo with the others as small insets along the bottom.
CollageLayout _inset(int n) {
  final cells = <Rect>[const Rect.fromLTWH(0, 0, 1, 1)];
  const w = 0.27;
  for (var i = 0; i < n - 1; i++) {
    final x = 0.97 - w - i * (w + 0.03);
    cells.add(_u(x, 0.97 - w, x + w, 0.97));
  }
  return CollageLayout(cells);
}

/// Photo-frame styles for a single picture. The spacing slider is the border.
List<CollageLayout> _frames() => [
      CollageLayout([_u(0, 0, 1, 1)]),
      CollageLayout([_u(0.07, 0.07, 0.93, 0.93)]),
      CollageLayout([_u(0.14, 0.14, 0.86, 0.86)], outline: true),
      CollageLayout([_u(0.07, 0.07, 0.93, 0.80)], shadow: true), // polaroid
      CollageLayout([_u(0.1, 0.1, 0.9, 0.9)], shadow: true),
      CollageLayout([_u(0.04, 0.04, 0.96, 0.96)], outline: true),
      CollageLayout([_u(0, 0.17, 1, 0.83)]), // cinema bars
      CollageLayout([_u(0.18, 0.06, 0.82, 0.94)], shadow: true),
    ];

/// Plenty of layouts for [n] photos.
List<CollageLayout> layoutsFor(int n) {
  if (n <= 1) return _frames();
  final out = <CollageLayout>[];
  final seen = <String>{};
  void addGrid(List<int> p) {
    if (p.fold<int>(0, (a, b) => a + b) != n || p.any((v) => v <= 0)) return;
    if (!seen.add(p.join(','))) return;
    out.add(_grid(p, false));
    out.add(_grid(p, true));
  }

  // Most balanced grid first (rows nearest sqrt(n)), single strip last.
  final order = [for (var r = 2; r <= math.min(n, 5); r++) r]
    ..sort((a, b) => (a - math.sqrt(n)).abs().compareTo((b - math.sqrt(n)).abs()));
  for (final rows in order) {
    final base = n ~/ rows, extra = n % rows;
    addGrid([for (var i = 0; i < rows; i++) base + (i < extra ? 1 : 0)]);
    addGrid([for (var i = 0; i < rows; i++) base + (i >= rows - extra ? 1 : 0)]);
    addGrid([for (var i = 0; i < rows; i++) base + (i == rows ~/ 2 ? extra : 0)]);
  }
  addGrid([n]);
  if (n >= 3) {
    addGrid([1, n - 1]);
    addGrid([n - 1, 1]);
    addGrid([1, n - 2, 1]);
  }
  for (var side = 0; side < 4; side++) {
    out.add(_hero(n, side, 0.62));
    if (n >= 3) out.add(_hero(n, side, 0.5));
  }
  if (n <= 5) out.add(_inset(n));
  for (var seed = 1; seed <= 10; seed++) {
    out.add(_mosaic(n, seed));
  }
  return out;
}

bool _edge(double v, double e) => (v - e).abs() < 1e-6;

/// Cells in pixels. Photos keep [gap] from the canvas edge and [gap] from
/// each other.
List<Rect> cellRects(Size size, CollageLayout l, double gap) {
  final w = size.width, h = size.height;
  return [
    for (final u in l.cells)
      Rect.fromLTRB(
        _edge(u.left, 0) ? gap : u.left * w + gap / 2,
        _edge(u.top, 0) ? gap : u.top * h + gap / 2,
        _edge(u.right, 1) ? w - gap : u.right * w - gap / 2,
        _edge(u.bottom, 1) ? h - gap : u.bottom * h - gap / 2,
      ),
  ];
}

/// The part of [img] (in image pixels) shown in cell [r], with the photo's
/// position clamped so it always covers the cell.
Rect sourceRect(ui.Image img, Rect r, CellXf x) {
  final scale = math.max(r.width / img.width, r.height / img.height) * x.zoom;
  final sw = math.min(img.width.toDouble(), r.width / scale);
  final sh = math.min(img.height.toDouble(), r.height / scale);
  final left = (x.cx * img.width - sw / 2).clamp(0.0, math.max(0.0, img.width - sw)).toDouble();
  final top = (x.cy * img.height - sh / 2).clamp(0.0, math.max(0.0, img.height - sh)).toDouble();
  return Rect.fromLTWH(left, top, sw, sh);
}

void paintCollage(Canvas canvas, Size size, List<ui.Image> images, CollageLayout layout, double gap,
    double radius, Color background, List<CellXf> xfs) {
  canvas.drawRect(Offset.zero & size, Paint()..color = background);
  final rects = cellRects(size, layout, gap);
  final ink = background.computeLuminance() > 0.5 ? Colors.black : Colors.white;
  final unit = math.min(size.width, size.height);
  for (var i = 0; i < rects.length && i < images.length; i++) {
    final img = images[i], r = rects[i];
    if (r.width <= 1 || r.height <= 1) continue;
    final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
    if (layout.shadow) {
      canvas.drawShadow(Path()..addRRect(rr), Colors.black, unit * 0.012, false);
    }
    final x = i < xfs.length ? xfs[i] : CellXf();
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawImageRect(img, sourceRect(img, r, x), r, Paint()..filterQuality = FilterQuality.medium);
    canvas.restore();
    if (layout.outline) {
      final g = unit * 0.014;
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.inflate(g), Radius.circular(radius + g)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, unit * 0.003)
          ..color = ink.withValues(alpha: 0.7),
      );
    }
  }
}

class CollagePage extends StatefulWidget {
  const CollagePage({super.key});

  @override
  State<CollagePage> createState() => _CollagePageState();
}

class _CollagePageState extends State<CollagePage> {
  final _images = <ui.Image>[];
  var _xfs = <CellXf>[];
  int _layout = 0;
  double _gap = 12, _radius = 10;
  double _aspect = 1;
  Color _bg = Colors.white;
  int _dragCell = -1;
  double _startZoom = 1, _previewW = 400;
  Offset _tapAt = Offset.zero;

  List<CollageLayout> get _layouts => layoutsFor(math.max(1, _images.length));

  double _fitAspect(ui.Image i) => (i.width / i.height).clamp(0.5, 2.0);

  void _imagesChanged() {
    _xfs = [for (final _ in _images) CellXf()];
    _layout = 0;
    if (_images.length == 1) _aspect = _fitAspect(_images.first);
  }

  Future<void> _pick() async {
    final files = await Media.pickImages();
    if (files.isEmpty || !mounted) return;
    final loaded = await withProgress(context, 'Loading photos', (_) async {
      final out = <ui.Image>[];
      for (final f in files.take(9 - _images.length)) {
        out.add(await Media.decode(await f.readAsBytes(), maxEdge: 1800));
      }
      return out;
    });
    if (loaded == null) return;
    setState(() {
      _images.addAll(loaded);
      _imagesChanged();
    });
  }

  Future<void> _addSample() async {
    final img = await Media.samplePhoto();
    setState(() {
      if (_images.length < 9) _images.add(img);
      _imagesChanged();
    });
  }

  Future<void> _export() async {
    if (_images.isEmpty) return;
    final msg = await withProgress(context, 'Exporting', (_) async {
      const long = 2400.0;
      final size = _aspect >= 1 ? Size(long, long / _aspect) : Size(long * _aspect, long);
      final k = size.width / _previewW;
      final layouts = _layouts;
      final rec = ui.PictureRecorder();
      paintCollage(Canvas(rec), size, _images, layouts[_layout.clamp(0, layouts.length - 1)], _gap * k, _radius * k,
          _bg, _xfs);
      final img = await rec.endRecording().toImage(size.width.round(), size.height.round());
      final bytes = await PhotoExport.encode(img, const ExportOptions(jpeg: true, quality: 94));
      return Saver.saveImage(bytes, 'OFA_collage_${DateTime.now().millisecondsSinceEpoch}.jpg');
    });
    if (mounted && msg != null) toast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final layouts = _layouts;
    final layout = layouts[_layout.clamp(0, layouts.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collage'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
              onPressed: _images.isEmpty ? null : _export,
              child: const Text('Export'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _images.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
                        onPressed: _pick,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Choose 1 to 9 photos'),
                      ),
                      TextButton(onPressed: _addSample, child: const Text('Use the sample photo')),
                    ]),
                  )
                : Padding(
                    padding: const EdgeInsets.all(14),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _aspect,
                        child: LayoutBuilder(builder: (context, box) {
                          final size = box.biggest;
                          _previewW = size.width;
                          int cellAt(Offset p) => cellRects(size, layout, _gap).lastIndexWhere((r) => r.contains(p));
                          return GestureDetector(
                            onDoubleTapDown: (d) => _tapAt = d.localPosition,
                            onDoubleTap: () {
                              final i = cellAt(_tapAt);
                              if (i >= 0 && i < _xfs.length) setState(() => _xfs[i].reset());
                            },
                            onScaleStart: (d) {
                              _dragCell = cellAt(d.localFocalPoint);
                              _startZoom = _dragCell >= 0 && _dragCell < _xfs.length ? _xfs[_dragCell].zoom : 1;
                            },
                            onScaleUpdate: (d) {
                              if (_dragCell < 0 || _dragCell >= _xfs.length || _dragCell >= _images.length) return;
                              final r = cellRects(size, layout, _gap)[_dragCell];
                              final img = _images[_dragCell], x = _xfs[_dragCell];
                              final before = math.max(r.width / img.width, r.height / img.height) * x.zoom;
                              setState(() {
                                // The photo follows the finger, in any direction.
                                x.cx -= d.focalPointDelta.dx / before / img.width;
                                x.cy -= d.focalPointDelta.dy / before / img.height;
                                if (d.pointerCount > 1) x.zoom = (_startZoom * d.scale).clamp(1.0, 8.0);
                                // Keep the cell covered.
                                final s = sourceRect(img, r, x);
                                x.cx = (s.left + s.width / 2) / img.width;
                                x.cy = (s.top + s.height / 2) / img.height;
                              });
                            },
                            child: CustomPaint(
                              size: size,
                              painter: _CollagePainter(_images, layout, _gap, _radius, _bg, _xfs),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
          ),
          if (_images.isNotEmpty)
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  height: 50,
                  child: Row(children: [
                    Expanded(
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                    for (var i = 0; i < layouts.length; i++)
                      GestureDetector(
                        onTap: () => setState(() => _layout = i),
                        child: Container(
                          width: 46,
                          height: 46,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: i == _layout ? AppColors.accent : AppColors.line, width: 2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: CustomPaint(painter: _LayoutIcon(layouts[i])),
                        ),
                      ),
                      ]),
                    ),
                    IconButton(onPressed: _images.length < 9 ? _pick : null, icon: const Icon(Icons.add_photo_alternate_outlined)),
                    IconButton(
                      onPressed: () => setState(() {
                        _images.clear();
                        _xfs = [];
                      }),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ]),
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    if (_images.length == 1)
                      Pill(
                        label: 'Photo',
                        selected: (_aspect - _fitAspect(_images.first)).abs() < 0.001,
                        onTap: () => setState(() => _aspect = _fitAspect(_images.first)),
                      ),
                    for (final a in const [('1:1', 1.0), ('4:5', 0.8), ('3:4', 0.75), ('9:16', 0.5625), ('4:3', 1.3333), ('16:9', 1.7778)])
                      Pill(label: a.$1, selected: (_aspect - a.$2).abs() < 0.001, onTap: () => setState(() => _aspect = a.$2)),
                    for (final c in const [Colors.white, Colors.black, Color(0xFFF4E9D8), Color(0xFF1F2937), Color(0xFFFFD60A), Color(0xFFE5383B)])
                      GestureDetector(
                        onTap: () => setState(() => _bg = c),
                        child: Container(
                          width: 26,
                          height: 26,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(color: _bg == c ? AppColors.accent : AppColors.line, width: 2),
                          ),
                        ),
                      ),
                  ]),
                ),
                ParamSlider(
                    label: _images.length == 1 ? 'Border' : 'Spacing',
                    value: _gap,
                    min: 0,
                    max: 40,
                    def: 12,
                    onChanged: (v) => setState(() => _gap = v)),
                ParamSlider(label: 'Corners', value: _radius, min: 0, max: 60, def: 10, onChanged: (v) => setState(() => _radius = v)),
                const Text('Drag a photo to move it anywhere in its frame, pinch to zoom, double-tap to reset.',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _CollagePainter extends CustomPainter {
  final List<ui.Image> images;
  final CollageLayout layout;
  final double gap, radius;
  final Color bg;
  final List<CellXf> xfs;
  _CollagePainter(this.images, this.layout, this.gap, this.radius, this.bg, this.xfs);

  @override
  void paint(Canvas canvas, Size size) => paintCollage(canvas, size, images, layout, gap, radius, bg, xfs);

  @override
  bool shouldRepaint(_CollagePainter old) => true;
}

class _LayoutIcon extends CustomPainter {
  final CollageLayout layout;
  _LayoutIcon(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in cellRects(size, layout, 4)) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(1.5)), Paint()..color = AppColors.textDim);
    }
  }

  @override
  bool shouldRepaint(_LayoutIcon old) => old.layout != layout;
}
