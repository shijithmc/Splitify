import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'spending_store.dart';

const spendingCategories = <String>[
  'Food & cafés',
  'Groceries',
  'Travel',
  'Shopping',
  'Bills',
  'Health',
  'Other',
];

/// Amount affecting the private budget. A reviewed group link replaces the
/// original debit with the user's share; transfers never consume a budget.
/// A refund reduces spending only by its explicitly reviewed personal portion.
int effectiveSpend(Json transaction) {
  if (transaction['excluded'] == true) return 0;
  final amount = transaction['amountPaise'] as int? ?? 0;
  switch (transaction['kind']) {
    case 'credit' || 'transfer':
      return 0;
    case 'refund':
      return -(transaction['refundBudgetPaise'] as int? ?? 0);
    default:
      return transaction['expenseId'] != null &&
              transaction['linkNeedsReview'] != true
          ? transaction['sharePaise'] as int? ?? amount
          : amount;
  }
}

String _normalized(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
String _merchant(Json transaction) => _normalized(
  (transaction['merchantKey'] as String?) ?? transaction['title'] as String,
);

Json _copy(Json value) => object(jsonDecode(jsonEncode(value)));
dynamic _freeze(dynamic value) => switch (value) {
  Map map => Map<String, dynamic>.unmodifiable(
    map.map((key, item) => MapEntry(key as String, _freeze(item))),
  ),
  List list => List<dynamic>.unmodifiable(list.map(_freeze)),
  _ => value,
};

/// A reference is reliable only alongside its account, amount and direction.
/// Without one, require the exact timestamp and merchant. Nearby equal-value
/// purchases are deliberately kept as distinct transactions.
String spendingIdentity(Json transaction) {
  final account = transaction['accountLast4'] ?? '';
  final bank = _normalized(transaction['bank'] as String? ?? '');
  final reference = transaction['reference'] as String?;
  final amount = transaction['amountPaise'];
  final kind = transaction['kind'];
  if (reference != null && reference.trim().isNotEmpty) {
    return 'ref|$bank|$account|${_normalized(reference)}|$amount|$kind';
  }
  return 'exact|$bank|$account|${transaction['date']}|${_merchant(transaction)}|$amount|$kind';
}

class SpendingController extends ChangeNotifier {
  final String account;
  final bool demo;
  final DateTime Function() _clock;
  final SpendingStore? _store;
  List<Json> _transactions = [];
  Map<String, int> _budgets = {};
  Map<String, String> _merchantRules = {};
  int? _payday;
  DateTime? _lastImport;
  bool loaded = false, loading = false;
  String? error;
  bool _ended = false, _disposed = false;
  Future<void>? _initializing;
  Future<void> _mutations = Future.value();

  SpendingController({
    required this.account,
    this.demo = false,
    DateTime Function()? clock,
    SpendingStore? store,
  }) : _clock = clock ?? DateTime.now,
       _store = store ?? (demo ? null : SpendingStore(account)) {
    if (account.trim().isEmpty) throw ArgumentError('Account is required');
    if (store != null && store.account != account) {
      throw ArgumentError('Spending store belongs to another account');
    }
  }

  List<String> get categories => spendingCategories;
  List<Json> get transactions => List.unmodifiable(
    _transactions.map((transaction) => _freeze(transaction) as Json),
  );
  Map<String, int> get budgets => Map.unmodifiable(_budgets);
  int? get payday => _payday;
  DateTime? get lastImport => _lastImport;

  bool _thisMonth(Json transaction) {
    final date = DateTime.parse(transaction['date'] as String).toLocal();
    final now = _clock().toLocal();
    return date.year == now.year && date.month == now.month;
  }

  int get spendingPaise => _transactions
      .where(_thisMonth)
      .fold(0, (sum, transaction) => sum + effectiveSpend(transaction));
  int spentFor(String category) => _transactions
      .where(
        (transaction) =>
            transaction['category'] == category && _thisMonth(transaction),
      )
      .fold(0, (sum, transaction) => sum + effectiveSpend(transaction));
  int get budgetPaise => _budgets.values.fold(0, (sum, value) => sum + value);
  int get remainingPaise => budgetPaise - spendingPaise;

  int? get daysToPayday {
    final day = _payday;
    if (day == null) return null;
    final now = _clock().toLocal();
    final today = DateTime.utc(now.year, now.month, now.day);
    DateTime paydayIn(int year, int month) => DateTime.utc(
      year,
      month,
      math.min(day, DateTime.utc(year, month + 1, 0).day),
    );
    var next = paydayIn(now.year, now.month);
    if (!next.isAfter(today)) next = paydayIn(now.year, now.month + 1);
    return next.difference(today).inDays;
  }

  int? get dailyPaise {
    final days = daysToPayday;
    if (days == null || budgetPaise <= 0) return null;
    return math.max(0, remainingPaise) ~/ math.max(1, days);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkActive() {
    if (_ended || _disposed) {
      throw StateError('Personal spending session ended');
    }
  }

  Future<void> initialize() {
    _checkActive();
    if (loaded) return Future.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    loading = true;
    error = null;
    _notify();
    try {
      final value = await _store?.load();
      _checkActive();
      if (value != null) {
        if (value['version'] != 1) {
          throw const FormatException('Unknown ledger version');
        }
        final transactions = rows(
          value['transactions'],
        ).map(_validate).toList();
        final budgets = <String, int>{};
        for (final entry in object(value['budgets']).entries) {
          _validateBudget(entry.key, entry.value);
          budgets[entry.key] = entry.value as int;
        }
        final rules = <String, String>{};
        for (final entry in object(value['merchantRules']).entries) {
          if (entry.key.isEmpty ||
              entry.value is! String ||
              !categories.contains(entry.value)) {
            throw const FormatException('Invalid merchant rule');
          }
          rules[entry.key] = entry.value as String;
        }
        final payday = value['payday'];
        if (payday != null) _validatePayday(payday);
        final imported = value['lastImport'];
        final lastImport = imported == null
            ? null
            : DateTime.parse(imported as String);
        _transactions = transactions;
        _budgets = budgets;
        _merchantRules = rules;
        _payday = payday as int?;
        _lastImport = lastImport;
      } else if (demo) {
        _seedDemo();
      }
      _sort();
      loaded = true;
    } catch (_) {
      if (!_ended) error = 'Could not open your private spending. Try again.';
    } finally {
      loading = false;
      _initializing = null;
      _notify();
    }
  }

  Json _validate(Json input) {
    final id = input['id'] ?? const Uuid().v4();
    final title = input['title'];
    final amount = input['amountPaise'];
    final category = input['category'] ?? 'Other';
    final kind = input['kind'] ?? 'debit';
    final source = input['source'] ?? 'Manual';
    final date = input['date'] is String
        ? DateTime.tryParse(input['date'] as String)
        : null;
    if (id is! String ||
        id.isEmpty ||
        id.length > 120 ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 240 ||
        amount is! int ||
        amount <= 0 ||
        amount > 1000000000 ||
        !categories.contains(category) ||
        !const ['debit', 'credit', 'refund', 'transfer'].contains(kind) ||
        !const [
          'SMS',
          'Statement',
          'Cash',
          'Manual',
          'Demo',
        ].contains(source) ||
        date == null ||
        date.year < 2000 ||
        date.year > 2100 ||
        (input['excluded'] != null && input['excluded'] is! bool)) {
      throw const FormatException(
        'Check the transaction name, amount, date and category.',
      );
    }
    final result = <String, dynamic>{
      'id': id,
      'title': title.trim(),
      'amountPaise': amount,
      'date': date.toUtc().toIso8601String(),
      'category': category,
      'kind': kind,
      'source': source,
      'excluded': input['excluded'] ?? false,
    };
    final refundBudget = input['refundBudgetPaise'];
    if (refundBudget != null) {
      if (kind != 'refund' ||
          refundBudget is! int ||
          refundBudget < 0 ||
          refundBudget > amount) {
        throw const FormatException(
          'Your refund portion must be between zero and the refunded amount.',
        );
      }
      result['refundBudgetPaise'] = refundBudget;
    }
    // An explicit allowlist prevents raw message bodies or arbitrary import
    // payloads being retained in the encrypted ledger or CSV export.
    for (final key in [
      'merchantKey',
      'accountLast4',
      'bank',
      'reference',
      'groupId',
      'expenseId',
    ]) {
      final value = input[key];
      if (value == null) continue;
      if (value is! String || value.trim().isEmpty || value.length > 240) {
        throw FormatException('Invalid $key.');
      }
      result[key] = value.trim();
    }
    if (result['accountLast4'] != null &&
        !RegExp(r'^\d{4}$').hasMatch(result['accountLast4'] as String)) {
      throw const FormatException(
        'Account must use its last four digits only.',
      );
    }
    final share = input['sharePaise'];
    if (input['linkNeedsReview'] != null && input['linkNeedsReview'] is! bool) {
      throw const FormatException('Invalid linked expense review state.');
    }
    if (share != null ||
        result['groupId'] != null ||
        result['expenseId'] != null) {
      if (share is! int ||
          share < 0 ||
          share > amount ||
          result['groupId'] == null ||
          result['expenseId'] == null ||
          kind != 'debit') {
        throw const FormatException(
          'A group link needs the group, expense and your share.',
        );
      }
      result['sharePaise'] = share;
      result['linkNeedsReview'] = input['linkNeedsReview'] ?? false;
    }
    final pending = input['pendingShare'];
    if (pending != null) {
      if (kind != 'debit' || result['expenseId'] != null || pending is! Map) {
        throw const FormatException('Invalid pending group expense.');
      }
      final draft = object(pending);
      final payload = object(draft['payload']);
      bool validId(dynamic value) =>
          value is String && RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(value);
      final description = payload['description'];
      final participants = rows(payload['participants']);
      final ids = participants.map((row) => row['participantId']).toSet();
      final expenseDate = payload['date'];
      if (!validId(draft['groupId']) ||
          !validId(draft['expenseId']) ||
          payload['id'] != draft['expenseId'] ||
          payload['amountPaise'] != amount ||
          payload['mode'] != 'Equal' ||
          description is! String ||
          description.trim().isEmpty ||
          description.runes.length > 100 ||
          !validId(payload['payerId']) ||
          expenseDate is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(expenseDate) ||
          DateTime.tryParse(expenseDate) == null ||
          participants.isEmpty ||
          participants.length > 100 ||
          ids.length != participants.length ||
          !ids.contains(payload['payerId']) ||
          participants.any(
            (row) => !validId(row['participantId']) || row['value'] != 1,
          )) {
        throw const FormatException('Invalid pending group expense.');
      }
      result['pendingShare'] = {
        'groupId': draft['groupId'],
        'expenseId': draft['expenseId'],
        'payload': {
          'id': payload['id'],
          'description': description,
          'amountPaise': amount,
          'date': expenseDate,
          'payerId': payload['payerId'],
          'mode': 'Equal',
          'participants': [
            for (final participant in participants)
              {'participantId': participant['participantId'], 'value': 1},
          ],
        },
      };
    }
    return result;
  }

  void _validateBudget(String category, dynamic amount) {
    if (!categories.contains(category) ||
        amount is! int ||
        amount < 0 ||
        amount > 1000000000) {
      throw const FormatException('Enter a valid category budget.');
    }
  }

  void _validatePayday(dynamic day) {
    if (day is! int || day < 1 || day > 31) {
      throw const FormatException('Payday must be between 1 and 31.');
    }
  }

  Json _snapshot() => {
    'version': 1,
    'transactions': _transactions,
    'budgets': _budgets,
    'merchantRules': _merchantRules,
    'payday': _payday,
    'lastImport': _lastImport?.toUtc().toIso8601String(),
  };

  void _sort() => _transactions.sort(
    (a, b) => (b['date'] as String).compareTo(a['date'] as String),
  );

  Future<T> _mutate<T>(T Function() change) {
    _checkActive();
    final result = _mutations.then((_) async {
      await initialize();
      _checkActive();
      if (!loaded) throw StateError('Private spending could not be loaded');
      final oldTransactions = _transactions.map(_copy).toList();
      final oldBudgets = Map<String, int>.from(_budgets);
      final oldRules = Map<String, String>.from(_merchantRules);
      final oldPayday = _payday, oldImport = _lastImport;
      try {
        final value = change();
        _sort();
        await _store?.save(_snapshot());
        _checkActive();
        error = null;
        _notify();
        return value;
      } catch (_) {
        if (!_ended) {
          _transactions = oldTransactions;
          _budgets = oldBudgets;
          _merchantRules = oldRules;
          _payday = oldPayday;
          _lastImport = oldImport;
          error =
              'Could not save your spending. Check the details and try again.';
          _notify();
        }
        rethrow;
      }
    });
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> add(Json input) {
    final frozen = _copy(input);
    return _mutate(() {
      final transaction = _validate(frozen);
      if (_transactions.any((row) => row['id'] == transaction['id'])) {
        throw const FormatException('This transaction already exists.');
      }
      final rule = _merchantRules[_merchant(transaction)];
      if (rule != null) transaction['category'] = rule;
      _transactions.add(transaction);
    });
  }

  Future<void> update(String id, Json patch) {
    final frozen = _copy(patch);
    return _mutate(() {
      final index = _transactions.indexWhere(
        (transaction) => transaction['id'] == id,
      );
      if (index < 0) {
        throw const FormatException('Transaction no longer exists.');
      }
      final before = _transactions[index];
      final updated = _validate({...before, ...frozen, 'id': id});
      if (before['expenseId'] != null || before['pendingShare'] != null) {
        for (final key in [
          'amountPaise',
          'kind',
          'date',
          'accountLast4',
          'reference',
        ]) {
          if (updated[key] != before[key]) {
            throw const FormatException(
              'A linked or pending payment cannot change its financial details.',
            );
          }
        }
      }
      if (before['pendingShare'] != null) {
        final pending = object(before['pendingShare']);
        if (updated['pendingShare'] == null &&
            (updated['groupId'] != pending['groupId'] ||
                updated['expenseId'] != pending['expenseId'])) {
          throw const FormatException(
            'Finish the pending group expense before changing its link.',
          );
        }
        if (updated['pendingShare'] != null &&
            jsonEncode(updated['pendingShare']) != jsonEncode(pending)) {
          throw const FormatException(
            'Finish the original pending group expense first.',
          );
        }
      }
      if (updated['category'] != before['category']) {
        _merchantRules[_merchant(updated)] = updated['category'] as String;
      }
      _transactions[index] = updated;
    });
  }

  Future<void> remove(String id) => _mutate(() {
    if (_transactions.any(
      (row) => row['id'] == id && row['pendingShare'] != null,
    )) {
      throw const FormatException(
        'Finish the pending group expense before deleting this payment.',
      );
    }
    _transactions.removeWhere((transaction) => transaction['id'] == id);
  });

  Future<int> importRows(List<Json> input) {
    final frozen = input.map(_copy).toList();
    return _mutate(() {
      final incoming = frozen.map(_validate).toList();
      final identities = _transactions.map(spendingIdentity).toSet();
      final ids = _transactions.map((row) => row['id']).toSet();
      var imported = 0;
      for (final transaction in incoming) {
        if (!identities.add(spendingIdentity(transaction))) continue;
        if (!ids.add(transaction['id'])) transaction['id'] = const Uuid().v4();
        final rule = _merchantRules[_merchant(transaction)];
        if (rule != null) transaction['category'] = rule;
        _transactions.add(transaction);
        imported++;
      }
      if (imported > 0) _lastImport = _clock();
      return imported;
    });
  }

  Future<void> setBudget(String category, int amount) => _mutate(() {
    _validateBudget(category, amount);
    if (amount == 0) {
      _budgets.remove(category);
    } else {
      _budgets[category] = amount;
    }
  });

  Future<void> setPayday(int day) => _mutate(() {
    _validatePayday(day);
    _payday = day;
  });

  /// Release a draft only after the share service has received an explicit
  /// validation rejection proving its new POST did not create an expense.
  /// Timeouts and failed lookups are not proof that a share was unsubmitted.
  Future<void> discardUnsubmittedShare(String id) => _mutate(() {
    final row = _transactions.where((row) => row['id'] == id).firstOrNull;
    if (row == null) {
      throw const FormatException('Transaction no longer exists.');
    }
    row.remove('pendingShare');
  });

  /// Explicit private-data deletion may discard uncertain drafts. Callers must
  /// explain that group expenses already created remain in their groups.
  Future<void> clear({bool discardPending = false}) => _mutate(() {
    if (!discardPending &&
        _transactions.any((row) => row['pendingShare'] != null)) {
      throw const FormatException(
        'Finish pending group expenses before clearing private spending.',
      );
    }
    _transactions.clear();
    _budgets.clear();
    _merchantRules.clear();
    _payday = null;
    _lastImport = null;
  });

  String exportCsv() {
    _checkActive();
    String cell(dynamic value) {
      var text = value?.toString() ?? '';
      if (RegExp(r'^[\s\u0000-\u001f]*[=+@-]').hasMatch(text) ||
          text.startsWith('\t') ||
          text.startsWith('\r') ||
          text.startsWith('\n')) {
        text = "'$text";
      }
      return '"${text.replaceAll('"', '""')}"';
    }

    final lines = <List<dynamic>>[
      [
        'Date',
        'Title',
        'Amount (INR)',
        'Kind',
        'Category',
        'Source',
        'Account last 4',
        'Excluded',
        'Group',
        'Expense',
        'Your share (INR)',
        'Personal refund (INR)',
      ],
      for (final transaction in _transactions)
        [
          transaction['date'],
          transaction['title'],
          ((transaction['amountPaise'] as int) / 100).toStringAsFixed(2),
          transaction['kind'],
          transaction['category'],
          transaction['source'],
          transaction['accountLast4'],
          transaction['excluded'],
          transaction['groupId'],
          transaction['expenseId'],
          transaction['sharePaise'] == null
              ? ''
              : ((transaction['sharePaise'] as int) / 100).toStringAsFixed(2),
          transaction['refundBudgetPaise'] == null
              ? ''
              : ((transaction['refundBudgetPaise'] as int) / 100)
                    .toStringAsFixed(2),
        ],
    ];
    return '${lines.map((line) => line.map(cell).join(',')).join('\r\n')}\r\n';
  }

  Future<void> endSession({bool delete = false}) async {
    _ended = true;
    _transactions = [];
    _budgets = {};
    _merchantRules = {};
    _payday = null;
    _lastImport = null;
    loaded = false;
    loading = false;
    error = null;
    _notify();
    await _store?.close(delete: delete);
    await _mutations;
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_ended) unawaited(endSession());
    super.dispose();
  }

  void _seedDemo() {
    final now = _clock();
    Json sample(
      String id,
      String title,
      int amount,
      String category,
      int days,
    ) => _validate({
      'id': id,
      'title': title,
      'amountPaise': amount,
      'date': DateTime(
        now.year,
        now.month,
        math.max(1, now.day - days),
        12,
      ).toIso8601String(),
      'category': category,
      'source': 'Demo',
    });
    _transactions = [
      sample('demo-lunch', 'Beachside lunch', 126000, 'Food & cafés', 0),
      sample('demo-food', 'Cafés & takeaways', 294000, 'Food & cafés', 2),
      sample('demo-groceries', 'Everyday essentials', 260000, 'Groceries', 3),
      sample('demo-travel', 'Getting around', 80000, 'Travel', 4),
    ];
    _budgets = {'Food & cafés': 500000, 'Groceries': 500000, 'Travel': 400000};
    _payday = 1;
    _lastImport = now;
  }
}
