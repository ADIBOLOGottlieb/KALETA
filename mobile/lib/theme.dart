import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'widgets/animations.dart';

/// Couleurs KALETA — Terrasse & Lounge (Lomé), tirées du logo (masque africain vert néon, couverts dorés)
/// et de l'identité du restaurant : vert nuit, vert profond, or et crème.
class AppColors {
  // Couleurs de la marque
  /// Vert du masque : fonds de marque (boutons pleins, pastilles, en-têtes) avec texte blanc. Pour une icône
  /// ou un texte sur la page, préférer [brandColor] (lisible en clair comme en sombre).
  static const brand = Color(0xFF13803F);
  /// Vert nuit : fin des dégradés de marque, fond du thème sombre.
  static const brandDark = Color(0xFF03150F);
  /// Vert profond (cartes et halos du thème sombre).
  static const deep = Color(0xFF0F4F38);
  /// Vert néon du masque : lueurs, halos, points lumineux (jamais pour du texte sur fond clair).
  static const neon = Color(0xFF5BEA6B);
  /// Or des couverts du logo (texte noir dessus).
  static const accent = Color(0xFFD4B566);
  static const goldLight = Color(0xFFF0DCA0);
  static const goldDark = Color(0xFF9B7F3D);
  static const ink = Color(0xFF1A1410);
  /// Teinte crème-or très claire (puces, encadrés) du thème clair.
  static const tint = Color(0xFFF3EAD3);
  /// Gris chaud du thème clair uniquement : dans les widgets, préférer [mutedColor] (lisible en sombre).
  static const muted = Color(0xFF6B5E4F);
  static const green = Color(0xFF2E9E5B);
  /// Actions destructrices et erreurs (supprimer, déconnexion, refus).
  static const danger = Color(0xFFC62828);

