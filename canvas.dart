import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import 'models.dart';

const double kPageW = 1000;
const double kPageH = 1400;
const Color kPaper = Color(0xFFE9EFF5);

Offset _starPoint(Offset c, double rx, double ry, int i) {
  final r = i.isEven ? 1.0 : 0.42;
  final ang = -math.pi / 2 + i * math.pi / 5;
  return Offset(c.dx + rx * r * math.cos(ang), c.dy + ry * r * math.sin(ang));
}

/// Polyline outline of a shape stroke (used for drawing and eraser hit-tests).
List<Offset> outline(Stroke s) {
  final a = s.points.first, b = s.points.last;
  final c = (a + b) / 2;
  final rx = (b.dx - a.dx).abs() / 2, ry = (b.dy - a.dy).abs() / 2;
  switch (s.shape) {
    case ShapeKind.rect:
      return [a, Offset(b.dx, a.dy), b, Offset(a.dx, b.dy), a];
    case ShapeKind.circle:
      return [
        for (int i = 0; i <= 48; i++)
          Offset(c.dx + rx * math.cos(2 * math.pi * i / 48),
              c.dy + ry * math.sin(2 * math.pi * i / 48))
      ];
    case ShapeKind.star:
      return [for (int i = 0; i <= 10; i++) _starPoint(c, rx, ry, i)];
    default:
      return [a, b];
  }
}

