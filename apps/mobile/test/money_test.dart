import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/money.dart';

void main() {
  test('parses decimal input without binary floating point', () {
    expect(parsePaise('0.29'), 29);
    expect(parsePaise('10000000'), maxAmountPaise);
    for (final input in [
      '0',
      '-1',
      '1.001',
      '1e3',
      'NaN',
      '10,000',
      '10000000.01',
      '1.',
    ]) {
      expect(() => parsePaise(input), throwsFormatException, reason: input);
    }
  });
  test('equal rounds by stable ID, independent of input order', () {
    expect(splitAmount(10000, 'Equal', {'c': 1, 'b': 1, 'a': 1}), {
      'a': 3334,
      'b': 3333,
      'c': 3333,
    });
  });
  test('exact input explains unassigned and excess money', () {
    expect(
      () => splitAmount(10000, 'Exact', {'a': 8750}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          '₹12.50 left to assign',
        ),
      ),
    );
    expect(
      () => splitAmount(10000, 'Exact', {'a': 11000}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          '₹10.00 over-assigned',
        ),
      ),
    );
  });
  test('percentage never gives rounding remainder to zero allocation', () {
    expect(splitAmount(1, 'Percentage', {'a': 0, 'b': 5000, 'c': 5000}), {
      'a': 0,
      'b': 1,
      'c': 0,
    });
    expect(
      () => splitAmount(10000, 'Percentage', {'a': 9000}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          '10.00% left to assign',
        ),
      ),
    );
    expect(
      () => splitAmount(1, 'Percentage', {'a': -1, 'b': 10001}),
      throwsFormatException,
    );
  });
  test('shares have bounded positive integral weights', () {
    expect(splitAmount(10001, 'Shares', {'b': 2, 'a': 1}), {
      'a': 3334,
      'b': 6667,
    });
    expect(() => splitAmount(1, 'Shares', {'a': 0}), throwsFormatException);
    expect(() => splitAmount(1, 'Shares', {'a': 10001}), throwsFormatException);
  });
  test(
    'random equal and weighted splits conserve every paise up to 50 people',
    () {
      final random = Random(17);
      for (var i = 0; i < 500; i++) {
        final count = random.nextInt(50) + 1;
        final amount = random.nextInt(maxAmountPaise) + 1;
        final weights = {
          for (var j = 0; j < count; j++)
            'p${j.toString().padLeft(2, '0')}': random.nextInt(10000) + 1,
        };
        for (final mode in ['Equal', 'Shares']) {
          final shares = splitAmount(amount, mode, weights);
          expect(shares.values.fold<int>(0, (a, b) => a + b), amount);
          expect(shares.values.every((v) => v >= 0), isTrue);
          expect(
            shares,
            splitAmount(
              amount,
              mode,
              Map.fromEntries(weights.entries.toList().reversed),
            ),
          );
        }
      }
    },
  );
}
