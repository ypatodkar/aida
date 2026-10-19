import 'package:flutter_test/flutter_test.dart';
import 'package:aida/design.dart';

int _ms(int y, int m, int d, [int h = 12]) =>
    DateTime(y, m, d, h).millisecondsSinceEpoch;

void main() {
  test('the day you connect is Day 1, whatever the hour', () {
    final t = Together(_ms(2026, 6, 3, 23), now: DateTime(2026, 6, 3, 23, 30));
    expect(t.day, 1);
    expect(t.nextLabel, 'Day 100');
    expect(t.daysUntilNext, 99);
  });

  test('counts calendar days across midnight', () {
    final t = Together(_ms(2026, 6, 3, 23), now: DateTime(2026, 6, 4, 0, 5));
    expect(t.day, 2);
  });

  test('a 100-day mark is celebrated on the day itself', () {
    final t = Together(_ms(2026, 1, 1), now: DateTime(2026, 4, 10));
    expect(t.day, 100);
    expect(t.nextLabel, 'Day 100');
    expect(t.countdown, 'today');
    expect(t.anniversary, isFalse);
  });

  test('the anniversary wins when it comes before the next 100 days', () {
    final t = Together(_ms(2026, 1, 1), now: DateTime(2026, 12, 20));
    expect(t.day, 354);
    expect(t.nextLabel, '1 year together');
    expect(t.nextDate, DateTime.utc(2027, 1, 1));
    expect(t.daysUntilNext, 12);
    expect(t.anniversary, isTrue);
  });

  test('on the anniversary itself', () {
    final t = Together(_ms(2025, 3, 14), now: DateTime(2027, 3, 14, 8));
    expect(t.nextLabel, '2 years together');
    expect(t.countdown, 'today');
    expect(t.anniversary, isTrue);
  });

  test('countdown wording', () {
    final t = Together(_ms(2026, 1, 1), now: DateTime(2026, 4, 9));
    expect(t.countdown, 'tomorrow');
  });
}
