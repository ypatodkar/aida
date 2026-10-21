import 'package:flutter/material.dart';

/// Display face for names, headings, and quiet moments. Body text stays on the
/// platform sans so long conversations read comfortably.
const serif = 'InstrumentSerif';

/// Calls always use a dark stage, whatever the app theme.
const night = Color(0xFF16131B);
const nightRaised = Color(0xFF2A2338);
const nightControl = Color(0xFF3A3347);
const nightText = Color(0xFFF6F1F8);
const apricot = Color(0xFFD9A27F);
const answerGreen = Color(0xFF5E9E78);
const endRed = Color(0xFFC9604F);

/// Personal accent choices. Each is a muted tone that keeps white text legible
/// on the sender's bubbles in light mode and a deeper bubble in dark mode.
enum AidaAccent {
  lavender('Lavender', Color(0xFF6B5BA5), Color(0xFFB7A8EA), Color(0xFF4B4078)),
  dusk('Dusk', Color(0xFF8A5A74), Color(0xFFDDAAC2), Color(0xFF5E3E55)),
  sage('Sage', Color(0xFF4E7766), Color(0xFF9DCDB7), Color(0xFF34584A)),
  ocean('Ocean', Color(0xFF4A6496), Color(0xFFA5BBEA), Color(0xFF33476F));

  const AidaAccent(this.label, this.light, this.dark, this.darkBubble);
  final String label;
  final Color light;
  final Color dark;
  final Color darkBubble;

  static AidaAccent named(String? name) => AidaAccent.values.firstWhere(
    (accent) => accent.name == name,
    orElse: () => AidaAccent.lavender,
  );
}

@immutable
class AidaColors extends ThemeExtension<AidaColors> {
  const AidaColors({
    required this.background,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.mine,
    required this.onMine,
    required this.theirs,
    required this.hero,
    required this.onHero,
    required this.warm,
    required this.danger,
    required this.online,
    required this.read,
  });

  final Color background;
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color ink;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color mine;
  final Color onMine;
  final Color theirs;
  final Color hero;
  final Color onHero;
  final Color warm;
  final Color danger;
  final Color online;
  final Color read;

  factory AidaColors.light(AidaAccent accent) => AidaColors(
    background: const Color(0xFFFAF7F3),
    surface: Colors.white,
    surfaceMuted: const Color(0xFFF2EEEF),
    border: const Color(0xFFEAE4E4),
    ink: const Color(0xFF241F2B),
    muted: const Color(0xFF7A7280),
    accent: accent.light,
    onAccent: Colors.white,
    accentSoft: Color.lerp(accent.light, const Color(0xFFFAF7F3), .86)!,
    mine: accent.light,
    onMine: Colors.white,
    theirs: Colors.white,
    hero: const Color(0xFF2A2235),
    onHero: nightText,
    warm: apricot,
    danger: const Color(0xFFB4544A),
    online: const Color(0xFF4F9A6E),
    read: const Color(0xFFBDF0D2),
  );

  factory AidaColors.dark(AidaAccent accent) => AidaColors(
    background: const Color(0xFF141217),
    surface: const Color(0xFF1F1C23),
    surfaceMuted: const Color(0xFF27232C),
    border: const Color(0xFF302B36),
    ink: const Color(0xFFEEE9F2),
    muted: const Color(0xFFA39BAA),
    accent: accent.dark,
    onAccent: const Color(0xFF1A1525),
    accentSoft: Color.lerp(accent.dark, const Color(0xFF141217), .82)!,
    mine: accent.darkBubble,
    onMine: const Color(0xFFF4F0FA),
    theirs: const Color(0xFF222026),
    hero: const Color(0xFF282131),
    onHero: nightText,
    warm: const Color(0xFFE3B597),
    danger: const Color(0xFFE07A6E),
    online: const Color(0xFF7CC197),
    read: const Color(0xFF9BE3B9),
  );

  @override
  AidaColors copyWith() => this;

