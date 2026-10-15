# New note

## Get the APK (no Flutter install needed)
1. Create a GitHub repo and upload everything in this folder (keep the .github folder).
2. Open the repo > Actions > "Build APK" > Run workflow (it also runs on every push).
3. When it finishes, download the artifact "new-note-apk" and install app-release.apk on your tablet.

## Build locally
flutter create --platforms=android,ios,windows --project-name new_note .
flutter pub get
flutter run

## Features
Library (folders, favorites, trash, search, theme color, local backup/restore), pen/highlighter/eraser,
text, shapes, lasso select+move+delete, laser pointer, move/zoom, auto straight-line, pressure,
stylus-only mode, pages + templates, undo/redo, PNG export, flashcards.

Also: pencase (favorite pens), bucket fill (shapes), copy/cut/paste with 4-item history, resize handle,
floating/dockable toolbar, spectrum sliders, eraser radius, stickers, cover picker, calculator, timer,
welcome guide, stroke smoothing.

Not done yet: PDF reader/annotation, image/screenshot insert, cloud sync, ruler/compass/divider,
dark mode, OCR/redaction/forms, real palm rejection and stylus double-tap.

## Added in round 3
PDF import + annotation (lazy page rendering, cached), image insert, ruler/compass/divider, palm rejection,
stylus double-tap, dark mode, PDF export, WebDAV + Supabase sync, page jump + bookmarks, last-page memory.

## Still not implemented
Google Drive sync (needs OAuth setup), OCR, PDF text search/redaction/forms, per-tool placement settings,
cross-app screenshot capture, moving/resizing images after placing them.
