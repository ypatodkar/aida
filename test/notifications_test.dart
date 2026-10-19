import 'package:flutter_test/flutter_test.dart';
import 'package:aida/notifications.dart';

void main() {
  group('live socket notifications', () {
    test('never for the conversation already on screen', () {
      expect(
        socketShouldNotify(
          foreground: true,
          conversationVisible: true,
          pushActive: false,
        ),
        isFalse,
      );
    });

    test('in the foreground, for another topic or screen', () {
      for (final push in [true, false]) {
        expect(
          socketShouldNotify(
            foreground: true,
            conversationVisible: false,
            pushActive: push,
          ),
          isTrue,
        );
      }
    });

    test('in the background, only when push cannot deliver it', () {
      expect(
        socketShouldNotify(
          foreground: false,
          conversationVisible: false,
          pushActive: true,
        ),
        isFalse,
      );
      expect(
        socketShouldNotify(
          foreground: false,
          conversationVisible: false,
          pushActive: false,
        ),
        isTrue,
      );
    });
  });

  group('push received while open', () {
    test('defers to the live socket when it is connected', () {
      expect(
        foregroundPushShouldNotify(
          liveConnected: true,
          conversationVisible: false,
        ),
        isFalse,
      );
    });

    test('covers a reconnecting socket, except for the open conversation', () {
      expect(
        foregroundPushShouldNotify(
          liveConnected: false,
          conversationVisible: false,
        ),
        isTrue,
      );
      expect(
        foregroundPushShouldNotify(
          liveConnected: false,
          conversationVisible: true,
        ),
        isFalse,
      );
    });
  });
}
