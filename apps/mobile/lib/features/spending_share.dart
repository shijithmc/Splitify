import 'package:flutter/material.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/spending.dart';
import '../core/spending_sharing.dart';
import 'shared.dart';

Future<void> shareSpendingTransaction(
  BuildContext context,
  AppController c,
  Json transaction, {
  bool linkExisting = false,
}) async {
  final account = c.userId, repository = c.repository;
  if (c.offline) {
    message(context, 'Connect to share or link an expense.');
    return;
  }
  final pending = object(transaction['pendingShare']);
  final groups = c.groups
      .where(
        (g) =>
            (!g.archived || pending.isNotEmpty) &&
            g.participant(account) != null &&
            (pending.isEmpty || pending['groupId'] == g.id),
      )
      .toList();
  if (groups.isEmpty) {
    message(context, 'Create or join an active group from Groups first.');
    return;
  }
  final group = groups.length == 1
      ? groups.first
      : await showModalBottomSheet<Group>(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .7,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  Text(
                    'Choose your group',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  for (final g in groups)
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: Text(g.name),
                      subtitle: Text('${g.count} people'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, g),
                    ),
                ],
              ),
            ),
          ),
        );
  if (group == null ||
      !context.mounted ||
      c.userId != account ||
      !identical(c.repository, repository)) {
    return;
  }
  await openPage<bool>(
    context,
    c,
    _ShareSpendingPage(
      controller: c,
      transactionId: transaction['id'],
      groupId: group.id,
      linkExisting: linkExisting && pending.isEmpty,
    ),
  );
}

class _ShareSpendingPage extends StatefulWidget {
  final AppController controller;
  final String transactionId, groupId;
  final bool linkExisting;
  const _ShareSpendingPage({
    required this.controller,
    required this.transactionId,
    required this.groupId,
    required this.linkExisting,
  });
  @override
  State<_ShareSpendingPage> createState() => _ShareSpendingPageState();
}

class _ShareSpendingPageState extends State<_ShareSpendingPage> {
  final title = TextEditingController();
  late final SpendingController store;
  late final String account;
  late final Object? repository;
  Group? group;
  final participants = <String>{};
  List<Expense> candidates = [];
  Expense? selected;
  String? cursor, error;
  bool loading = true, saving = false, loadingMore = false;
  AppController get c => widget.controller;
  Json? get transaction => store.transactions
      .where((t) => t['id'] == widget.transactionId)
      .firstOrNull;
  bool get current =>
      mounted &&
      c.spendingAvailable &&
      c.userId == account &&
      identical(c.repository, repository);
  bool get pending => object(transaction?['pendingShare']).isNotEmpty;

