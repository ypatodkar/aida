import 'package:flutter/material.dart';

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'design.dart';
import 'updates.dart';

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
    required this.partnerLabel,
    required this.photoOf,
    required this.onNickname,
    required this.onPhoto,
    this.updater,
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
  final String Function(Map<String, dynamic> partner) partnerLabel;
  final ImageProvider? Function(Map<String, dynamic> person) photoOf;
  final Future<void> Function() onNickname;
  final Future<void> Function() onPhoto;

  /// Checks GitHub for new versions; absent in design previews.
  final AppUpdater? updater;

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
    final them = widget.partnerLabel(partner);
    final realName = partner['name']?.toString() ?? '';
    final myPhoto = widget.photoOf(user);
    final theirPhoto = widget.photoOf(partner);
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
          Center(
            child: Semantics(
              button: true,
              label: 'Change your photo',
              child: GestureDetector(
                onTap: () => _then(widget.onPhoto),
                child: CoupleAvatars(
                  me,
                  them,
                  size: 76,
                  mePhoto: myPhoto,
                  partnerPhoto: theirPhoto,
                ),
              ),
            ),
          ),
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
                leading: PersonAvatar(them, size: 36, photo: theirPhoto),
                title: them,
                subtitle: them == realName
                    ? widget.presence(partner)
                    : '$realName · ${widget.presence(partner)}',
                onTap: () => _then(widget.onNickname),
                trailingIcon: Icons.edit_outlined,
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
                leading: PersonAvatar(me, size: 36, photo: myPhoto),
                title: 'Your photo',
                subtitle: myPhoto == null ? 'Add a photo' : 'Change or remove',
                onTap: () => _then(widget.onPhoto),
              ),
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
          const _Heading('App'),
          _Group(
            children: [
              _UpdateRow(updater: widget.updater, version: widget.version),
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
    this.trailingIcon,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final VoidCallback? onTap;
  final IconData? trailingIcon;

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
          : Icon(
              trailingIcon ?? Icons.chevron_right_rounded,
              color: c.muted,
              size: 20,
            ),
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

enum _UpdateStage {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  permission,
  installing,
  failed,
}

/// Settings row for updating Aida in place: check GitHub, download the APK,
/// verify it, and open Android's installer, which asks to confirm.
class _UpdateRow extends StatefulWidget {
  const _UpdateRow({required this.updater, required this.version});
  final AppUpdater? updater;
  final String version;

  @override
  State<_UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends State<_UpdateRow> {
  _UpdateStage _stage = _UpdateStage.idle;
  AppRelease? _release;
  double _progress = 0;
  String _problem = '';
  File? _downloaded;

  /// The installed version, read from Android; null until checked.
  String? _current;

  @override
  void initState() {
    super.initState();
    // A quiet look when Us opens; problems only show after a tap.
    if (widget.updater != null) _check(quiet: true);
  }

  Future<void> _check({bool quiet = false}) async {
    final updater = widget.updater;
    if (updater == null) return;
    setState(() => _stage = _UpdateStage.checking);
    try {
      final current = await updater.currentVersion();
      if (mounted) setState(() => _current = current);
      final release = await updater.latest();
      if (!mounted) return;
      setState(() {
        _release = release;
        _stage = release != null && AppUpdater.isNewer(release.version, current)
            ? _UpdateStage.available
            : _UpdateStage.upToDate;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = quiet ? _UpdateStage.idle : _UpdateStage.failed;
        _problem = error is UpdateException
            ? error.message
            : 'Couldn’t check for updates. Check your connection.';
      });
    }
  }

  Future<void> _update() async {
    final updater = widget.updater!;
    final release = _release!;
    try {
      if (!await updater.canInstall()) {
        setState(() => _stage = _UpdateStage.permission);
        await updater.allowInstalls();
        return;
      }
      setState(() {
        _stage = _UpdateStage.downloading;
        _progress = 0;
      });
      final file = await updater.download(
        release,
        await getTemporaryDirectory(),
        onProgress: (fraction) {
          if (mounted) setState(() => _progress = fraction);
        },
      );
      if (!mounted) return;
      _downloaded = file;
      await _install();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _UpdateStage.failed;
        _problem = error is UpdateException
            ? error.message
            : 'The update didn’t finish. Try again.';
      });
    }
  }

  /// Opens Android's installer; if it was dismissed, this reopens it
  /// without downloading again.
  Future<void> _install() async {
    setState(() => _stage = _UpdateStage.installing);
    try {
      await widget.updater!.install(_downloaded!);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _stage = _UpdateStage.failed;
        _problem = 'Android couldn’t open the installer.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.aida;
    final release = _release;
    final megabytes = release == null
        ? ''
        : ' · ${(release.size / (1024 * 1024)).toStringAsFixed(0)} MB';
    final (
      String subtitle,
      String? action,
      VoidCallback? onAction,
    ) = switch (_stage) {
      _UpdateStage.idle => (
        'Check for a newer version',
        'Check',
        () => _check(),
      ),
      _UpdateStage.checking => ('Checking…', null, null),
      _UpdateStage.upToDate => (
        'You have the latest version',
        'Check',
        () => _check(),
      ),
      _UpdateStage.available => (
        'Version ${release!.version} is ready$megabytes',
        'Update',
        _update,
      ),
      _UpdateStage.downloading => (
        'Downloading… ${(_progress * 100).round()}%',
        null,
        null,
      ),
      _UpdateStage.permission => (
        'Allow “Install unknown apps” for Aida, then come back and tap Update.',
        'Update',
        _update,
      ),
      _UpdateStage.installing => (
        'Confirm in the installer to finish updating.',
        'Install',
        _install,
      ),
      _UpdateStage.failed => (_problem, 'Try again', () => _check()),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _stage == _UpdateStage.available
                    ? Icons.system_update_rounded
                    : Icons.verified_outlined,
                color: c.accent,
                size: 22,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _current == null ? widget.version : 'Aida $_current',
                      style: TextStyle(color: c.ink, fontSize: 15.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _stage == _UpdateStage.failed
                            ? c.danger
                            : c.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (_stage == _UpdateStage.checking)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (action != null && widget.updater != null)
                _stage == _UpdateStage.available
                    ? FilledButton(
                        onPressed: onAction,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 40),
                        ),
                        child: Text(action),
                      )
                    : TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
          if (_stage == _UpdateStage.downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: _progress, minHeight: 3),
          ],
        ],
      ),
    );
  }
}
