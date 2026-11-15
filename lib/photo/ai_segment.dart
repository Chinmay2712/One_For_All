import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../core/media.dart';
import '../core/save.dart';

/// On-device person segmentation (Google ML Kit). Android and iOS only.
class AiSegmenter {
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Returns a mask image where alpha (and brightness) = "is a person".
  static Future<ui.Image?> personMask(String imagePath) async {
    var path = imagePath;
    if (path.startsWith('sample://')) {
      path = await Saver.tempPath('sample_for_ai.png');
      await File(path).writeAsBytes(await Media.readBytes(imagePath), flush: true);
    }
    final segmenter = SelfieSegmenter(mode: SegmenterMode.single, enableRawSizeMask: true);
    try {
      final mask = await segmenter.processImage(InputImage.fromFilePath(path));
      if (mask == null || mask.width == 0 || mask.height == 0) return null;
      final n = mask.width * mask.height;
      final bytes = Uint8List(n * 4);
      var person = 0;
      for (var i = 0; i < n && i < mask.confidences.length; i++) {
        // Steepen the soft edge a little so the cut-out is not hazy.
        final c = ((mask.confidences[i] - 0.35) / 0.3).clamp(0.0, 1.0);
        if (c > 0.5) person++;
        final v = (c * 255).round();
        bytes[i * 4] = v;
        bytes[i * 4 + 1] = v;
        bytes[i * 4 + 2] = v;
        bytes[i * 4 + 3] = v;
      }
      // The segmenter always returns a mask; treat a near-empty one as "no person".
      if (person < n * 0.005) return null;
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(bytes, mask.width, mask.height, ui.PixelFormat.rgba8888, done.complete);
      return done.future;
    } finally {
      await segmenter.close();
    }
  }

  /// PNG (base64) of [mask], small enough to store inside the edit recipe.
  static Future<String> encodeMask(ui.Image mask) async {
    final k = 384 / (mask.width > mask.height ? mask.width : mask.height);
    final w = (mask.width * (k < 1 ? k : 1)).round(), h = (mask.height * (k < 1 ? k : 1)).round();
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      mask,
      Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final small = await rec.endRecording().toImage(w, h);
    final data = await small.toByteData(format: ui.ImageByteFormat.png);
    return base64Encode(data!.buffer.asUint8List());
  }

  /// Returns PNG bytes of [image] with everything but the person transparent.
  static Future<Uint8List> cutOut(ui.Image image, ui.Image mask) async {
    final full = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.saveLayer(full, Paint());
    c.drawImage(image, Offset.zero, Paint());
    c.drawImageRect(
      mask,
      Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
      full,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..filterQuality = FilterQuality.medium,
    );
    c.restore();
    final out = await rec.endRecording().toImage(image.width, image.height);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}
