import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'store.dart';

const kSamplePhotoPath = 'sample://photo';

bool isImagePath(String path) {
  final p = path.toLowerCase();
  return p.startsWith('sample://') ||
      ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.bmp', '.gif']
          .any(p.endsWith);
}

/// Picking, persisting and decoding media.
class Media {
  static final _picker = ImagePicker();

  static Future<List<XFile>> pickImages() => _picker.pickMultiImage();

  static Future<XFile?> pickImage() =>
      _picker.pickImage(source: ImageSource.gallery);

  static Future<XFile?> pickVideo() =>
      _picker.pickVideo(source: ImageSource.gallery);

  /// Photos and videos together (for the video timeline).
  static Future<List<XFile>> pickMixed() => _picker.pickMultipleMedia();

  static Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/$name');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static Future<String> workDir() async => (await _dir('work')).path;

  /// Copies a picked file into app storage so projects keep working after the
  /// picker cache is cleared. On web the blob URL is returned unchanged.
  static Future<String> persist(XFile file) async {
    if (kIsWeb) return file.path;
    final dir = await _dir('media');
    final ext = _ext(file.name.isNotEmpty ? file.name : file.path);
    final dest = '${dir.path}/${Store.newId()}$ext';
    await File(file.path).copy(dest);
    return dest;
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i).toLowerCase();
  }

  static Future<Uint8List> readBytes(String path) async {
    if (path == kSamplePhotoPath) {
      final img = await samplePhoto();
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }
    if (kIsWeb) return XFile(path).readAsBytes();
    return File(path).readAsBytes();
  }

  /// Decodes [bytes], scaling down so the long edge is at most [maxEdge].
  static Future<ui.Image> decode(Uint8List bytes, {int? maxEdge}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        final long = math.max(w, h);
        if (maxEdge == null || long <= maxEdge) {
          return ui.TargetImageSize(width: w, height: h);
        }
        final f = maxEdge / long;
        return ui.TargetImageSize(
          width: math.max(1, (w * f).round()),
          height: math.max(1, (h * f).round()),
        );
      },
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static Future<ui.Image> load(String path, {int? maxEdge}) async {
    if (path == kSamplePhotoPath) return samplePhoto();
    return decode(await readBytes(path), maxEdge: maxEdge);
  }

  static ui.Image? _sample;

  /// A procedurally drawn landscape so the editor can be tried without
  /// importing anything.
  static Future<ui.Image> samplePhoto() async {
    if (_sample != null) return _sample!.clone();
    const w = 1500.0, h = 1000.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final rnd = math.Random(7);
    // Sky.
    c.drawRect(
      const Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF27407A), Color(0xFF6E8FC9), Color(0xFFF2B98A), Color(0xFFF7D9A8)],
          stops: [0, 0.4, 0.62, 0.7],
        ).createShader(const Rect.fromLTWH(0, 0, w, h * 0.72)),
    );
    // Sun glow.
    c.drawCircle(
      const Offset(w * 0.68, h * 0.56),
      300,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFFFF6D8), Color(0x88FFD08A), Color(0x00FFD08A)],
          stops: [0, 0.25, 1],
        ).createShader(Rect.fromCircle(center: const Offset(w * 0.68, h * 0.56), radius: 300)),
    );
    // Clouds.
    for (var i = 0; i < 9; i++) {
      final cx = rnd.nextDouble() * w, cy = 80 + rnd.nextDouble() * 320;
      for (var j = 0; j < 6; j++) {
        c.drawOval(
          Rect.fromCenter(
            center: Offset(cx + (rnd.nextDouble() - 0.5) * 220, cy + (rnd.nextDouble() - 0.5) * 30),
            width: 120 + rnd.nextDouble() * 140,
            height: 30 + rnd.nextDouble() * 30,
          ),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.22)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
        );
      }
    }
    // Mountain ranges, far to near.
    const ranges = [
      [0.60, 0xFF6B6FA6, 150.0],
      [0.66, 0xFF4C5B8C, 120.0],
      [0.73, 0xFF2F5E55, 90.0],
      [0.82, 0xFF3F7A3C, 60.0],
    ];
    for (final r in ranges) {
      final base = h * (r[0] as double);
      final amp = r[2] as double;
      final path = Path()..moveTo(0, h);
      var y = base;
      for (var x = 0.0; x <= w; x += 30) {
        y = base + math.sin(x / 170 + amp) * amp * 0.5 + (rnd.nextDouble() - 0.5) * amp * 0.35;
        path.lineTo(x, y);
      }
      path
        ..lineTo(w, h)
        ..close();
      c.drawPath(path, Paint()..color = Color(r[1] as int));
    }
    // Meadow with flowers for colour-mixer testing.
    c.drawRect(
      const Rect.fromLTWH(0, h * 0.86, w, h * 0.14),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4C8F3A), Color(0xFF2C5A22)],
        ).createShader(const Rect.fromLTWH(0, h * 0.86, w, h * 0.14)),
    );
    const flowers = [0xFFE5383B, 0xFFFF8C1A, 0xFFFFD60A, 0xFF9D4EDD, 0xFFFF5DA2, 0xFF2EC4F1, 0xFFFFFFFF];
    for (var i = 0; i < 260; i++) {
      final fx = rnd.nextDouble() * w, fy = h * 0.87 + rnd.nextDouble() * h * 0.12;
      c.drawCircle(Offset(fx, fy), 3 + rnd.nextDouble() * 6, Paint()..color = Color(flowers[i % flowers.length]));
    }
    // Lake reflection band.
    c.drawRect(
      const Rect.fromLTWH(0, h * 0.775, w, h * 0.03),
      Paint()..color = const Color(0x8087C6E8),
    );
    final pic = rec.endRecording();
    _sample = await pic.toImage(w.toInt(), h.toInt());
    pic.dispose();
    return _sample!.clone();
  }
}
