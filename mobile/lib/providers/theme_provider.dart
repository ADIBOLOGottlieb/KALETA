import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thème de l'application : clair, sombre ou celui du système (mémorisé).
class ThemeProvider extends ChangeNotifier {
  static const _prefKey = 'theme_mode';

  // Sombre par défaut : l'ambiance lounge de KALETA (le client peut choisir clair ou système).
  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;

  /// Charge le choix enregistré ('light', 'dark' ou 'system').
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null) {
        _themeMode = ThemeMode.values.firstWhere(
          (mode) => mode.name == saved,
          orElse: () => ThemeMode.dark,
        );
      }
    } catch (e) {
      debugPrint('[ThemeProvider] Lecture du thème impossible : $e');
    }
    notifyListeners();
  }

  /// Change le thème et l'enregistre.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (e) {
      debugPrint('[ThemeProvider] Enregistrement du thème impossible : $e');
    }
  }

  /// Bascule clair <-> sombre (depuis « système », passe en clair).
  Future<void> toggleThemeMode() =>
      setThemeMode(_themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light);

  /// Vrai si l'affichage est actuellement sombre.
  bool get isDarkMode {
    switch (_themeMode) {
      case ThemeMode.dark:
        return true;
      case ThemeMode.light:
        return false;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
  }

  /// Libellé français du mode.
  static String label(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'Clair',
        ThemeMode.dark => 'Sombre',
        ThemeMode.system => 'Système',
      };
}