  /// Dégradé de marque : vert du masque vers vert nuit (en-têtes, boutons de marque).
  static const brandGradient = LinearGradient(
    colors: [Color(0xFF17924A), deep, brandDark],
    stops: [0, 0.55, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Dégradé or (accents premium : signatures du chef, bouton principal secondaire).
  static const goldGradient = LinearGradient(
    colors: [goldLight, accent, goldDark],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Material 3 semantic colors for light theme
  static const lightPrimary = Color(0xFF0F7A3A);
  static const lightOnPrimary = Colors.white;
  static const lightPrimaryContainer = Color(0xFFC6F2D2);
  static const lightOnPrimaryContainer = Color(0xFF00210D);

  static const lightSecondary = accent;
  static const lightOnSecondary = ink;
  static const lightSecondaryContainer = Color(0xFFF7E9C2);
  static const lightOnSecondaryContainer = Color(0xFF3A2C00);

  static const lightTertiary = deep;
  static const lightOnTertiary = Colors.white;
  static const lightTertiaryContainer = Color(0xFFB7EBD3);
  static const lightOnTertiaryContainer = Color(0xFF002116);

  static const lightBackground = Color(0xFFF8F3E8);
  static const lightSurface = Color(0xFFFFFCF4);
  static const lightSurfaceVariant = Color(0xFFEDE5D3);
  static const lightOnSurface = ink;
  static const lightOnSurfaceVariant = muted;
  static const lightOutline = Color(0xFFA89C86);

  // Material 3 semantic colors for dark theme (thème par défaut : l'ambiance lounge du soir)
  static const darkPrimary = Color(0xFF25A453);
  static const darkOnPrimary = Colors.white;
  static const darkPrimaryContainer = deep;
  static const darkOnPrimaryContainer = Color(0xFFB9F5C8);

  static const darkSecondary = Color(0xFFE5C97A);
  static const darkOnSecondary = Color(0xFF2B2000);
  static const darkSecondaryContainer = Color(0xFF4A3B12);
  static const darkOnSecondaryContainer = goldLight;

  static const darkTertiary = Color(0xFF8ADBB1);
  static const darkOnTertiary = Color(0xFF003829);
  static const darkTertiaryContainer = Color(0xFF00523D);
  static const darkOnTertiaryContainer = Color(0xFFA5F8D4);

  static const darkBackground = brandDark;
  static const darkSurface = Color(0xFF0A241A);
  static const darkSurfaceVariant = Color(0xFF1B3B2E);
  static const darkOnSurface = Color(0xFFFAF5E8);
  static const darkOnSurfaceVariant = Color(0xFFC8C0B0);
  static const darkOutline = Color(0xFF6E8579);
}

/// Police des titres (Playfair Display, comme le site du restaurant).
const String displayFont = 'Playfair';

/// Couleur de marque pour une icône, un texte ou une bordure : vert profond en clair, vert vif en sombre.
Color brandColor(BuildContext context) => Theme.of(context).colorScheme.primary;

/// Texte secondaire (gris) adapté au thème courant, clair ou sombre.
Color mutedColor(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

/// Titres en Playfair Display, corps de texte en Poppins.
TextTheme _textTheme(Color onSurface) {
  TextStyle display(double size, [FontWeight weight = FontWeight.w700]) =>
      TextStyle(fontFamily: displayFont, fontSize: size, fontWeight: weight, color: onSurface, height: 1.15);
  return TextTheme(
    displayLarge: display(52, FontWeight.w900),
    displayMedium: display(42, FontWeight.w900),
    displaySmall: display(34),
    headlineLarge: display(30),
    headlineMedium: display(26),
    headlineSmall: display(22),
  );
}

const _pageTransitions = PageTransitionsTheme(builders: {
  TargetPlatform.android: KaletaPageTransitionsBuilder(),
  // iOS : le glissement natif garde le geste « retour » au bord de l'écran.
  TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  TargetPlatform.windows: KaletaPageTransitionsBuilder(),
  TargetPlatform.linux: KaletaPageTransitionsBuilder(),
  TargetPlatform.macOS: KaletaPageTransitionsBuilder(),
});

/// Champs de saisie arrondis ; la lueur animée au focus est ajoutée par [GlowField].
InputDecorationTheme _inputTheme(ColorScheme scheme, {required Color fill, required Color enabled}) {
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecorationTheme(
    filled: true,
    fillColor: fill,
    border: border(scheme.outline),
    enabledBorder: border(enabled),
    focusedBorder: border(scheme.primary, 1.8),
    errorBorder: border(scheme.error),
    focusedErrorBorder: border(scheme.error, 1.8),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) => TextStyle(
          color: states.contains(WidgetState.error)
              ? scheme.error
              : states.contains(WidgetState.focused)
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        )),
    hintStyle: TextStyle(color: scheme.onSurfaceVariant),
    prefixIconColor: WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.focused) ? scheme.primary : scheme.onSurfaceVariant,
    ),
    suffixIconColor: scheme.onSurfaceVariant,
  );
}

ThemeData _buildTheme(ColorScheme scheme, {required Color background, required InputDecorationTheme input}) {
  final dark = scheme.brightness == Brightness.dark;
  const buttonText = TextStyle(fontFamily: 'Poppins', fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.5);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Poppins',
    brightness: scheme.brightness,
    colorScheme: scheme,
    textTheme: _textTheme(scheme.onSurface),
    pageTransitionsTheme: _pageTransitions,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: displayFont,
        fontSize: 23,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: buttonText,
        elevation: 2,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: BorderSide(color: dark ? AppColors.accent.withValues(alpha: 0.55) : scheme.outline),
        foregroundColor: dark ? AppColors.goldLight : scheme.primary,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark ? AppColors.darkSecondary : scheme.primary,
        textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      ),
    ),
    inputDecorationTheme: input,
    cardTheme: CardThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: dark ? AppColors.accent.withValues(alpha: 0.14) : scheme.outlineVariant),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      side: dark ? BorderSide(color: scheme.outline.withValues(alpha: 0.3)) : BorderSide.none,
      labelStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.22 : 0.14),
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontFamily: 'Poppins', fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: dark ? AppColors.neon : scheme.primary,
      circularTrackColor: scheme.surfaceContainerHighest.withValues(alpha: dark ? 0.3 : 1),
      linearTrackColor: scheme.surfaceContainerHighest.withValues(alpha: dark ? 0.3 : 1),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? scheme.primary : null,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: dark ? BorderSide(color: AppColors.accent.withValues(alpha: 0.2)) : BorderSide.none,
      ),
      backgroundColor: scheme.surface,
      titleTextStyle: TextStyle(fontFamily: displayFont, fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      showDragHandle: true,
      dragHandleColor: AppColors.accent.withValues(alpha: 0.6),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
  );
}

