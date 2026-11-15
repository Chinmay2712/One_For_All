import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../core/media.dart';
import '../core/save.dart';
import '../core/widgets.dart';
import 'photo_library.dart';

/// Rows of cells; when [vertical] the "rows" are columns instead.
class CollageLayout {
  final List<int> rows;
  final bool vertical;
  const CollageLayout(this.rows, [this.vertical = false]);
}

/// A handful of sensible layouts for [n] photos.
List<CollageLayout> layoutsFor(int n) {
  final parts = <List<int>>{};
  void add(List<int> p) {
    if (p.fold<int>(0, (a, b) => a + b) == n && p.every((v) => v > 0)) parts.add(p);
  }

  add([n]);
  for (var rows = 2; rows <= math.min(n, 4); rows++) {
    final base = n ~/ rows, extra = n % rows;
    add([for (var i = 0; i < rows; i++) base + (i < extra ? 1 : 0)]);
    add([for (var i = 0; i < rows; i++) base + (i >= rows - extra ? 1 : 0)]);
  }
  if (n >= 3) add([1, n - 1]);
  if (n >= 3) add([n - 1, 1]);
  final seen = <String>{};
  final out = <CollageLayout>[];
  for (final p in parts) {
    if (!seen.add(p.join(','))) continue;
    out.add(CollageLayout(p));
    if (p.length > 1 || n > 1) out.add(CollageLayout(p, true));
  }
  return out;
}

List<Rect> cellRects(Size size, CollageLayout l, double gap) {
  final out = <Rect>[];
  final major = l.vertical ? size.width : size.height;
  final minor = l.vertical ? size.height : size.width;
  final rowSize = (major - gap * (l.rows.length + 1)) / l.rows.length;
  for (var r = 0; r < l.rows.length; r++) {
    final n = l.rows[r];
    final cell = (minor - gap * (n + 1)) / n;
    for (var c = 0; c < n; c++) {
      final a = gap + r * (rowSize + gap), b = gap + c * (cell + gap);
      out.add(l.vertical ? Rect.fromLTWH(a, b, rowSize, cell) : Rect.fromLTWH(b, a, cell, rowSize));
    }
  }
  return out;
}

void paintCollage(Canvas canvas, Size size, List<ui.Image> images, CollageLayout layout, double gap,
    double radius, Color background, List<Offset> aligns) {
  canvas.drawRect(Offset.zero & size, Paint()..color = background);
  final rects = cellRects(size, layout, gap);
  for (var i = 0; i < rects.length && i < images.length; i++) {
    final img = images[i], r = rects[i];
    final scale = math.max(r.width / img.width, r.height / img.height);
    final sw = r.width / scale, sh = r.height / scale;
    final a = i < aligns.length ? aligns[i] : Offset.zero;
    final src = Rect.fromLTWH(
      (img.width - sw) * (a.dx + 1) / 2,
      (img.height - sh) * (a.dy + 1) / 2,
      sw,
      sh,
    );
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)));
    canvas.drawImageRect(img, src, r, Paint()..filterQuality = FilterQuality.medium);
    canvas.restore();
  }
}

class CollagePage extends StatefulWidget {
  const CollagePage({super.key});

  @override
  State<CollagePage> createState() => _CollagePageState();
}

class _CollagePageState extends State<CollagePage> {
  final _images = <ui.Image>[];
  var _aligns = <Offset>[];
  int _layout = 0;
  double _gap = 12, _radius = 10;
  double _aspect = 1;
  Color _bg = Colors.white;
  int _dragCell = -1;

  List<CollageLayout> get _layouts => layoutsFor(math.max(1, _images.length));

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
      _aligns = List.filled(_images.length, Offset.zero);
      _layout = 0;
    });
  }

  Future<void> _addSample() async {
    final img = await Media.samplePhoto();
    setState(() {
      if (_images.length < 9) _images.add(img);
      _aligns = List.filled(_images.length, Offset.zero);
      _layout = 0;
    });
  }

  Future<void> _export() async {
    if (_images.isEmpty) return;
    final msg = await withProgress(context, 'Exporting', (_) async {
      const long = 2400.0;
      final size = _aspect >= 1 ? Size(long, long / _aspect) : Size(long * _aspect, long);
      final preview = context.size?.width ?? 400;
      final k = size.width / preview;
      final rec = ui.PictureRecorder();
      paintCollage(Canvas(rec), size, _images, _layouts[_layout], _gap * k, _radius * k, _bg, _aligns);
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
                        label: const Text('Choose 2 to 9 photos'),
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
                          return GestureDetector(
                            onPanStart: (d) {
                              final rects = cellRects(size, layout, _gap);
                              _dragCell = rects.indexWhere((r) => r.contains(d.localPosition));
                            },
                            onPanUpdate: (d) {
                              if (_dragCell < 0 || _dragCell >= _aligns.length) return;
                              final a = _aligns[_dragCell];
                              setState(() => _aligns[_dragCell] = Offset(
                                    (a.dx - d.delta.dx / 80).clamp(-1.0, 1.0),
                                    (a.dy - d.delta.dy / 80).clamp(-1.0, 1.0),
                                  ));
                            },
                            child: CustomPaint(
                              size: size,
                              painter: _CollagePainter(_images, layout, _gap, _radius, _bg, List.of(_aligns)),
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
                    IconButton(onPressed: _images.length < 9 ? _pick : null, icon: const Icon(Icons.add_photo_alternate_outlined)),
                    IconButton(
                      onPressed: () => setState(() {
                        _images.clear();
                        _aligns = [];
                      }),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ]),
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
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
                ParamSlider(label: 'Spacing', value: _gap, min: 0, max: 40, def: 12, onChanged: (v) => setState(() => _gap = v)),
                ParamSlider(label: 'Corners', value: _radius, min: 0, max: 60, def: 10, onChanged: (v) => setState(() => _radius = v)),
                const Text('Drag a photo to reposition it inside its frame.', style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
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
  final List<Offset> aligns;
  _CollagePainter(this.images, this.layout, this.gap, this.radius, this.bg, this.aligns);

  @override
  void paint(Canvas canvas, Size size) => paintCollage(canvas, size, images, layout, gap, radius, bg, aligns);

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
  bool shouldRepaint(_LayoutIcon old) => false;
}
