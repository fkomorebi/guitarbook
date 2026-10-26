import 'package:flutter/material.dart';

ThemeData buildAppTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF795548),
      brightness: brightness,
    ),
  );
}
