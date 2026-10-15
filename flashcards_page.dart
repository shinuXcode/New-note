import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

class FlashcardsView extends StatefulWidget {
  final AppStore store;
  final Color accent;
  const FlashcardsView({super.key, required this.store, required this.accent});

  @override
  State<FlashcardsView> createState() => _FlashcardsViewState();
}

class _FlashcardsViewState extends State<FlashcardsView> {
  final Set<String> flipped = {};

  Future<void> _add() async {
    final f = TextEditingController();
    final b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New flashcard'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: f, decoration: const InputDecoration(labelText: 'Front'), autofocus: true),
          TextField(controller: b, decoration: const InputDecoration(labelText: 'Back')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok == true && f.text.trim().isNotEmpty) {
      widget.store.addCard(f.text.trim(), b.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.store.cards;
    return Stack(children: [
      cards.isEmpty
          ? const Center(child: Text('No flashcards yet - tap +', style: TextStyle(color: Colors.black45)))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300, childAspectRatio: 1.5, crossAxisSpacing: 14, mainAxisSpacing: 14),
              itemCount: cards.length,
              itemBuilder: (_, i) {
                final c = cards[i];
                final back = flipped.contains(c.id);
                return GestureDetector(
                  onTap: () => setState(() => back ? flipped.remove(c.id) : flipped.add(c.id)),
                  child: Card(
                    color: back ? widget.accent.withAlpha(30) : Theme.of(context).colorScheme.surface,
                    child: Stack(children: [
                      Center(
                          child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(back ? c.back : c.front,
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
                      )),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => widget.store.deleteCard(c),
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
      Positioned(
        right: 24,
        bottom: 24,
        child: FloatingActionButton(
          backgroundColor: widget.accent,
          foregroundColor: Colors.white,
          onPressed: _add,
          child: const Icon(Icons.add),
        ),
      ),
    ]);
  }
}
