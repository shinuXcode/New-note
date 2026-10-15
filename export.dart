import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'canvas.dart';
import 'models.dart';

Future<ui.Image?> loadImage(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

Future<Uint8List> renderPagePng(PageData page, Map<String, ui.Image> images) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(2.0);
  PagePainter(page, null, images: images).paint(canvas, const Size(kPageW, kPageH));
  final img = await rec.endRecording().toImage((kPageW * 2).round(), (kPageH * 2).round());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