double distToSeg(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

Rect bounds(Stroke s) {
  final pts = s.shape == null ? s.points : outline(s);
  double minX = pts.first.dx, maxX = pts.first.dx, minY = pts.first.dy, maxY = pts.first.dy;
  for (final p in pts) {
    minX = math.min(minX, p.dx);
    maxX = math.max(maxX, p.dx);
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

bool polygonContains(List<Offset> poly, Offset p) {
  bool inside = false;
  for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

bool strokeHit(Stroke s, Offset p, double radius) {
  final pts = s.shape == null ? s.points : outline(s);
  if (pts.length == 1) return (pts.first - p).distance <= radius;
  for (int i = 1; i < pts.length; i++) {
    if (distToSeg(p, pts[i - 1], pts[i]) <= radius) return true;
  }
  return false;
}

bool textHit(TextItem t, Offset p) {
  final r = Rect.fromLTWH(
      t.pos.dx, t.pos.dy, t.text.length * t.size * 0.6, t.size * 1.3);
  return r.inflate(8).contains(p);
}

class PagePainter extends CustomPainter {
  final PageData page;
  final Stroke? live;
  final Set<Stroke> selected;
  final List<Offset> lasso;
  final Map<String, ui.Image> images;
  final String? measure;
  final Offset? measurePos;
  PagePainter(this.page, this.live,
      {this.selected = const {},
      this.lasso = const [],
      this.images = const {},
      this.measure,
      this.measurePos});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kPaper);
    final bg = page.bgImage == null ? null : images[page.bgImage];
    if (bg != null) {
      paintImage(canvas: canvas, rect: Offset.zero & size, image: bg, fit: BoxFit.contain);
    }
    _template(canvas);
    for (final im in page.images) {
      final img = images[im.path];
      if (img != null) paintImage(canvas: canvas, rect: im.rect, image: img, fit: BoxFit.fill);
    }
    for (final s in page.strokes) {
      _stroke(canvas, s);
    }
    if (live != null) _stroke(canvas, live!);
    for (final t in page.texts) {
      final tp = TextPainter(
        text: TextSpan(
            text: t.text,
            style: TextStyle(color: Color(t.color), fontSize: t.size)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 800);
      tp.paint(canvas, t.pos);
    }
    if (selected.isNotEmpty) {
      Rect? r;
      for (final s in selected) {
        r = r == null ? bounds(s) : r.expandToInclude(bounds(s));
      }
      final box = r!.inflate(10);
      canvas.drawRect(box, Paint()..color = const Color(0x143D7BFF));
      canvas.drawRect(
          box,
          Paint()
            ..color = const Color(0xFF3D7BFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      canvas.drawRect(Rect.fromCenter(center: box.bottomRight, width: 22, height: 22),
          Paint()..color = const Color(0xFF3D7BFF));
    }
    if (measure != null && measurePos != null) {
      final tp = TextPainter(
        text: TextSpan(
            text: measure,
            style: const TextStyle(
                color: Color(0xFF3D7BFF), fontSize: 28, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, measurePos! + const Offset(8, -36));
    }
    if (lasso.length > 1) {
      final path = Path()..moveTo(lasso.first.dx, lasso.first.dy);
      for (final q in lasso.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFF3D7BFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  void _template(Canvas c) {
    switch (page.template) {
      case PageTemplate.dots:
        final pts = <Offset>[
          for (double x = 40; x < kPageW; x += 40)
            for (double y = 40; y < kPageH; y += 40) Offset(x, y)
        ];
        c.drawPoints(
            PointMode.points,
            pts,
            Paint()
              ..color = const Color(0xFF8A8F98)
              ..strokeWidth = 4
              ..strokeCap = StrokeCap.round);
        break;
      case PageTemplate.grid:
        final p = Paint()
          ..color = const Color(0x33000000)
          ..strokeWidth = 1;
        for (double x = 40; x < kPageW; x += 40) {
          c.drawLine(Offset(x, 0), Offset(x, kPageH), p);
        }
        for (double y = 40; y < kPageH; y += 40) {
          c.drawLine(Offset(0, y), Offset(kPageW, y), p);
        }
        break;
      case PageTemplate.lines:
        final p = Paint()
          ..color = const Color(0x44000000)
          ..strokeWidth = 1;
        for (double y = 100; y < kPageH; y += 50) {
          c.drawLine(Offset(0, y), Offset(kPageW, y), p);
        }
        break;
      case PageTemplate.blank:
        break;
    }
  }

  void _stroke(Canvas c, Stroke s) {
    final col = Color(s.color);

    if (s.shape != null) {
      final p = Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final a = s.points.first, b = s.points.last;
      final fillPaint = s.fill == null ? null : (Paint()..color = Color(s.fill!));
      if (s.shape == ShapeKind.circle) {
        if (fillPaint != null) c.drawOval(Rect.fromPoints(a, b), fillPaint);
        c.drawOval(Rect.fromPoints(a, b), p);
        return;
      }
      final pts = outline(s);
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final q in pts.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      if (fillPaint != null && s.shape != ShapeKind.line && s.shape != ShapeKind.arrow) {
        c.drawPath(path, fillPaint);
      }
      c.drawPath(path, p);
      if (s.shape == ShapeKind.arrow && (b - a).distance > 1) {
        final ang = (b - a).direction;
        for (final d in [2.6, -2.6]) {
          c.drawLine(b, b + Offset.fromDirection(ang + d, 22), p);
        }
      }
      return;
    }

    if (s.highlighter) {
      final p = Paint()
        ..color = col.withAlpha(90)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.width * 3
        ..strokeCap = StrokeCap.square
        ..strokeJoin = StrokeJoin.round
        ..blendMode = BlendMode.multiply;
      if (s.points.length == 1) {
        c.drawCircle(s.points.first, s.width * 1.5, p..style = PaintingStyle.fill);
        return;
      }
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (final q in s.points.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      c.drawPath(path, p);
      return;
    }

    // Pen with pressure-sensitive width
    final p = Paint()
      ..color = col
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (s.points.length == 1) {
      c.drawCircle(s.points.first,
          s.width * (0.4 + 0.6 * s.pressures.first) / 2,
          Paint()..color = col);
      return;
    }
    for (int i = 1; i < s.points.length; i++) {
      final pr = (s.pressures[i] + s.pressures[i - 1]) / 2;
      p.strokeWidth = s.width * (0.4 + 0.6 * pr);
      c.drawLine(s.points[i - 1], s.points[i], p);
    }
  }

  @override
  bool shouldRepaint(covariant PagePainter old) => true;
}
