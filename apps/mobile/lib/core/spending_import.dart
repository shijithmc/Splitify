import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// Imports stay on-device. The native SMS channel returns structured financial
/// fields only, never an SMS body, sender phone number, OTP, or message content.
class SpendingImportService {
  SpendingImportService({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel('app.hisaab/spending'),
      supportsSms =
          android ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool supportsSms;
  int unrecognizedCount = 0;
  bool truncated = false;
  String? _owner;
  int? _generation;
  List<String> _pendingIds = [];

  /// Must run at login/account change and logout. Native capture is disabled and
  /// its cache removed when ownership changes. Only a hash crosses the channel.
  Future<void> configureOwner(String? ownerId) async {
    if (!supportsSms) return;
    _owner = ownerId == null
        ? null
        : sha256.convert(utf8.encode(ownerId)).toString();
    _pendingIds = [];
    unrecognizedCount = 0;
    truncated = false;
    final owner = _owner;
    _generation = null;
    final generation = await _channel.invokeMethod<int>('setOwner', {
      'owner': owner,
    });
    if (owner == _owner) _generation = generation;
  }

  Future<bool> smsEnabled() async =>
      supportsSms && (await _channel.invokeMethod<bool>('smsEnabled') ?? false);

  /// requestPermission may only be true after the in-app consent screen.
  Future<List<Json>> importSms({bool requestPermission = false}) async {
    if (!supportsSms) return [];
    final owner = _owner;
    final generation = _generation;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'importSms',
      {
        'requestPermission': requestPermission,
        'owner': owner,
        'generation': generation,
      },
    );
    if (owner != _owner || generation != _generation) return [];
    unrecognizedCount = (result?['unrecognizedCount'] as num?)?.toInt() ?? 0;
    truncated = result?['truncated'] == true;
    final rows = (result?['transactions'] as List? ?? const [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    _pendingIds = rows
        .map((row) => row['importId'])
        .whereType<String>()
        .toList();
    return rows;
  }

  Future<void> disableSms() async {
    if (supportsSms) {
      final owner = _owner;
      final generation = await _channel.invokeMethod<int>('disableSms', {
        'owner': owner,
        'generation': _generation,
      });
      if (owner != _owner) return;
      _generation = generation;
    }
    _pendingIds = [];
    unrecognizedCount = 0;
    truncated = false;
  }

  /// Call only after the ledger has durably saved the most recent import.
  Future<void> acknowledgeSms() async {
    if (!supportsSms || _pendingIds.isEmpty) return;
    final owner = _owner;
    final ids = _pendingIds;
    await _channel.invokeMethod<void>('acknowledgeSms', {
      'owner': owner,
      'ids': ids,
      'generation': _generation,
    });
    if (owner == _owner && identical(ids, _pendingIds)) _pendingIds = [];
  }

  Future<void> clearImportedData() async {
    if (supportsSms) {
      final owner = _owner;
      final generation = await _channel.invokeMethod<int>('clearImportedData', {
        'owner': owner,
        'generation': _generation,
      });
      if (owner != _owner) return;
      _generation = generation;
    }
    _pendingIds = [];
    unrecognizedCount = 0;
    truncated = false;
  }

  Future<String> pdfText(String path, {String? password}) async {
    final text = await _channel.invokeMethod<String>('pdfText', {
      'path': path,
      'password': ?password,
    });
    if (text == null || text.trim().isEmpty) {
      throw const FormatException(
        'This PDF has no readable text. Use a CSV statement or add a transaction.',
      );
    }
    return text;
  }
}

const _banks = <String, List<String>>{
  'SBI': ['SBI', 'SBIINB'],
  'HDFC': ['HDFC', 'HDFCBK'],
  'ICICI': ['ICICI', 'ICICIB'],
  'Axis': ['AXIS', 'AXISBK'],
  'Kotak': ['KOTAK', 'KOTAKB'],
  'PNB': ['PNB', 'PNBSMS'],
  'Bank of Baroda': ['BOB', 'BOBTXN', 'BARODA'],
  'Canara': ['CANARA', 'CANBNK'],
  'Union Bank': ['UNION', 'UBI', 'UNIONB'],
  'IDFC First': ['IDFC', 'IDFCFB'],
  'Yes Bank': ['YESBNK', 'YESBANK'],
  'IndusInd': ['INDUSB', 'INDUSIND'],
  'AU Bank': ['AUBANK', 'AUSFBL'],
  'Federal': ['FEDERAL', 'FEDBNK'],
  'Paytm Payments Bank': ['PAYTMB', 'PYTMBK'],
};

String? _bankForSender(String sender) {
  // Accept Indian alphanumeric DLT sender IDs, never arbitrary personal numbers.
  final segments = sender.toUpperCase().split('-');
  final id = segments.length > 1 && RegExp(r'^[PSTG]$').hasMatch(segments.last)
      ? segments[segments.length - 2]
      : segments.last;
  for (final entry in _banks.entries) {
    if (entry.value.contains(id)) return entry.key;
  }
  return null;
}

final _rejectSms = RegExp(
  r'\b(otp|one[ -]?time|verification code|failed|declined|pending|unsuccessful|request|requested|due|minimum due|will be debited|scheduled)\b',
  caseSensitive: false,
);
final _money = RegExp(
  r'(?:INR|Rs\.?|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)(?![0-9]|\.[0-9])',
  caseSensitive: false,
);
final _debit = RegExp(
  r'\b(debited|spent|paid|withdrawn|transferred|purchase(?:d)?)\b',
  caseSensitive: false,
);
final _credit = RegExp(
  r'\b(credited|received|deposited)\b',
  caseSensitive: false,
);
final _refund = RegExp(
  r'\b(refund(?:ed)?|revers(?:ed|al))\b',
  caseSensitive: false,
);

int? _paise(String value) {
  final cleaned = value
      .trim()
      .replaceAll(',', '')
      .replaceAll(RegExp(r'^(?:INR|Rs\.?|₹)\s*', caseSensitive: false), '');
  if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(cleaned)) return null;
  final pieces = cleaned.split('.');
  final rupees = int.tryParse(pieces.first);
  if (rupees == null || rupees > 10000000) return null;
  final amount =
      rupees * 100 +
      (pieces.length == 2 ? int.parse(pieces[1].padRight(2, '0')) : 0);
  return amount > 0 && amount <= 1000000000 ? amount : null;
}

String _safeTitle(String text) {
  var result = text
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\d{8,}'), '••••')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (RegExp(r'^[=+@-]').hasMatch(result)) result = "'$result";
  if (result.length > 80) result = result.substring(0, 80).trim();
  return result;
}

String _category(String title) {
  final text = title.toLowerCase();
  if (RegExp(
    r'swiggy|zomato|restaurant|cafe|coffee|pizza|food',
  ).hasMatch(text)) {
    return 'Food & cafés';
  }
  if (RegExp(
    r'bigbasket|blinkit|zepto|grocery|groceries|supermarket',
  ).hasMatch(text)) {
    return 'Groceries';
  }
  if (RegExp(r'uber|ola\b|metro|irctc|petrol|fuel|rapido').hasMatch(text)) {
    return 'Travel';
  }
  if (RegExp(r'netflix|spotify|prime video|hotstar|youtube').hasMatch(text)) {
    return 'Bills';
  }
  if (RegExp(
    r'jio\b|airtel|electric|broadband|utility|water bill',
  ).hasMatch(text)) {
    return 'Bills';
  }
  if (RegExp(r'amazon|flipkart|myntra|shopping').hasMatch(text)) {
    return 'Shopping';
  }
  if (RegExp(r'pharmacy|hospital|medical|clinic|apollo').hasMatch(text)) {
    return 'Health';
  }
  if (RegExp(r'\brent\b').hasMatch(text)) return 'Bills';
  return 'Other';
}

String _merchantKey(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

Json _row({
  required String title,
  required int amountPaise,
  required DateTime date,
  required String kind,
  required String source,
  String? bank,
  String? accountLast4,
  String? reference,
  String? category,
}) {
  final safeTitle = _safeTitle(title);
  final values = <String, dynamic>{
    'title': safeTitle,
    'amountPaise': amountPaise,
    'date': date.toIso8601String(),
    'kind': kind,
    'source': source,
    'category':
        category ??
        (kind == 'transfer' || kind == 'credit'
            ? 'Other'
            : _category(safeTitle)),
    if (_merchantKey(safeTitle).isNotEmpty)
      'merchantKey': _merchantKey(safeTitle),
    'bank': ?bank,
    'accountLast4': ?accountLast4,
    'reference': ?reference,
  };
  // Stable IDs make repeated imports idempotent. References are preferred; the
  // ledger also checks same-account, same-amount records from other sources.
  final identity = reference != null
      ? '$bank|$accountLast4|$reference|$amountPaise|$kind'
      : '${date.toIso8601String()}|$accountLast4|$amountPaise|$kind|${_merchantKey(safeTitle).isEmpty ? safeTitle : _merchantKey(safeTitle)}';
  values['importId'] = sha256.convert(utf8.encode(identity)).toString();
  return values;
}

/// Conservative English template parser. Unknown formats are skipped rather
/// than guessing financial amounts; this is not a validated bank-wide corpus.
Json? parseFinancialSms(
  String body, {
  required String sender,
  required DateTime date,
}) {
  final bank = _bankForSender(sender);
  if (bank == null || body.length > 4000 || _rejectSms.hasMatch(body)) {
    return null;
  }
  final debit = _debit.hasMatch(body);
  final credit = _credit.hasMatch(body);
  final refund = _refund.hasMatch(body);
  if ((!debit && !credit && !refund) || (debit && credit && !refund)) {
    return null;
  }
  final amountMatch = _money.firstMatch(body);
  if (amountMatch == null) return null;
  if (RegExp(
    r'(?:bal(?:ance)?|available|limit)\s*[:.-]?\s*$',
    caseSensitive: false,
  ).hasMatch(body.substring(0, amountMatch.start))) {
    return null;
  }
  final amount = _paise(amountMatch.group(1)!);
  if (amount == null) return null;
  final account = RegExp(
    r'(?:a/c|ac(?:ct)?|account|card)\s*(?:no\.?\s*)?[:.*\sXx-]*([0-9]{4,18})\b',
    caseSensitive: false,
  ).firstMatch(body)?.group(1);
  final last4 = account?.substring(account.length - 4);
  final reference = RegExp(
    r'(?:UPI\s*(?:Ref(?:erence)?\s*(?:No\.?)?|Ref)|Ref(?:erence)?\s*(?:No\.?)?|UTR|RRN)\s*[:.#-]?\s*([A-Za-z0-9]{6,30})\b',
    caseSensitive: false,
  ).firstMatch(body)?.group(1);
  final merchant = RegExp(
    r'\b(?:at|to|from)\s+(?!(?:a/c|ac(?:ct)?|account|card)(?=[\sXx*\d.:_-]|$)|your\b)([A-Za-z][A-Za-z0-9 &._@/-]{1,80}?)(?=\s+(?:on|via|using|UPI|Ref|Avl|Bal|a/c|account|card|for)\b|[.;]|$)',
    caseSensitive: false,
  ).firstMatch(body)?.group(1)?.trim();
  var kind = refund
      ? 'refund'
      : credit
      ? 'credit'
      : 'debit';
  final own = RegExp(
    r'\b(?:self transfer|own account|cash withdrawal|ATM)\b',
    caseSensitive: false,
  ).hasMatch(body);
  final p2p =
      debit &&
      merchant != null &&
      _category(merchant) == 'Other' &&
      RegExp(r'\bUPI\b', caseSensitive: false).hasMatch(body) &&
      RegExp(
        r'\b(?:transferred|P2P|person.to.person)\b',
        caseSensitive: false,
      ).hasMatch(body);
  if (!refund && own) kind = 'transfer';
  final title = merchant == null
      ? (refund
            ? 'Refund'
            : credit
            ? 'Money received'
            : 'Bank payment')
      : p2p && !own
      ? 'Transfer to $merchant'
      : merchant;
  return _row(
    title: title,
    amountPaise: amount,
    date: date,
    kind: kind,
    source: 'SMS',
    bank: bank,
    accountLast4: last4,
    reference: reference,
  );
}

DateTime? _date(String text) {
  final value = text.trim();
  // ISO dates may include a time and zone; reject DateTime's overflow rollover.
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?$').firstMatch(value);
  if (iso != null) {
    final result = DateTime.tryParse(value);
    if (result == null) return null;
    final calendar = DateTime(
      int.parse(iso[1]!),
      int.parse(iso[2]!),
      int.parse(iso[3]!),
    );
    if (calendar.year != int.parse(iso[1]!) ||
        calendar.month != int.parse(iso[2]!) ||
        calendar.day != int.parse(iso[3]!)) {
      return null;
    }
    return result;
  }
  final indian = RegExp(
    r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2}|\d{4})$',
  ).firstMatch(value);
  if (indian == null) return null;
  final day = int.parse(indian[1]!);
  final month = int.parse(indian[2]!);
  var year = int.parse(indian[3]!);
  if (year < 100) year += 2000;
  final date = DateTime(year, month, day);
  return date.day == day && date.month == month && date.year == year
      ? date
      : null;
}

List<List<String>> _csvRows(String text) {
  if (text.length > 2 * 1024 * 1024) {
    throw const FormatException('Choose a CSV smaller than 2 MB.');
  }
  final rows = <List<String>>[];
  var cells = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (quoted || cell.isEmpty) {
        quoted = !quoted;
      } else {
        throw const FormatException(
          'This CSV contains an invalid quoted field.',
        );
      }
    } else if (char == ',' && !quoted) {
      cells.add(cell.toString());
      cell = StringBuffer();
    } else if ((char == '\n' || char == '\r') && !quoted) {
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      cells.add(cell.toString());
      if (cells.any((value) => value.trim().isNotEmpty)) rows.add(cells);
      if (rows.length > 5001) {
        throw const FormatException(
          'Import at most 5,000 transactions at a time.',
        );
      }
      cells = [];
      cell = StringBuffer();
    } else {
      cell.write(char);
    }
  }
  if (quoted) {
    throw const FormatException('This CSV has an unclosed quoted field.');
  }
  cells.add(cell.toString());
  if (cells.any((value) => value.trim().isNotEmpty)) rows.add(cells);
  return rows;
}

