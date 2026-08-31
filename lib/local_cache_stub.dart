/// Заглушка для не-веб платформ: кэш просто отключён.
String? readCachedSnapshot() => null;

void writeCachedSnapshot(String json) {}
