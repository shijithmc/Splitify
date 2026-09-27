import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/amount_calculator.dart';
import 'package:hisaab/core/money.dart';

void main() {
  test('keeps decimal arithmetic exact until the final paise rounding', () {
    expect(calculateAmountPaise('245.50'), 24550);
    expect(calculateAmountPaise('0.1 + 0.2'), 30);
    expect(calculateAmountPaise('0.29 * 100'), 2900);
    expect(calculateAmountPaise('.5 + .25'), 75);
    expect(calculateAmountPaise('1 / 3 * 3'), 100);
    expect(calculateAmountPaise('0.005 + 0.005'), 1);
  });

  test(
    'uses ordinary precedence and left associativity with both symbol sets',
    () {
      expect(calculateAmountPaise('240 + 60 ÷ 2'), 27000);
      expect(calculateAmountPaise('2 + 3 × 4 − 5'), 900);
      expect(calculateAmountPaise('12 / 3 * 2'), 800);
      expect(calculateAmountPaise('10 - 3 - 2'), 500);
      expect(calculateAmountPaise('1 - 3 + 5'), 300);
      expect(calculateAmountPaise('  245.50 \n + 4.50  '), 25000);
    },
  );

  test('rounds once, half up, to the nearest paise', () {
    expect(calculateAmountPaise('10 / 3'), 333);
    expect(calculateAmountPaise('20 / 3'), 667);
    expect(calculateAmountPaise('1.005'), 101);
    expect(calculateAmountPaise('1.0049999'), 100);
    expect(calculateAmountPaise('0.005'), 1);
  });

  test(
    'rejects incomplete syntax and unsupported input instead of executing it',
    () {
      for (final input in [
        '',
        ' ',
        '.',
        '1.',
        '1+',
        '1++2',
        '-2',
        '1 + -2',
        '1 2',
        '1.2.3',
        '(2 + 3) * 4',
        '1e3',
        'NaN',
        'Infinity',
        '1,000',
        'print(1)',
      ]) {
        expect(
          () => calculateAmountPaise(input),
          throwsFormatException,
          reason: input,
        );
      }
    },
  );

  test(
    'rejects zero, negative, division by zero and amounts beyond the limit',
    () {
      expect(calculateAmountPaise('10000000'), maxAmountPaise);
      expect(calculateAmountPaise('5000000 * 2'), maxAmountPaise);
      for (final input in [
        '0',
        '0.0049',
        '1 - 1',
        '1 - 2',
        '1 / 0',
        '0 ÷ 0',
        '1 ÷ 0.00',
        '10000000.001',
        '99999999',
      ]) {
        expect(
          () => calculateAmountPaise(input),
          throwsFormatException,
          reason: input,
        );
      }
    },
  );

  test('bounds input length and operation count before excessive work', () {
    expect(calculateAmountPaise(List.filled(25, '1').join('+')), 2500);
    expect(
      () => calculateAmountPaise(List.filled(26, '1').join('+')),
      throwsFormatException,
    );
    expect(
      () => calculateAmountPaise('9' * (maxCalculatorExpressionLength + 1)),
      throwsFormatException,
    );
  });
}
