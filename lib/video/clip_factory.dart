import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../core/media.dart';
import '../core/store.dart';
import 'ff.dart';
import 'models.dart';

/// Turns picked files into timeline items.
class ClipFactory {
  static Future<Clip> fromFile(XFile f) async {
    final image = (f.mimeType?.startsWith('image/') ?? false) || isImagePath(f.name) || isImagePath(f.path);
    var path = await Media.persist(f);
    final name = f.name.isEmpty ? (image ? 'Photo' : 'Video') : f.name;
    if (image) {
      path = await FF.normalizeImage(path);
      final size = await FF.imageSize(path);
      return Clip(kind: ClipKind.image, path: path, name: name, srcDuration: 3, srcW: size.width.round(), srcH: size.height.round());
    }
    final info = await FF.probeVideo(path);
    return Clip(
      kind: ClipKind.video,
      path: path,
      name: name,
      srcDuration: info.duration,
      srcW: info.width,
      srcH: info.height,
      hasAudio: info.hasAudio,
      thumb: await FF.thumbnail(path),
    );
  }

  static Future<List<Clip>> pick() async {
    final files = await Media.pickMixed();
    final clips = <Clip>[];
    for (final f in files) {
      try {
        clips.add(await fromFile(f));
      } catch (_) {
        // Skip files the platform cannot open.
      }
    }
    return clips;
  }

  /// The built-in sample landscape as a still clip.
  static Future<Clip> sample() async {
    var path = kSamplePhotoPath;
    if (FF.available) {
      path = '${await Media.workDir()}/sample_${Store.newId()}.png';
      await File(path).writeAsBytes(await Media.readBytes(kSamplePhotoPath), flush: true);
    }
    return Clip(kind: ClipKind.image, path: path, name: 'Sample', srcDuration: 3, srcW: 1500, srcH: 1000);
  }

  static Future<AudioItem?> pickAudio(double start) async {
    final file = await FilePicker.pickFile(type: FileType.audio);
    if (file == null) return null;
    final path = await Media.persist(file.xFile);
    return AudioItem(path: path, name: file.name, srcDuration: await FF.probeAudioDuration(path), start: start);
  }
}

// ---------------------------------------------------------------- captions

TextItem captionItem(String text, double start, double duration) =>
    TextItem(text: text, start: start, duration: duration)
      ..caption = true
      ..y = 0.36
      ..size = 0.04
      ..shadow = false
      ..background = 0xB0000000;

/// Splits [text] into caption lines spread evenly between [from] and [to].
List<TextItem> spreadCaptions(String text, double from, double to) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty || to <= from) return [];
  final each = (to - from) / lines.length;
  return [for (var i = 0; i < lines.length; i++) captionItem(lines[i], from + each * i, each)];
}

double? _srtTime(String s) {
  final m = RegExp(r'(\d+):(\d+):(\d+)[,.](\d+)').firstMatch(s);
  if (m == null) return null;
  return int.parse(m[1]!) * 3600 + int.parse(m[2]!) * 60 + int.parse(m[3]!) + int.parse(m[4]!.padRight(3, '0').substring(0, 3)) / 1000;
}

/// Parses SubRip (.srt) subtitles into caption items.
List<TextItem> parseSrt(String srt) {
  final out = <TextItem>[];
  for (final block in srt.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
    final lines = block.trim().split('\n');
    final ti = lines.indexWhere((l) => l.contains('-->'));
    if (ti < 0 || ti == lines.length - 1) continue;
    final parts = lines[ti].split('-->');
    final a = _srtTime(parts[0]), b = _srtTime(parts[1]);
    if (a == null || b == null || b <= a) continue;
    final text = lines.sublist(ti + 1).join('\n').replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (text.isNotEmpty) out.add(captionItem(text, a, b - a));
  }
  return out;
}
