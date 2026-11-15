import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'effects.dart';

/// Live approximations of the effects, built from widgets (the export uses the
/// exact FFmpeg versions). [make] builds a fresh copy of the clip's picture,
/// which glow-style effects stack on top of the original.
Widget applyFxPreview(List<ClipFx> effects, Widget base, Widget Function() make, double ch) {
  var w = base;
  for (final e in effects) {
    final def = e.def;
    if (def == null || !def.preview) continue;
    switch (e.type) {
      case 'halation':
      case 'bloom':
      case 'dream':
        final thr = e.type == 'dream' ? 0.0 : e.get('threshold') / 100;
        final k = thr >= 0.99 ? 100.0 : 1 / (1 - thr);
        final warm = e.type == 'halation' ? e.get('warmth') / 100 : 0.0;
        final tr = 1.0, tg = 1 - 0.72 * warm, tb = 1 - 0.95 * warm;
        final alpha = thr == 0
            ? <double>[0, 0, 0, 0, 255]
            : <double>[k * .299, k * .587, k * .114, 0, -k * thr * 255];
        final glow = ColorFiltered(
          colorFilter: ColorFilter.matrix(<double>[
            tr, 0, 0, 0, 0, //
            0, tg, 0, 0, 0,
            0, 0, tb, 0, 0,
            ...alpha,
          ]),
          child: make(),
        );
        final s = e.get('size') / 100 * 0.06 * ch;
        final amount = (e.get('amount') / 100).clamp(0.0, 1.0);
        w = Stack(fit: StackFit.expand, children: [
          w,
          Opacity(
            opacity: amount,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal),
              child: glow,
            ),
          ),
        ]);
      case 'vignette':
        final a = (e.get('amount') / 100).clamp(0.0, 1.0);
        w = Stack(fit: StackFit.expand, children: [
          w,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.95,
                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.85 * a)],
                  stops: const [0.45, 1],
                ),
              ),
            ),
          ),
        ]);
      case 'letterbox':
        final b = e.get('size') / 100;
        w = Stack(fit: StackFit.expand, children: [
          w,
          Align(alignment: Alignment.topCenter, child: FractionallySizedBox(heightFactor: b, widthFactor: 1, child: const ColoredBox(color: Colors.black))),
          Align(alignment: Alignment.bottomCenter, child: FractionallySizedBox(heightFactor: b, widthFactor: 1, child: const ColoredBox(color: Colors.black))),
        ]);
      case 'boxblur':
        final s = e.get('amount') / 100 * 0.025 * ch;
        w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal), child: w);
      case 'motionblur':
        final s = e.get('amount') / 100 * 0.06 * ch;
        w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: 0.01, tileMode: TileMode.decal), child: w);
      case 'vblur':
        final s = e.get('amount') / 100 * 0.06 * ch;
        w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 0.01, sigmaY: s, tileMode: TileMode.decal), child: w);
      case 'invert':
        w = ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            -1, 0, 0, 0, 255, //
            0, -1, 0, 0, 255,
            0, 0, -1, 0, 255,
            0, 0, 0, 1, 0,
          ]),
          child: w,
        );
      case 'sepia':
        w = ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            .393, .769, .189, 0, 0, //
            .349, .686, .168, 0, 0,
            .272, .534, .131, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: w,
        );
      case 'flipv':
        w = Transform.flip(flipY: true, child: w);
    }
  }
  return w;
}
