import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';

/// A ready-made edit: the user supplies clips, the template arranges them.
class VideoTemplate {
  final String name;
  final String blurb;
  final IconData icon;
  final List<int> aspect;
  final Color color;
  final void Function(Project p) arrange;
  const VideoTemplate(this.name, this.blurb, this.icon, this.aspect, this.color, this.arrange);

  Project build(List<Clip> clips) {
    final p = Project(name: name, aspectW: aspect[0], aspectH: aspect[1])..main = clips;
    arrange(p);
    return p;
  }
}

/// Limits a clip to [seconds] on the timeline (taking the middle of videos).
void _fit(Clip c, double seconds) {
  if (c.isImage) {
    c.outPoint = seconds;
    c.srcDuration = seconds;
    return;
  }
  final len = math.min(seconds * c.speed, c.srcDuration);
  final from = math.max(0.0, (c.srcDuration - len) / 2);
  c.inPoint = from;
  c.outPoint = from + len;
}

/// Scale that makes the clip cover the whole canvas.
double _cover(Clip c, Project p) {
  final canvas = p.aspect, src = c.srcW / c.srcH;
  return math.max(canvas / src, src / canvas);
}

TextItem _title(String text, double start, double dur, {double y = 0, double size = 0.07, String font = 'Inter'}) =>
    TextItem(text: text, start: start, duration: dur)
      ..y = y
      ..size = size
      ..font = font
      ..animIn = 'fade'
      ..animOut = 'fade';

final kVideoTemplates = <VideoTemplate>[
  VideoTemplate('Travel Reel', 'Warm tones, soft dissolves and a title card.', Icons.flight_takeoff, const [9, 16], const Color(0xFFE08A3C), (p) {
    for (final c in p.main) {
      _fit(c, 2.6);
      c
        ..scale = _cover(c, p)
        ..filter = 'Warm'
        ..filterAmount = 0.7
        ..transition = 'fade'
        ..transitionDur = 0.5;
    }
    p.texts.add(_title('WANDER', 0.2, 2.4, font: 'Bebas Neue', size: 0.11)..animIn = 'zoom');
    p.texts.add(_title('your story here', 0.6, 2.0, y: 0.09, size: 0.035, font: 'Caveat'));
  }),
  VideoTemplate('Beat Cuts', 'Fast punchy cuts for music edits.', Icons.bolt, const [9, 16], const Color(0xFFE5484D), (p) {
    for (var i = 0; i < p.main.length; i++) {
      final c = p.main[i];
      _fit(c, i.isEven ? 0.9 : 0.6);
      c
        ..scale = _cover(c, p)
        ..filter = 'Punch'
        ..transition = 'none';
      // A quick push-in on every cut.
      c.keys = [Keyframe(0, 0, 0, c.scale * 1.12, 0), Keyframe(c.duration, 0, 0, c.scale, 0)];
    }
  }),
  VideoTemplate('Slideshow', 'Slow zooms and dissolves for photos.', Icons.photo_library_outlined, const [16, 9], const Color(0xFF3E8ED0), (p) {
    for (var i = 0; i < p.main.length; i++) {
      final c = p.main[i];
      _fit(c, 3.5);
      final s = _cover(c, p);
      c
        ..transition = 'fade'
        ..transitionDur = 0.8
        ..keys = i.isEven
            ? [Keyframe(0, 0, 0, s, 0), Keyframe(c.duration, 0.02, 0, s * 1.14, 0)]
            : [Keyframe(0, -0.02, 0, s * 1.14, 0), Keyframe(c.duration, 0, 0, s, 0)];
    }
  }),
  VideoTemplate('Vintage Memories', 'Faded film look with dips to black.', Icons.camera_roll_outlined, const [4, 5], const Color(0xFF9C7A4D), (p) {
    for (final c in p.main) {
      _fit(c, 3.0);
      c
        ..scale = _cover(c, p)
        ..filter = 'Vintage'
        ..transition = 'fadeblack'
        ..transitionDur = 0.7;
    }
    p.texts.add(_title('memories', 0.3, 2.5, font: 'Pacifico', size: 0.08)
      ..y = 0.34
      ..color = 0xFFFFF3D6);
  }),
  VideoTemplate('Product Promo', 'Square format, slides and bold captions.', Icons.sell_outlined, const [1, 1], const Color(0xFF30A46C), (p) {
    for (var i = 0; i < p.main.length; i++) {
      final c = p.main[i];
      _fit(c, 2.2);
      c
        ..scale = _cover(c, p)
        ..filter = 'Vivid'
        ..filterAmount = 0.6
        ..transition = i.isEven ? 'slideleft' : 'slideup'
        ..transitionDur = 0.45;
    }
    p.texts.add(_title('NEW DROP', 0.1, 2.0, font: 'Anton', size: 0.12)
      ..animIn = 'slideUp'
      ..background = 0xCC000000);
    if (p.main.length > 1) {
      p.texts.add(_title('Shop now', p.mainDuration - 2.0, 1.9, y: 0.36, size: 0.055, font: 'Montserrat')
        ..animIn = 'slideUp'
        ..color = 0xFF000000
        ..shadow = false
        ..background = 0xFFFFD60A);
    }
  }),
];
