import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../core/save.dart';
import '../core/widgets.dart';
import '../home/home_page.dart';
import 'develop_settings.dart';
import 'photo_editor_page.dart';
import 'photo_library.dart';
import 'presets.dart';

/// Apply one look to many photos, then export them all.
class BatchPage extends StatefulWidget {
  const BatchPage({super.key});

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  late List<PhotoDoc> _docs;
  final _picked = <String>{};
  Preset? _preset;
  bool _useCopied = false;

  @override
  void initState() {
    super.initState();
    _docs = PhotoLibrary.all();
    _useCopied = PhotoClipboard.look != null;
  }

  List<PhotoDoc> get _targets => _docs.where((d) => _picked.contains(d.id)).toList();

  bool get _hasLook => _useCopied ? PhotoClipboard.look != null : _preset != null;

  void _applyTo(DevelopSettings s) {
    if (_useCopied) {
      s.applyLook(PhotoClipboard.look!);
    } else {
      _preset!.applyTo(s);
    }
  }

  Future<void> _apply() async {
    for (final d in _targets) {
      _applyTo(d.settings);
      PhotoLibrary.thumbs.remove(d.id);
      await PhotoLibrary.save(d);
      // Refresh the stored thumbnail with the new look.
      await PhotoLibrary.delete(d.id);
      await PhotoLibrary.save(d);
    }
    if (!mounted) return;
    setState(() => _docs = PhotoLibrary.all());
    toast(context, 'Look applied to ${_picked.length} photos');
  }

  Future<void> _export() async {
    final o = await showExportSheet(context, action: 'Export ${_picked.length} photos');
    if (o == null || !mounted) return;
    final targets = _targets;
    var done = 0;
    try {
      await withProgress(context, 'Exporting', (p) async {
        for (final d in targets) {
          final bytes = await PhotoExport.renderFile(d.path, d.settings, o);
          await Saver.saveImage(bytes, 'OFA_${DateTime.now().millisecondsSinceEpoch}_$done.${o.ext}');
          done++;
          p.value = done / targets.length;
        }
      });
      if (mounted) {
        await showDoneSheet(
          context,
          title: 'Exported $done ${done == 1 ? 'photo' : 'photos'}',
          detail: 'Saved at full resolution to the One For All Studio album.',
        );
      }
    } catch (e) {
      if (mounted) toast(context, 'Stopped after $done photos: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = [...kBuiltInPresets, ...UserPresets.all()];
    return Scaffold(
      appBar: AppBar(
        title: Text(_picked.isEmpty ? 'Batch edit' : '${_picked.length} selected'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (_picked.length == _docs.length) {
                _picked.clear();
              } else {
                _picked.addAll(_docs.map((d) => d.id));
              }
            }),
            child: Text(_picked.length == _docs.length && _docs.isNotEmpty ? 'Clear' : 'Select all'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _docs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Import photos on the Photos tab first, then come back to edit them together.',
                          textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 150, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: _docs.length,
                    itemBuilder: (_, i) => PhotoTile(
                      doc: _docs[i],
                      selected: _picked.contains(_docs[i].id),
                      onTap: () => setState(() => _picked.contains(_docs[i].id) ? _picked.remove(_docs[i].id) : _picked.add(_docs[i].id)),
                    ),
                  ),
          ),
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Look to apply', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              const SizedBox(height: 6),
              SizedBox(
                height: 32,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  if (PhotoClipboard.look != null)
                    Pill(label: 'Copied settings', selected: _useCopied, onTap: () => setState(() => _useCopied = true)),
                  for (final p in presets)
                    Pill(
                      label: p.name,
                      selected: !_useCopied && _preset == p,
                      onTap: () => setState(() {
                        _useCopied = false;
                        _preset = p;
                      }),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _picked.isNotEmpty && _hasLook ? _apply : null,
                    child: const Text('Apply look'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _picked.isNotEmpty ? _export : null,
                    child: const Text('Export selected'),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