/// Supports explicit date/description/amount/type or debit/credit columns.
/// CSV has no implied sign convention: positive amounts need a type column.
List<Json> parseCsv(String text) {
  final rows = _csvRows(text.replaceFirst('\uFEFF', ''));
  if (rows.length < 2) {
    throw const FormatException('The CSV has no transactions.');
  }
  final headers = rows.first
      .map((cell) => cell.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
      .toList();
  int column(List<String> names) => headers.indexWhere(names.contains);
  final dateCol = column(['date', 'transactiondate', 'valuedate']);
  final titleCol = column([
    'description',
    'title',
    'narration',
    'particulars',
    'merchant',
  ]);
  final amountCol = column(['amount', 'transactionamount']);
  final debitCol = column([
    'debit',
    'withdrawal',
    'withdrawals',
    'withdrawalamount',
    'debitamount',
  ]);
  final creditCol = column([
    'credit',
    'deposit',
    'deposits',
    'depositamount',
    'creditamount',
  ]);
  final kindCol = column(['type', 'kind', 'transactiontype', 'drcr']);
  final categoryCol = column(['category']);
  final bankCol = column(['bank', 'bankname']);
  final accountCol = column(['account', 'accountlast4', 'accountnumber']);
  final referenceCol = column([
    'reference',
    'referenceno',
    'utr',
    'rrn',
    'transactionid',
  ]);
  if (dateCol < 0 ||
      titleCol < 0 ||
      (amountCol < 0 && debitCol < 0 && creditCol < 0)) {
    throw const FormatException(
      'Use Date, Description and Debit/Credit columns, or Date, Description, Amount and Type.',
    );
  }
  final output = <Json>[];
  for (var index = 1; index < rows.length; index++) {
    final cells = rows[index];
    String value(int column) =>
        column < 0 || column >= cells.length ? '' : cells[column].trim();
    if (cells.length != headers.length) {
      throw FormatException(
        'CSV row ${index + 1} has missing or extra columns.',
      );
    }
    final date = _date(value(dateCol));
    final title = value(titleCol);
    int? amount;
    String? kind;
    if (debitCol >= 0 || creditCol >= 0) {
      final debit = _paise(value(debitCol));
      final credit = _paise(value(creditCol));
      if (debit != null && credit == null) {
        amount = debit;
        kind = 'debit';
      }
      if (credit != null && debit == null) {
        amount = credit;
        kind = 'credit';
      }
    } else {
      var raw = value(amountCol);
      final type = value(kindCol).toLowerCase();
      kind = switch (type) {
        'debit' || 'dr' || 'expense' || 'withdrawal' => 'debit',
        'credit' || 'cr' || 'income' || 'deposit' => 'credit',
        'refund' || 'reversal' => 'refund',
        'transfer' => 'transfer',
        _ => null,
      };
      // An explicit sign is unambiguous; unsigned values require a type.
      if (kind == null && raw.startsWith('-')) kind = 'debit';
      if (kind == null && raw.startsWith('+')) kind = 'credit';
      raw = raw.replaceFirst(RegExp(r'^[+-]'), '');
      amount = _paise(raw);
    }
    if (date == null || title.isEmpty || amount == null || kind == null) {
      throw FormatException(
        'CSV row ${index + 1} needs a valid date, description, amount and debit/credit type.',
      );
    }
    final account = value(accountCol).replaceAll(RegExp(r'\D'), '');
    final reference = value(referenceCol);
    output.add(
      _row(
        title: title,
        amountPaise: amount,
        date: date,
        kind: kind,
        source: 'Statement',
        bank: value(bankCol).isEmpty ? null : _safeTitle(value(bankCol)),
        category: value(categoryCol).isEmpty
            ? null
            : _safeTitle(value(categoryCol)),
        accountLast4: account.length < 4
            ? null
            : account.substring(account.length - 4),
        reference: RegExp(r'^[A-Za-z0-9-]{6,40}$').hasMatch(reference)
            ? reference
            : null,
      ),
    );
  }
  return output;
}

/// Text PDF layouts vary by bank. Accept only dated rows with an explicit
/// debit/credit marker next to an amount, never a balance or summary amount.
List<Json> parseStatementText(String text) {
  if (text.length > 2 * 1024 * 1024) {
    throw const FormatException(
      'Choose a statement with less than 2 MB of text.',
    );
  }
  if (text.split('\n').first.contains(',')) return parseCsv(text);
  final output = <Json>[];
  final dated = RegExp(
    r'^\s*(\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-](?:\d{4}|\d{2}))\s+(.+)$',
  );
  final amount = RegExp(
    r'(?:INR|Rs\.?|₹)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s+(DR|CR|debit|credit|refund|transfer)\b',
    caseSensitive: false,
  );
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final match = dated.firstMatch(line);
    if (match == null) continue;
    final date = _date(match[1]!);
    final details = match[2]!;
    if (RegExp(
      r'^(?:opening balance|closing balance|balance brought|total)\b',
      caseSensitive: false,
    ).hasMatch(details)) {
      continue;
    }
    final money = amount.firstMatch(details);
    if (date == null || money == null) {
      throw const FormatException(
        'Some dated rows in this statement could not be read reliably. Use a CSV export with Date, Description and Debit/Credit columns.',
      );
    }
    final paise = _paise(money[1]!);
    final title = details.substring(0, money.start).trim();
    if (paise == null || title.isEmpty) {
      throw const FormatException(
        'Some amounts in this statement could not be read reliably. Use a CSV export instead.',
      );
    }
    final type = money[2]!.toLowerCase();
    output.add(
      _row(
        title: title,
        amountPaise: paise,
        date: date,
        kind: switch (type) {
          'dr' || 'debit' => 'debit',
          'refund' => 'refund',
          'transfer' => 'transfer',
          _ => 'credit',
        },
        source: 'Statement',
      ),
    );
    if (output.length > 5000) {
      throw const FormatException(
        'Import at most 5,000 transactions at a time.',
      );
    }
  }
  if (output.isEmpty) {
    throw const FormatException(
      'This statement layout is not supported yet. Export a CSV with Date, Description and Debit/Credit columns.',
    );
  }
  return output;
}
