import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'models.dart';

/// Draws text layers. The on-screen preview and the exported PNG overlays both
/// go through [paint], so they match.
class TextRender {
  static TextStyle _style(TextItem t, double fontSize, {Paint? foreground, Color? color}) {
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.15,
      fontWeight: t.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
      color: foreground == null ? color : null,
      foreground: foreground,
    );
    try {
      return GoogleFonts.getFont(t.font, textStyle: base);
    } catch (_) {
      return base;
    }
  }

  static TextPainter _layout(TextItem t, double cw, double fontSize, {Paint? foreground, Color? color}) {
    return TextPainter(
      text: TextSpan(text: t.text.isEmpty ? ' ' : t.text, style: _style(t, fontSize, foreground: foreground, color: color)),
      textAlign: const [TextAlign.left, TextAlign.center, TextAlign.right][t.align.clamp(0, 2)],
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(40, cw * 0.92));
  }

  static double _pad(double fontSize) => fontSize * 0.28;

  /// Size of the text box (including padding) at scale 1 on a canvas of
  /// [cw] x [ch].
  static Size measure(TextItem t, double cw, double ch) {
    final fs = t.size * ch;
    final tp = _layout(t, cw, fs, color: Colors.white);
    final pad = _pad(fs);
    return Size(tp.width + pad * 2, tp.height + pad * 2);
  }

  /// Paints the text box with its top-left corner at the origin.
  static void paint(Canvas canvas, TextItem t, double cw, double ch) {
    final fs = t.size * ch;
    final pad = _pad(fs);
    final fill = _layout(t, cw, fs, color: Color(t.color));
    final size = Size(fill.width + pad * 2, fill.height + pad * 2);
    if ((t.background >> 24) & 0xFF != 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(fs * 0.22)),
        Paint()..color = Color(t.background),
      );
    }
    final at = Offset(pad, pad);
    if (t.shadow) {
      final sh = _layout(
        t,
        cw,
        fs,
        foreground: Paint()
          ..color = const Color(0x99000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, fs * 0.06),
      );
      sh.paint(canvas, at + Offset(0, fs * 0.05));
    }
    if (t.strokeWidth > 0) {
      final st = _layout(
        t,
        cw,
        fs,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = fs * 0.02 * t.strokeWidth
          ..color = Color(t.stroke),
      );
      st.paint(canvas, at);
    }
    fill.paint(canvas, at);
  }

  /// Renders [t] to a PNG for export. [exportW]/[exportH] is the output video
  /// size and [raster] the scale to bake in. Returns the file's pixel size.
  static Future<Size> writePng(TextItem t, double exportW, double exportH, double raster, String path) async {
    await GoogleFonts.pendingFonts();
    final base = measure(t, exportW, exportH);
    final w = math.max(2, (base.width * raster).ceil()), h = math.max(2, (base.height * raster).ceil());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(raster);
    paint(c, t, exportW, exportH);
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    await File(path).writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return Size(w.toDouble(), h.toDouble());
  }
}

class TextLayerPainter extends CustomPainter {
  final TextItem item;
  final double cw, ch;
  TextLayerPainter(this.item, this.cw, this.ch);

  @override
  void paint(Canvas canvas, Size size) => TextRender.paint(canvas, item, cw, ch);

  // Text items are mutable and fonts load late, so always repaint.
  @override
  bool shouldRepaint(TextLayerPainter old) => true;
}
