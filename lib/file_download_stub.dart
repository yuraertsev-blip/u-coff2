/// Заглушка для не-веб платформ: приложение собирается, но скачивание недоступно.
void downloadTextFile(String filename, String content) {
  throw UnsupportedError('Скачивание файла доступно только в веб-версии');
}
