import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Отдаёт текст браузеру как файл: создаём Blob и кликаем по временной ссылке.
void downloadTextFile(String filename, String content) {
  final bytes = utf8.encode(content);
  final blob = web.Blob(
    <JSUint8Array>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
