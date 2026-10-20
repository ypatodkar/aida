import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aida/design.dart';
import 'package:aida/updates.dart';
import 'package:aida/us_screen.dart';

class _FakeUpdater extends AppUpdater {
  _FakeUpdater(this.release, {this.allowed = true});
  final AppRelease? release;
  bool allowed;
  bool askedForPermission = false;
  File? installed;

  @override
  Future<String> currentVersion() async => '2.3.0';
  @override
  Future<AppRelease?> latest() async => release;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> allowInstalls() async => askedForPermission = true;
  @override
  Future<void> install(File apk) async => installed = apk;
}

Widget _us(AppUpdater updater) => MaterialApp(
  theme: aidaTheme(Brightness.light, AidaAccent.lavender),
  home: UsScreen(
    state: () => {
      'user': {'id': 'me', 'name': 'Yash'},
      'pair': {
        'id': 'p',
        'partner': {'id': 'them', 'name': 'Sofia', 'nickname': 'Love'},
      },
    },
    presence: (_) => 'Online',
    themeMode: () => ThemeMode.light,
    accent: () => AidaAccent.lavender,
    onThemeMode: (_) {},
    onAccent: (_) {},
    onChangeName: () async {},
    onNotifications: () async {},
    onServer: () async {},
    onSignOut: () async {},
    onDisconnect: () async {},
    version: 'Aida 2.3.0',
    partnerLabel: (partner) => partner['nickname'] as String,
    photoOf: (_) => null,
    onNickname: () async {},
    onPhoto: () async {},
    updater: updater,
  ),
);

AppRelease _release(String version) => AppRelease(
  version: version,
  apk: Uri.parse('https://example.test/aida.apk'),
  size: 96 * 1024 * 1024,
);

void main() {
  testWidgets('shows the nickname with their real name underneath', (
    tester,
  ) async {
    await tester.pumpWidget(_us(_FakeUpdater(null)));
    await tester.pumpAndSettle();
    expect(find.text('Yash & Love'), findsOneWidget);
    expect(find.text('Sofia · Online'), findsOneWidget);
  });

  testWidgets('says when Aida is up to date', (tester) async {
    await tester.pumpWidget(_us(_FakeUpdater(_release('2.3.0'))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Aida 2.3.0'), 200);
    expect(find.text('You have the latest version'), findsOneWidget);
  });

  testWidgets('offers a newer version and asks for install permission first', (
    tester,
  ) async {
    final updater = _FakeUpdater(_release('2.4.0'), allowed: false);
    await tester.pumpWidget(_us(updater));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Aida 2.3.0'), 200);
    expect(find.text('Version 2.4.0 is ready · 96 MB'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pumpAndSettle();
    expect(updater.askedForPermission, isTrue);
    expect(find.textContaining('Install unknown apps'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
