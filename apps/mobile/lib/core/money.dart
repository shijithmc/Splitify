import 'package:intl/intl.dart';

const maxAmountPaise = 1000000000;
int parsePaise(String input, {bool allowZero = false}) {
  final value = input.trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException(
      'Use an amount with at most two decimal places.',
    );
  }
  final parts = value.split('.');
  final amount =
      int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  if (amount < (allowZero ? 0 : 1) || amount > maxAmountPaise) {
    throw const FormatException('Enter an amount from ₹0.01 to ₹1,00,00,000.');
  }
  return amount;
}

String money(int paise) => NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
).format(paise / 100);
String decimal(int paise) =>
    '${paise ~/ 100}.${(paise.abs() % 100).toString().padLeft(2, '0')}';
String day(DateTime value) => DateFormat('yyyy-MM-dd').format(value);

Map<String, int> splitAmount(int amount, String mode, Map<String, int> inputs) {
  if (amount <= 0 || amount > maxAmountPaise) {
    throw const FormatException('Enter a valid expense amount.');
  }
  if (inputs.isEmpty || inputs.length > 50) {
    throw const FormatException('Choose between 1 and 50 people.');
  }
  final ids = inputs.keys.toList()..sort();
  final result = <String, int>{};
  if (mode == 'Exact') {
    if (inputs.values.any((v) => v < 0 || v > maxAmountPaise)) {
      throw const FormatException('Amounts cannot be negative.');
    }
    final gap =
        amount - inputs.values.fold<int>(0, (sum, value) => sum + value);
    if (gap != 0) {
      throw FormatException(
        '${money(gap.abs())} ${gap > 0 ? 'left to assign' : 'over-assigned'}',
      );
    }
    return Map.from(inputs);
  }
  if (!['Equal', 'Percentage', 'Shares'].contains(mode)) {
    throw const FormatException('Choose a split method.');
  }
  if (mode == 'Percentage') {
    if (inputs.values.any((v) => v < 0 || v > 10000)) {
      throw const FormatException('Each percentage must be between 0 and 100.');
    }
    final gap = 10000 - inputs.values.fold<int>(0, (sum, value) => sum + value);
    if (gap != 0) {
      throw FormatException(
        '${decimal(gap.abs())}% ${gap > 0 ? 'left to assign' : 'over-assigned'}',
      );
    }
  }
  if (mode == 'Shares' && inputs.values.any((v) => v < 1 || v > 10000)) {
    throw const FormatException(
      'Shares must be whole numbers from 1 to 10,000.',
    );
  }
  final weights = {for (final id in ids) id: mode == 'Equal' ? 1 : inputs[id]!};
  final totalWeight = weights.values.fold<int>(0, (sum, value) => sum + value);
  for (final id in ids) {
    result[id] = amount * weights[id]! ~/ totalWeight;
  }
  var remaining =
      amount - result.values.fold<int>(0, (sum, value) => sum + value);
  for (final id in ids.where((id) => weights[id]! > 0)) {
    if (remaining-- <= 0) break;
    result[id] = result[id]! + 1;
  }
  return result;
}
