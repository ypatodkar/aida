import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aida/main.dart';

void main() {
  testWidgets(
    'chat design fits small Android screens and larger text without overflowing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const RepaintBoundary(child: AidaApp()));
      await tester.pumpAndSettle();
      expect(find.text('Summer in Italy'), findsOneWidget);
      expect(find.text('Sofia'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.byTooltip('Read'), findsOneWidget);
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
    skip: !const bool.fromEnvironment('AIDA_DESIGN_PREVIEW'),
  );
}
