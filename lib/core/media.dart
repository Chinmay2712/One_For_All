import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
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

  // image_picker hands back copies called "image_picker_123.jpg". file_picker
  // keeps the name the file has on the device, so the app can show it.
  // (Its "compression quality" mode must stay off: it renames and re-encodes.)
  // On iOS, "compatible" turns HEIC into a JPEG at full resolution.
  static const _ios = DarwinOptions(assetRepresentationMode: DarwinAssetRepresentationMode.compatible);

  static const _imageExt = ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'bmp', 'gif'];
  static const _videoExt = ['mp4', 'mov', 'm4v', 'mkv', 'webm', '3gp', 'avi'];

  /// Android's own photo picker hides real names ("1000000033.jpg"), so on
  /// Android the file chooser is used, filtered to the right kinds of file.
  /// iPhone keeps the photo-library picker.
  static Future<List<XFile>> _pick(FileType type, {bool multiple = true}) async {
    final android = !kIsWeb && Platform.isAndroid;
    final kind = android ? FileType.custom : type;
    final ext = !android
        ? null
        : switch (type) {
            FileType.image => _imageExt,
            FileType.video => _videoExt,
            _ => [..._imageExt, ..._videoExt],
          };
    final files = multiple
        ? await FilePicker.pickFiles(type: kind, allowedExtensions: ext, darwinOptions: _ios)
        : [await FilePicker.pickFile(type: kind, allowedExtensions: ext, darwinOptions: _ios)].whereType<PlatformFile>().toList();
    return [
      for (final f in files)
        if (f.xFile.path.isNotEmpty) XFile(f.xFile.path, name: f.name),
    ];
  }

  static Future<List<XFile>> pickImages() => _pick(FileType.image);

  static Future<XFile?> pickImage() async => (await _pick(FileType.image, multiple: false)).firstOrNull;

  static Future<XFile?> pickVideo() async => (await _pick(FileType.video, multiple: false)).firstOrNull;

  /// Photos and videos together (for the video timeline).
  static Future<List<XFile>> pickMixed() => _pick(FileType.media);

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

  // A tiny JPEG whose EXIF says "rotate 90°". Decoding it shows whether this
  // device's decoder already applies EXIF orientation (it must not be applied
  // twice, and some decoders skip it).
  static const _exifProbe = '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wCEAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSgBBwcHCggKEwoKEygaFhooKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKP/AABEIAAQACAMBEQACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncAAQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/AIq+PPvj/9k=';
  static bool? _decoderHonorsExif;

  static Future<bool> _honorsExif() async {
    if (_decoderHonorsExif != null) return _decoderHonorsExif!;
    try {
      final codec = await ui.instantiateImageCodec(base64.decode(_exifProbe));
      final img = (await codec.getNextFrame()).image;
      codec.dispose();
      _decoderHonorsExif = img.height > img.width;
      img.dispose();
    } catch (_) {
      _decoderHonorsExif = true;
    }
    return _decoderHonorsExif!;
  }

  /// EXIF orientation (1-8) of a JPEG, or 1 when absent.
  static int exifOrientation(Uint8List b) {
    if (b.length < 12 || b[0] != 0xFF || b[1] != 0xD8) return 1;
    var i = 2;
    while (i + 4 < b.length && b[i] == 0xFF) {
      final marker = b[i + 1];
      if (marker == 0xDA || marker == 0xD9) break;
      final len = (b[i + 2] << 8) | b[i + 3];
      if (marker == 0xE1 && i + 10 < b.length && b[i + 4] == 0x45 && b[i + 5] == 0x78 && b[i + 6] == 0x69 && b[i + 7] == 0x66) {
        final t = i + 10; // TIFF header
        final le = b[t] == 0x49;
        int u16(int o) => le ? b[t + o] | (b[t + o + 1] << 8) : (b[t + o] << 8) | b[t + o + 1];
        int u32(int o) => le
            ? b[t + o] | (b[t + o + 1] << 8) | (b[t + o + 2] << 16) | (b[t + o + 3] << 24)
            : (b[t + o] << 24) | (b[t + o + 1] << 16) | (b[t + o + 2] << 8) | b[t + o + 3];
        if (t + 8 >= b.length) return 1;
        final ifd = u32(4);
        if (t + ifd + 2 >= b.length) return 1;
        final n = u16(ifd);
        for (var k = 0; k < n; k++) {
          final e = ifd + 2 + k * 12;
          if (t + e + 12 > b.length) break;
          if (u16(e) == 0x0112) {
            final v = u16(e + 8);
            return v >= 1 && v <= 8 ? v : 1;
          }
        }
        return 1;
      }
      i += 2 + len;
    }
    return 1;
  }

  /// Redraws [src] upright for EXIF [o] (2-8).
  static Future<ui.Image> _orient(ui.Image src, int o) async {
    final w = src.width.toDouble(), h = src.height.toDouble();
    final swap = o >= 5;
    final m = switch (o) {
      1 => Matrix4.identity(),
      2 => Matrix4(-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, w, 0, 0, 1),
      3 => Matrix4(-1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, w, h, 0, 1),
      4 => Matrix4(1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, h, 0, 1),
      5 => Matrix4(0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1),
      6 => Matrix4(0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, h, 0, 0, 1),
      7 => Matrix4(0, -1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, h, w, 0, 1),
      _ => Matrix4(0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, w, 0, 1),
    };
    final rec = ui.PictureRecorder();
    final c = Canvas(rec)..transform(m.storage);
    c.drawImage(src, Offset.zero, Paint()..filterQuality = FilterQuality.none);
    final out = await rec.endRecording().toImage(swap ? src.height : src.width, swap ? src.width : src.height);
    src.dispose();
    return out;
  }

  /// Decodes [bytes], scaling down so the long edge is at most [maxEdge].
  /// Photos always come out upright, whatever the device's decoder does.
  static Future<ui.Image> decode(Uint8List bytes, {int? maxEdge}) async {
    final orient = exifOrientation(bytes);
    final fix = orient > 1 && !await _honorsExif();
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
    // Always redraw: the picture then has the same texture layout as the
    // procedurally drawn sample on every graphics backend.
    return _orient(frame.image, fix ? orient : 1);
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
