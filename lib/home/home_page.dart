import 'dart:typed_data';

import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.blur_circular, color: AppColors.accent),
          SizedBox(width: 8),
          Text('One For All Studio'),
        ]),
      ),
      body: IndexedStack(index: _tab, children: const [
        PhotosTab(),
        VideosTab(),
        CreateTab(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.accent.withValues(alpha: 0.25),
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo_outlined), selectedIcon: Icon(Icons.photo), label: 'Photos'),
          NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: 'Videos'),
          NavigationDestination(icon: Icon(Icons.dashboard_customize_outlined), selectedIcon: Icon(Icons.dashboard_customize), label: 'Create'),
        ],
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _import,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Import photos'),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14)),
              onPressed: _sample,
              child: const Text('Try a sample'),
            ),
          ]),
        ),
      ),
      if (_docs.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text('Your edited photos will appear here.', style: TextStyle(color: AppColors.textDim)),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
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
          borderRadius: BorderRadius.circular(6),
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
          if (!doc.settings.isDefault)
            const Positioned(
              right: 5,
              bottom: 5,
              child: Icon(Icons.tune, size: 14, color: Colors.white),
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
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: () => _open(Project()),
        icon: const Icon(Icons.add),
        label: const Text('New video project'),
      ),
      const SizedBox(height: 18),
      const Text('Templates', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SizedBox(
        height: 118,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final t in kVideoTemplates)
            GestureDetector(
              onTap: () => _useTemplate(t),
              child: Container(
                width: 150,
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: t.color.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(t.icon, color: t.color),
                  const SizedBox(height: 8),
                  Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(t.blurb, overflow: TextOverflow.fade, style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 18),
      const Text('Projects', style: TextStyle(fontWeight: FontWeight.w600)),
      if (_projects.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('Your video projects will appear here.', style: TextStyle(color: AppColors.textDim)),
        ),
      for (final p in _projects)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.movie_outlined, color: AppColors.accent),
          title: Text(p.name),
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
    ]);
  }
}

class CreateTab extends StatelessWidget {
  const CreateTab({super.key});

  @override
  Widget build(BuildContext context) {
    Widget card(IconData icon, String title, String sub, Widget page) => Card(
          color: AppColors.surface,
          child: ListTile(
            leading: Icon(icon, color: AppColors.accent),
            title: Text(title),
            subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
          ),
        );
    return ListView(padding: const EdgeInsets.all(16), children: [
      card(Icons.grid_view, 'Collage', 'Combine 2 to 9 photos in a grid.', const CollagePage()),
      card(Icons.auto_awesome_motion, 'Batch edit', 'Apply one look to many photos and export them together.', const BatchPage()),
    ]);
  }
}
