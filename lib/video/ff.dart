import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../core/media.dart';
import '../core/store.dart';

class MediaInfo {
  final double duration;
  final int width, height;
  final bool hasAudio;
  const MediaInfo(this.duration, this.width, this.height, this.hasAudio);
}

/// Thin wrapper around FFmpegKit. FFmpeg only exists on Android and iOS; on
/// other platforms [available] is false and callers fall back or disable.
class FF {
  static bool get available => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static String lastLog = '';

  /// Runs ffmpeg. [onTime] reports the encoded position in seconds.
  static Future<bool> run(List<String> args, {void Function(double seconds)? onTime}) async {
    final done = Completer<bool>();
    final log = StringBuffer();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final code = await session.getReturnCode();
        lastLog = log.toString();
        if (lastLog.length > 6000) lastLog = lastLog.substring(lastLog.length - 6000);
        done.complete(ReturnCode.isSuccess(code));
      },
      (l) => log.write(l.getMessage()),
      (stats) => onTime?.call(stats.getTime() / 1000.0),
    );
    return done.future;
  }

  static Future<void> cancel() => FFmpegKit.cancel();

  static Future<String> workFile(String ext) async => '${await Media.workDir()}/${Store.newId()}.$ext';

  static Future<MediaInfo> probeVideo(String path) async {
    if (available) {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info != null) {
        var w = 0, h = 0, audio = false;
        for (final s in info.getStreams()) {
          if (s.getType() == 'video' && w == 0) {
            w = s.getWidth() ?? 0;
            h = s.getHeight() ?? 0;
            if (_isQuarterTurned(s.getAllProperties())) {
              final t = w;
              w = h;
              h = t;
            }
          } else if (s.getType() == 'audio') {
            audio = true;
          }
        }
        final dur = double.tryParse(info.getDuration() ?? '') ?? 0;
        if (w > 0 && dur > 0) return MediaInfo(dur, w, h, audio);
      }
    }
    // Fallback (and web): ask the platform player.
    final c = kIsWeb ? VideoPlayerController.networkUrl(Uri.parse(path)) : VideoPlayerController.file(File(path));
    try {
      await c.initialize();
      final size = c.value.size;
      return MediaInfo(
        c.value.duration.inMilliseconds / 1000.0,
        size.width.round() > 0 ? size.width.round() : 1080,
        size.height.round() > 0 ? size.height.round() : 1920,
        true,
      );
    } finally {
      await c.dispose();
    }
  }

  static bool _isQuarterTurned(Map<dynamic, dynamic>? props) {
    if (props == null) return false;
    num? rot;
    final tags = props['tags'];
    if (tags is Map && tags['rotate'] != null) rot = num.tryParse('${tags['rotate']}');
    final side = props['side_data_list'];
    if (side is List) {
      for (final d in side) {
        if (d is Map && d['rotation'] != null) rot = num.tryParse('${d['rotation']}');
      }
    }
    return rot != null && (rot.abs().round() % 180) == 90;
  }

  static Future<double> probeAudioDuration(String path) async {
    if (available) {
      final session = await FFprobeKit.getMediaInformation(path);
      final d = double.tryParse(session.getMediaInformation()?.getDuration() ?? '');
      if (d != null && d > 0) return d;
    }
    final c = kIsWeb ? VideoPlayerController.networkUrl(Uri.parse(path)) : VideoPlayerController.file(File(path));
    try {
      await c.initialize();
      return c.value.duration.inMilliseconds / 1000.0;
    } catch (_) {
      return 30;
    } finally {
      await c.dispose();
    }
  }

  /// Writes a small poster frame for the timeline. Returns null if unavailable.
  static Future<String?> thumbnail(String path, {double at = 0.2}) async {
    if (!available) return null;
    final out = await workFile('jpg');
    final ok = await run(['-y', '-ss', '$at', '-i', path, '-frames:v', '1', '-vf', 'scale=-2:120', '-q:v', '5', out]);
    return ok && File(out).existsSync() ? out : null;
  }

  /// Size of an image as displayed (EXIF orientation applied).
  static Future<ui.Size> imageSize(String path) async {
    final img = await Media.load(path, maxEdge: 1024);
    final s = ui.Size(img.width.toDouble(), img.height.toDouble());
    img.dispose();
    return s;
  }

  /// Re-encodes a picked photo as an upright PNG (max 2160 px) so both the
  /// preview and ffmpeg see the same pixels regardless of EXIF or HEIC.
  static Future<String> normalizeImage(String path) async {
    if (!available) return path;
    final img = await Media.load(path, maxEdge: 2160);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    final out = '${await Media.workDir()}/${Store.newId()}.png';
    await File(out).writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return out;
  }
}
