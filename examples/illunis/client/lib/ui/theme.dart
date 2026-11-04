/// The app theme from the tokens, so nothing falls back to Material
/// defaults: the sans (Source Sans 3) everywhere, star-blue (or zenith-blue) cursor, selection
/// and handles, no ripple, tooltips and the copy / paste toolbar on the
/// glass colours, controls with the small radius.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData illunisTheme(Palette p, {required bool day}) {
  final brightness = day ? Brightness.light : Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.glass,
    secondary: p.accent,
    onSecondary: p.glass,
    error: p.ink,
    onError: p.glass,
    surface: p.glass,
    onSurface: p.ink,
    onSurfaceVariant: p.ink2,
    outline: p.rule,
    primaryContainer: p.glass,
    onPrimaryContainer: p.ink,
    surfaceContainerHigh: p.glass,
    surfaceContainerHighest: p.glass,
  );
  final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  final overlay = WidgetStateProperty.resolveWith<Color?>(
      (s) => s.contains(WidgetState.pressed) || s.contains(WidgetState.focused) ? p.ink.withValues(alpha: 0.08) : null);
  final base = ThemeData(brightness: brightness, colorScheme: scheme, fontFamily: Fonts.sans, useMaterial3: true);
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: p.ink.withValues(alpha: 0.08),
    hoverColor: Colors.transparent,
    focusColor: p.accent.withValues(alpha: 0.20),
    canvasColor: p.glass,
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: base.textTheme.apply(fontFamily: Fonts.sans, bodyColor: p.ink, displayColor: p.ink),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.selection,
      selectionHandleColor: p.accent,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.glass, borderRadius: BorderRadius.circular(Radii.control)),
      textStyle: TypeScale.label(p.ink),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(control),
        foregroundColor: WidgetStatePropertyAll(p.ink),
        overlayColor: overlay,
        splashFactory: NoSplash.splashFactory,
        minimumSize: const WidgetStatePropertyAll(Size(Space.target, Space.target)),
        textStyle: WidgetStatePropertyAll(TypeScale.label(p.ink)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(control),
        foregroundColor: WidgetStatePropertyAll(p.ink),
        overlayColor: overlay,
        splashFactory: NoSplash.splashFactory,
        minimumSize: const WidgetStatePropertyAll(Size(Space.target, Space.target)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: InputBorder.none,
      hintStyle: TypeScale.body(p.ink2),
    ),
  );
}