  @override
  AidaColors lerp(AidaColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AidaColors(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      border: mix(border, other.border),
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      accent: mix(accent, other.accent),
      onAccent: mix(onAccent, other.onAccent),
      accentSoft: mix(accentSoft, other.accentSoft),
      mine: mix(mine, other.mine),
      onMine: mix(onMine, other.onMine),
      theirs: mix(theirs, other.theirs),
      hero: mix(hero, other.hero),
      onHero: mix(onHero, other.onHero),
      warm: mix(warm, other.warm),
      danger: mix(danger, other.danger),
      online: mix(online, other.online),
      read: mix(read, other.read),
    );
  }
}

extension AidaTheme on BuildContext {
  AidaColors get aida => Theme.of(this).extension<AidaColors>()!;
}

final _themes = <(Brightness, AidaAccent), ThemeData>{};

/// Themes are cached so rebuilding the app never looks like a theme change.
ThemeData aidaTheme(Brightness brightness, AidaAccent accent) =>
    _themes.putIfAbsent((brightness, accent), () => _theme(brightness, accent));

ThemeData _theme(Brightness brightness, AidaAccent accent) {
  final c = brightness == Brightness.dark
      ? AidaColors.dark(accent)
      : AidaColors.light(accent);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: c.accent,
        brightness: brightness,
      ).copyWith(
        primary: c.accent,
        onPrimary: c.onAccent,
        secondary: c.warm,
        surface: c.background,
        onSurface: c.ink,
        surfaceContainerHighest: c.surfaceMuted,
        outline: c.border,
        outlineVariant: c.border,
        error: c.danger,
      );
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(24),
    borderSide: BorderSide(color: c.border),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    extensions: [c],
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontFamily: serif,
        fontSize: 46,
        height: 1.05,
        color: c.ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: serif,
        fontSize: 36,
        height: 1.1,
        color: c.ink,
      ),
      headlineSmall: TextStyle(
        fontFamily: serif,
        fontSize: 28,
        height: 1.15,
        color: c.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: c.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: c.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: c.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: c.ink),
      labelSmall: TextStyle(fontSize: 11, letterSpacing: 1.5, color: c.muted),
    ),
    iconTheme: IconThemeData(color: c.ink),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      hintStyle: TextStyle(color: c.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(
        borderSide: BorderSide(color: c.accent, width: 1.4),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      titleTextStyle: TextStyle(fontFamily: serif, fontSize: 28, color: c.ink),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: TextStyle(color: c.ink, fontSize: 15),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: c.border,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.hero,
      contentTextStyle: TextStyle(color: c.onHero),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.accentSoft,
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
    ),
  );
}

/// Two interlocking rings: two people, one space. With [breathing], the rings
/// drift together and apart very slowly.
class AidaMark extends StatefulWidget {
  const AidaMark({
    super.key,
    this.size = 70,
    this.breathing = false,
    this.first,
    this.second,
  });
  final double size;
  final bool breathing;
  final Color? first;
  final Color? second;

  @override
  State<AidaMark> createState() => _AidaMarkState();
}

class _AidaMarkState extends State<AidaMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.breathing && !still) {
      if (!_drift.isAnimating) _drift.repeat(reverse: true);
    } else {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final size = widget.size;
    Widget ring(Color color, double angle) => Transform.rotate(
      angle: angle,
      child: Container(
        width: size * .53,
        height: size * .72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size),
          border: Border.all(color: color, width: size * .065),
        ),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _drift,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_drift.value);
          final gap = size * (.12 - .03 * t);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.translate(
                offset: Offset(-gap, 0),
                child: ring(widget.first ?? c.accent, -.3),
              ),
              Transform.translate(
                offset: Offset(gap, 0),
                child: ring(widget.second ?? c.warm, .3),
              ),
            ],
          );
        },
      ),
    );
  }
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar(
    this.name, {
    super.key,
    this.size = 44,
    this.dark = false,
    this.photo,
  });
  final String name;
  final double size;
  final bool dark;

  /// Their profile photo, if they added one; the initial shows otherwise.
  final ImageProvider? photo;
  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final initial = _initial(c);
    if (photo == null) return initial;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: dark ? Colors.white12 : c.background,
          width: 2,
        ),
      ),
      child: ClipOval(
        child: Image(
          image: photo!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => initial,
        ),
      ),
    );
  }

  Widget _initial(AidaColors c) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: dark ? nightControl : c.accentSoft,
        shape: BoxShape.circle,
        border: Border.all(
          color: dark ? Colors.white12 : c.background,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        name.trim().isEmpty ? 'A' : name.trim().characters.first.toUpperCase(),
        style: TextStyle(
          fontFamily: serif,
          fontSize: size * .5,
          height: 1.1,
          color: dark ? nightText : c.accent,
        ),
      ),
    );
  }
}