  @override
  void initState() {
    super.initState();
    store = c.spending;
    account = c.userId;
    repository = c.repository;
    title.text = transaction?['title'] ?? '';
    _load();
  }

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final loaded = Group.from(
        await c.request('GET', '/groups/${widget.groupId}'),
      );
      if (!current) return;
      if ((loaded.archived && !pending) ||
          loaded.participant(account) == null) {
        throw ApiFailure('This group is no longer available for sharing.');
      }
      group = loaded;
      final draft = object(transaction?['pendingShare']);
      if (draft.isNotEmpty) {
        final payload = object(draft['payload']);
        title.text = payload['description'];
        participants.addAll(
          rows(
            payload['participants'],
          ).map((p) => p['participantId'] as String),
        );
      } else {
        participants.addAll(
          loaded.members.where((m) => !m.left && !m.deleted).map((m) => m.id),
        );
      }
      if (widget.linkExisting) await _more();
    } catch (e) {
      if (current) error = '$e';
    } finally {
      if (current) setState(() => loading = false);
    }
  }

  Future<void> _more() async {
    if (loadingMore) return;
    setState(() => loadingMore = true);
    try {
      final suffix = cursor == null
          ? ''
          : '?cursor=${Uri.encodeQueryComponent(cursor!)}';
      final result = await c.request(
        'GET',
        '/groups/${widget.groupId}/expenses$suffix',
      );
      if (!current) return;
      final me = group!.participant(account);
      final used = store.transactions
          .where((t) => t['groupId'] == group!.id)
          .map((t) => t['expenseId'])
          .toSet();
      candidates.addAll(
        rows(result['items'])
            .map(Expense.new)
            .where(
              (e) =>
                  !e.deleted &&
                  e.payer == me &&
                  e.amount == transaction?['amountPaise'] &&
                  !used.contains(e.id),
            ),
      );
      cursor = result['nextCursor'];
    } catch (e) {
      if (current) error = '$e';
    } finally {
      if (current) setState(() => loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, store]),
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    if (!current) {
      return Scaffold(
        appBar: AppBar(title: const Text('Share expense')),
        body: const Center(
          child: Text('Account changed. Open your spending again.'),
        ),
      );
    }
    final row = transaction;
    final g = group;
    Map<String, int>? shares;
    if (g != null && row != null && participants.isNotEmpty) {
      shares = widget.linkExisting
          ? selected?.shares
          : splitAmount(row['amountPaise'], 'Equal', {
              for (final id in participants) id: 1,
            });
    }
    final me = g?.participant(account);
    final own = shares?[me] ?? 0;
    final canSave =
        row != null &&
        g != null &&
        !loading &&
        !saving &&
        (widget.linkExisting
            ? selected != null
            : participants.contains(me) && title.text.trim().isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.linkExisting ? 'Link existing expense' : 'Share expense',
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : row == null
          ? const Center(
              child: Text('This transaction is no longer available.'),
            )
          : PageBody(
              children: [
                Text(
                  widget.linkExisting
                      ? 'One payment. One expense.'
                      : 'A little check before sharing.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                if (g != null)
                  Card(
                    child: ListTile(
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: EditorialArtwork(
                          asset: HisaabArt.forGroup(g.type),
                          height: 48,
                        ),
                      ),
                      title: Text(g.name),
                      subtitle: Text(
                        '${g.members.where((m) => !m.left && !m.deleted).length} people',
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: HisaabColors.lime,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!widget.linkExisting)
                        TextField(
                          controller: title,
                          enabled: !pending && !saving,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Shared title',
                          ),
                          onChanged: (_) => setState(() {}),
                        )
                      else
                        Text(
                          row['title'],
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        money(row['amountPaise']),
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      Text(
                        'Paid by you · ${day(DateTime.parse(row['date']).toLocal())}',
                      ),
                    ],
                  ),
                ),
                if (pending)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'A previous share is waiting for confirmation. Continue to check its result without adding it twice.',
                    ),
                  ),
                if (widget.linkExisting) ...[
                  const SectionTitle('Expenses you paid with this total'),
                  if (candidates.isEmpty && !loadingMore)
                    const Text('No matching expenses on this page.'),
                  for (final e in candidates)
                    Card(
                      child: ListTile(
                        title: Text(e.description),
                        subtitle: Text(
                          '${e.date} · Your share ${money(e.shares[me] ?? 0)}',
                        ),
                        leading: Icon(
                          selected?.id == e.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        selected: selected?.id == e.id,
                        onTap: saving
                            ? null
                            : () => setState(() => selected = e),
                      ),
                    ),
                  if (cursor != null)
                    OutlinedButton(
                      onPressed: loadingMore ? null : _more,
                      child: Text(
                        loadingMore ? 'Loading…' : 'Load more expenses',
                      ),
                    ),
                ] else if (g != null) ...[
                  SectionTitle('Split equally · ${participants.length} people'),
                  Material(
                    color: HisaabColors.mint,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final member in g.members.where(
                          (m) => !m.left && !m.deleted,
                        ))
                          CheckboxListTile(
                            value: participants.contains(member.id),
                            onChanged: saving || pending || member.id == me
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      participants.add(member.id);
                                    } else {
                                      participants.remove(member.id);
                                    }
                                  }),
                            title: Text(member.id == me ? 'You' : member.name),
                            subtitle: Text(money(shares?[member.id] ?? 0)),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                      ],
                    ),
                  ),
                ],
                if (shares != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Your budget counts ${money(own)}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    '${money((row['amountPaise'] as int) - own)} paid for others. This is not available cash until repaid.',
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  widget.linkExisting
                      ? 'Linking changes only your private budget. The existing group expense stays as it is.'
                      : 'Members see the title, amount, date, who paid and the split.',
                ),
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Icon(Icons.lock_outline, size: 18),
                    SizedBox(width: 8),
                    Expanded(child: Text('Your bank details stay private.')),
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(color: HisaabColors.warning),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: canSave ? _save : null,
          child: Text(
            saving
                ? 'Saving…'
                : widget.linkExisting
                ? 'Link expense'
                : pending
                ? 'Confirm pending share'
                : 'Share expense',
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final service = SpendingShareService(c);
      if (widget.linkExisting) {
        await service.link(
          transactionId: widget.transactionId,
          group: group!,
          expenseId: selected!.id,
        );
      } else {
        await service.share(
          transactionId: widget.transactionId,
          group: group!,
          participants: participants,
          description: title.text,
        );
      }
      if (mounted && current) Navigator.pop(context, true);
    } catch (e) {
      if (current) setState(() => error = '$e');
    } finally {
      if (current) setState(() => saving = false);
    }
  }
}
