import 'money.dart';

const maxCalculatorExpressionLength = 120;
const _maxOperations = 24;

/// Calculates rupees using exact fractions, then rounds half up to one paise.
///
/// Supports decimal numbers and binary +, -, ×/* and ÷/ operators with the
/// usual precedence. Throws [FormatException] for invalid or out-of-range input.
int calculateAmountPaise(String expression) {
  if (expression.length > maxCalculatorExpressionLength) {
    throw const FormatException('Use 120 characters or fewer.');
  }
  final result = _AmountParser(expression).parse();
  final scaled = result.numerator * BigInt.from(100);
  if (scaled <= BigInt.zero ||
      scaled > BigInt.from(maxAmountPaise) * result.denominator) {
    throw const FormatException('Enter an amount from ₹0.01 to ₹1,00,00,000.');
  }
  final paise =
      (scaled * BigInt.two + result.denominator) ~/
      (result.denominator * BigInt.two);
  if (paise == BigInt.zero) {
    throw const FormatException('The rounded amount must be at least ₹0.01.');
  }
  return paise.toInt();
}

class _Fraction {
  final BigInt numerator, denominator;

  factory _Fraction(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) {
      throw const FormatException('Cannot divide by zero.');
    }
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final divisor = numerator.gcd(denominator);
    return _Fraction._(numerator ~/ divisor, denominator ~/ divisor);
  }

  const _Fraction._(this.numerator, this.denominator);

  _Fraction apply(String operation, _Fraction other) => switch (operation) {
    '+' => _Fraction(
      numerator * other.denominator + other.numerator * denominator,
      denominator * other.denominator,
    ),
    '-' || '−' => _Fraction(
      numerator * other.denominator - other.numerator * denominator,
      denominator * other.denominator,
    ),
    '*' || '×' => _Fraction(
      numerator * other.numerator,
      denominator * other.denominator,
    ),
    '/' || '÷' => _Fraction(
      numerator * other.denominator,
      denominator * other.numerator,
    ),
    _ => throw const FormatException('Use +, −, × or ÷ between amounts.'),
  };
}

class _AmountParser {
  final String source;
  int position = 0, operations = 0;
  _AmountParser(this.source);

  _Fraction parse() {
    var result = _product();
    while (_next == '+' || _next == '-' || _next == '−') {
      final operation = _operator();
      result = result.apply(operation, _product());
    }
    if (_next.isNotEmpty) {
      throw const FormatException('Use +, −, × or ÷ between amounts.');
    }
    return result;
  }

  _Fraction _product() {
    var result = _number();
    while (['*', '×', '/', '÷'].contains(_next)) {
      final operation = _operator();
      result = result.apply(operation, _number());
    }
    return result;
  }

  String get _next {
    _skipWhitespace();
    return position < source.length ? source[position] : '';
  }

  void _skipWhitespace() {
    while (position < source.length && source[position].trim().isEmpty) {
      position++;
    }
  }

  String _operator() {
    if (++operations > _maxOperations) {
      throw const FormatException('Use no more than 24 operations at a time.');
    }
    return source[position++];
  }

  _Fraction _number() {
    _skipWhitespace();
    final start = position;
    while (_isDigit) {
      position++;
    }
    var decimalPlaces = 0;
    if (position < source.length && source[position] == '.') {
      position++;
      final fractionStart = position;
      while (_isDigit) {
        position++;
      }
      decimalPlaces = position - fractionStart;
      if (decimalPlaces == 0) {
        throw const FormatException('Complete the number after the decimal.');
      }
    }
    if (position == start) {
      throw const FormatException('Enter a number after each operator.');
    }
    final digits = source.substring(start, position).replaceAll('.', '');
    return _Fraction(BigInt.parse(digits), BigInt.from(10).pow(decimalPlaces));
  }

  bool get _isDigit =>
      position < source.length &&
      source.codeUnitAt(position) >= 48 &&
      source.codeUnitAt(position) <= 57;
}
