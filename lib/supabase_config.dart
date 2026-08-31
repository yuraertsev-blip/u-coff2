/// Подключение к Supabase.
///
/// Оба значения публичные по замыслу — их видно в любом браузере, и защищают
/// данные не они, а правила RLS в supabase/schema.sql. Секретный
/// service_role-ключ сюда класть НЕЛЬЗЯ ни при каких обстоятельствах.
///
/// Взять здесь: Supabase → Connect, либо Settings → API Keys (ключ) и
/// Settings → Data API (адрес).
class SupabaseConfig {
  /// Project URL, вида https://xxxxxxxxxxxx.supabase.co
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://dcfdfdgohbtbskwkhajo.supabase.co',
  );

  /// Публичный ключ: в новых проектах он называется publishable
  /// (sb_publishable_...), в старых — anon. Подходит любой из них.
  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_80EB8_yAhVXjLE3jABF9ug_jnGfM7Uv',
  );

  /// Учётка управляющего: правит график и сотрудников.
  static const String adminEmail = 'admin@u-coffee.app';

  /// Общая учётка баристов: правит только пожелания.
  static const String baristaEmail = 'barista@u-coffee.app';

  static bool get isConfigured =>
      url.startsWith('https://') && publishableKey.length > 20;
}
