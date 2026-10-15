import 'dart:ui';

enum ToolType { pen, highlighter, eraser, text, shape, lasso, laser, hand, bucket, ruler, compass, divider }

enum ShapeKind { line, arrow, rect, circle, star }

enum PageTemplate { blank, dots, grid, lines }

double _r1(double v) => (v * 10).round() / 10;

class Stroke {
  final bool highlighter;
  final ShapeKind? shape;
  final int color;
  final double width;
  final List<Offset> points;
  final List<double> pressures;
  final int? fill;

  Stroke({
    required this.highlighter,
    this.shape,
    required this.color,
    required this.width,
    required this.points,
    required this.pressures,
    this.fill,
  });

  Stroke copy({List<Offset>? points, int? fill}) => Stroke(
        highlighter: highlighter,
        shape: shape,
        color: color,
        width: width,
        points: points ?? List.of(this.points),
        pressures: List.of(pressures),
        fill: fill ?? this.fill,
      );

  Map<String, dynamic> toJson() => {
        'h': highlighter,
        's': shape?.index,
        'c': color,
        'w': width,
        'p': [
          for (final p in points) [_r1(p.dx), _r1(p.dy)]
        ],
        'r': [for (final r in pressures) (r * 100).round() / 100],
        'f': fill,
      };

  factory Stroke.fromJson(Map<String, dynamic> j) => Stroke(
        highlighter: j['h'] as bool,
        shape: j['s'] == null ? null : ShapeKind.values[j['s'] as int],
        color: j['c'] as int,
        width: (j['w'] as num).toDouble(),
        points: [
          for (final p in j['p'] as List)
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
        ],
        pressures: [for (final r in j['r'] as List) (r as num).toDouble()],
        fill: j['f'] as int?,
      );
}

class TextItem {
  final Offset pos;
  final String text;
  final int color;
  final double size;
  const TextItem(this.pos, this.text, this.color, this.size);

  Map<String, dynamic> toJson() =>
      {'x': pos.dx, 'y': pos.dy, 't': text, 'c': color, 's': size};

  factory TextItem.fromJson(Map<String, dynamic> j) => TextItem(
        Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
        j['t'] as String,
        j['c'] as int,
        (j['s'] as num).toDouble(),
      );
}

class ImageItem {
  final String path;
  final Rect rect;
  const ImageItem(this.path, this.rect);

  Map<String, dynamic> toJson() =>
      {'p': path, 'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height};

  factory ImageItem.fromJson(Map<String, dynamic> j) => ImageItem(
        j['p'] as String,
        Rect.fromLTWH((j['x'] as num).toDouble(), (j['y'] as num).toDouble(),
            (j['w'] as num).toDouble(), (j['h'] as num).toDouble()),
      );
}

class PageData {
  List<Stroke> strokes;
  List<TextItem> texts;
  List<ImageItem> images;
  PageTemplate template;
  String? bgImage;
  int? pdfIndex;
  bool bookmark;

  PageData({
    List<Stroke>? strokes,
    List<TextItem>? texts,
    List<ImageItem>? images,
    this.template = PageTemplate.dots,
    this.bgImage,
    this.pdfIndex,
    this.bookmark = false,
  })  : strokes = strokes ?? [],
        texts = texts ?? [],
        images = images ?? [];

  Map<String, dynamic> toJson() => {
        'tpl': template.index,
        'strokes': [for (final s in strokes) s.toJson()],
        'texts': [for (final t in texts) t.toJson()],
        'images': [for (final i in images) i.toJson()],
        'bg': bgImage,
        'pdf': pdfIndex,
        'bm': bookmark,
      };

  factory PageData.fromJson(Map<String, dynamic> j) => PageData(
        template: PageTemplate.values[j['tpl'] as int],
        strokes: [
          for (final s in j['strokes'] as List)
            Stroke.fromJson(Map<String, dynamic>.from(s as Map))
        ],
        texts: [
          for (final t in j['texts'] as List)
            TextItem.fromJson(Map<String, dynamic>.from(t as Map))
        ],
        images: [
          for (final i in (j['images'] as List? ?? []))
            ImageItem.fromJson(Map<String, dynamic>.from(i as Map))
        ],
        bgImage: j['bg'] as String?,
        pdfIndex: j['pdf'] as int?,
        bookmark: j['bm'] as bool? ?? false,
      );
}

class Item {
  final String id;
  String title;
  final bool isFolder;
  String? parentId;
  bool favorite;
  bool trashed;
  DateTime modified;
  int color;
  List<PageData> pages;
  String? pdfPath;
  int lastPage;

  Item({
    required this.id,
    required this.title,
    required this.isFolder,
    this.parentId,
    this.favorite = false,
    this.trashed = false,
    DateTime? modified,
    this.color = 0xFFE8D9B5,
    List<PageData>? pages,
    this.pdfPath,
    this.lastPage = 0,
  })  : modified = modified ?? DateTime.now(),
        pages = pages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'folder': isFolder,
        'parent': parentId,
        'fav': favorite,
        'trash': trashed,
        'mod': modified.toIso8601String(),
        'color': color,
        'pages': [for (final p in pages) p.toJson()],
        'pdfPath': pdfPath,
        'last': lastPage,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        title: j['title'] as String,
        isFolder: j['folder'] as bool,
        parentId: j['parent'] as String?,
        favorite: j['fav'] as bool,
        trashed: j['trash'] as bool,
        modified: DateTime.parse(j['mod'] as String),
        color: j['color'] as int,
        pages: [
          for (final p in j['pages'] as List)
            PageData.fromJson(Map<String, dynamic>.from(p as Map))
        ],
        pdfPath: j['pdfPath'] as String?,
        lastPage: j['last'] as int? ?? 0,
      );
}

class Flashcard {
  final String id;
  String front;
  String back;
  Flashcard(this.id, this.front, this.back);

  Map<String, dynamic> toJson() => {'id': id, 'f': front, 'b': back};
  factory Flashcard.fromJson(Map<String, dynamic> j) =>
      Flashcard(j['id'] as String, j['f'] as String, j['b'] as String);
}

class FavPen {
  final int color;
  final double width;
  final bool highlighter;
  const FavPen(this.color, this.width, this.highlighter);

  Map<String, dynamic> toJson() => {'c': color, 'w': width, 'h': highlighter};
  factory FavPen.fromJson(Map<String, dynamic> j) =>
      FavPen(j['c'] as int, (j['w'] as num).toDouble(), j['h'] as bool);
}
