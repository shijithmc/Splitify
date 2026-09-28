import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../main.dart';
import 'expense.dart';
import 'shared.dart';
import 'receipts.dart';
import 'receipt_viewer.dart';

class GroupPage extends StatefulWidget {
  final AppController controller;
  final String groupId;
  final bool addOnOpen;
  const GroupPage({
    super.key,
    required this.controller,
    required this.groupId,
    this.addOnOpen = false,
  });
  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> with WidgetsBindingObserver {
  AppController get c => widget.controller;
  Group? group;
  List<Expense> expenses = [];
  List<Json> settlements = [];
  String? cursor, error;
  bool loading = true, fetching = false, more = false, active = true;
  int section = 0;
  Timer? poll;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load().then((_) {
      if (widget.addOnOpen && mounted && group != null) editExpense();
    });
    poll = Timer.periodic(const Duration(seconds: 1), (_) {
      if (active && !c.demo && ModalRoute.of(context)?.isCurrent == true) {
        load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) load();
  }

  Future<void> load({bool silent = false}) async {
    if (fetching) return;
    fetching = true;
    try {
      final values = await Future.wait([
        c.request('GET', '/groups/${widget.groupId}'),
        c.request('GET', '/groups/${widget.groupId}/expenses'),
        c.request('GET', '/groups/${widget.groupId}/settlements'),
      ]);
      if (!mounted) return;
      setState(() {
        group = Group.from(values[0]);
        final first = rows(values[1]['items']).map(Expense.new).toList();
        if (more) {
          final ids = first.map((e) => e.id).toSet();
          expenses = [...first, ...expenses.where((e) => !ids.contains(e.id))];
        } else {
          expenses = first;
          cursor = values[1]['nextCursor'];
        }
        settlements = rows(values[2]['items']);
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiFailure && [403, 404].contains(e.status)) {
            group = null;
            expenses = [];
            settlements = [];
          }
          loading = false;
        });
      }
    } finally {
      fetching = false;
    }
  }

  Future<void> loadMore() async {
    if (cursor == null) return;
    await act(context, () async {
      final data = await c.request(
        'GET',
        '/groups/${widget.groupId}/expenses?cursor=${Uri.encodeQueryComponent(cursor!)}',
      );
      if (mounted) {
        setState(() {
          expenses.addAll(rows(data['items']).map(Expense.new));
          cursor = data['nextCursor'];
          more = true;
        });
      }
    });
  }

