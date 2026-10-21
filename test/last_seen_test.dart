import 'package:flutter_test/flutter_test.dart';
import 'package:aida/design.dart';

void main() {
  final now = DateTime(2026, 10, 20, 18, 30);

  test('today shows the time they last had Aida open', () {
    expect(
      lastSeenLabel(DateTime(2026, 10, 20, 14, 5), now),
      'Last seen today at 14:05',
    );
    expect(
      lastSeenLabel(DateTime(2026, 10, 20, 18, 29, 50), now),
      'Last seen today at 18:29',
    );
  });

  test('yesterday and earlier dates keep the time', () {
    expect(
      lastSeenLabel(DateTime(2026, 10, 19, 22, 15), now),
      'Last seen yesterday at 22:15',
    );
    expect(
      lastSeenLabel(DateTime(2026, 10, 3, 9, 10), now),
      'Last seen 3 Oct at 09:10',
    );
    expect(
      lastSeenLabel(DateTime(2025, 12, 31, 23, 59), now),
      'Last seen 31 Dec 2025 at 23:59',
    );
  });

  test('a clock slightly ahead of this phone still reads as today', () {
    expect(
      lastSeenLabel(DateTime(2026, 10, 20, 18, 31), now),
      'Last seen today at 18:31',
    );
  });
}