/// Both people, overlapping slightly.
class CoupleAvatars extends StatelessWidget {
  const CoupleAvatars(
    this.me,
    this.partner, {
    super.key,
    this.size = 64,
    this.mePhoto,
    this.partnerPhoto,
  });
  final String me;
  final String partner;
  final double size;
  final ImageProvider? mePhoto;
  final ImageProvider? partnerPhoto;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.72,
    height: size,
    child: Stack(
      children: [
        PersonAvatar(partner, size: size, photo: partnerPhoto),
        Positioned(
          right: 0,
          child: PersonAvatar(me, size: size, photo: mePhoto),
        ),
      ],
    ),
  );
}

/// Small uppercase section label.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 10.5,
      letterSpacing: 2.2,
      fontWeight: FontWeight.w600,
      color: color ?? context.aida.muted,
    ),
  );
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String longDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// When the person last had Aida open, as a clock time, e.g.
/// "Last seen today at 14:05". [seen] and [now] are local times.
String lastSeenLabel(DateTime seen, DateTime now) {
  final clock =
      '${seen.hour.toString().padLeft(2, '0')}:${seen.minute.toString().padLeft(2, '0')}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(seen.year, seen.month, seen.day);
  final daysAgo = today.difference(day).inHours ~/ 24;
  if (daysAgo <= 0) return 'Last seen today at $clock';
  if (daysAgo == 1) return 'Last seen yesterday at $clock';
  final month = _months[seen.month - 1].substring(0, 3);
  final year = seen.year == now.year ? '' : ' ${seen.year}';
  return 'Last seen ${seen.day} $month$year at $clock';
}

/// How long two people have been connected, counted in calendar days.
/// The day they connected is Day 1.
class Together {
  factory Together(int sinceMs, {DateTime? now}) {
    final since = _day(DateTime.fromMillisecondsSinceEpoch(sinceMs));
    final today = _day(now ?? DateTime.now());
    final day = today.difference(since).inDays + 1;
    DateTime anniversary(int years) =>
        DateTime.utc(since.year + years, since.month, since.day);
    var years = today.year - since.year;
    if (anniversary(years).isBefore(today)) years++;
    final hundred = day % 100 == 0 ? day : (day ~/ 100 + 1) * 100;
    final hundredDate = since.add(Duration(days: hundred - 1));
    final yearly = years > 0 && !hundredDate.isBefore(anniversary(years));
    final next = yearly ? anniversary(years) : hundredDate;
    return Together._(
      since: since,
      day: day,
      nextLabel: !yearly
          ? 'Day $hundred'
          : years == 1
          ? '1 year together'
          : '$years years together',
      nextDate: next,
      daysUntilNext: next.difference(today).inDays,
      anniversary: yearly,
    );
  }

  const Together._({
    required this.since,
    required this.day,
    required this.nextLabel,
    required this.nextDate,
    required this.daysUntilNext,
    required this.anniversary,
  });

  final DateTime since;
  final int day;
  final String nextLabel;
  final DateTime nextDate;
  final int daysUntilNext;

  /// Whether the next milestone is a yearly anniversary (vs. a 100-day mark).
  final bool anniversary;

  static DateTime _day(DateTime local) =>
      DateTime.utc(local.year, local.month, local.day);

  String get countdown => daysUntilNext == 0
      ? 'today'
      : daysUntilNext == 1
      ? 'tomorrow'
      : 'in $daysUntilNext days';
}
