import 'dart:convert';
import 'dart:io';

class SyncConfig {
  String mode;
  String url;
  String user;
  String secret;
  String bucket;
  SyncConfig({this.mode = 'none', this.url = '', this.user = '', this.secret = '', this.bucket = 'notes'});

  Map<String, dynamic> toJson() =>
      {'mode': mode, 'url': url, 'user': user, 'secret': secret, 'bucket': bucket};

  factory SyncConfig.fromJson(Map<String, dynamic> j) => SyncConfig(
        mode: j['mode'] as String? ?? 'none',
        url: j['url'] as String? ?? '',
        user: j['user'] as String? ?? '',
        secret: j['secret'] as String? ?? '',
        bucket: j['bucket'] as String? ?? 'notes',
      );
}

Future<HttpClientResponse> _send(String method, Uri uri, Map<String, String> headers,
    [String? body]) async {
  final client = HttpClient();
  final req = await client.openUrl(method, uri);
  headers.forEach((k, v) => req.headers.set(k, v));
  if (body != null) {
    final b = utf8.encode(body);
    req.headers.contentLength = b.length;
    req.add(b);
  }
  return req.close();
}

Map<String, String> _headers(SyncConfig c) {
  if (c.mode == 'webdav') {
    return {'Authorization': 'Basic ${base64Encode(utf8.encode('${c.user}:${c.secret}'))}'};
  }
  return {'Authorization': 'Bearer ${c.secret}', 'apikey': c.secret};
}

Uri? _uri(SyncConfig c, {required bool upload}) {
  if (c.url.isEmpty) return null;
  if (c.mode == 'webdav') {
    final b = c.url.endsWith('/') ? c.url : '${c.url}/';
    return Uri.parse('${b}new_note.json');
  }
  final b = c.url.endsWith('/') ? c.url.substring(0, c.url.length - 1) : c.url;
  return Uri.parse(upload
      ? '$b/storage/v1/object/${c.bucket}/new_note.json'
      : '$b/storage/v1/object/authenticated/${c.bucket}/new_note.json');
}

/// Uploads the notes data. Note: only note data is synced, not PDF/image files.
Future<String> uploadData(SyncConfig c, String data) async {
  if (c.mode == 'none') return 'Choose WebDAV or Supabase first';
  final uri = _uri(c, upload: true);
  if (uri == null) return 'Enter the URL';
  try {
    final h = {..._headers(c), 'Content-Type': 'application/json'};
    if (c.mode == 'supabase') h['x-upsert'] = 'true';
    final res = await _send(c.mode == 'webdav' ? 'PUT' : 'POST', uri, h, data);
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode < 300 ? 'Uploaded' : 'Failed (${res.statusCode}) $body';
  } catch (e) {
    return 'Failed: $e';
  }
}

/// Returns the data, or a string starting with "ERR:" on failure.
Future<String> downloadData(SyncConfig c) async {
  if (c.mode == 'none') return 'ERR:Choose WebDAV or Supabase first';
  final uri = _uri(c, upload: false);
  if (uri == null) return 'ERR:Enter the URL';
  try {
    final res = await _send('GET', uri, _headers(c));
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode < 300 ? body : 'ERR:Failed (${res.statusCode}) $body';
  } catch (e) {
    return 'ERR:Failed: $e';
  }
}
