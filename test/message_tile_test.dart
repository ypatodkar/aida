import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aida/api.dart';
import 'package:aida/design.dart';
import 'package:aida/media_view.dart';

Widget _host(Widget child) => MaterialApp(
  theme: aidaTheme(Brightness.light, AidaAccent.lavender),
  home: Scaffold(body: ListView(children: [child])),
);

Map<String, dynamic> _message({
  List<Map<String, dynamic>> reactions = const [],
}) => {
  'id': 1,
  'senderId': 'me',
  'kind': 'text',
  'text': 'Hello',
  'createdAt': DateTime(2026, 10, 19, 9).millisecondsSinceEpoch,
  'reactions': reactions,
};

void main() {
  final api = AidaApi('https://example.invalid', token: 't');

  testWidgets('a reacted message grouped with the next one lays out', (
    tester,
  ) async {
    for (final joinsBelow in [false, true]) {
      await tester.pumpWidget(
        _host(
          MessageTile(
            message: _message(
              reactions: const [
                {'userId': 'them', 'emoji': '❤️'},
              ],
            ),
            mine: true,
            api: api,
            joinsBelow: joinsBelow,
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'joinsBelow: $joinsBelow');
      expect(find.bySemanticsLabel('Reactions: ❤️'), findsOneWidget);
    }
  });

  testWidgets('deleted messages offer no gestures and show no reactions', (
    tester,
  ) async {
    var held = false;
    await tester.pumpWidget(
      _host(
        MessageTile(
          message: {
            ..._message(
              reactions: const [
                {'userId': 'them', 'emoji': '❤️'},
              ],
            ),
            'deleted': true,
            'text': null,
          },
          mine: false,
          api: api,
          onOptions: () => held = true,
        ),
      ),
    );
    expect(find.text('This message was deleted'), findsOneWidget);
    expect(find.bySemanticsLabel('Reactions: ❤️'), findsNothing);
    await tester.longPress(find.text('This message was deleted'));
    expect(held, isFalse);
  });
}