  Future<void> editExpense([Expense? expense]) async {
    if (expense?.receiptId != null) {
      await openPage(
        context,
        c,
        ReceiptViewerPage(
          controller: c,
          group: group!,
          receiptId: expense!.receiptId!,
          expense: expense,
          editOnOpen: true,
        ),
      );
      await load();
      await c.refresh();
      return;
    }
    await openPage(
      context,
      c,
      ExpensePage(controller: c, group: group!, expense: expense),
    );
    await load();
    await c.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(group?.name ?? 'Your circle'),
        actions: [
          if (group != null)
            PopupMenuButton<String>(
              tooltip: 'Group options',
              onSelected: options,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('Rename group'),
                ),
                PopupMenuItem(
                  value: 'archive',
                  child: Text(
                    group!.archived ? 'Reopen group' : 'Archive group',
                  ),
                ),
                const PopupMenuItem(value: 'leave', child: Text('Leave group')),
                if (group!.creatorId == c.userId)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete group'),
                  ),
              ],
            ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : group == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error ?? 'Group unavailable'),
                  TextButton(onPressed: load, child: const Text('Retry')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: load,
              child: PageBody(
                children: [
                  if (c.demo)
                    const Text(
                      'DEMO · local data only',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (c.offline)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Offline · saved data is read-only',
                        style: TextStyle(color: clay),
                      ),
                    ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: clay)),
                  const SizedBox(height: 12),
                  _summary(),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!group!.archived)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await openPage(
                              context,
                              c,
                              ReceiptCapturePage(controller: c, group: group!),
                            );
                            await load();
                            await c.refresh();
                          },
                          icon: const Icon(Icons.attach_file_rounded, size: 18),
                          label: const Text('Attach receipt'),
                        ),
                      OutlinedButton.icon(
                        onPressed: group!.archived || c.offline
                            ? null
                            : addMember,
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('Add person'),
                      ),
                      OutlinedButton.icon(
                        onPressed: group!.archived || c.offline ? null : invite,
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('Invite'),
                      ),
                      if (!group!.archived)
                        OutlinedButton.icon(
                          onPressed: c.offline ? null : () => openSettlement(),
                          icon: const Icon(
                            Icons.check_circle_outline,
                            size: 18,
                          ),
                          label: const Text('Settle up'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (index, label) in [
                        'Expenses',
                        'Balances',
                        'Payments',
                      ].indexed)
                        ChoiceChip(
                          label: Text(label),
                          selected: section == index,
                          onSelected: (_) => setState(() => section = index),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  ...switch (section) {
                    0 => _expenseList(),
                    1 => _balanceList(),
                    _ => _paymentList(),
                  },
                  const SizedBox(height: 90),
                ],
              ),
            ),
      floatingActionButton: group == null || group!.archived
          ? null
          : FloatingActionButton.extended(
              onPressed: c.offline ? null : () => editExpense(),
              icon: const Icon(Icons.add),
              label: const Text('Add expense'),
            ),
    ),
  );
  Widget _summary() {
    final g = group!;
    final me = g.participant(c.userId);
    final net = me == null ? 0 : g.netFor(me);
    final type = g.type == 'Direct' ? 'With a friend' : g.type;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: HisaabColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EditorialArtwork(
            asset: g.type == 'Home'
                ? 'assets/illustrations/shared-home.png'
                : 'assets/illustrations/moments.png',
            height: 148,
            borderRadius: BorderRadius.zero,
            fit: BoxFit.cover,
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.name, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  '$type · ${g.members.length} people${g.archived ? ' · Archived' : ''}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: HisaabColors.muted,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: net < 0 ? HisaabColors.peach : HisaabColors.mint,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        net == 0
                            ? 'All settled up'
                            : net > 0
                            ? 'You get back'
                            : 'You owe',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: HisaabColors.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        money(net.abs()),
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.w600,
                          fontSize: 38,
                          color: HisaabColors.ink,
                          letterSpacing: -1,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  g.archived
                      ? 'History stays here. Reopen the group to add expenses.'
                      : 'Good times. Shared fairly. Everyone has the same record.',
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: HisaabColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _expenseList() => [
    if (expenses.isEmpty)
      const EmptyCard(
        icon: Icons.receipt_long_outlined,
        title: 'Your first shared moment',
        body: 'Add an expense and choose how to split it.',
      ),
    ...expenses.map(
      (e) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          leading: e.receiptId != null && !e.deleted
              ? ReceiptThumbnail(controller: c, receiptId: e.receiptId!)
              : CircleAvatar(
                  backgroundColor: e.deleted
                      ? HisaabColors.surface
                      : HisaabColors.peach,
                  child: Icon(
                    e.deleted
                        ? Icons.delete_outline
                        : Icons.receipt_long_outlined,
                    color: HisaabColors.teal,
                  ),
                ),
          title: Text(
            e.description,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: e.deleted ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${group!.memberName(e.payer)} paid · ${e.date}${e.deleted ? '\nDeleted · tap to restore' : ''}',
            style: const TextStyle(fontSize: 14),
          ),
          trailing: Text(
            money(e.amount),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          onTap: () => expenseDetails(e),
        ),
      ),
    ),
    if (cursor != null)
      TextButton(onPressed: loadMore, child: const Text('Load older expenses')),
  ];
  List<Widget> _balanceList() => [
    ...group!.members.map((m) {
      final net = group!.netFor(m.id);
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ExpansionTile(
          shape: const Border(),
          leading: CircleAvatar(
            backgroundColor: net < 0 ? HisaabColors.peach : HisaabColors.mint,
            foregroundColor: HisaabColors.ink,
            child: Text(
              m.name.isEmpty ? '?' : m.name.characters.first.toUpperCase(),
            ),
          ),
          title: Text(
            m.userId == c.userId ? 'You' : m.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(
                net == 0
                    ? 'Settled'
                    : net > 0
                    ? 'is owed ${money(net)}'
                    : 'owes ${money(-net)}',
                style: TextStyle(
                  color: net < 0 ? HisaabColors.warning : HisaabColors.positive,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (m.external || m.placeholder || m.left)
                Text(
                  [
                    if (m.external)
                      'External'
                    else if (m.placeholder)
                      'Not joined yet',
                    if (m.left) 'Left',
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 14,
                    color: HisaabColors.muted,
                  ),
                ),
            ],
          ),
          children: [
            ...group!
                .pairs(m.id)
                .entries
                .where((p) => p.value != 0)
                .map(
                  (p) => ListTile(
                    dense: true,
                    title: Text(
                      p.value > 0
                          ? '${group!.memberName(p.key)} owes ${money(p.value)}'
                          : 'Owes ${group!.memberName(p.key)} ${money(-p.value)}',
                    ),
                  ),
                ),
            if (m.externalReviewDue &&
                group!.creatorId == c.userId &&
                !group!.archived)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    const Text(
                      'This person has not joined for 90 days. Keep their history and mark them as external if they will not use Hisaab.',
                      style: TextStyle(fontSize: 14),
                    ),
                    TextButton(
                      onPressed: c.offline
                          ? null
                          : () => act(context, () async {
                              await c.request(
                                'POST',
                                '/groups/${group!.id}/members/${m.id}/external',
                                {'version': group!.version},
                              );
                              await load();
                              await c.refresh();
                            }),
                      child: const Text('Mark as external'),
                    ),
                  ],
                ),
              ),
            if (m.placeholder && !group!.archived)
              TextButton(
                onPressed: () => invite(m.id),
                child: const Text('Invite to claim this balance'),
              ),
          ],
        ),
      );
    }),
  ];
  List<Widget> _paymentList() => [
    if (settlements.isEmpty)
      const EmptyCard(
        icon: Icons.handshake_outlined,
        title: 'No payments recorded',
        body: 'Paid them back? Record the amount and method here.',
      ),
    ...settlements.map(
      (p) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          isThreeLine: true,
          leading: Icon(
            p['disputed'] == true ? Icons.undo : Icons.check_circle_outline,
            color: p['disputed'] == true ? clay : green,
          ),
          title: Text(
            '${group!.memberName(p['fromId'])} → ${group!.memberName(p['toId'])}',
          ),
          subtitle: Text(
            '${money(p['amountPaise'])} · ${p['method']}\n${p['disputed'] == true ? 'Disputed · balance reversed' : 'Payment recorded'}',
          ),
          trailing:
              p['disputed'] != true && p['toId'] == group!.participant(c.userId)
              ? IconButton(
                  tooltip: 'Dispute payment',
                  onPressed: c.offline || group!.archived
                      ? null
                      : () async {
                          if (await confirm(
                            context,
                            'Dispute this payment?',
                            'This reverses the recorded payment once. Both people keep the history.',
                            action: 'Dispute',
                          )) {
                            if (!mounted) return;
                            await act(context, () async {
                              await c.request(
                                'POST',
                                '/groups/${group!.id}/settlements/${p['id']}/dispute',
                                {'version': p['version']},
                              );
                              await load();
                              await c.refresh();
                            });
                          }
                        },
                  icon: const Icon(Icons.report_outlined),
                )
              : null,
        ),
      ),
    ),
  ];
  Future<void> addMember() async {
    final name = TextEditingController(),
        email = TextEditingController(),
        phone = TextEditingController();
    final member = await showDialog<Json>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add someone'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'A name is enough to start. A verified email or a private invitation link lets them claim their shared history. Phone numbers alone never grant access.',
                style: TextStyle(fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(context, {
                'displayName': name.text.trim(),
                if (email.text.trim().isNotEmpty) 'email': email.text.trim(),
                if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
              });
            },
            child: const Text('Add person'),
          ),
        ],
      ),
    );
    if (member == null || !mounted) return;
    await act(context, () async {
      await c.request('POST', '/groups/${group!.id}/members', member);
      await load();
      await c.refresh();
    });
  }

  Future<void> invite([String? participantId]) async {
    await act(context, () async {
      final invite = await c.request('POST', '/groups/${group!.id}/invites', {
        'participantId': ?participantId,
      });
      if (!mounted) return;
      final link = invite['url'] as String;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('An invitation to your circle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Only share this private link with the person you want to invite.',
              ),
              const SizedBox(height: 16),
              SelectableText(link),
              const SizedBox(height: 12),
              Text(
                'Expires ${invite['expiresAt'].toString().split('T').first}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
          actions: [
            if (group!.creatorId == c.userId)
              TextButton(
                onPressed: () => act(ctx, () async {
                  await c.request(
                    'POST',
                    '/groups/${group!.id}/invites/revoke',
                    {'token': invite['token']},
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) message(context, 'Invitation revoked.');
                }),
                child: const Text('Revoke'),
              ),
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                message(context, 'Invitation copied');
              },
              child: const Text('Copy'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final box = ctx.findRenderObject() as RenderBox?;
                await SharePlus.instance.share(
                  ShareParams(
                    text: 'Join my Hisaab circle: $link',
                    sharePositionOrigin: box == null
                        ? null
                        : box.localToGlobal(Offset.zero) & box.size,
                  ),
                );
              },
              icon: const Icon(Icons.share),
              label: const Text('Share'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> expenseDetails(Expense e) async {
    final me = group!.participant(c.userId);
    final permitted =
        !group!.archived &&
        !c.offline &&
        (e.payer == me || e.shares.containsKey(me));
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.description,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text('${money(e.amount)} · ${e.displayMode} · ${e.date}'),
                if (e.receiptId != null)
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, 'receipt'),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('View bill & item breakdown'),
                  ),
                const SizedBox(height: 20),
                ...e.shares.entries.map(
                  (share) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(group!.memberName(share.key)),
                    trailing: Text(money(share.value)),
                  ),
                ),
                if (permitted) ...[
                  const SizedBox(height: 16),
                  if (!e.deleted)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(context, 'edit'),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit expense'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(
                        context,
                        e.deleted ? 'restore' : 'delete',
                      ),
                      icon: Icon(
                        e.deleted ? Icons.restore : Icons.delete_outline,
                      ),
                      label: Text(
                        e.deleted ? 'Restore expense' : 'Delete expense',
                      ),
                    ),
                  ),
                ],
                if (e.deleted)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Deleted expenses can be restored for 30 days.',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'receipt') {
      await openPage(
        context,
        c,
        ReceiptViewerPage(
          controller: c,
          group: group!,
          receiptId: e.receiptId!,
          expense: e,
        ),
      );
      await load();
      return;
    }
    if (action == 'edit') {
      await editExpense(e);
      return;
    }
    if (action == 'delete' &&
        !await confirm(
          context,
          'Delete expense?',
          'Balances update immediately. You can restore it within 30 days.',
          action: 'Delete',
        )) {
      return;
    }
    if (!mounted) return;
    await act(context, () async {
      await c.request(
        action == 'restore' ? 'POST' : 'DELETE',
        '/groups/${group!.id}/expenses/${e.id}${action == 'restore' ? '/restore' : ''}',
        {'version': e.version},
      );
      await load();
      await c.refresh();
    });
  }

  Future<void> openSettlement() async {
    await openPage(context, c, SettlementPage(controller: c, group: group!));
    await load();
    await c.refresh();
  }

  Future<void> options(String option) async {
    if (c.offline) {
      message(context, 'Refresh online before changing this group.');
      return;
    }
    final g = group!;
    if (option == 'rename') {
      final name = await askText(
        context,
        'Rename circle',
        'Group name',
        initial: g.name,
      );
      if (name == null || !mounted) return;
      await act(context, () async {
        await c.request('PATCH', '/groups/${g.id}', {
          'version': g.version,
          'name': name,
        });
        await load();
        await c.refresh();
      });
    }
    if (!mounted) return;
    if (option == 'archive') {
      await act(context, () async {
        await c.request('PATCH', '/groups/${g.id}', {
          'version': g.version,
          'archived': !g.archived,
        });
        await load();
        await c.refresh();
      });
    }
    if (!mounted) return;
    if (option == 'leave' || option == 'delete') {
      final ok = await confirm(
        context,
        option == 'leave' ? 'Leave this circle?' : 'Delete this circle?',
        option == 'leave'
            ? 'Any balance remains your responsibility. Your ledger identity and shared history remain available.'
            : 'Deletion requires all balances settled. Shared ledger records are retained under the retention policy.',
        action: option == 'leave' ? 'Leave and acknowledge' : 'Delete',
      );
      if (!ok || !mounted) return;
      await act(context, () async {
        await c.request(
          option == 'leave' ? 'POST' : 'DELETE',
          '/groups/${g.id}${option == 'leave' ? '/leave' : ''}',
          option == 'leave'
              ? {'acknowledgeBalance': true}
              : {'version': g.version},
        );
        await c.refresh();
        if (mounted) Navigator.pop(context);
      });
    }
  }
}

