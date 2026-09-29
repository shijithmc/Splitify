import 'package:uuid/uuid.dart';
import 'controller.dart';
import 'models.dart';
import 'money.dart';

/// Only the explicitly reviewed ledger fields cross the private/group boundary.
Json spendingExpensePayload({
  required Json transaction,
  required String expenseId,
  required String payerId,
  required Set<String> participants,
  required String description,
}) {
  if (description.trim().isEmpty || description.trim().runes.length > 100) {
    throw const FormatException('Use a title between 1 and 100 characters.');
  }
  final ordered = participants.toList()..sort();
  splitAmount(transaction['amountPaise'], 'Equal', {
    for (final id in ordered) id: 1,
  });
  return {
    'id': expenseId,
    'description': description.trim(),
    'amountPaise': transaction['amountPaise'],
    'date': day(DateTime.parse(transaction['date']).toLocal()),
    'payerId': payerId,
    'mode': 'Equal',
    'participants': [
      for (final id in ordered) {'participantId': id, 'value': 1},
    ],
  };
}

class SpendingShareService {
  final AppController controller;
  SpendingShareService(this.controller);
  static final _inflight = Expando<Set<String>>();

  Future<T> _exclusive<T>(String id, Future<T> Function() action) async {
    final active = _inflight[controller.spending] ??= <String>{};
    if (active.isNotEmpty) {
      throw ApiFailure('This payment is already being shared.');
    }
    active.add(id);
    try {
      return await action();
    } finally {
      active.remove(id);
    }
  }

  Future<Json> share({
    required String transactionId,
    required Group group,
    required Set<String> participants,
    required String description,
  }) => _exclusive(
    transactionId,
    () => _share(
      transactionId: transactionId,
      group: group,
      participants: participants,
      description: description,
    ),
  );

  Future<Json> _share({
    required String transactionId,
    required Group group,
    required Set<String> participants,
    required String description,
  }) async {
    final c = controller;
    final account = c.userId, repository = c.repository, store = c.spending;
    void current() {
      if (!c.spendingAvailable ||
          c.userId != account ||
          !identical(c.repository, repository) ||
          !identical(c.spending, store)) {
        throw ApiFailure('Account changed. Open your spending again.');
      }
    }

    current();
    if (c.offline) throw ApiFailure('Connect to share this expense.');
    final row = store.transactions
        .where((t) => t['id'] == transactionId)
        .firstOrNull;
    if (row == null) {
      throw ApiFailure('This transaction is no longer available.');
    }
    if (row['expenseId'] != null) {
      throw ApiFailure('This payment is already linked.');
    }
    if (row['kind'] != 'debit' || row['excluded'] == true) {
      throw ApiFailure('Only an included purchase can be shared.');
    }
    final me = group.participant(account);
    final pending = object(row['pendingShare']);
    final validMembers =
        me != null &&
        !group.archived &&
        participants.contains(me) &&
        !participants.any(
          (id) =>
              !group.members.any((m) => m.id == id && !m.left && !m.deleted),
        );
    if (me == null || (pending.isEmpty && !validMembers)) {
      throw ApiFailure(
        'Choose yourself and current members of an active group.',
      );
    }
    final payload = pending.isEmpty
        ? spendingExpensePayload(
            transaction: row,
            expenseId: const Uuid().v4(),
            payerId: me,
            participants: participants,
            description: description,
          )
        : object(pending['payload']);
    if (pending.isNotEmpty && pending['groupId'] != group.id) {
      throw ApiFailure('Finish the pending share in its original group first.');
    }
    if (pending.isEmpty) {
      await store.update(transactionId, {
        'pendingShare': {
          'groupId': group.id,
          'expenseId': payload['id'],
          'payload': payload,
        },
      });
    }
    current();
    // A durable UUID lets us recover a lost HTTP response or process restart.
    // No second expense is created when the first response was uncertain.
    Json? saved;
    try {
      saved = await c.request(
        'GET',
        '/groups/${group.id}/expenses/${payload['id']}',
      );
    } on ApiFailure catch (e) {
      if (e.status != 404) rethrow;
    }
    current();
    if (saved == null) {
      if (!validMembers) {
        throw ApiFailure(
          'Group members changed. Review the pending expense before sharing.',
        );
      }
      try {
        saved = await c.request(
          'POST',
          '/groups/${group.id}/expenses',
          payload,
        );
      } on ApiFailure catch (e) {
        current();
        if (pending.isEmpty && (e.status == 400 || e.status == 422)) {
          // An explicit validation rejection is different from an uncertain
          // timeout. Only the former proves this command was not committed.
          await store.discardUnsubmittedShare(transactionId);
          rethrow;
        }
        if (e.status != 409 || e.code != 'expense_exists') rethrow;
        saved = await c.request(
          'GET',
          '/groups/${group.id}/expenses/${payload['id']}',
        );
      }
    }
    current();
    final expense = Expense(saved);
    if (expense.json['createdBy'] != account) {
      throw ApiFailure(
        'The saved expense changed. Review it in the group before linking.',
      );
    }
    await store.update(transactionId, {
      'groupId': group.id,
      'expenseId': expense.id,
      'sharePaise':
          expense.deleted ||
              expense.payer != me ||
              expense.amount != row['amountPaise']
          ? 0
          : expense.shares[me] ?? 0,
      'linkNeedsReview':
          expense.deleted ||
          expense.payer != me ||
          expense.amount != row['amountPaise'],
      'pendingShare': null,
    });
    current();
    await c.refresh();
    return saved;
  }

  Future<void> link({
    required String transactionId,
    required Group group,
    required String expenseId,
  }) => _exclusive(
    transactionId,
    () =>
        _link(transactionId: transactionId, group: group, expenseId: expenseId),
  );

  Future<void> _link({
    required String transactionId,
    required Group group,
    required String expenseId,
  }) async {
    final c = controller;
    final account = c.userId, repository = c.repository, store = c.spending;
    final row = store.transactions
        .where((t) => t['id'] == transactionId)
        .firstOrNull;
    if (row == null ||
        row['expenseId'] != null ||
        row['pendingShare'] != null) {
      throw ApiFailure(
        'This payment is already linked or has a pending share.',
      );
    }
    if (row['kind'] != 'debit' || row['excluded'] == true) {
      throw ApiFailure('Only an included purchase can be linked.');
    }
    if (store.transactions.any(
      (t) => t['groupId'] == group.id && t['expenseId'] == expenseId,
    )) {
      throw ApiFailure('Another payment is already linked to this expense.');
    }
    final expense = Expense(
      await c.request('GET', '/groups/${group.id}/expenses/$expenseId'),
    );
    if (!c.spendingAvailable ||
        c.userId != account ||
        !identical(repository, c.repository) ||
        !identical(store, c.spending)) {
      throw ApiFailure('Account changed.');
    }
    final me = group.participant(account);
    if (me == null ||
        expense.deleted ||
        expense.payer != me ||
        expense.amount != row['amountPaise']) {
      throw ApiFailure('Choose an expense you paid with the same total.');
    }
    await store.update(transactionId, {
      'groupId': group.id,
      'expenseId': expense.id,
      'sharePaise': expense.shares[me] ?? 0,
    });
  }
}
