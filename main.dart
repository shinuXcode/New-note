import 'package:flutter/material.dart';
import 'library_page.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.load();
  runApp(NewNoteApp(store: store));
}

class NewNoteApp extends StatelessWidget {
  final AppStore store;
  const NewNoteApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => MaterialApp(
        title: 'New note',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Color(store.accent),
          brightness: store.dark ? Brightness.dark : Brightness.light,
          scaffoldBackgroundColor: store.dark ? null : const Color(0xFFF7F7F7),
        ),
        home: LibraryPage(store: store),
      ),
    );
  }
}
