import 'package:flutter/material.dart';

import 'design.dart';

/// The couple's profile: who you're connected to, how the app looks, privacy,
/// and account controls.
///
/// The app state owns all data; this screen reads it through getters and
/// rebuilds after each action so changes (a new name, a new theme) show
/// immediately.
class UsScreen extends StatefulWidget {
  const UsScreen({
    super.key,
    required this.state,
    required this.presence,
    required this.themeMode,
    required this.accent,
    required this.onThemeMode,
    required this.onAccent,
    required this.onChangeName,
    required this.onNotifications,
    required this.onServer,
    required this.onSignOut,
    required this.onDisconnect,
    required this.version,
  });

  final Map<String, dynamic>? Function() state;
  final String Function(Map<String, dynamic> partner) presence;
  final ThemeMode Function() themeMode;
  final AidaAccent Function() accent;
  final void Function(ThemeMode mode) onThemeMode;
  final void Function(AidaAccent accent) onAccent;
  final Future<void> Function() onChangeName;
  final Future<void> Function() onNotifications;
  final Future<void> Function() onServer;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onDisconnect;
  final String version;

  @override
  State<UsScreen> createState() => _UsScreenState();
}

class _UsScreenState extends State<UsScreen> {
  Future<void> _then(Future<void> Function() action) async {
    await action();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final state = widget.state();
    final pair = state?['pair'] as Map<String, dynamic>?;
    if (state == null || pair == null) {
      // Signed out or disconnected; the app is returning to the start.
      return const Scaffold();
    }
    final user = state['user'] as Map<String, dynamic>;
    final partner = pair['partner'] as Map<String, dynamic>;
    final me = user['name']?.toString() ?? '';
    final them = partner['name']?.toString() ?? '';
    final since = pair['createdAt'] as int?;
    final together = since == null ? null : Together(since);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to chat',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          'Us',
          style: TextStyle(
            fontFamily: serif,
            fontSize: 28,
            fontWeight: FontWeight.w400,
            color: c.ink,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const SizedBox(height: 12),
          Center(child: CoupleAvatars(me, them, size: 76)),
          const SizedBox(height: 18),
          Text(
            '$me & $them',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          if (together != null) ...[
            const SizedBox(height: 8),
            Text(
              'Together since ${longDate(together.since)} · Day ${together.day}',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 13.5),
            ),
          ],
          const SizedBox(height: 30),
          const _Heading('Your person'),
          _Group(
            children: [
              _Row(
                leading: PersonAvatar(them, size: 36),
                title: them,
                subtitle: widget.presence(partner),
              ),
            ],
          ),
          const _Heading('Appearance'),
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: c.accentSoft,
                      selectedForegroundColor: c.accent,
                      foregroundColor: c.muted,
                      side: BorderSide(color: c.border),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('Auto'),
                        icon: Icon(Icons.brightness_auto_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                      ),
                    ],
                    selected: {widget.themeMode()},
                    onSelectionChanged: (value) {
                      widget.onThemeMode(value.first);
                      setState(() {});
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final accent in AidaAccent.values)
                      _Swatch(
                        accent: accent,
                        selected: accent == widget.accent(),
                        onTap: () {
                          widget.onAccent(accent);
                          setState(() {});
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
          const _Heading('Privacy'),
          _Group(
            children: [
              _Row(
                icon: Icons.notifications_none_rounded,
                title: 'Notifications',
                subtitle: 'Messages and calls when Aida is closed',
                onTap: () => _then(widget.onNotifications),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(52, 4, 16, 16),
                child: Text(
                  'Message text never passes through Google\'s push '
                  'service. Aida fetches it from your own server when a '
                  'notification arrives.',
                  style: TextStyle(color: c.muted, fontSize: 12.5, height: 1.5),
                ),
              ),
            ],
          ),
          const _Heading('Account'),
          _Group(
            children: [
              _Row(
                icon: Icons.badge_outlined,
                title: 'Your name',
                subtitle: me,
                onTap: () => _then(widget.onChangeName),
              ),
              _Row(
                icon: Icons.dns_outlined,
                title: 'Server address',
                onTap: () => _then(widget.onServer),
              ),
              _Row(
                icon: Icons.logout_rounded,
                title: 'Sign out',
                subtitle: 'Your connection and messages stay',
                onTap: widget.onSignOut,
              ),
            ],
          ),
          const SizedBox(height: 26),
          OutlinedButton.icon(
            onPressed: widget.onDisconnect,
            style: OutlinedButton.styleFrom(
              foregroundColor: c.danger,
              side: BorderSide(color: c.danger.withValues(alpha: .4)),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(Icons.link_off_rounded),
            label: const Text('Disconnect and delete'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Text(
              'Ends your connection and permanently deletes every message, '
              'photo, and video for both of you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            widget.version,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 18, 6, 10),
    child: Eyebrow(text),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return Material(
      color: c.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: c.border),
      ),
      child: Column(children: children),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.onTap,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: leading ?? Icon(icon, color: c.accent, size: 22),
      minLeadingWidth: 24,
      title: Text(title, style: TextStyle(color: c.ink, fontSize: 15.5)),
      subtitle: subtitle == null || subtitle!.isEmpty
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.muted, fontSize: 12.5),
            ),
      trailing: onTap == null
          ? null
          : Icon(Icons.chevron_right_rounded, color: c.muted, size: 20),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });
  final AidaAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? accent.dark : accent.light;
    return Semantics(
      button: true,
      selected: selected,
      label: '${accent.label} accent',
      child: InkResponse(
        onTap: onTap,
        radius: 32,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: 44,
              height: 44,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? color : Colors.transparent,
                  width: 2,
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: dark ? c.onAccent : Colors.white,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            ExcludeSemantics(
              child: Text(
                accent.label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected ? c.ink : c.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
