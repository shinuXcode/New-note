import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdflib;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import 'canvas.dart';
import 'export.dart';
import 'models.dart';
import 'store.dart';
import 'tools.dart';

class _Snap {
  final int page;
  final List<Stroke> strokes;
  final List<TextItem> texts;
  final List<ImageItem> images;
  _Snap(this.page, this.strokes, this.texts, this.images);
}

class EditorPage extends StatefulWidget {
  final AppStore store;
  final Item note;
  const EditorPage({super.key, required this.store, required this.note});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  int pageIndex = 0;
  ToolType tool = ToolType.pen;
  ShapeKind shapeKind = ShapeKind.line;
  int color = 0xFF313131;
  double width = 5;
  bool stylusOnly = false; // when true, finger touch cannot draw
  bool pressure = true;
  bool showPageNumber = true;
  bool fullScreen = false;
  bool autoShape = true;
  double eraserRadius = 18;
  bool resizing = false;
  bool palmReject = true;
  PdfDocument? pdf;
  final Map<String, ui.Image> images = {};
  final Set<String> _busy = {};
  final Set<String> _failed = {};
  String? pendingImage;
  String? measure;
  Offset? measurePos;
  DateTime? lastStylus;
  DateTime? lastStylusDown;
  Offset? lastStylusDownPos;
  Offset resizeOrigin = Offset.zero;
  Offset tbPos = const Offset(12, 8);
  bool tbVertical = false;
  final Set<Stroke> selected = {};
  List<Offset> lassoPts = [];
  bool movingSel = false;
  Offset? lastPos;
  final TransformationController tc = TransformationController();

  Stroke? live;
  Offset? downPos;
  bool movedFar = false;
  bool erasedThisGesture = false;
  final List<_Snap> undoStack = [];
  final List<_Snap> redoStack = [];
  final GlobalKey repaintKey = GlobalKey();
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  static const swatches = [
    0xFF313131, 0xFF6C8CFF, 0xFF11AE9C, 0xFF4CAF10, 0xFFB71010, 0xFF9A9A10,
  ];

  Item get note => widget.note;
  PageData get page => note.pages[pageIndex];

  @override
  void initState() {
    super.initState();
    if (note.pages.isEmpty) note.pages.add(PageData());
    pageIndex = note.lastPage.clamp(0, note.pages.length - 1);
    _openPdf();
  }

  @override
  void dispose() {
    tc.dispose();
    pdf?.dispose();
    widget.store.saveNow();
    super.dispose();
  }

  // ---------- undo / redo ----------
  _Snap _snap() =>
      _Snap(pageIndex, List.of(page.strokes), List.of(page.texts), List.of(page.images));

  void _pushUndo() {
    undoStack.add(_snap());
    redoStack.clear();
  }

  void _restore(_Snap s) {
    if (s.page >= note.pages.length) return;
    selected.clear();
    pageIndex = s.page;
    page.strokes = List.of(s.strokes);
    page.texts = List.of(s.texts);
    page.images = List.of(s.images);
  }

  void _undo() {
    if (undoStack.isEmpty) return;
    redoStack.add(_snap());
    setState(() => _restore(undoStack.removeLast()));
    widget.store.touch(note);
  }

  void _redo() {
    if (redoStack.isEmpty) return;
    undoStack.add(_snap());
    setState(() => _restore(redoStack.removeLast()));
    widget.store.touch(note);
  }

  // ---------- pointer handling ----------
  bool _accept(PointerEvent e) {
    if (e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus) {
      lastStylus = DateTime.now();
      return true;
    }
    if (e.kind == PointerDeviceKind.touch) {
      if (stylusOnly) return false;
      if (palmReject) {
        if (e.radiusMajor > 30) return false;
        if (lastStylus != null &&
            DateTime.now().difference(lastStylus!) < const Duration(milliseconds: 1500)) {
          return false;
        }
      }
    }
    return true;
  }

  String _cm(double d) => '${(d * 0.021).toStringAsFixed(1)} cm';

  void _stylusDoubleTap() {
    if (page.strokes.isNotEmpty && undoStack.isNotEmpty) {
      final s = page.strokes.last;
      if (s.shape == null && s.points.length <= 3) {
        page.strokes.removeLast();
        undoStack.removeLast();
      }
    }
    setState(() => tool = tool == ToolType.eraser ? ToolType.pen : ToolType.eraser);
  }

