import 'dart:async';

import 'package:flutter/material.dart';

void showGuide(BuildContext context, {bool welcome = false}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(welcome ? 'Welcome to New note' : 'Guide'),
      content: const SingleChildScrollView(
        child: Text(
          '- Tap + to create a note or folder.\n'
          '- Pen, highlighter and eraser are in the floating toolbar. Drag its handle to move it, or use the dock button to snap it to an edge.\n'
          '- Lasso: draw around strokes to select, drag to move, drag the corner square to resize. Copy, cut or delete from the bar.\n'
          '- Hand tool: pinch or drag to zoom and pan.\n'
          '- Bucket: tap inside a rectangle, circle or star to fill it.\n'
          '- Pencase: save your favourite pens and pick them in one tap.\n'
          '- Right panel (gear): pages, templates, stickers, calculator, timer and settings.\n'
          '- Ruler, compass and divider tools show measurements. Insert images from the toolbar, import PDFs from the + menu and annotate on them.\n'
          '- Turn on Stylus Mode in Settings to stop finger touches drawing. Double-tap the pen to switch between pen and eraser.',
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
    ),
  );
}

void showCalculator(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _CalcDialog());

void showTimerDialog(BuildContext context) =>
    showDialog(context: context, builder: (_) => const _TimerDialog());

class _CalcDialog extends StatefulWidget {
  const _CalcDialog();
  @override
  State<_CalcDialog> createState() => _CalcDialogState();
}

class _CalcDialogState extends State<_CalcDialog> {
  String display = '0';
  double? acc;
  String? op;
  bool fresh = true;

  String _fmt(double v) {
    if (v.isNaN || v.isInfinite) return 'Error';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  }

  void _compute() {
    final cur = double.tryParse(display) ?? 0;
    if (acc != null && op != null) {
      if (op == '+') acc = acc! + cur;
      if (op == '-') acc = acc! - cur;
      if (op == 'x') acc = acc! * cur;
      if (op == '/') acc = cur == 0 ? double.nan : acc! / cur;
      display = _fmt(acc!);
    } else {
      acc = cur;
    }
  }

  void _press(String k) {
    setState(() {
      if ('0123456789.'.contains(k)) {
        if (fresh) {
          display = k == '.' ? '0.' : k;
          fresh = false;
        } else if (!(k == '.' && display.contains('.'))) {
          display += k;
        }
      } else if (k == 'C') {
        display = '0';
        acc = null;
        op = null;
        fresh = true;
      } else if (k == '+/-') {
        if (display != '0' && display != 'Error') {
          display = display.startsWith('-') ? display.substring(1) : '-$display';
        }
      } else if (k == '%') {
        display = _fmt((double.tryParse(display) ?? 0) / 100);
        fresh = true;
      } else {
        _compute();
        if (k == '=') {
          acc = null;
          op = null;
        } else {
          op = k;
        }
        fresh = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['C', '+/-', '%', '/'],
      ['7', '8', '9', 'x'],
      ['4', '5', '6', '-'],
      ['1', '2', '3', '+'],
      ['0', '.', '='],
    ];
    return AlertDialog(
      title: const Text('Calculator'),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.all(12),
            child: Text(display, style: const TextStyle(fontSize: 36)),
          ),
          for (final r in rows)
            Row(children: [
              for (final k in r)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: FilledButton.tonal(
                      onPressed: () => _press(k),
                      child: Text(k, style: const TextStyle(fontSize: 20)),
                    ),
                  ),
                ),
            ]),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

class _TimerDialog extends StatefulWidget {
  const _TimerDialog();
  @override
  State<_TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<_TimerDialog> {
  int total = 300;
  int left = 300;
  Timer? t;
  bool running = false;

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  void _start() {
    t?.cancel();
    setState(() => running = true);
    t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (left <= 1) {
        t?.cancel();
        setState(() {
          left = 0;
          running = false;
        });
      } else {
        setState(() => left--);
      }
    });
  }

  void _pause() {
    t?.cancel();
    setState(() => running = false);
  }

  void _set(int minutes) {
    t?.cancel();
    setState(() {
      total = minutes * 60;
      left = total;
      running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mm = (left ~/ 60).toString().padLeft(2, '0');
    final ss = (left % 60).toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('Timer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(left == 0 ? "Time's up!" : '$mm:$ss', style: const TextStyle(fontSize: 48)),
        Wrap(spacing: 6, children: [
          for (final m in [1, 5, 10, 25, 45])
            ActionChip(label: Text('$m min'), onPressed: () => _set(m)),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => _set(total ~/ 60), child: const Text('Reset')),
        TextButton(
            onPressed: running ? _pause : (left == 0 ? null : _start),
            child: Text(running ? 'Pause' : 'Start')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
