import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'sync.dart';

class AppStore extends ChangeNotifier {
  List<Item> items = [];
  List<Flashcard> cards = [];
  List<FavPen> pens = [];
  final List<List<Stroke>> clipboard = [];
  bool seenWelcome = false;
  bool dark = false;
  SyncConfig syncCfg = SyncConfig();
  int accent = 0xFFFF6445;
  File? _file;
  Timer? _debounce;

  static const covers = [
    0xFFE8D9B5, 0xFFBFD8E8, 0xFFD4E8BF, 0xFFE8BFC8, 0xFFD9C8E8, 0xFFF2D6A0,
    0xFFB5D6E8, 0xFFF5B7A0, 0xFFC9C9C9, 0xFF8FB8A0, 0xFFE8E0A0, 0xFFA0A8E8,
  ];

  void _apply(String text, {bool keepSync = false}) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    accent = j['accent'] as int? ?? accent;
    items = [
      for (final i in j['items'] as List)
        Item.fromJson(Map<String, dynamic>.from(i as Map))
    ];
    pens = [
      for (final p in (j['pens'] as List? ?? []))
        FavPen.fromJson(Map<String, dynamic>.from(p as Map))
    ];
    seenWelcome = j['welcome'] as bool? ?? false;
    dark = j['dark'] as bool? ?? dark;
    if (!keepSync && j['sync'] != null) {
      syncCfg = SyncConfig.fromJson(Map<String, dynamic>.from(j['sync'] as Map));
    }
    cards = [
      for (final c in (j['cards'] as List? ?? []))
        Flashcard.fromJson(Map<String, dynamic>.from(c as Map))
    ];
  }

  String _encode({bool withSync = true}) => jsonEncode({
        'accent': accent,
        'items': [for (final i in items) i.toJson()],
        'cards': [for (final c in cards) c.toJson()],
        'pens': [for (final p in pens) p.toJson()],
        'welcome': seenWelcome,
        'dark': dark,
        if (withSync) 'sync': syncCfg.toJson(),
      });

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}new_note.json');
    if (await _file!.exists()) {
      try {
        _apply(await _file!.readAsString());
      } catch (_) {}
    }
  }

  Future<void> _write() async {
    await _file?.writeAsString(_encode());
  }

  /// Saves a timestamped copy of all data; returns its path.
  Future<String> backup() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File(
        '${dir.path}${Platform.pathSeparator}new_note_backup_${DateTime.now().millisecondsSinceEpoch}.json');
    await f.writeAsString(_encode());
    return f.path;
  }

  /// Restores the newest backup; returns false if none exists.
  Future<bool> restoreLatest() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('new_note_backup_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return false;
    try {
      _apply(await files.last.readAsString());
      saveNow();
      return true;
    } catch (_) {
      return false;
    }
  }

  void setDark(bool v) {
    dark = v;
    saveNow();
  }

  Future<String> syncUp() => uploadData(syncCfg, _encode(withSync: false));

  Future<String> syncDown() async {
    final r = await downloadData(syncCfg);
    if (r.startsWith('ERR:')) return r.substring(4);
    try {
      _apply(r, keepSync: true);
      saveNow();
      return 'Downloaded';
    } catch (e) {
      return 'Bad data: $e';
    }
  }

  void addPen(FavPen p) {
    pens.add(p);
    saveNow();
  }

  void deletePen(FavPen p) {
    pens.remove(p);
    saveNow();
  }

  void setCover(Item it, int c) {
    it.color = c;
    saveNow();
  }

  void markWelcome() {
    seenWelcome = true;
    saveNow();
  }

  void addCard(String front, String back) {
    cards.add(Flashcard(DateTime.now().microsecondsSinceEpoch.toString(), front, back));
    saveNow();
  }

  void deleteCard(Flashcard c) {
    cards.remove(c);
    saveNow();
  }

  /// Debounced save (used while drawing).
  void save() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _write);
    notifyListeners();
  }

  void saveNow() {
    _debounce?.cancel();
    _write();
    notifyListeners();
  }

  Item create({required bool folder, String? parentId, required String title}) {
    final it = Item(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      isFolder: folder,
      parentId: parentId,
      color: covers[items.length % covers.length],
      pages: folder ? [] : [PageData()],
    );
    items.add(it);
    saveNow();
    return it;
  }

  void touch(Item it) {
    it.modified = DateTime.now();
    save();
  }

  void rename(Item it, String title) {
    it.title = title;
    touch(it);
  }

  void toggleFavorite(Item it) {
    it.favorite = !it.favorite;
    saveNow();
  }

  void setTrashed(Item it, bool value) {
    it.trashed = value;
    if (it.isFolder) {
      for (final c in items.where((x) => x.parentId == it.id)) {
        setTrashed(c, value);
      }
    }
    saveNow();
  }

  void deleteForever(Item it) {
    if (it.isFolder) {
      for (final c in items.where((x) => x.parentId == it.id).toList()) {
        deleteForever(c);
      }
    }
    items.remove(it);
    saveNow();
  }

  void setAccent(int c) {
    accent = c;
    saveNow();
  }
}
