/// Скачивание файла на устройство пользователя.
///
/// Реализация выбирается на этапе компиляции: в вебе — через Blob и <a download>,
/// на остальных платформах — заглушка, чтобы сборка не ломалась.
export 'file_download_stub.dart'
    if (dart.library.js_interop) 'file_download_web.dart';
