import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'editor_page.dart';
import 'flashcards_page.dart';
import 'models.dart';
import 'store.dart';
import 'tools.dart';

class LibraryPage extends StatefulWidget {
  final AppStore store;
  const LibraryPage({super.key, required this.store});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String section = 'notes'; // notes | flashcards | favorites | trash
  final List<String> path = [];
  bool sidebar = true;
  bool searching = false;
  String query = '';

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!store.seenWelcome && mounted) {
        store.markWelcome();
        showGuide(context, welcome: true);
      }
    });
  }

  Future<void> _importPdf() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final src = r?.files.single.path;
    if (src == null) return;
    final name = src.split(RegExp(r'[\\/]')).last;
    final title = name.toLowerCase().endsWith('.pdf') ? name.substring(0, name.length - 4) : name;
    try {
      final doc = await PdfDocument.openFile(src);
      final count = doc.pages.length;
      doc.dispose();
      final it = store.create(
          folder: false, parentId: path.isEmpty ? null : path.last, title: title);
      final dir = await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}${Platform.pathSeparator}pdf_${it.id}.pdf');
      await File(src).copy(dest.path);
      it.pdfPath = dest.path;
      it.pages = [
        for (int i = 0; i < count; i++) PageData(template: PageTemplate.blank)..pdfIndex = i
      ];
      store.saveNow();
      _open(it);
    } catch (e) {
      _snack('Could not open PDF: $e');
    }
  }

  void _syncDialog() {
    final c = store.syncCfg;
    final url = TextEditingController(text: c.url);
    final user = TextEditingController(text: c.user);
    final secret = TextEditingController(text: c.secret);
    final bucket = TextEditingController(text: c.bucket);
    String mode = c.mode;
    String status = '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        void saveCfg() {
          c.mode = mode;
          c.url = url.text.trim();
          c.user = user.text.trim();
          c.secret = secret.text;
          c.bucket = bucket.text.trim();
          store.saveNow();
        }

        Future<void> run(Future<String> Function() f) async {
          saveCfg();
          setD(() => status = 'Working...');
          final res = await f();
          setD(() => status = res);
        }

        return AlertDialog(
          title: const Text('Cloud Sync'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButton<String>(
                  value: mode,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('Off')),
                    DropdownMenuItem(value: 'webdav', child: Text('WebDAV')),
                    DropdownMenuItem(value: 'supabase', child: Text('Supabase Storage')),
                  ],
                  onChanged: (v) => setD(() => mode = v ?? 'none'),
                ),
                TextField(
                    controller: url,
                    decoration: InputDecoration(
                        labelText: mode == 'supabase' ? 'Project URL' : 'WebDAV folder URL')),
                if (mode == 'webdav')
                  TextField(controller: user, decoration: const InputDecoration(labelText: 'Username')),
                TextField(
                    controller: secret,
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: mode == 'supabase' ? 'API key' : 'Password')),
                if (mode == 'supabase')
                  TextField(controller: bucket, decoration: const InputDecoration(labelText: 'Bucket name')),
                const SizedBox(height: 8),
                Text(status),
                const Text('Syncs note data only (not PDF/image files).',
                    style: TextStyle(fontSize: 12, color: Colors.black45)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => run(store.syncUp), child: const Text('Upload')),
            TextButton(onPressed: () => run(store.syncDown), child: const Text('Download')),
            TextButton(
                onPressed: () {
                  saveCfg();
                  Navigator.pop(ctx);
                },
                child: const Text('Save')),
          ],
        );
      }),
    );
  }

  void _pickCover(Item it) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cover'),
        content: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final c in AppStore.covers)
            GestureDetector(
              onTap: () {
                store.setCover(it, c);
                Navigator.pop(ctx);
              },
              child: Container(
                width: 48,
                height: 64,
                decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.black26)),
              ),
            ),
        ]),
      ),
    );
  }

  String _two(int n) => n.toString().padLeft(2, '0');
  String _fmt(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

  List<Item> get visible {
    Iterable<Item> r;
    if (section == 'favorites') {
      r = store.items.where((i) => i.favorite && !i.trashed);
    } else if (section == 'trash') {
      r = store.items.where((i) => i.trashed);
    } else {
      final parent = path.isEmpty ? null : path.last;
      r = store.items.where((i) => !i.trashed && i.parentId == parent);
    }
    if (query.isNotEmpty) {
      r = r.where((i) => i.title.toLowerCase().contains(query.toLowerCase()));
    }
    final list = r.toList();
    list.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return b.modified.compareTo(a.modified);
    });
    return list;
  }

  Future<String?> _prompt(String title, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _create(bool folder) async {
    final t = await _prompt(folder ? 'New folder' : 'New note', folder ? 'Folder' : 'Untitled');
    if (t == null || t.isEmpty) return;
    final it = store.create(
        folder: folder, parentId: path.isEmpty ? null : path.last, title: t);
    if (!folder) _open(it);
  }

  Future<void> _open(Item it) async {
    if (it.isFolder) {
      setState(() => path.add(it.id));
      return;
    }
    if (it.trashed) return;
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => EditorPage(store: store, note: it)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final accent = Color(store.accent);
        return Scaffold(
          body: SafeArea(
            child: Column(children: [
              _header(accent),
              const Divider(height: 1),
              Expanded(
                child: Row(children: [
                  if (sidebar) _sidebar(accent),
                  Expanded(child: _content(accent)),
                ]),
              ),
            ]),
          ),
          floatingActionButton: section == 'notes' ? _fab(accent) : null,
        );
      },
    );
  }

  Widget _header(Color accent) {
    final titles = {
      'notes': 'Notes',
      'flashcards': 'Flashcards',
      'favorites': 'Favorites',
      'trash': 'Trash'
    };
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => setState(() => sidebar = !sidebar)),
        if (path.isNotEmpty && section == 'notes')
          IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => path.removeLast())),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
              color: Colors.black.withAlpha(10),
              borderRadius: BorderRadius.circular(20)),
          child: Text(titles[section]!, style: TextStyle(color: accent, fontSize: 16)),
        ),
        const SizedBox(width: 12),
        if (searching)
          Expanded(
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search…', border: InputBorder.none),
              onChanged: (v) => setState(() => query = v),
            ),
          )
        else
          const Spacer(),
        IconButton(
          icon: Icon(searching ? Icons.close : Icons.search),
          onPressed: () => setState(() {
            searching = !searching;
            if (!searching) query = '';
          }),
        ),
      ]),
    );
  }

  Widget _sidebar(Color accent) {
    Widget tile(IconData icon, String label, String key) {
      final sel = section == key;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: ListTile(
          selected: sel,
          selectedTileColor: Colors.black.withAlpha(12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(icon, color: accent),
          title: Text(label, style: TextStyle(color: sel ? accent : Theme.of(context).colorScheme.onSurface)),
          onTap: () => setState(() {
            section = key;
            path.clear();
          }),
        ),
      );
    }

    return Container(
      width: 260,
      color: Theme.of(context).colorScheme.surface,
      child: ListView(children: [
        const SizedBox(height: 8),
        tile(Icons.description, 'Notes', 'notes'),
        tile(Icons.style, 'Flashcards', 'flashcards'),
        tile(Icons.star, 'Favorites', 'favorites'),
        tile(Icons.delete, 'Trash', 'trash'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.palette, color: accent),
            title: const Text('Theme Color'),
            onTap: _pickTheme,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.backup_outlined, color: accent),
            title: const Text('Local Backup'),
            onTap: () async {
              final p = await store.backup();
              _snack('Backup saved: $p');
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.restore, color: accent),
            title: const Text('Restore latest backup'),
            onTap: () async {
              final ok = await store.restoreLatest();
              _snack(ok ? 'Backup restored' : 'No backup found');
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.help_outline, color: accent),
            title: const Text('Guide'),
            onTap: () => showGuide(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.cloud_sync_outlined, color: accent),
            title: const Text('Cloud Sync'),
            onTap: _syncDialog,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            leading: Icon(Icons.dark_mode_outlined, color: accent),
            title: const Text('Dark mode'),
            trailing: Switch(value: store.dark, onChanged: store.setDark),
          ),
        ),
      ]),
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _pickTheme() {
    const colors = [
      0xFFFF6445, 0xFF3D7BFF, 0xFF11AE9C, 0xFF4CAF10,
      0xFF9C27B0, 0xFFE91E63, 0xFF795548, 0xFF313131,
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Theme Color'),
        content: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final c in colors)
            GestureDetector(
              onTap: () {
                store.setAccent(c);
                Navigator.pop(ctx);
              },
              child: CircleAvatar(backgroundColor: Color(c), radius: 22),
            ),
        ]),
      ),
    );
  }

  Widget _fab(Color accent) {
    return PopupMenuButton<String>(
      offset: const Offset(-40, -130),
      onSelected: (v) => v == 'pdf' ? _importPdf() : _create(v == 'folder'),
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'note',
            child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Note'))),
        PopupMenuItem(
            value: 'folder',
            child: ListTile(leading: Icon(Icons.folder_outlined), title: Text('Folder'))),
        PopupMenuItem(
            value: 'pdf',
            child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Import PDF'))),
      ],
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: accent, shape: BoxShape.circle, boxShadow: const [
          BoxShadow(blurRadius: 8, color: Colors.black26, offset: Offset(0, 3))
        ]),
        child: const Icon(Icons.add, color: Colors.white, size: 34),
      ),
    );
  }

  Widget _content(Color accent) {
    if (section == 'flashcards') {
      return FlashcardsView(store: store, accent: accent);
    }
    final list = visible;
    if (list.isEmpty) {
      return Center(
          child: Text(section == 'trash' ? 'Trash is empty' : 'Nothing here yet — tap +',
              style: const TextStyle(color: Colors.black45)));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.66,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _tile(list[i], accent),
    );
  }

  Widget _cover(Item it) {
    return Container(
      decoration: BoxDecoration(
        color: Color(it.color),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26, offset: Offset(0, 2))],
        border: Border.all(color: Colors.brown.withAlpha(60)),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Text(it.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 22, fontStyle: FontStyle.italic, color: Color(0xFF4A3B2A))),
    );
  }

  Widget _tile(Item it, Color accent) {
    return GestureDetector(
      onTap: () => _open(it),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: it.isFolder
              ? Center(child: Icon(Icons.folder, size: 120, color: accent.withAlpha(190)))
              : _cover(it),
        ),
        const SizedBox(height: 8),
        Row(children: [
          if (it.favorite) Icon(Icons.star, size: 16, color: accent),
          Expanded(
            child: Text(it.title.toUpperCase(),
                textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            padding: EdgeInsets.zero,
            onSelected: (v) async {
              if (v == 'rename') {
                final t = await _prompt('Rename', it.title);
                if (t != null && t.isNotEmpty) store.rename(it, t);
              } else if (v == 'cover') {
                _pickCover(it);
              } else if (v == 'fav') {
                store.toggleFavorite(it);
              } else if (v == 'trash') {
                store.setTrashed(it, true);
              } else if (v == 'restore') {
                store.setTrashed(it, false);
              } else if (v == 'delete') {
                store.deleteForever(it);
              }
            },
            itemBuilder: (_) => it.trashed
                ? const [
                    PopupMenuItem(value: 'restore', child: Text('Restore')),
                    PopupMenuItem(value: 'delete', child: Text('Delete forever')),
                  ]
                : [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    if (!it.isFolder)
                      const PopupMenuItem(value: 'cover', child: Text('Change cover')),
                    PopupMenuItem(
                        value: 'fav',
                        child: Text(it.favorite ? 'Remove favorite' : 'Add to favorites')),
                    const PopupMenuItem(value: 'trash', child: Text('Move to trash')),
                  ],
          ),
        ]),
        Text(_fmt(it.modified),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.black45)),
      ]),
    );
  }
}
