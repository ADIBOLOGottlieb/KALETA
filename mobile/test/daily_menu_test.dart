import 'package:flutter_test/flutter_test.dart';
import 'package:kaleta/utils/format.dart';

void main() {
  test('menu du jour : jour lu au début du nom', () {
    expect(dailyMenuWeekday('Lundi · Spaghetti Kaleta'), 1);
    expect(dailyMenuWeekday('mercredi · Poulet sauté + koliko'), 3);
    expect(dailyMenuWeekday('Dimanche · Poisson braisé + attiéké'), 7);
  });

  test('plat ordinaire : pas un menu du jour', () {
    expect(dailyMenuWeekday('Pizza Kaleta'), isNull);
    expect(dailyMenuWeekday('Pack · Lundi'), isNull);
    expect(dailyMenuWeekday(' · Lundi'), isNull);
  });
}
