import 'package:shared_preferences/shared_preferences.dart';

// Thin SharedPreferences wrapper for theme, language, and last-route persistence.
class SettingsService {
  static const String _themeKey = 'app_theme_mode';
  static const String _languageKey = 'app_language';
  static const String _lastRouteKey = 'app_last_route';

  SharedPreferences? _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  String getThemeMode() {
    if (!_initialized) return 'light';
    return _prefs?.getString(_themeKey) ?? 'light';
  }

  Future<void> setThemeMode(String mode) async {
    await _ensureInitialized();
    await _prefs!.setString(_themeKey, mode);
  }

  String getLanguage() {
    if (!_initialized) return 'fr';
    final savedLanguage = _prefs?.getString(_languageKey);
    if (savedLanguage == null) {
      return 'fr';
    }

    // Backward compatibility with old display-name values.
    switch (savedLanguage) {
      case 'English':
        return 'en';
      case 'العربية':
        return 'ar';
      case 'Français':
        return 'fr';
      default:
        return savedLanguage;
    }
  }

  Future<void> setLanguage(String language) async {
    await _ensureInitialized();
    await _prefs!.setString(_languageKey, language);
  }

  String? getLastRoute() {
    if (!_initialized) return null;
    return _prefs?.getString(_lastRouteKey);
  }

  Future<void> setLastRoute(String route) async {
    await _ensureInitialized();
    await _prefs!.setString(_lastRouteKey, route);
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
    }
  }
}
