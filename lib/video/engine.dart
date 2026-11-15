import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'models.dart';

class _Player {
  final VideoPlayerController c;
  bool ready = false;
  bool failed = false;
  bool seeking = false;
  double? pendingSeek;
  double lastVolume = -1;
  double lastSpeed = -1;
  int lastUsed = 0;
  _Player(this.c);
}

/// Plays a [Project] in real time by driving one platform player per active
/// clip and keeping them in step with a single timeline clock.
class VideoEngine extends ChangeNotifier {
  Project project;
  double position = 0;
  bool playing = false;

  final _players = <String, _Player>{};
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  int _frame = 0;
  bool _disposed = false;

  VideoEngine(this.project, TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  double get duration => project.duration;

  VideoPlayerController? controllerFor(String id) {
    final p = _players[id];
    return p != null && p.ready ? p.c : null;
  }

  void play() {
    if (playing || duration <= 0) return;
    if (position >= duration - 0.03) position = 0;
    playing = true;
    _last = Duration.zero;
    _ticker.start();
    _sync();
    notifyListeners();
  }

  void pause() {
    if (!playing) return;
    playing = false;
    _ticker.stop();
    _sync();
    notifyListeners();
  }

  void toggle() => playing ? pause() : play();

  void seek(double t) {
    position = t.clamp(0.0, math.max(0.0, duration));
    _sync();
    notifyListeners();
  }

  /// Call after the project changed.
  void refresh() {
    position = position.clamp(0.0, math.max(0.0, duration));
    _sync();
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    position += dt;
    if (position >= duration) {
      position = duration;
      playing = false;
      _ticker.stop();
    }
    _sync();
    notifyListeners();
  }

  // ------------------------------------------------------------ syncing

  void _sync() {
    if (_disposed) return;
    _frame++;
    final needed = <String>{};
    const preload = 1.2;

    void visit(String id, String path, double start, double dur, double inPoint, double speed, double volume) {
      final lt = position - start;
      if (lt < -preload || lt > dur + 0.05) return;
      needed.add(id);
      final p = _ensure(id, path);
      p.lastUsed = _frame;
      if (!p.ready) return;
      final active = lt >= 0 && lt <= dur;
      final target = inPoint + lt.clamp(0.0, dur) * speed;
      if (playing && active) {
        _setVolume(p, volume);
        if (p.lastSpeed != speed) {
          p.lastSpeed = speed;
          p.c.setPlaybackSpeed(speed);
        }
        final cur = p.c.value.position.inMilliseconds / 1000.0;
        if (!p.c.value.isPlaying) {
          if ((cur - target).abs() > 0.08) _seek(p, target);
          p.c.play();
        } else if ((cur - target).abs() > 0.4 * math.max(1.0, speed)) {
          _seek(p, target);
        }
      } else {
        if (p.c.value.isPlaying) p.c.pause();
        final cur = p.c.value.position.inMilliseconds / 1000.0;
        if ((cur - target).abs() > 0.035) _seek(p, target);
      }
    }

    for (var i = 0; i < project.main.length; i++) {
      final c = project.main[i];
      if (c.isImage) continue;
      final start = project.mainStart(i);
      final lt = position - start;
      // Fade audio across transitions as well as the clip's own fades.
      visit(c.id, c.path, start, c.duration, c.inPoint, c.speed,
          _clipVolume(c, lt, project.transitionAfter(i - 1), project.transitionAfter(i)));
    }
    for (final c in project.overlays) {
      if (c.isImage) continue;
      visit(c.id, c.path, c.start, c.duration, c.inPoint, c.speed, _clipVolume(c, position - c.start, 0, 0));
    }
    for (final a in project.audios) {
      final lt = position - a.start;
      visit(a.id, a.path, a.start, a.duration, a.inPoint, 1, a.volume * _fade(lt, a.duration, a.fadeIn, a.fadeOut));
    }

    // Park players that are no longer near the playhead; keep a few warm.
    final idle = _players.entries.where((e) => !needed.contains(e.key)).toList()
      ..sort((a, b) => b.value.lastUsed.compareTo(a.value.lastUsed));
    for (var i = 0; i < idle.length; i++) {
      final p = idle[i].value;
      if (p.ready && p.c.value.isPlaying) p.c.pause();
      if (i >= 3) {
        _players.remove(idle[i].key);
        p.c.dispose();
      }
    }
  }

  static double _fade(double lt, double dur, double fadeIn, double fadeOut) {
    var v = 1.0;
    if (fadeIn > 0 && lt < fadeIn) v *= (lt / fadeIn).clamp(0.0, 1.0);
    if (fadeOut > 0 && lt > dur - fadeOut) v *= ((dur - lt) / fadeOut).clamp(0.0, 1.0);
    return v;
  }

  double _clipVolume(Clip c, double lt, double transIn, double transOut) {
    if (!c.audible) return 0;
    return c.volume *
        _fade(lt, c.duration, math.max(c.fadeIn, transIn), math.max(c.fadeOut, transOut));
  }

  void _setVolume(_Player p, double v) {
    v = v.clamp(0.0, 1.0);
    if ((p.lastVolume - v).abs() < 0.02) return;
    p.lastVolume = v;
    p.c.setVolume(v);
  }

  Future<void> _seek(_Player p, double seconds) async {
    if (p.seeking) {
      p.pendingSeek = seconds;
      return;
    }
    p.seeking = true;
    try {
      await p.c.seekTo(Duration(microseconds: (seconds * 1e6).round()));
      while (p.pendingSeek != null && !_disposed) {
        final next = p.pendingSeek!;
        p.pendingSeek = null;
        await p.c.seekTo(Duration(microseconds: (next * 1e6).round()));
      }
    } catch (_) {
      // The player may have been disposed mid-seek.
    } finally {
      p.seeking = false;
    }
    if (!_disposed && !playing) notifyListeners();
  }

  _Player _ensure(String id, String path) {
    final existing = _players[id];
    if (existing != null) return existing;
    final options = VideoPlayerOptions(mixWithOthers: true);
    final c = kIsWeb
        ? VideoPlayerController.networkUrl(Uri.parse(path), videoPlayerOptions: options)
        : VideoPlayerController.file(File(path), videoPlayerOptions: options);
    final p = _Player(c);
    _players[id] = p;
    c.initialize().then((_) {
      if (_disposed || _players[id] != p) return;
      p.ready = true;
      _sync();
      notifyListeners();
    }).catchError((Object _) {
      p.failed = true;
    });
    return p;
  }

  /// Drops the player for [id] (for example after its file was replaced).
  void forget(String id) {
    _players.remove(id)?.c.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    for (final p in _players.values) {
      p.c.dispose();
    }
    _players.clear();
    super.dispose();
  }
}
