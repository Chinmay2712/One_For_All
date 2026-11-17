
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../core/media.dart';
import '../core/store.dart';
import '../core/widgets.dart';
import '../photo/batch_page.dart';
import '../photo/collage_page.dart';
import '../photo/photo_editor_page.dart';
import '../video/clip_factory.dart';
import '../video/models.dart' show Project, ProjectStore;
import '../video/templates.dart';
import '../video/timeline.dart' show formatTime;
import '../video/video_editor_page.dart';
import '../photo/photo_library.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // A faint safelight glow behind the header; the rest stays quiet.
      decoration: const BoxDecoration(
        color: AppColors.bg,
        gradient: RadialGradient(
          center: Alignment(-0.9, -1.05),
          radius: 1.1,
          colors: [Color(0x1FFFB02E), Color(0x0A4FD8E0), Color(0x0008090C)],
          stops: [0, 0.45, 1],
        ),
      ),
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        toolbarHeight: 64,
        titleSpacing: 20,
        title: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent),
            child: const Icon(Icons.blur_circular, size: 20, color: AppColors.onAccent),
          ),
          const SizedBox(width: 10),
          Text.rich(TextSpan(children: [
            TextSpan(text: 'One For All ', style: display(21)),
            TextSpan(text: 'Studio', style: display(21, weight: FontWeight.w400, color: AppColors.textDim)),
          ])),
        ]),
      ),
      body: IndexedStack(index: _tab, children: const [
        PhotosTab(),
        VideosTab(),
        CreateTab(),
      ]),
      // Floating dock: big targets in thumb reach, lit along its top edge.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          decoration: litPanel(glow: true),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            NavigationBar(
              backgroundColor: Colors.transparent,
              height: 70,
              selectedIndex: _tab,
              onDestinationSelected: (i) {
                HapticFeedback.selectionClick();
                setState(() => _tab = i);
              },
              destinations: const [
                NavigationDestination(icon: Icon(Icons.photo_outlined), selectedIcon: Icon(Icons.photo), label: 'Photos'),
                NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: 'Videos'),
                NavigationDestination(icon: Icon(Icons.dashboard_customize_outlined), selectedIcon: Icon(Icons.dashboard_customize), label: 'Create'),
              ],
            ),
            const Positioned(left: 0, right: 0, top: 0, child: LightEdge(inset: 30)),
          ]),
        ),
      ),
      ),
    );
  }
}

class PhotosTab extends StatefulWidget {
  const PhotosTab({super.key});

  @override
  State<PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<PhotosTab> {
  List<PhotoDoc> _docs = [];

  @override
  void initState() {
    super.initState();
    _docs = PhotoLibrary.all();
  }

  void _reload() => setState(() => _docs = PhotoLibrary.all());

  /// The most recently touched photo that has edits: unfinished work is what
  /// people come back for.
  PhotoDoc? get _resume {
    final edited = _docs.where((d) => !d.settings.isDefault).toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
    return edited.isEmpty ? null : edited.first;
  }

  Future<void> _open(PhotoDoc doc) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoEditorPage(doc: doc)));
    // The editor saves on dispose; give it a beat to write the thumbnail.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted) _reload();
  }

  Future<void> _import() async {
    final files = await Media.pickImages();
    if (files.isEmpty) return;
    PhotoDoc? first;
    for (final f in files) {
      final doc = PhotoDoc(id: Store.newId(), path: await Media.persist(f), name: f.name);
      await PhotoLibrary.save(doc);
      first ??= doc;
    }
    if (!mounted) return;
    _reload();
    if (files.length == 1) _open(first!);
  }

  Future<void> _sample() async {
    final doc = PhotoDoc(id: Store.newId(), path: kSamplePhotoPath, name: 'Sample landscape');
    await PhotoLibrary.save(doc);
    if (mounted) _open(doc);
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: _import,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Import photos'),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18)),
              onPressed: _sample,
              child: const Text('Try a sample'),
            ),
          ]),
        ),
      ),
      if (_resume case final doc?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: _ResumeCard(doc: doc, onTap: () => _open(doc)),
          ),
        ),
      if (_docs.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text('Library', style: display(18, weight: FontWeight.w600)),
          ),
        ),
      if (_docs.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.photo_library_outlined, size: 42, color: AppColors.line),
                const SizedBox(height: 14),
                Text('No photos yet', style: display(18, weight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(
                  'Import a photo to start editing. Everything you edit is saved here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textDim, height: 1.4),
                ),
              ]),
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.86,
            ),
            delegate: SliverChildBuilderDelegate(
              childCount: _docs.length,
              (context, i) => PhotoTile(
                doc: _docs[i],
                onTap: () => _open(_docs[i]),
                onLongPress: () async {
                  if (await confirm(context, 'Remove "${_docs[i].name}" from the library?', 'Remove')) {
                    await PhotoLibrary.delete(_docs[i].id);
                    _reload();
                  }
                },
              ),
            ),
          ),
        ),
    ]);
  }
}