class _SettlementPerson extends StatelessWidget {
  final String? name;
  final String role;
  final Color background;
  const _SettlementPerson({
    required this.name,
    required this.role,
    required this.background,
  });

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ExcludeSemantics(
        child: CircleAvatar(
          radius: 34,
          backgroundColor: background,
          foregroundColor: HisaabColors.ink,
          child: name == null || name!.isEmpty
              ? const Icon(Icons.person_outline, size: 30)
              : Text(
                  name!.characters.first.toUpperCase(),
                  style: const TextStyle(fontFamily: 'Outfit', fontSize: 28),
                ),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        name ?? 'Choose a person',
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        role,
        style: const TextStyle(fontSize: 14, color: HisaabColors.muted),
      ),
    ],
  );
}

class SettlementPage extends StatefulWidget {
  final AppController controller;
  final Group group;
  const SettlementPage({
    super.key,
    required this.controller,
    required this.group,
  });
  @override
  State<SettlementPage> createState() => _SettlementPageState();
}

class _SettlementPageState extends State<SettlementPage> {
  String? from, to;
  String method = 'UPI';
  final amount = TextEditingController();
  bool saving = false;
  String? error;
  Group get g => widget.group;
  @override
  void initState() {
    super.initState();
    final me = g.participant(widget.controller.userId);
    final debt = me == null
        ? null
        : g.pairs(me).entries.where((p) => p.value < 0).firstOrNull;
    if (debt != null) {
      from = me;
      to = debt.key;
      amount.text = decimal(-debt.value);
    } else {
      from = g.members.firstOrNull?.id;
      to = g.members.length > 1 ? g.members[1].id : null;
    }
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final payer = from == null ? null : g.memberName(from!);
    final recipient = to == null ? null : g.memberName(to!);
    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: PageBody(
        children: [
          const SizedBox(height: 8),
          Text(
            'Paid them back?',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            g.name,
            textAlign: TextAlign.center,
            style: const TextStyle(color: HisaabColors.muted),
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SettlementPerson(
                  name: payer,
                  role: 'Paid',
                  background: HisaabColors.mint,
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 22, 12, 0),
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    color: HisaabColors.muted,
                  ),
                ),
              ),
              Expanded(
                child: _SettlementPerson(
                  name: recipient,
                  role: 'Received',
                  background: HisaabColors.lilac,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: HisaabColors.mint,
              borderRadius: BorderRadius.circular(24),
            ),
            child: TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 36,
                fontWeight: FontWeight.w600,
                color: HisaabColors.ink,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount paid',
                labelStyle: TextStyle(fontSize: 16, color: HisaabColors.teal),
                prefixText: '₹ ',
                suffixText: 'INR',
                suffixStyle: TextStyle(fontSize: 14, color: HisaabColors.teal),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: HisaabColors.primary, width: 2),
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: from,
            decoration: const InputDecoration(
              labelText: 'Who paid?',
              prefixIcon: Icon(Icons.north_east),
            ),
            items: g.members
                .map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => from = v),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: to,
            decoration: const InputDecoration(
              labelText: 'Who received?',
              prefixIcon: Icon(Icons.south_west),
            ),
            items: g.members
                .map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => to = v),
          ),
          const SectionTitle('Paid with'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: ['UPI', 'Cash', 'Other']
                .map(
                  (value) => ChoiceChip(
                    avatar: Icon(switch (value) {
                      'UPI' => Icons.account_balance_outlined,
                      'Cash' => Icons.payments_outlined,
                      _ => Icons.more_horiz,
                    }, size: 20),
                    label: Text(value),
                    selected: method == value,
                    onSelected: (_) => setState(() => method = value),
                  ),
                )
                .toList(),
          ),
          if (from != null && to != null) ...[
            const SizedBox(height: 20),
            Text(
              'Outstanding: ${money((-(g.pairs(from!)[to] ?? 0)).clamp(0, maxAmountPaise))}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: HisaabColors.peach,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 22, color: HisaabColors.ink),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Record a payment you have already made. Hisaab does not move money.',
                    style: TextStyle(height: 1.5, color: HisaabColors.ink),
                  ),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(error!, style: const TextStyle(color: clay)),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: saving || widget.controller.offline ? null : save,
            icon: Icon(saving ? Icons.hourglass_top : Icons.check),
            label: Text(saving ? 'Recording…' : 'Record payment'),
          ),
          const SizedBox(height: 12),
          const Text(
            'This adds a payment record to your shared history.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: HisaabColors.muted,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      final paise = parsePaise(amount.text);
      if (from == null || to == null || from == to) {
        throw ApiFailure('Choose two different people.');
      }
      if (paise > -(g.pairs(from!)[to] ?? 0)) {
        throw ApiFailure('Payment must not exceed the outstanding debt.');
      }
      await widget.controller.request('POST', '/groups/${g.id}/settlements', {
        'id': const Uuid().v4(),
        'fromId': from,
        'toId': to,
        'amountPaise': paise,
        'method': method,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