  double _pressureOf(PointerEvent e) {
    if (!pressure) return 1;
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      if (e.pressureMax > e.pressureMin) {
        return ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
            .clamp(0.2, 1.0);
      }
    }
    return 1;
  }

  Rect _selBounds() {
    Rect? r;
    for (final s in selected) {
      r = r == null ? bounds(s) : r.expandToInclude(bounds(s));
    }
    return r ?? Rect.zero;
  }

  void _beginMove() {
    _pushUndo();
    final copies = <Stroke>[];
    for (int i = 0; i < page.strokes.length; i++) {
      final s = page.strokes[i];
      if (selected.contains(s)) {
        final c = s.copy();
        page.strokes[i] = c;
        copies.add(c);
      }
    }
    selected
      ..clear()
      ..addAll(copies);
  }

  bool _inLasso(Stroke s) {
    if (lassoPts.length < 3) return false;
    final pts = s.shape == null ? s.points : outline(s);
    return pts.any((p) => polygonContains(lassoPts, p));
  }

  void _down(PointerDownEvent e) {
    if (!_accept(e) || tool == ToolType.hand) return;
    final p = e.localPosition;
    if (e.kind == PointerDeviceKind.stylus) {
      final now = DateTime.now();
      if (lastStylusDown != null &&
          now.difference(lastStylusDown!) < const Duration(milliseconds: 320) &&
          (p - lastStylusDownPos!).distance < 40) {
        lastStylusDown = null;
        _stylusDoubleTap();
        return;
      }
      lastStylusDown = now;
      lastStylusDownPos = p;
    }
    if (pendingImage != null) {
      final img = images[pendingImage!];
      if (img != null) {
        const w = 420.0;
        final h = w * img.height / img.width;
        _pushUndo();
        page.images.add(ImageItem(pendingImage!, Rect.fromCenter(center: p, width: w, height: h)));
        widget.store.touch(note);
      }
      pendingImage = null;
      setState(() {});
      return;
    }
    downPos = p;
    movedFar = false;
    erasedThisGesture = false;
    if (tool == ToolType.pen || tool == ToolType.highlighter) {
      live = Stroke(
          highlighter: tool == ToolType.highlighter,
          color: color,
          width: width,
          points: [p],
          pressures: [_pressureOf(e)]);
    } else if (tool == ToolType.shape) {
      live = Stroke(
          highlighter: false,
          shape: shapeKind,
          color: color,
          width: width,
          points: [p, p],
          pressures: [1, 1]);
    } else if (tool == ToolType.ruler || tool == ToolType.divider) {
      live = Stroke(
          highlighter: false,
          shape: ShapeKind.line,
          color: tool == ToolType.ruler ? color : 0xFF607D8B,
          width: tool == ToolType.ruler ? width : 2,
          points: [p, p],
          pressures: [1, 1]);
    } else if (tool == ToolType.compass) {
      live = Stroke(
          highlighter: false,
          shape: ShapeKind.circle,
          color: color,
          width: width,
          points: [p, p],
          pressures: [1, 1]);
    } else if (tool == ToolType.laser) {
      live = Stroke(
          highlighter: false,
          color: 0xFFFF1744,
          width: 10,
          points: [p],
          pressures: [1]);
    } else if (tool == ToolType.lasso) {
      if (selected.isNotEmpty &&
          Rect.fromCenter(center: _selBounds().inflate(10).bottomRight, width: 44, height: 44)
              .contains(p)) {
        resizeOrigin = _selBounds().topLeft;
        _beginMove();
        resizing = true;
        movingSel = true;
        lastPos = p;
      } else if (selected.isNotEmpty && _selBounds().inflate(10).contains(p)) {
        _beginMove();
        movingSel = true;
        lastPos = p;
      } else {
        selected.clear();
        movingSel = false;
        lassoPts = [p];
      }
    } else if (tool == ToolType.bucket) {
      _fillAt(p);
    } else if (tool == ToolType.eraser) {
      _erase(p, first: true);
    }
    setState(() {});
  }

  void _move(PointerMoveEvent e) {
    if (!_accept(e) || downPos == null || tool == ToolType.hand) return;
    final p = e.localPosition;
    if ((p - downPos!).distance > 8) movedFar = true;
    if (tool == ToolType.lasso) {
      if (movingSel && resizing) {
        final den = lastPos!.dx - resizeOrigin.dx;
        if (den.abs() > 5) {
          final f = ((p.dx - resizeOrigin.dx) / den).clamp(0.5, 2.0).toDouble();
          for (final s in selected) {
            for (int i = 0; i < s.points.length; i++) {
              s.points[i] = resizeOrigin + (s.points[i] - resizeOrigin) * f;
            }
          }
          lastPos = p;
        }
      } else if (movingSel) {
        final d = p - lastPos!;
        lastPos = p;
        for (final s in selected) {
          for (int i = 0; i < s.points.length; i++) {
            s.points[i] = s.points[i] + d;
          }
        }
      } else {
        lassoPts.add(p);
      }
    } else if (live != null) {
      if (tool == ToolType.shape || tool == ToolType.ruler || tool == ToolType.divider) {
        live!.points[1] = p;
        if (tool != ToolType.shape) {
          measure = _cm((p - downPos!).distance);
          measurePos = (downPos! + p) / 2;
        }
      } else if (tool == ToolType.compass) {
        final r = (p - downPos!).distance;
        live!.points[0] = downPos! - Offset(r, r);
        live!.points[1] = downPos! + Offset(r, r);
        measure = 'r ${_cm(r)}';
        measurePos = downPos;
      } else {
        live!.points.add(p);
        live!.pressures.add(_pressureOf(e));
      }
    } else if (tool == ToolType.eraser) {
      _erase(p);
    }
    setState(() {});
  }

  Future<void> _up(PointerUpEvent e) async {
    if (!_accept(e) || downPos == null || tool == ToolType.hand) return;
    final p = e.localPosition;
    downPos = null;
    measure = null;
    measurePos = null;
    if (live != null) {
      var s = live!;
      live = null;
      if (tool != ToolType.laser && tool != ToolType.divider) {
        final tiny = ((tool == ToolType.shape || tool == ToolType.ruler) &&
                (s.points[0] - s.points[1]).distance < 6) ||
            (tool == ToolType.compass && (s.points[1].dx - s.points[0].dx).abs() < 6);
        if (autoShape && tool == ToolType.pen && s.points.length > 5) {
          final a = s.points.first, b = s.points.last;
          final len = (b - a).distance;
          if (len > 80) {
            double dev = 0;
            for (final q in s.points) {
              dev = math.max(dev, distToSeg(q, a, b));
            }
            if (dev < len * 0.04) {
              s = Stroke(
                  highlighter: false,
                  shape: ShapeKind.line,
                  color: s.color,
                  width: s.width,
                  points: [a, b],
                  pressures: [1, 1]);
            }
          }
        }
        if (s.shape == null && !s.highlighter && s.points.length > 4) s = _smooth(s);
        if (!tiny) {
          _pushUndo();
          page.strokes.add(s);
          if (tool == ToolType.ruler) {
            page.texts.add(TextItem((s.points[0] + s.points[1]) / 2 + const Offset(0, -34),
                _cm((s.points[1] - s.points[0]).distance), color, 26));
          }
          widget.store.touch(note);
        }
      }
    } else if (tool == ToolType.lasso) {
      if (movingSel) {
        movingSel = false;
        resizing = false;
        widget.store.touch(note);
      } else {
        selected.addAll(page.strokes.where(_inLasso));
        lassoPts = [];
      }
    } else if (tool == ToolType.text && !movedFar) {
      await _addText(p);
    }
    if (mounted) setState(() {});
  }

  void _cancel(PointerCancelEvent e) {
    downPos = null;
    live = null;
    movingSel = false;
    resizing = false;
    setState(() {});
  }

  void _erase(Offset p, {bool first = false}) {
    final radius = eraserRadius;
    final hitS = page.strokes.where((s) => strokeHit(s, p, radius)).toList();
    final hitT = page.texts.where((t) => textHit(t, p)).toList();
    final hitI = first && hitS.isEmpty && hitT.isEmpty
        ? page.images.where((i) => i.rect.contains(p)).toList()
        : <ImageItem>[];
    if (hitS.isEmpty && hitT.isEmpty && hitI.isEmpty) return;
    if (!erasedThisGesture) {
      _pushUndo();
      erasedThisGesture = true;
    }
    page.strokes.removeWhere(hitS.contains);
    page.texts.removeWhere(hitT.contains);
    page.images.removeWhere(hitI.contains);
    widget.store.touch(note);
  }

  Future<void> _addText(Offset p) async {
    final c = TextEditingController();
    final t = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(controller: c, autofocus: true, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
        ],
      ),
    );
    if (t == null || t.trim().isEmpty) return;
    _pushUndo();
    page.texts.add(TextItem(p, t, color, 34));
    widget.store.touch(note);
  }

  // ---------- pages ----------
  // ---------- PDF / images / export ----------
  Future<void> _openPdf() async {
    if (note.pdfPath == null) return;
    try {
      pdf = await PdfDocument.openFile(note.pdfPath!);
    } catch (e) {
      _snack('Could not open PDF: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _ensurePdfPage(int i) async {
    if (pdf == null || i < 0 || i >= note.pages.length) return;
    final pg = note.pages[i];
    if (pg.pdfIndex == null || pg.bgImage != null) return;
    final key = 'pdf${note.id}_${pg.pdfIndex}';
    if (_failed.contains(key) || !_busy.add(key)) return;
    try {
      await Future<void>.delayed(Duration.zero);
      final pp = pdf!.pages[pg.pdfIndex!];
      final k = 2000 / pp.height;
      final img = await pp.render(fullWidth: pp.width * k, fullHeight: pp.height * k);
      if (img == null) throw 'render returned nothing';
      final ui.Image uiImg = await img.createImage();
      img.dispose();
      final data = await uiImg.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}pdf_${note.id}_${pg.pdfIndex}.png');
      await f.writeAsBytes(data!.buffer.asUint8List());
      images[f.path] = uiImg;
      pg.bgImage = f.path;
      widget.store.save();
    } catch (e) {
      _failed.add(key);
      _snack('PDF page render failed: $e');
    } finally {
      _busy.remove(key);
      if (mounted) setState(() {});
    }
  }

  void _ensureAssets() {
    note.lastPage = pageIndex;
    final pg = page;
    final paths = [if (pg.bgImage != null) pg.bgImage!, for (final im in pg.images) im.path];
    for (final p in paths) {
      if (!images.containsKey(p) && !_failed.contains(p) && _busy.add(p)) {
        loadImage(p).then((img) {
          if (img != null) {
            images[p] = img;
          } else {
            _failed.add(p);
          }
          _busy.remove(p);
          if (mounted) setState(() {});
        });
      }
    }
    _ensurePdfPage(pageIndex);
    _ensurePdfPage(pageIndex + 1);
  }

  Future<void> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    final src = r?.files.single.path;
    if (src == null) return;
    final dot = src.lastIndexOf('.');
    final ext = dot < 0 ? '.png' : src.substring(dot);
    final dir = await getApplicationDocumentsDirectory();
    final dest = File(
        '${dir.path}${Platform.pathSeparator}img_${DateTime.now().microsecondsSinceEpoch}$ext');
    await File(src).copy(dest.path);
    final img = await loadImage(dest.path);
    if (img == null) {
      _snack('Could not read that image');
      return;
    }
    images[dest.path] = img;
    setState(() => pendingImage = dest.path);
    _snack('Tap the page where the image should go');
  }

  Future<void> _exportPdf() async {
    _snack('Preparing PDF...');
    try {
      final doc = pw.Document();
      for (int i = 0; i < note.pages.length; i++) {
        await _ensurePdfPage(i);
        final pg = note.pages[i];
        for (final p in [if (pg.bgImage != null) pg.bgImage!, for (final im in pg.images) im.path]) {
          if (!images.containsKey(p)) {
            final img = await loadImage(p);
            if (img != null) images[p] = img;
          }
        }
        final png = await renderPagePng(pg, images);
        final mem = pw.MemoryImage(png);
        doc.addPage(pw.Page(
          pageFormat: pdflib.PdfPageFormat.a4
              .copyWith(marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0),
          build: (_) => pw.Image(mem, fit: pw.BoxFit.fill),
        ));
      }
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}${note.title}.pdf');
      await f.writeAsBytes(await doc.save());
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _toggleBookmark() {
    setState(() => page.bookmark = !page.bookmark);
    widget.store.touch(note);
  }

  void _gotoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to page'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (int i = 0; i < note.pages.length; i++)
                ActionChip(
                  avatar: note.pages[i].bookmark ? const Icon(Icons.bookmark, size: 16) : null,
                  label: Text('${i + 1}'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      pageIndex = i;
                      undoStack.clear();
                      redoStack.clear();
                      selected.clear();
                    });
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Stroke _smooth(Stroke s) {
    final p = s.points;
    final out = <Offset>[p.first];
    for (int i = 1; i < p.length - 1; i++) {
      out.add((p[i - 1] + p[i] + p[i + 1]) / 3);
    }
    out.add(p.last);
    return s.copy(points: out);
  }

  void _fillAt(Offset p) {
    for (int i = page.strokes.length - 1; i >= 0; i--) {
      final s = page.strokes[i];
      if (s.shape == ShapeKind.rect || s.shape == ShapeKind.circle || s.shape == ShapeKind.star) {
        if (polygonContains(outline(s), p)) {
          _pushUndo();
          page.strokes[i] = s.copy(fill: color);
          widget.store.touch(note);
          return;
        }
      }
    }
    _snack('Tap inside a rectangle, circle or star to fill it');
  }

  void _copySel(bool cut) {
    if (selected.isEmpty) return;
    final cb = widget.store.clipboard;
    cb.insert(0, [for (final s in selected) s.copy()]);
    if (cb.length > 4) cb.removeLast();
    if (cut) {
      _pushUndo();
      setState(() {
        page.strokes.removeWhere(selected.contains);
        selected.clear();
      });
      widget.store.touch(note);
    } else {
      _snack('Copied');
    }
  }

  void _paste(int index) {
    final cb = widget.store.clipboard;
    if (index >= cb.length) return;
    _pushUndo();
    final added = [
      for (final s in cb[index])
        s.copy(points: [for (final p in s.points) p + const Offset(30, 30)])
    ];
    setState(() {
      page.strokes.addAll(added);
      selected
        ..clear()
        ..addAll(added);
      tool = ToolType.lasso;
    });
    widget.store.touch(note);
  }

  void _clipboardDialog() {
    final cb = widget.store.clipboard;
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Clipboard (last 4)'),
        children: cb.isEmpty
            ? [const Padding(padding: EdgeInsets.all(16), child: Text('Empty'))]
            : [
                for (int i = 0; i < cb.length; i++)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _paste(i);
                    },
                    child: Text('Item ${i + 1} - ${cb[i].length} strokes'),
                  ),
              ],
      ),
    );
  }

  static const stickerSets = {
    'Faces': ['😀', '😎', '😍', '🤔', '😴', '🥳'],
    'Study': ['📚', '✏️', '📝', '🧪', '🔬', '🧮'],
    'Symbols': ['⭐', '❤️', '✅', '❗', '❓', '💡'],
    'Nature': ['🌸', '🌳', '☀️', '🌙', '⛰️', '🔥'],
  };

  Future<void> _stickers() async {
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stickers'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final k in stickerSets.entries) ...[
                Text(k.key, style: const TextStyle(color: Colors.black54)),
                Wrap(children: [
                  for (final st in k.value)
                    InkWell(
                      onTap: () => Navigator.pop(ctx, st),
                      child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(st, style: const TextStyle(fontSize: 34))),
                    ),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
    if (pick == null) return;
    _pushUndo();
    page.texts.add(TextItem(const Offset(450, 650), pick, 0xFF000000, 90));
    widget.store.touch(note);
    setState(() {});
  }

  void _pencase() {
    showDialog(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: widget.store,
        builder: (_, __) => AlertDialog(
          title: const Text('Pencase'),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (widget.store.pens.isEmpty) const Text('No saved pens yet'),
              for (final p in widget.store.pens)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(radius: 12, backgroundColor: Color(p.color)),
                  title: Text('${p.highlighter ? "Highlighter" : "Pen"} - width ${p.width.round()}'),
                  onTap: () {
                    setState(() {
                      color = p.color;
                      width = p.width;
                      tool = p.highlighter ? ToolType.highlighter : ToolType.pen;
                    });
                    Navigator.pop(ctx);
                  },
                  trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => widget.store.deletePen(p)),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => widget.store
                    .addPen(FavPen(color, width, tool == ToolType.highlighter)),
                child: const Text('Save current pen')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  void _dock(String v) {
    final size = MediaQuery.of(context).size;
    setState(() {
      switch (v) {
        case 'top':
          tbVertical = false;
          tbPos = const Offset(12, 8);
        case 'bottom':
          tbVertical = false;
          tbPos = Offset(12, size.height - 190);
        case 'left':
          tbVertical = true;
          tbPos = const Offset(8, 70);
        default:
          tbVertical = true;
          tbPos = Offset(size.width - 72, 70);
      }
    });
  }

  void _zoom(double f) => setState(() => tc.value = tc.value.clone()..scale(f));

  void _addPage() {
    setState(() {
      note.pages.insert(pageIndex + 1, PageData(template: page.template));
      pageIndex++;
      undoStack.clear();
      redoStack.clear();
    });
    widget.store.touch(note);
  }

  void _deletePage() {
    if (note.pages.length == 1) {
      _clearPage();
      return;
    }
    setState(() {
      note.pages.removeAt(pageIndex);
      pageIndex = pageIndex.clamp(0, note.pages.length - 1);
      undoStack.clear();
      redoStack.clear();
    });
    widget.store.touch(note);
  }

  void _clearPage() {
    _pushUndo();
    setState(() {
      page.strokes = [];
      page.texts = [];
      page.images = [];
    });
    widget.store.touch(note);
  }

  Future<void> _chooseTemplate() async {
    final t = await showDialog<PageTemplate>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Page template'), children: [
        for (final t in PageTemplate.values)
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Text(t.name[0].toUpperCase() + t.name.substring(1))),
      ]),
    );
    if (t == null) return;
    setState(() => page.template = t);
    widget.store.touch(note);
  }

  Future<void> _exportPng() async {
    try {
      final b = repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      final dir = await getApplicationDocumentsDirectory();
      final f = File(
          '${dir.path}${Platform.pathSeparator}${note.title}_p${pageIndex + 1}.png');
      await f.writeAsBytes(data!.buffer.asUint8List());
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------- colour picker ----------
  Future<void> _pickColor() async {
    double hue = 0, light = 0.5;
    final hex = TextEditingController(
        text: color.toRadixString(16).substring(2).toUpperCase());
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Colour'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (int row = 0; row < 10; row++)
                Row(children: [
                  for (int col = 0; col < 13; col++)
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          final c = _gridColor(col, row).value;
                          setD(() => hex.text = c.toRadixString(16).substring(2).toUpperCase());
                        },
                        child: Container(height: 26, color: _gridColor(col, row)),
                      ),
                    ),
                ]),
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft, child: Text('Spectrum')),
              Slider(
                min: 0,
                max: 360,
                value: hue,
                onChanged: (v) => setD(() {
                  hue = v;
                  hex.text = HSLColor.fromAHSL(1, hue, 0.9, light).toColor().value
                      .toRadixString(16).substring(2).toUpperCase();
                }),
              ),
              Slider(
                min: 0.1,
                max: 0.9,
                value: light,
                onChanged: (v) => setD(() {
                  light = v;
                  hex.text = HSLColor.fromAHSL(1, hue, 0.9, light).toColor().value
                      .toRadixString(16).substring(2).toUpperCase();
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: hex,
                decoration: const InputDecoration(prefixText: '#', labelText: 'Hex'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final v = int.tryParse(hex.text, radix: 16);
                Navigator.pop(ctx, v == null ? null : 0xFF000000 | v);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => color = picked);
  }

  Color _gridColor(int col, int row) {
    final light = 0.92 - row * 0.08;
    if (col == 0) {
      final g = (255 * (1 - row / 9)).round();
      return Color.fromARGB(255, g, g, g);
    }
    return HSLColor.fromAHSL(1, (col - 1) * 30.0, 0.9, light).toColor();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final accent = Color(widget.store.accent);
    _ensureAssets();
    return Scaffold(
      key: scaffoldKey,
      endDrawer: _panel(accent),
      body: SafeArea(
        child: Column(children: [
          if (!fullScreen) _topBar(accent),
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, fullScreen ? 56 : 70, 8, 60),
                  child: InteractiveViewer(
                    transformationController: tc,
                    minScale: 0.5,
                    maxScale: 6,
                    panEnabled: tool == ToolType.hand,
                    scaleEnabled: tool == ToolType.hand,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: kPageW,
                        height: kPageH,
                        child: RepaintBoundary(
                          key: repaintKey,
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _down,
                            onPointerMove: _move,
                            onPointerUp: _up,
                            onPointerCancel: _cancel,
                            child: CustomPaint(
                                painter: PagePainter(page, live,
                                    selected: selected,
                                    lasso: lassoPts,
                                    images: images,
                                    measure: measure,
                                    measurePos: measurePos)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(left: tbPos.dx, top: tbPos.dy, child: _toolbar(accent)),
              Positioned(left: 16, bottom: 12, child: _pageNav()),
              if (selected.isNotEmpty)
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(24),
                      color: Theme.of(context).colorScheme.surface,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: 'Copy',
                          onPressed: () => _copySel(false),
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_cut),
                          tooltip: 'Cut',
                          onPressed: () => _copySel(true),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete selection',
                          onPressed: () {
                            _pushUndo();
                            setState(() {
                              page.strokes.removeWhere(selected.contains);
                              selected.clear();
                            });
                            widget.store.touch(note);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Deselect',
                          onPressed: () => setState(selected.clear),
                        ),
                      ]),
                    ),
                  ),
                ),
              if (fullScreen)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    onPressed: () => setState(() => fullScreen = false),
                    child: const Icon(Icons.fullscreen_exit),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _topBar(Color accent) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
        IconButton(
            icon: Icon(Icons.undo, color: undoStack.isEmpty ? Colors.black26 : Theme.of(context).colorScheme.onSurface),
            onPressed: _undo),
        IconButton(
            icon: Icon(Icons.redo, color: redoStack.isEmpty ? Colors.black26 : Theme.of(context).colorScheme.onSurface),
            onPressed: _redo),
        const SizedBox(width: 8),
        Expanded(
            child: Text(note.title,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16))),
        IconButton(icon: const Icon(Icons.note_add_outlined), tooltip: 'Add page', onPressed: _addPage),
        IconButton(icon: const Icon(Icons.grid_on), tooltip: 'Template', onPressed: _chooseTemplate),
        IconButton(
            icon: const Icon(Icons.fullscreen), onPressed: () => setState(() => fullScreen = true)),
        IconButton(icon: const Icon(Icons.ios_share), tooltip: 'Export PNG', onPressed: _exportPng),
        IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => scaffoldKey.currentState?.openEndDrawer()),
      ]),
    );
  }

  Widget _toolBtn(IconData icon, ToolType t, Color accent, {String? tip}) {
    final sel = tool == t;
    return Tooltip(
      message: tip ?? t.name,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() {
          tool = t;
          selected.clear();
          lassoPts = [];
        }),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: sel ? accent.withAlpha(40) : Colors.transparent, shape: BoxShape.circle),
          child: Icon(icon, color: sel ? accent : Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }

  IconData _shapeIcon(ShapeKind k) => switch (k) {
        ShapeKind.line => Icons.horizontal_rule,
        ShapeKind.arrow => Icons.arrow_right_alt,
        ShapeKind.rect => Icons.crop_square,
        ShapeKind.circle => Icons.circle_outlined,
        ShapeKind.star => Icons.star_border,
      };

  Widget _toolbar(Color accent) {
    final Widget div = tbVertical
        ? const SizedBox(width: 28, child: Divider())
        : const SizedBox(height: 28, child: VerticalDivider());
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(32),
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: tbVertical
            ? BoxConstraints(maxHeight: MediaQuery.of(context).size.height - 150)
            : BoxConstraints(maxWidth: math.min(900.0, MediaQuery.of(context).size.width - 24)),
        child: SingleChildScrollView(
          scrollDirection: tbVertical ? Axis.vertical : Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Flex(direction: tbVertical ? Axis.vertical : Axis.horizontal, children: [
            GestureDetector(
              onPanUpdate: (d) => setState(() => tbPos = Offset(
                  math.max(0, tbPos.dx + d.delta.dx), math.max(0, tbPos.dy + d.delta.dy))),
              child: const SizedBox(
                  width: 36,
                  height: 44,
                  child: Icon(Icons.drag_indicator, color: Colors.black45)),
            ),
            PopupMenuButton<String>(
              tooltip: 'Dock toolbar',
              icon: const Icon(Icons.open_with, color: Colors.black45),
              onSelected: _dock,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'top', child: Text('Dock top')),
                PopupMenuItem(value: 'bottom', child: Text('Dock bottom')),
                PopupMenuItem(value: 'left', child: Text('Dock left')),
                PopupMenuItem(value: 'right', child: Text('Dock right')),
              ],
            ),
            _toolBtn(Icons.edit, ToolType.pen, accent, tip: 'Pen'),
            _toolBtn(Icons.highlight, ToolType.highlighter, accent, tip: 'Highlighter'),
            _toolBtn(Icons.layers_clear, ToolType.eraser, accent, tip: 'Eraser'),
            _toolBtn(Icons.highlight_alt, ToolType.lasso, accent, tip: 'Lasso select'),
            _toolBtn(Icons.flash_on, ToolType.laser, accent, tip: 'Laser pointer'),
            _toolBtn(Icons.pan_tool, ToolType.hand, accent, tip: 'Move / zoom'),
            _toolBtn(Icons.format_color_fill, ToolType.bucket, accent, tip: 'Fill shape'),
            _toolBtn(Icons.straighten, ToolType.ruler, accent, tip: 'Ruler line'),
            _toolBtn(Icons.architecture, ToolType.compass, accent, tip: 'Compass circle'),
            _toolBtn(Icons.swap_horiz, ToolType.divider, accent, tip: 'Divider (measure)'),
            IconButton(icon: const Icon(Icons.image_outlined), tooltip: 'Insert image', onPressed: _pickImage),
            IconButton(icon: const Icon(Icons.bookmarks_outlined), tooltip: 'Pencase', onPressed: _pencase),
            IconButton(icon: const Icon(Icons.emoji_emotions_outlined), tooltip: 'Stickers', onPressed: _stickers),
            div,
            _toolBtn(Icons.text_fields, ToolType.text, accent, tip: 'Text'),
            PopupMenuButton<ShapeKind>(
              tooltip: 'Shapes',
              onSelected: (k) => setState(() {
                shapeKind = k;
                tool = ToolType.shape;
              }),
              itemBuilder: (_) => [
                for (final k in ShapeKind.values)
                  PopupMenuItem(
                      value: k,
                      child: Row(children: [
                        Icon(_shapeIcon(k)),
                        const SizedBox(width: 10),
                        Text(k.name),
                      ])),
              ],
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                    color: tool == ToolType.shape ? accent.withAlpha(40) : Colors.transparent,
                    shape: BoxShape.circle),
                child: Icon(_shapeIcon(shapeKind),
                    color: tool == ToolType.shape ? accent : Theme.of(context).colorScheme.onSurface),
              ),
            ),
            div,
            for (final w in [2.0, 5.0, 10.0])
              GestureDetector(
                onTap: () => setState(() => width = w),
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  child: Container(
                    width: 8 + w * 1.6,
                    height: 4 + w * 0.9,
                    decoration: BoxDecoration(
                        color: Color(color),
                        borderRadius: BorderRadius.circular(10),
                        border: width == w ? Border.all(color: accent, width: 2) : null),
                  ),
                ),
              ),
            div,
            for (final c in swatches)
              GestureDetector(
                onTap: () => setState(() => color = c),
                child: Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(8),
                    border: color == c ? Border.all(color: accent, width: 3) : null,
                  ),
                ),
              ),
            GestureDetector(
              onTap: _pickColor,
              child: Container(
                width: 30,
                height: 30,
                margin: const EdgeInsets.only(left: 5, right: 4),
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                child: const Icon(Icons.add, color: Colors.white, size: 20),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _pageNav() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: pageIndex == 0
                ? null
                : () => setState(() {
                      pageIndex--;
                      undoStack.clear();
                      redoStack.clear();
                    })),
        if (showPageNumber)
          InkWell(
            onTap: _gotoDialog,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Text('${pageIndex + 1} / ${note.pages.length}'),
            ),
          ),
        IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () {
              if (pageIndex == note.pages.length - 1) {
                _addPage();
              } else {
                setState(() {
                  pageIndex++;
                  undoStack.clear();
                  redoStack.clear();
                });
              }
            }),
      ]),
    );
  }

  // ---------- side panel: Tools / Export / Settings ----------
  Widget _panel(Color accent) {
    Widget item(IconData i, String t, VoidCallback f) => ListTile(
          leading: Icon(i),
          title: Text(t),
          onTap: () {
            Navigator.pop(context);
            f();
          },
        );

    return Drawer(
      width: 340,
      child: SafeArea(
        child: DefaultTabController(
          length: 3,
          child: Column(children: [
            TabBar(
              labelColor: accent,
              indicatorColor: accent,
              tabs: const [Tab(text: 'Tools'), Tab(text: 'Export'), Tab(text: 'Settings')],
            ),
            Expanded(
              child: TabBarView(children: [
                ListView(children: [
                  const _Header('Page'),
                  item(Icons.note_add_outlined, 'Add Page', _addPage),
                  item(Icons.grid_on, 'Template', _chooseTemplate),
                  item(Icons.delete_outline, 'Delete Page', _deletePage),
                  item(Icons.cleaning_services_outlined, 'Clear Page', _clearPage),
                  item(Icons.bookmark_border, 'Bookmark this page', _toggleBookmark),
                  item(Icons.grid_view, 'Go to page / bookmarks', _gotoDialog),
                  const _Header('Other'),
                  item(Icons.fullscreen, 'FullScreen', () => setState(() => fullScreen = true)),
                  const _Header('View'),
                  item(Icons.zoom_in, 'Zoom In', () => _zoom(1.25)),
                  item(Icons.zoom_out, 'Zoom Out', () => _zoom(0.8)),
                  item(Icons.fit_screen, 'Reset Zoom', () => setState(() => tc.value = Matrix4.identity())),
                  const _Header('Insert & Edit'),
                  item(Icons.emoji_emotions_outlined, 'Stickers', _stickers),
                  item(Icons.paste, 'Clipboard history', _clipboardDialog),
                  item(Icons.calculate_outlined, 'Calculator', () => showCalculator(context)),
                  item(Icons.timer_outlined, 'Timer', () => showTimerDialog(context)),
                  item(Icons.help_outline, 'Guide', () => showGuide(context)),
                  item(Icons.image_outlined, 'Insert image', _pickImage),
                ]),
                ListView(children: [
                  const _Header('Export'),
                  item(Icons.picture_as_pdf, 'Whole note as PDF', _exportPdf),
                  item(Icons.image_outlined, 'Current page as PNG', _exportPng),
                ]),
                ListView(children: [
                  const _Header('Writing'),
                  SwitchListTile(
                    title: const Text('Stylus Mode'),
                    subtitle: const Text('Only allow stylus writing permitted'),
                    value: stylusOnly,
                    onChanged: (v) => setState(() => stylusOnly = v),
                  ),
                  SwitchListTile(
                    title: const Text('Pressure sensitivity'),
                    value: pressure,
                    onChanged: (v) => setState(() => pressure = v),
                  ),
                  SwitchListTile(
                    title: const Text('Auto Recognition'),
                    subtitle: const Text('Draw a straight line and it snaps straight'),
                    value: autoShape,
                    onChanged: (v) => setState(() => autoShape = v),
                  ),
                  ListTile(
                    title: Text('Eraser radius: ${eraserRadius.round()}'),
                    subtitle: Slider(
                        min: 6,
                        max: 60,
                        value: eraserRadius,
                        onChanged: (v) => setState(() => eraserRadius = v)),
                  ),
                  SwitchListTile(
                    title: const Text('Palm rejection'),
                    subtitle: const Text('Ignore large touches and touches right after the pen'),
                    value: palmReject,
                    onChanged: (v) => setState(() => palmReject = v),
                  ),
                  SwitchListTile(
                    title: const Text('Dark mode'),
                    value: widget.store.dark,
                    onChanged: (v) => widget.store.setDark(v),
                  ),
                  const _Header('Display'),
                  SwitchListTile(
                    title: const Text('Show page number'),
                    value: showPageNumber,
                    onChanged: (v) => setState(() => showPageNumber = v),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: const TextStyle(color: Colors.black54)),
      );
}