class _ResumeCard extends StatelessWidget {
  final PhotoDoc doc;
  final VoidCallback onTap;
  const _ResumeCard({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Continue editing ${doc.name}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Ink(
            decoration: litPanel(radius: AppRadius.card),
            child: Stack(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: FutureBuilder<Uint8List?>(
                        key: ValueKey('resume-${doc.id}-${doc.updated}'),
                        future: PhotoLibrary.loadThumb(doc),
                        builder: (_, snap) => snap.data == null
                            ? Container(color: AppColors.surfaceHi)
                            : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Continue editing', style: display(16, weight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(doc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
                    ]),
                  ),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent),
                    child: const Icon(Icons.arrow_forward_rounded, color: AppColors.onAccent),
                  ),
                ]),
              ),
              const Positioned(left: 0, right: 0, top: 0, child: LightEdge()),
            ]),
          ),
        ),
      ),
    );
  }
}

class PhotoTile extends StatelessWidget {
  final PhotoDoc doc;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  const PhotoTile({super.key, required this.doc, required this.onTap, this.onLongPress, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 2.5),
        ),
        child: Stack(fit: StackFit.expand, children: [
          FutureBuilder<Uint8List?>(
            key: ValueKey('${doc.id}-${doc.updated}'),
            future: PhotoLibrary.loadThumb(doc),
            builder: (_, snap) => snap.data == null
                ? const Icon(Icons.image_outlined, color: AppColors.line)
                : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 22, 8, 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xCC000000)],
                ),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(doc.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
                ),
                if (!doc.settings.isDefault) const Icon(Icons.tune, size: 14, color: AppColors.accent),
              ]),
            ),
          ),
          if (selected)
            const Positioned(top: 5, right: 5, child: Icon(Icons.check_circle, color: AppColors.accent, size: 20)),
        ]),
      ),
    );
  }
}

class VideosTab extends StatefulWidget {
  const VideosTab({super.key});

  @override
  State<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends State<VideosTab> {
  List<Project> _projects = ProjectStore.all();

  Future<void> _open(Project p) async {
    await ProjectStore.save(p);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => VideoEditorPage(project: p)));
    if (mounted) setState(() => _projects = ProjectStore.all());
  }

  Future<void> _useTemplate(VideoTemplate t) async {
    var clips = await withProgress(context, 'Importing', (_) => ClipFactory.pick()) ?? [];
    if (!mounted) return;
    if (clips.isEmpty) {
      if (!await confirm(context, 'No media chosen. Try "${t.name}" with sample images?', 'Use samples')) return;
      clips = [for (var i = 0; i < 4; i++) await ClipFactory.sample()];
    }
    _open(t.build(clips));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: [
      FilledButton.icon(
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
        onPressed: () => _open(Project()),
        icon: const Icon(Icons.add),
        label: const Text('New video project'),
      ),
      const SizedBox(height: 26),
      Text('Templates', style: display(18, weight: FontWeight.w600)),
      const SizedBox(height: 12),
      SizedBox(
        height: 132,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
          for (final t in kVideoTemplates)
            GestureDetector(
              onTap: () => _useTemplate(t),
              child: Container(
                width: 156,
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Color.alphaBlend(t.color.withValues(alpha: 0.16), AppColors.surface),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: t.color.withValues(alpha: 0.35)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(t.icon, color: t.color, size: 22),
                  const SizedBox(height: 10),
                  Text(t.name, style: display(14, weight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(t.blurb, overflow: TextOverflow.fade, style: const TextStyle(fontSize: 11.5, color: AppColors.textDim, height: 1.3)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 26),
      Text('Projects', style: display(18, weight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (_projects.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('No projects yet. Start a new one or pick a template above.', style: TextStyle(color: AppColors.textDim, height: 1.4)),
        ),
      for (final p in _projects)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: const BorderSide(color: AppColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.only(left: 16, right: 6),
              leading: const Icon(Icons.movie_outlined, color: AppColors.accent),
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${formatTime(p.duration)}  ·  ${p.aspectW}:${p.aspectH}  ·  ${p.main.length} ${p.main.length == 1 ? 'clip' : 'clips'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
              onTap: () => _open(p),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  if (await confirm(context, 'Delete "${p.name}"?', 'Delete')) {
                    await ProjectStore.delete(p.id);
                    if (mounted) setState(() => _projects = ProjectStore.all());
                  }
                },
              ),
            ),
          ),
        ),
    ]);
  }
}

class CreateTab extends StatelessWidget {
  const CreateTab({super.key});

  @override
  Widget build(BuildContext context) {
    Widget card(IconData icon, String title, String sub, Widget page, Color tint) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Color.alphaBlend(tint.withValues(alpha: 0.10), AppColors.surface),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: BorderSide(color: tint.withValues(alpha: 0.30)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(color: tint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
                    child: Icon(icon, color: tint, size: 26),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: display(19, weight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(sub, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim, height: 1.35)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right, color: AppColors.textDim),
                ]),
              ),
            ),
          ),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), children: [
      card(Icons.grid_view_rounded, 'Collage', 'Frame one photo or combine up to 9.', const CollagePage(), AppColors.accent),
      card(Icons.auto_awesome_motion, 'Batch edit', 'Apply one look to many photos and export them together.', const BatchPage(), AppColors.accent2),
    ]);
  }
}
