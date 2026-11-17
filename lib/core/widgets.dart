import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';

/// A labelled slider row. Double-tap the label to reset to [def].
class ParamSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final double def;
  final int decimals;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final List<Color>? track;

  const ParamSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.def = 0,
    this.decimals = 0,
    this.track,
  });

  @override
  Widget build(BuildContext context) {
    final changed = (value - def).abs() > 1e-6;
    final text = decimals == 0
        ? value.round().toString()
        : value.toStringAsFixed(decimals);
    void reset() {
      if (changed) HapticFeedback.lightImpact();
      onChanged(def);
      onChangeEnd?.call();
    }

    // A soft detent at the default: values within a hair of it snap to it,
    // and crossing it gives a tick, so "back to neutral" can be felt.
    final detent = (max - min) * 0.008;
    void change(double v) {
      if ((v - def).abs() < detent) v = def;
      final before = (value - def).sign, after = (v - def).sign;
      if (before != after && (after == 0 || before != 0)) HapticFeedback.selectionClick();
      onChanged(v);
    }

    Widget slider = Builder(
      builder: (ctx) => SliderTheme(
        // A ring on the thumb shows the value has moved away from its default.
        data: SliderTheme.of(ctx).copyWith(
          thumbShape: _RingThumb(changed: changed),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: SliderGeom.overlay),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          semanticFormatterCallback: (_) => text,
          onChanged: change,
          onChangeEnd: (_) => onChangeEnd?.call(),
        ),
      ),
    );
    // Tapping the thumb itself (a quick press with no drag) resets the value.
    final inner = slider; // the closure must not capture the reassigned variable
    slider = LayoutBuilder(builder: (context, box) {
      final t = max > min ? ((value.clamp(min, max) - min) / (max - min)) : 0.0;
      const inset = SliderGeom.overlay;
      final thumbX = inset + t * (box.maxWidth - 2 * inset);
      return _TapThumb(thumbX: thumbX, onTap: reset, child: inner);
    });
    if (track != null) {
      slider = Stack(alignment: Alignment.center, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: SliderGeom.overlay),
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(colors: track!),
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
          ),
          child: slider,
        ),
      ]);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SliderGeom.rowHeight),
      child: Row(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: reset,
          child: SizedBox(
            width: 96,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: changed ? FontWeight.w600 : FontWeight.w400,
                color: changed ? AppColors.text : AppColors.textDim,
              ),
            ),
          ),
        ),
        Expanded(child: slider),
        SizedBox(
          width: 40,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: changed ? AppColors.accent : AppColors.textDim,
            ),
          ),
        ),
      ]),
    );
  }
}

/// Slider thumb: a paper-white disc, with an amber ring once the value has
/// moved off its default.
class _RingThumb extends SliderComponentShape {
  final bool changed;
  const _RingThumb({required this.changed});

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(18, 18);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final c = context.canvas;
    final grow = 1 + 0.15 * activationAnimation.value;
    if (changed) {
      c.drawCircle(center, 9 * grow + 2, Paint()..color = AppColors.accent.withValues(alpha: 0.9));
    }
    c.drawCircle(center, 9 * grow, Paint()..color = AppColors.text);
  }
}

/// Reports a quick, stationary tap that lands on the slider thumb, without
/// competing with the slider's own drag handling.
class _TapThumb extends StatefulWidget {
  final double thumbX;
  final VoidCallback onTap;
  final Widget child;
  const _TapThumb({required this.thumbX, required this.onTap, required this.child});

  @override
  State<_TapThumb> createState() => _TapThumbState();
}

class _TapThumbState extends State<_TapThumb> {
  Offset? _down;
  Duration? _at;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        _down = e.localPosition;
        _at = e.timeStamp;
      },
      onPointerUp: (e) {
        final d = _down;
        if (d != null &&
            (e.localPosition - d).distance < 10 &&
            e.timeStamp - _at! < const Duration(milliseconds: 350) &&
            (d.dx - widget.thumbX).abs() <= 22) {
          widget.onTap();
        }
        _down = null;
      },
      onPointerCancel: (_) => _down = null,
      child: widget.child,
    );
  }
}

/// Icon-over-label button used in the bottom tool bars.
class ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final Color? color;

  /// Shows a small cyan dot: this tool holds edits.
  final bool edited;

  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.color,
    this.edited = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = !enabled
        ? AppColors.line
        : selected
            ? AppColors.accent
            : (color ?? AppColors.text);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: edited ? '$label, edited' : label,
      excludeSemantics: true,
      child: InkWell(
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onTap?.call();
              }
            : null,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          constraints: const BoxConstraints(minWidth: 64, minHeight: 56),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent.withValues(alpha: 0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: selected ? AppColors.accent.withValues(alpha: 0.45) : Colors.transparent),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(icon, size: 22, color: c),
              if (edited)
                Positioned(
                  right: -5,
                  top: -3,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.accent2,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: AppColors.accent2.withValues(alpha: 0.6), blurRadius: 6)],
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: c)),
          ]),
        ),
      ),
    );
  }
}

/// The one primary action on an editor screen (usually Export). It is the
/// only element that glows, so it is always the easiest thing to find.
class GlowButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const GlowButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.control),
        boxShadow: on ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.35), blurRadius: 18, spreadRadius: -2)] : null,
      ),
      child: FilledButton(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18)),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// A thin vertical rule that separates groups of tools in a bar, so related
/// tools read as one chunk (proximity, common region).
class ToolGroupDivider extends StatelessWidget {
  const ToolGroupDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppColors.line,
      );
}

/// The bar that holds an editor's tools: the app's signature lit panel.
class ToolDock extends StatelessWidget {
  final Widget child;
  const ToolDock({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(color: AppColors.bg),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Container(
          decoration: litPanel(radius: AppRadius.card),
          child: Stack(children: [
            child,
            const Positioned(left: 0, right: 0, top: 0, child: LightEdge()),
          ]),
        ),
      );
}

/// Small selectable pill.
class Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  const Pill({super.key, required this.label, required this.selected, required this.onTap, this.leading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surfaceHi,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(color: selected ? AppColors.accent : AppColors.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.onAccent : AppColors.text,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The end of an export: a calm confirmation with the next steps, rather
/// than a toast that vanishes (peak-end rule).
Future<void> showDoneSheet(
  BuildContext context, {
  required String title,
  String? detail,
  VoidCallback? onShare,
}) {
  HapticFeedback.mediumImpact();
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withValues(alpha: 0.14),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.6)),
              boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: 0.25), blurRadius: 28)],
            ),
            child: const Icon(Icons.check_rounded, color: AppColors.accent, size: 34),
          ),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: display(20, weight: FontWeight.w600)),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textDim, height: 1.4)),
          ],
          const SizedBox(height: 22),
          Row(children: [
            if (onShare != null) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onShare();
                  },
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))),
          ]),
        ]),
      ),
    ),
  );
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
}

/// Runs [task] behind a modal progress dialog and returns its result.
Future<T?> withProgress<T>(
  BuildContext context,
  String message,
  Future<T> Function(ValueNotifier<double?> progress) task,
) async {
  final progress = ValueNotifier<double?>(null);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: p, color: AppColors.accent, backgroundColor: AppColors.line),
            const SizedBox(height: 16),
            Text(p == null ? message : '$message  ${(p * 100).round()}%'),
          ]),
        ),
      ),
    ),
  );
  try {
    return await task(progress);
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: null,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    ) ??
    false;
