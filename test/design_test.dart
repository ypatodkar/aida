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

  /// The bubble's own text, not a quote of it inside a reply.
  Finder bubbleText(String text) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is MessageTile && w.message['text'] == text,
    ),
    matching: find.text(text),
  );

  Future<void> holdMessage(WidgetTester tester, String text) async {
    await tester.longPress(bubbleText(text));
    await tester.pumpAndSettle();
  }

  testWidgets('reactions show under the bubble and can be added', (
    tester,
  ) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Reactions: ❤️'), findsOneWidget);
    expect(find.textContaining('edited ·'), findsOneWidget);

    await holdMessage(tester, 'Just because you’re there.');
    await tester.tap(find.bySemanticsLabel('React 😂'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Reactions: ❤️ 😂'), findsOneWidget);

    // Choosing the same reaction again takes it back.
    await holdMessage(tester, 'Just because you’re there.');
    await tester.tap(find.bySemanticsLabel('React 😂'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Reactions: ❤️'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('only your own messages can be edited or deleted', (
    tester,
  ) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    await holdMessage(tester, 'Found the little café I told you about ☕');
    expect(find.text('Keep in Moments'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for both of you'), findsNothing);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await holdMessage(tester, 'Already my favorite place.');
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete for both of you'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('editing a message updates it and marks it edited', (
    tester,
  ) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    await holdMessage(tester, 'Already my favorite place.');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    expect(find.bySemanticsLabel('Take a photo'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'Already our favorite place.',
    );
    await tester.tap(find.byTooltip('Save edit'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsNothing);
    expect(bubbleText('Already our favorite place.'), findsOneWidget);
    expect(find.textContaining('edited ·'), findsNWidgets(2));
    // The draft that was set aside comes back empty, with the camera.
    expect(find.bySemanticsLabel('Take a photo'), findsOneWidget);
  }, skip: _skip);

  testWidgets('deleting asks first, then leaves a placeholder', (tester) async {
    await _phone(tester);
    await tester.pumpAndSettle();
    await holdMessage(tester, 'Already my favorite place.');
    await tester.tap(find.text('Delete for both of you'));
    await tester.pumpAndSettle();
    expect(find.text('Delete for both of you?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.text('You deleted this message'), findsNothing);

    await holdMessage(tester, 'Already my favorite place.');
    await tester.tap(find.text('Delete for both of you'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('You deleted this message'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('kept messages appear in Moments', (tester) async {
    await _phone(tester, size: const Size(390, 900));
    await tester.pumpAndSettle();
    await holdMessage(tester, 'Found the little café I told you about ☕');
    await tester.tap(find.text('Keep in Moments'));
    await tester.pumpAndSettle();
    expect(find.text('Kept in Moments'), findsOneWidget);

    await tester.tap(find.byTooltip('Moments and Us'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moments'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('KEPT'), findsOneWidget);
    expect(
      find.text('“Found the little café I told you about ☕”'),
      findsOneWidget,
    );
    expect(
      find.text('“Saving you a seat for when you get here.”'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Remove from Moments').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Remove from Moments'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: _skip);

  testWidgets('the attach sheet offers camera, video, and gallery', (
    tester,
  ) async {
    await _phone(tester, size: const Size(360, 740));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Take a photo'), findsOneWidget);
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    expect(find.text('Share with Sofia'), findsOneWidget);
    expect(find.text('In Everyday'), findsOneWidget);
    for (final label in ['Camera', 'Video', 'Gallery']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();
    expect(find.bySemanticsLabel('Take a photo'), findsNothing);
  }, skip: _skip);
}
