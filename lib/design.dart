import 'package:flutter/material.dart';

const ink = Color(0xFF183F36);
const cream = Color(0xFFF8F6F0);
const sage = Color(0xFFE7EEE6);
const muted = Color(0xFF737C74);
const gold = Color(0xFFE7BC77);

ThemeData aidaTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: cream,
  colorScheme: ColorScheme.fromSeed(
    seedColor: ink,
    primary: ink,
    surface: cream,
    secondary: const Color(0xFF9C6939),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: cream,
    foregroundColor: ink,
    elevation: 0,
    scrolledUnderElevation: 0,
    centerTitle: false,
  ),
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontFamily: 'serif',
      fontSize: 42,
      height: 1.12,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontFamily: 'serif',
      fontSize: 32,
      height: 1.18,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
    labelSmall: TextStyle(fontSize: 11, letterSpacing: 1.5, color: muted),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 52),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0xFFE5E8DF)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: ink),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: ink,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  ),
  dividerTheme: const DividerThemeData(color: Color(0xFFE0E4DA), thickness: 1),
);

class AidaMark extends StatelessWidget {
  const AidaMark({super.key, this.size = 70});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Transform.translate(
          offset: Offset(-size * .12, 0),
          child: Transform.rotate(
            angle: -.3,
            child: Container(
              width: size * .53,
              height: size * .72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size),
                border: Border.all(color: ink, width: size * .065),
              ),
            ),
          ),
        ),
        Transform.translate(
          offset: Offset(size * .12, 0),
          child: Transform.rotate(
            angle: .3,
            child: Container(
              width: size * .53,
              height: size * .72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size),
                border: Border.all(color: gold, width: size * .065),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar(this.name, {super.key, this.size = 44, this.dark = false});
  final String name;
  final double size;
  final bool dark;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: dark ? const Color(0xFF355C51) : sage,
      shape: BoxShape.circle,
      border: Border.all(color: dark ? Colors.white12 : Colors.white, width: 2),
    ),
    alignment: Alignment.center,
    child: Text(
      name.trim().isEmpty ? 'A' : name.trim().characters.first.toUpperCase(),
      style: TextStyle(
        fontFamily: 'serif',
        fontSize: size * .42,
        color: dark ? cream : ink,
      ),
    ),
  );
}
