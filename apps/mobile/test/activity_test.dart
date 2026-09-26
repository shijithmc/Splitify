import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/features/shell.dart';

void main() {
  test(
    'activity communicates meaningful changes without ledger identity IDs',
    () {
      final summary = activityChangeSummary({
        'changes': {
          'before': {
            'amountPaise': 10000,
            'date': '2026-09-20',
            'payerId': 'private-id-1',
            'mode': 'Equal',
            'shares': {'p': 10000},
            'version': 1,
            'deletedAt': null,
          },
          'after': {
            'amountPaise': 12000,
            'date': '2026-09-21',
            'payerId': 'private-id-2',
            'mode': 'Exact',
            'shares': {'p': 12000},
            'version': 2,
            'deletedAt': null,
          },
          'descriptionChanged': true,
        },
      });
      expect(summary, contains('Amount: ₹100.00 → ₹120.00'));
      expect(summary, contains('Date: 2026-09-20 → 2026-09-21'));
      expect(summary, contains('Payer changed'));
      expect(summary, contains('Split: Equal → Exact'));
      expect(summary, contains('Description edited'));
      expect(summary, contains('Split allocations changed'));
      expect(summary, isNot(contains('private-id')));
    },
  );
}
