import 'package:flutter/material.dart';

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
    Widget slider = Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      onChanged: onChanged,
      onChangeEnd: (_) => onChangeEnd?.call(),
    );
    if (track != null) {
      slider = Stack(alignment: Alignment.center, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
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
    return SizedBox(
      height: 38,
      child: Row(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () {
            onChanged(def);
            onChangeEnd?.call();
          },
          child: SizedBox(
            width: 96,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
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

/// Icon-over-label button used in the bottom tool bars.
class ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final Color? color;

  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = !enabled
        ? AppColors.line
        : selected
            ? AppColors.accent
            : (color ?? AppColors.text);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 21, color: c),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 10.5, color: c)),
        ]),
      ),
    );
  }
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
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surfaceHi,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.black : AppColors.text,
              ),
            ),
          ]),
        ),
      ),
    );
  }
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