/// Build Material 3 theme with light mode
ThemeData buildLightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.lightPrimary,
    onPrimary: AppColors.lightOnPrimary,
    primaryContainer: AppColors.lightPrimaryContainer,
    onPrimaryContainer: AppColors.lightOnPrimaryContainer,
    secondary: AppColors.lightSecondary,
    onSecondary: AppColors.lightOnSecondary,
    secondaryContainer: AppColors.lightSecondaryContainer,
    onSecondaryContainer: AppColors.lightOnSecondaryContainer,
    tertiary: AppColors.lightTertiary,
    onTertiary: AppColors.lightOnTertiary,
    tertiaryContainer: AppColors.lightTertiaryContainer,
    onTertiaryContainer: AppColors.lightOnTertiaryContainer,
    error: Color(0xFFC62828),
    onError: Colors.white,
    errorContainer: Color(0xFFFFCDD2),
    onErrorContainer: Color(0xFFB71C1C),
    surface: AppColors.lightSurface,
    onSurface: AppColors.lightOnSurface,
    // Paliers de surface (champs, encadrés, boutons désactivés), distincts des cartes.
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFBF7EE),
    surfaceContainer: Color(0xFFF5EFE3),
    surfaceContainerHigh: Color(0xFFF1EADB),
    surfaceContainerHighest: AppColors.lightSurfaceVariant,
    onSurfaceVariant: AppColors.lightOnSurfaceVariant,
    outline: AppColors.lightOutline,
    outlineVariant: Color(0xFFE2D8C3),
    scrim: Colors.black,
    inverseSurface: Color(0xFF0A241A),
    onInverseSurface: Color(0xFFFAF5E8),
    inversePrimary: AppColors.darkPrimary,
    surfaceTint: AppColors.lightPrimary,
  );
  return _buildTheme(
    scheme,
    background: AppColors.lightBackground,
    input: _inputTheme(scheme, fill: AppColors.lightSurface, enabled: scheme.outlineVariant),
  );
}

/// Build Material 3 theme with dark mode
ThemeData buildDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.darkPrimary,
    onPrimary: AppColors.darkOnPrimary,
    primaryContainer: AppColors.darkPrimaryContainer,
    onPrimaryContainer: AppColors.darkOnPrimaryContainer,
    secondary: AppColors.darkSecondary,
    onSecondary: AppColors.darkOnSecondary,
    secondaryContainer: AppColors.darkSecondaryContainer,
    onSecondaryContainer: AppColors.darkOnSecondaryContainer,
    tertiary: AppColors.darkTertiary,
    onTertiary: AppColors.darkOnTertiary,
    tertiaryContainer: AppColors.darkTertiaryContainer,
    onTertiaryContainer: AppColors.darkOnTertiaryContainer,
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: AppColors.darkSurface,
    onSurface: AppColors.darkOnSurface,
    surfaceContainerLowest: Color(0xFF020F0A),
    surfaceContainerLow: Color(0xFF071D15),
    surfaceContainer: Color(0xFF0D2A1F),
    surfaceContainerHigh: Color(0xFF133326),
    surfaceContainerHighest: AppColors.darkSurfaceVariant,
    onSurfaceVariant: AppColors.darkOnSurfaceVariant,
    outline: AppColors.darkOutline,
    outlineVariant: Color(0xFF1F4134),
    scrim: Colors.black,
    inverseSurface: Color(0xFFFAF5E8),
    onInverseSurface: Color(0xFF0A241A),
    inversePrimary: AppColors.lightPrimary,
    surfaceTint: AppColors.darkPrimary,
  );
  return _buildTheme(
    scheme,
    background: AppColors.darkBackground,
    input: _inputTheme(
      scheme,
      fill: AppColors.deep.withValues(alpha: 0.28),
      enabled: AppColors.accent.withValues(alpha: 0.22),
    ),
  );
}

/// Build light theme (backward compatibility)
ThemeData buildTheme() => buildLightTheme();
