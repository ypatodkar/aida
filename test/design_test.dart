import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aida/main.dart';
import 'package:aida/media_view.dart';

const _skip = !bool.fromEnvironment('AIDA_DESIGN_PREVIEW');

Future<void> _phone(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(const RepaintBoundary(child: AidaApp()));
}

Brightness _brightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).last)).brightness;

void main() {
  testWidgets(
    'chat design fits small Android screens and larger text without overflowing',
    (tester) async {
      await _phone(tester);
      await tester.pumpAndSettle();
      expect(find.text('Summer in Italy'), findsOneWidget);
      expect(find.text('Sofia'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.byTooltip('Read'), findsOneWidget);
      expect(find.byTooltip('Delivered'), findsOneWidget);
      expect(
        find.text('Saving you a seat for when you get here.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(360, 740);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    skip: _skip,
  );

  testWidgets('follows the system dark mode', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await _phone(tester);
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.dark);
    expect(find.text('Sofia'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('Moments opens from the header menu', (tester) async {
    await _phone(tester, size: const Size(360, 740));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Moments and Us'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moments'));
    // The together card's mark breathes forever, so pump instead of settle.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Day 142'), findsOneWidget);
    expect(find.text('Yash & Sofia'.toUpperCase()), findsOneWidget);
    expect(find.text('PHOTOS & VIDEOS'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('Us changes theme and accent, then returns to chat', (
    tester,
  ) async {
    await _phone(tester, size: const Size(360, 740));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sofia'));
    await tester.pumpAndSettle();
    expect(find.text('Yash & Sofia'), findsOneWidget);
    expect(find.textContaining('Day 142'), findsOneWidget);
    expect(_brightness(tester), Brightness.light);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.dark);

    await tester.tap(find.bySemanticsLabel('Dusk accent'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('Yash & Sofia'))).colorScheme.primary,
      const Color(0xFFDDAAC2),
    );

    await tester.scrollUntilVisible(find.text('Disconnect and delete'), 200);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Back to chat'));
    await tester.pumpAndSettle();
    expect(
      find.text('Saving you a seat for when you get here.'),
      findsOneWidget,
    );
    expect(_brightness(tester), Brightness.dark);
  }, skip: _skip);

  testWidgets('replies show the quoted message and its author', (tester) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Replying to You: Already my favorite place.'),
      findsOneWidget,
    );
    expect(find.text('Already my favorite place.'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('press and hold opens message options; Reply starts a reply', (
    tester,
  ) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    await tester.longPress(
      find.text('Saving you a seat for when you get here.'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy text'), findsOneWidget);
    expect(find.textContaining('Sofia ·'), findsOneWidget);

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Sofia'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Sofia'), findsNothing);
  }, skip: _skip);

  testWidgets('swiping a message to the right starts a reply', (tester) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    final bubble = find.text('Just because you’re there.');
    // A short drag springs back without replying.
    await tester.drag(bubble, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to yourself'), findsNothing);

    await tester.drag(bubble, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to yourself'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('tapping a quote jumps to the original message', (tester) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find.bySemanticsLabel('Replying to You: Already my favorite place.'),
    );
    bool highlighted() => tester
        .widget<MessageTile>(
          find.byWidgetPredicate(
            (w) => w is MessageTile && w.message['id'] == 3,
          ),
        )
        .highlighted;
    expect(highlighted(), isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(highlighted(), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(highlighted(), isFalse);
    expect(tester.takeException(), isNull);
  }, skip: _skip);
}
