import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'money.dart';

Json emptyReceiptReview() => {
  'merchant': '',
  'date': day(DateTime.now()),
  'sourceCurrency': 'INR',
  'grandTotalPaise': 0,
  'items': <Json>[],
  'charges': <Json>[],
  'splitByItems': false,
  'differenceAcknowledged': false,
};

/// Offline/demo estimate only. Production saves always use the server preview
/// and server arithmetic; this routine never supplies authoritative shares.
Json estimateReceipt(Json review) {
  final items = rows(
    review['items'],
  ).where((i) => i['ignored'] != true).toList();
  final charges = rows(review['charges']);
  var subtotal = items.fold<int>(0, (a, i) => a + (i['lineTotalPaise'] as int));
  if (items.isEmpty &&
      review['splitByItems'] != true &&
      review['subtotalPaise'] is int) {
    subtotal = review['subtotalPaise'];
  }
  final additional = charges
      .where((c) => c['includedInItemPrices'] != true)
      .fold<int>(0, (a, c) => a + (c['amountPaise'] as int));
  final difference =
      (review['sourceCurrency'] != 'INR' ||
              (items.isEmpty && review['subtotalPaise'] == null)) &&
          review['splitByItems'] != true
      ? 0
      : (review['grandTotalPaise'] as int) - subtotal - additional;
  final base = <String, int>{};
  final details = <String, List<Json>>{};
  for (final item in items) {
    final ids =
        (item['assigneeIds'] as List? ?? []).cast<String>().toSet().toList()
          ..sort();
    if (review['splitByItems'] == true && ids.isEmpty) {
      throw const FormatException('Assign every item before continuing.');
    }
    if (ids.isEmpty) continue;
    final values = _allocate(item['lineTotalPaise'], {
      for (final id in ids) id: 1,
    });
    for (final entry in values.entries) {
      base[entry.key] = (base[entry.key] ?? 0) + entry.value;
      details.putIfAbsent(entry.key, () => []).add({
        'id': item['id'],
        'amountPaise': entry.value,
      });
    }
  }
  final shares = Map<String, int>.from(base);
  final components = <String, List<Json>>{for (final id in base.keys) id: []};
  final allCharges = [
    ...charges,
    if (difference != 0)
      {
        'id': '__difference',
        'kind': 'Adjustment',
        'amountPaise': difference,
        'includedInItemPrices': false,
      },
  ];
  final orderedCharges = [
    ...allCharges.where((c) => (c['amountPaise'] as int) >= 0),
    ...allCharges.where((c) => (c['amountPaise'] as int) < 0),
  ];
  if (review['splitByItems'] == true) {
    for (final charge in orderedCharges) {
      final custom = object(
        charge['weights'],
      ).map((k, v) => MapEntry(k, v as int));
      final weights = custom.isEmpty ? base : custom;
      final value = charge['amountPaise'] as int;
      final inclusive = charge['includedInItemPrices'] == true;
      final parts = _allocate(
        value,
        weights,
        available: value < 0 && !inclusive ? shares : null,
      );
      for (final entry in parts.entries) {
        if (!inclusive) {
          shares[entry.key] = (shares[entry.key] ?? 0) + entry.value;
        }
        components.putIfAbsent(entry.key, () => []).add({
          'id': charge['id'],
          'kind': charge['kind'],
          'amountPaise': entry.value,
          'includedInItemPrices': inclusive,
        });
      }
    }
  }
  final hashInput = {...review}
    ..remove('differenceAcknowledged')
    ..remove('acknowledgedReviewHash');
  return {
    'reviewHash': sha256.convert(utf8.encode(jsonEncode(hashInput))).toString(),
    'itemSubtotalPaise': subtotal,
    'additiveChargesPaise': additional,
    'differencePaise': difference,
    'requiresDifferenceAcknowledgement': difference.abs() > 100,
    'shares': shares,
    'people': [
      for (final id in shares.keys)
        {
          'participantId': id,
          'itemsPaise': base[id] ?? 0,
          'totalPaise': shares[id],
          'items': details[id] ?? <Json>[],
          'charges': components[id] ?? <Json>[],
        },
    ],
    'warnings': <String>[],
  };
}

Map<String, int> _allocate(
  int amount,
  Map<String, int> weights, {
  Map<String, int>? available,
}) {
  final valid = Map<String, int>.fromEntries(
    weights.entries.where((e) => e.value > 0),
  );
  if (amount == 0) return {for (final id in weights.keys) id: 0};
  if (valid.isEmpty) {
    throw const FormatException(
      'A charge needs a positive item subtotal or allocation weight.',
    );
  }
  final result = {for (final id in weights.keys) id: 0};
  var remaining = amount.abs();
  while (remaining > 0) {
    final eligible =
        valid.keys
            .where(
              (id) => available == null || (available[id] ?? 0) > result[id]!,
            )
            .toList()
          ..sort();
    if (eligible.isEmpty) {
      throw const FormatException(
        'Discount would make a person’s total negative.',
      );
    }
    final denominator = eligible.fold<int>(0, (sum, id) => sum + valid[id]!);
    final allocation = {
      for (final id in eligible)
        id:
            (BigInt.from(remaining) *
                    BigInt.from(valid[id]!) ~/
                    BigInt.from(denominator))
                .toInt(),
    };
    var remainder = remaining - allocation.values.fold<int>(0, (a, b) => a + b);
    for (final id in eligible) {
      if (remainder-- > 0) allocation[id] = allocation[id]! + 1;
    }
    var assigned = 0;
    for (final id in eligible) {
      final proposed = allocation[id]!;
      final accepted = available == null
          ? proposed
          : proposed.clamp(0, (available[id] ?? 0) - result[id]!);
      result[id] = result[id]! + accepted;
      assigned += accepted;
    }
    if (assigned == 0) {
      throw const FormatException('Charge cannot be allocated.');
    }
    remaining -= assigned;
  }
  return result.map((id, value) => MapEntry(id, amount < 0 ? -value : value));
}
