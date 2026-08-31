import 'package:web/web.dart' as web;

const _key = 'u_coffee_snapshot_v1';

/// Читает последний снимок. null — если его нет или хранилище недоступно
/// (приватный режим, запрет на данные сайта).
String? readCachedSnapshot() {
  try {
    return web.window.localStorage.getItem(_key);
  } catch (_) {
    return null;
  }
}

void writeCachedSnapshot(String json) {
  try {
    web.window.localStorage.setItem(_key, json);
  } catch (_) {
    // Переполнение или запрет хранилища — не повод ронять приложение.
  }
}
