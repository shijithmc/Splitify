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
        title: const Text('Groups'),
        actions: [
          if (group != null && !group!.archived)
            IconButton(
              tooltip: 'Attach receipt',
              onPressed: c.offline ? null : attachReceipt,
              icon: const Icon(Icons.attach_file_rounded),
            ),
          if (group != null)
            IconButton(
              tooltip: 'Group options',
              onPressed: showOptions,
              icon: const Icon(Icons.more_horiz_rounded),
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
                  const SizedBox(height: 8),
                  _summary(),
                  const SizedBox(height: 12),
                  _sectionPicker(),
                  const SizedBox(height: 12),
                  ...switch (section) {
                    0 => _expenseList(),
                    1 => _balanceList(),
                    _ => _paymentList(),
                  },
                  const SizedBox(height: 16),
                ],
              ),
            ),
      bottomNavigationBar: group == null
          ? null
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: c.offline
                    ? null
                    : group!.archived
                    ? () => options('archive')
                    : section == 1
                    ? openSettlement
                    : () => editExpense(),
                icon: Icon(
                  group!.archived
                      ? Icons.unarchive_outlined
                      : section == 1
                      ? Icons.handshake_outlined
                      : Icons.add_circle_outline_rounded,
                ),
                label: Text(
                  group!.archived
                      ? 'Reopen group'
                      : section == 1
                      ? 'Settle up'
                      : 'Add expense',
                ),
              ),
            ),
    ),
  );

  Widget _sectionPicker() => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: HisaabColors.lilac.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final chips = [
          for (final (index, label) in [
            'Expenses',
            'Balances',
            'Payments',
          ].indexed)
            ChoiceChip(
              label: Text(label),
              selected: section == index,
              showCheckmark: false,
              side: BorderSide.none,
              backgroundColor: Colors.transparent,
              selectedColor: HisaabColors.lilac,
              labelStyle: TextStyle(
                color: section == index
                    ? HisaabColors.primary
                    : HisaabColors.muted,
                fontWeight: section == index
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
              onSelected: (_) => setState(() => section = index),
            ),
        ];
        if (constraints.maxWidth < 320 ||
            MediaQuery.textScalerOf(context).scale(14) > 17) {
          return Wrap(spacing: 4, runSpacing: 4, children: chips);
        }
        return Row(children: [for (final chip in chips) Expanded(child: chip)]);
      },
    ),
  );

  Widget _summary() {
    final g = group!;
    final me = g.participant(c.userId);
    final net = me == null ? 0 : g.netFor(me);
    final hasBalances = me != null && g.pairs(me).values.any((v) => v != 0);
    final type = g.type == 'Direct' ? 'Just you two' : g.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EditorialArtwork(
          asset: g.type == 'Home'
              ? HisaabArt.home
              : g.type == 'Trip'
              ? HisaabArt.trip
              : HisaabArt.sharing,
          height: 128,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 12),
        Text(g.name, style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 4),
        Text(
          '$type · ${g.members.length} people${g.archived ? ' · Archived' : ''}',
          style: const TextStyle(fontSize: 14, color: HisaabColors.muted),
        ),
        if (g.archived)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'History stays here. Reopen the group to add expenses.',
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: g.members.length + (g.archived ? 0 : 1),
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index == g.members.length) {
                return IconButton.filledTonal(
                  tooltip: 'Add person',
                  onPressed: c.offline ? null : addMember,
                  icon: const Icon(Icons.add),
                );
              }
              final member = g.members[index];
              final name = member.userId == c.userId
                  ? 'You'
                  : g.memberName(member.id);
              return Tooltip(
                message: name,
                child: Semantics(
                  label: name,
                  child: ExcludeSemantics(child: _MemberAvatar(member, index)),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: net < 0 ? HisaabColors.peach : HisaabColors.mint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      net == 0
                          ? hasBalances
                                ? 'No net balance'
                                : 'You are settled up'
                          : net > 0
                          ? 'You get back'
                          : 'You owe',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (net != 0)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          money(net.abs()),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 32,
                            color: net < 0
                                ? HisaabColors.warning
                                : HisaabColors.positive,
                          ),
                        ),
                      ),
                    if (net == 0 && hasBalances) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'You owe and are owed the same amount. Check Balances before settling up.',
                        style: TextStyle(
                          fontSize: 14,
                          color: HisaabColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!g.archived && section != 1) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: c.offline ? null : openSettlement,
                  child: const Text('Settle up'),
                ),
              ],
              if (g.archived && !hasBalances && net == 0)
                const Icon(
                  Icons.check_circle_rounded,
                  color: HisaabColors.positive,
                  size: 32,
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _expenseShare(Expense expense) {
    final me = group!.participant(c.userId);
    if (me == null ||
        (expense.payer != me && !expense.shares.containsKey(me))) {
      return 'You were not involved';
    }
    final share = expense.shares[me] ?? 0;
    final lent = expense.payer == me ? expense.amount - share : 0;
    return lent > 0 ? 'You lent ${money(lent)}' : 'Your share ${money(share)}';
  }

  List<Widget> _expenseList() => [
    if (expenses.isEmpty)
      EmptyCard(
        icon: Icons.receipt_long_outlined,
        illustrationAsset: HisaabArt.sharing,
        title: 'No expenses yet',
        body: 'Add a bill, choose who paid, and split it with your group.',
        action: group!.archived
            ? null
            : FilledButton.icon(
                onPressed: c.offline ? null : () => editExpense(),
                icon: const Icon(Icons.add),
                label: const Text('Add the first expense'),
              ),
      ),
    for (final (index, e) in expenses.indexed)
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(
          top: index == 0 ? const Radius.circular(18) : Radius.zero,
          bottom: index == expenses.length - 1
              ? const Radius.circular(18)
              : Radius.zero,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            if (index != 0) const Divider(height: 1, indent: 64),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              leading: e.receiptId != null && !e.deleted
                  ? ReceiptThumbnail(controller: c, receiptId: e.receiptId!)
                  : CircleAvatar(
                      radius: 22,
                      backgroundColor: e.deleted
                          ? HisaabColors.surface
                          : HisaabColors.peach,
                      child: Icon(
                        e.deleted
                            ? Icons.delete_outline
                            : _expenseIcon(e.description),
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
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(
                    '${group!.memberName(e.payer)} paid ${money(e.amount)} · ${e.date}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.deleted ? 'Deleted · tap to restore' : _expenseShare(e),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: e.deleted ? HisaabColors.muted : HisaabColors.ink,
                    ),
                  ),
                ],
              ),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: HisaabColors.muted,
                size: 20,
              ),
              onTap: () => expenseDetails(e),
            ),
          ],
        ),
      ),
    if (cursor != null)
      TextButton(onPressed: loadMore, child: const Text('Load older expenses')),
  ];
  List<Widget> _balanceList() => [
    const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Text(
        'See who owes whom, at a glance.',
        style: TextStyle(color: HisaabColors.muted),
      ),
    ),
    ...group!.members.map((m) {
      final net = group!.netFor(m.id);
      final hasBalances = group!.pairs(m.id).values.any((v) => v != 0);
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
                    ? hasBalances
                          ? 'No net balance · see details'
                          : 'Settled'
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
                onPressed: c.offline ? null : () => invite(m.id),
                child: const Text('Invite to claim this balance'),
              ),
          ],
        ),
      );
    }),
  ];
  List<Widget> _paymentList() => [
    if (settlements.isNotEmpty) const SectionTitle('Payment history'),
    if (settlements.isEmpty)
      const EmptyCard(
        icon: Icons.handshake_outlined,
        illustrationAsset: HisaabArt.together,
        title: 'No payments recorded',
        body: 'Paid them back? Record the amount and method here.',
      ),
    ...settlements.map(
      (p) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: p['disputed'] == true
                ? HisaabColors.peach
                : HisaabColors.mint,
            child: Icon(
              p['disputed'] == true ? Icons.undo : Icons.check_rounded,
              color: p['disputed'] == true
                  ? HisaabColors.warning
                  : HisaabColors.positive,
            ),
          ),
          title: Text(
            '${group!.memberName(p['fromId'])} paid ${group!.memberName(p['toId'])}',
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                money(p['amountPaise']),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: p['disputed'] == true
                      ? HisaabColors.warning
                      : HisaabColors.positive,
                ),
              ),
              Text(
                '${p['method']} · ${p['disputed'] == true ? 'Disputed · balance reversed' : 'Payment recorded'}',
              ),
            ],
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
  Future<void> showOptions() async {
    final g = group!;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(g.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              for (final entry in [
                if (!g.archived) ...[
                  ('member', 'Add person', Icons.person_add_alt_1_outlined),
                  ('invite', 'Invite', Icons.send_outlined),
                ],
                ('rename', 'Rename group', Icons.edit_outlined),
                (
                  'archive',
                  g.archived ? 'Reopen group' : 'Archive group',
                  Icons.inventory_2_outlined,
                ),
                ('leave', 'Leave group', Icons.logout_rounded),
                if (g.creatorId == c.userId)
                  ('delete', 'Delete group', Icons.delete_outline_rounded),
              ])
                ListTile(
                  enabled: !c.offline,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entry.$3,
                    color: entry.$1 == 'delete'
                        ? HisaabColors.warning
                        : HisaabColors.primary,
                  ),
                  title: Text(entry.$2),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, entry.$1),
                ),
              if (c.offline)
                const _GroupNote(
                  icon: Icons.wifi_off_rounded,
                  text:
                      'Reconnect to make changes. Your saved history is still here.',
                ),
            ],
          ),
        ),
      ),
    );
    if (action != null && mounted) await options(action);
  }

  Future<void> addMember() async {
    if (c.offline || group!.archived) return;
    final member = await showModalBottomSheet<Json>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _AddPersonSheet(),
    );
    if (member == null || !mounted) return;
    await act(context, () async {
      await c.request('POST', '/groups/${group!.id}/members', member);
      await load();
      await c.refresh();
    });
  }

  Future<void> invite([String? participantId]) async {
    if (c.offline || group!.archived) return;
    await act(context, () async {
      final invite = await c.request('POST', '/groups/${group!.id}/invites', {
        'participantId': ?participantId,
      });
      if (!mounted) return;
      final link = invite['url'] as String;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Save them a spot',
                  style: Theme.of(ctx).textTheme.headlineLarge,
                ),
                const SizedBox(height: 6),
                const Text('Share an invitation to your circle.'),
                const SizedBox(height: 16),
                const EditorialArtwork(asset: HisaabArt.together, height: 152),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: GroupArtwork(type: group!.type, size: 52),
                  title: Text(group!.name),
                  subtitle: Text('${group!.members.length} people'),
                ),
                const SectionTitle('Private invitation'),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: HisaabColors.lilac,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SelectableText(link),
                ),
                const SizedBox(height: 8),
                Text(
                  'Expires ${invite['expiresAt'].toString().split('T').first}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: HisaabColors.muted,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (mounted) message(context, 'Invitation copied');
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy link'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
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
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share'),
                ),
                const SizedBox(height: 16),
                const _GroupNote(
                  icon: Icons.lock_outline_rounded,
                  text:
                      'Only share this private link with the person you want to invite.',
                ),
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
                    style: TextButton.styleFrom(
                      foregroundColor: HisaabColors.warning,
                    ),
                    child: const Text('Revoke invitation'),
                  ),
              ],
            ),
          ),
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
                if (e.deleted) ...[
                  const _GroupNote(
                    icon: Icons.delete_outline_rounded,
                    text:
                        'Deleted · this expense is no longer included in balances.',
                    warning: true,
                  ),
                  const SizedBox(height: 12),
                ],
                const EditorialArtwork(asset: HisaabArt.receipt, height: 128),
                const SizedBox(height: 16),
                Text(
                  e.description,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  money(e.amount),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '${group!.memberName(e.payer)} paid · ${e.displayMode} · ${e.date}',
                  style: const TextStyle(color: HisaabColors.muted),
                ),
                const SizedBox(height: 12),
                const _GroupNote(
                  icon: Icons.lock_outline_rounded,
                  text: 'Visible to this group',
                ),
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
                    leading: CircleAvatar(
                      backgroundColor: HisaabColors.lilac,
                      foregroundColor: HisaabColors.primary,
                      child: Text(
                        group!
                                .memberName(share.key)
                                .characters
                                .firstOrNull
                                ?.toUpperCase() ??
                            '?',
                      ),
                    ),
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

  Future<void> attachReceipt() async {
    await openPage(
      context,
      c,
      ReceiptCapturePage(controller: c, group: group!),
    );
    await load();
    await c.refresh();
  }

  Future<void> options(String option) async {
    if (c.offline) {
      message(context, 'Refresh online before changing this group.');
      return;
    }
    final g = group!;
    if (option == 'member' && !g.archived) {
      await addMember();
      return;
    }
    if (option == 'invite' && !g.archived) {
      await invite();
      return;
    }
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
  bool canRecord(Member payer, Member recipient) {
    final userId = widget.controller.userId;
    final actor = g.members.where((m) => m.userId == userId).firstOrNull;
    if (actor == null || actor.deleted) return false;
    if (payer.userId == userId || recipient.userId == userId) return true;
    return g.creatorId == userId &&
        !actor.left &&
        [payer, recipient].any((m) => m.placeholder || m.external || m.deleted);
  }

  List<Member> get payers =>
      g.members.where((m) => recipients(m.id).isNotEmpty).toList();

  List<Member> recipients(String? payerId) {
    final payer = g.members.where((m) => m.id == payerId).firstOrNull;
    if (payer == null) return [];
    return g.members
        .where((m) => (g.pairs(payer.id)[m.id] ?? 0) < 0 && canRecord(payer, m))
        .toList();
  }

  void selectPayer(String payer, {String? recipient}) {
    from = payer;
    final available = recipients(payer);
    to = available.any((m) => m.id == recipient)
        ? recipient
        : available.firstOrNull?.id;
    updateAmount();
  }

  void updateAmount() {
    amount.text = from == null || to == null
        ? ''
        : decimal(-(g.pairs(from!)[to] ?? 0));
    error = null;
  }

  @override
  void initState() {
    super.initState();
    final me = g.participant(widget.controller.userId);
    final incoming = payers
        .where((m) => (g.pairs(m.id)[me] ?? 0) < 0)
        .firstOrNull;
    if (me != null && payers.any((m) => m.id == me)) {
      selectPayer(me);
    } else if (incoming != null) {
      selectPayer(incoming.id, recipient: me);
    } else if (payers.isNotEmpty) {
      selectPayer(payers.first.id);
    }
  }

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (payers.isEmpty) {
      final hasBalances = g.members.any(
        (m) => g.pairs(m.id).values.any((value) => value != 0),
      );
      return Scaffold(
        appBar: AppBar(title: const Text('Settle up')),
        body: PageBody(
          children: [
            EmptyCard(
              icon: Icons.check_circle_outline,
              illustrationAsset: HisaabArt.together,
              title: hasBalances
                  ? 'No payments for you to record'
                  : 'Everyone is settled up',
              body: hasBalances
                  ? 'Only the people involved can record these payments.'
                  : 'There are no outstanding balances in ${g.name}.',
              action: OutlinedButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Back to group'),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: Column(
        children: [
          Expanded(
            child: PageBody(
              children: [
                const EditorialArtwork(asset: HisaabArt.together, height: 120),
                const SizedBox(height: 16),
                Text(
                  'Clear between friends',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(g.name, style: const TextStyle(color: HisaabColors.muted)),
                const SizedBox(height: 16),
                const _GroupNote(
                  icon: Icons.info_outline_rounded,
                  text:
                      'Record a payment you have already made. Hisaab does not move money.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amount,
                  enabled: !saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: HisaabColors.ink,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Amount paid',
                    prefixText: '₹ ',
                    suffixText: 'INR',
                    fillColor: HisaabColors.lilac,
                  ),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: from,
                  decoration: const InputDecoration(
                    labelText: 'Who paid?',
                    prefixIcon: Icon(Icons.north_east),
                  ),
                  items: payers
                      .map(
                        (m) => DropdownMenuItem(
                          value: m.id,
                          child: Text(
                            g.memberName(m.id),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (v) {
                          if (v != null) {
                            setState(() => selectPayer(v, recipient: to));
                          }
                        },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('recipient-$from-$to'),
                  initialValue: to,
                  decoration: const InputDecoration(
                    labelText: 'Who received?',
                    prefixIcon: Icon(Icons.south_west),
                  ),
                  items: recipients(from)
                      .map(
                        (m) => DropdownMenuItem(
                          value: m.id,
                          child: Text(
                            g.memberName(m.id),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (v) => setState(() {
                          to = v;
                          updateAmount();
                        }),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Choose an outstanding balance you can record. Partial payments are welcome.',
                  style: TextStyle(fontSize: 14, color: HisaabColors.muted),
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
                          onSelected: saving
                              ? null
                              : (_) => setState(() => method = value),
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
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(error!, style: const TextStyle(color: clay)),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: saving || widget.controller.offline ? null : save,
                  icon: Icon(saving ? Icons.hourglass_top : Icons.check),
                  label: Text(saving ? 'Recording…' : 'Record payment'),
                ),
              ],
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

IconData _expenseIcon(String description) {
  final value = description.toLowerCase();
  if (RegExp(r'coffee|café|cafe|tea').hasMatch(value)) {
    return Icons.local_cafe_outlined;
  }
  if (RegExp(r'taxi|cab|uber|ride|fuel').hasMatch(value)) {
    return Icons.local_taxi_outlined;
  }
  if (RegExp(r'dinner|lunch|breakfast|food|meal|restaurant').hasMatch(value)) {
    return Icons.restaurant_rounded;
  }
  if (RegExp(r'home|rent|electric|internet').hasMatch(value)) {
    return Icons.home_outlined;
  }
  if (RegExp(r'trip|flight|hotel|travel').hasMatch(value)) {
    return Icons.luggage_outlined;
  }
  return Icons.receipt_long_outlined;
}

class _MemberAvatar extends StatelessWidget {
  final Member member;
  final int index;
  const _MemberAvatar(this.member, this.index);

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 24,
    backgroundColor: [
      HisaabColors.lilac,
      HisaabColors.peach,
      HisaabColors.mint,
    ][index % 3],
    foregroundColor: HisaabColors.ink,
    child: Text(
      member.deleted
          ? '?'
          : member.name.characters.firstOrNull?.toUpperCase() ?? '?',
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
    ),
  );
}

class _GroupNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warning;
  const _GroupNote({
    required this.icon,
    required this.text,
    this.warning = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: warning ? HisaabColors.peach : HisaabColors.lilac,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: warning ? HisaabColors.warning : HisaabColors.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4)),
        ),
      ],
    ),
  );
}

class _AddPersonSheet extends StatefulWidget {
  const _AddPersonSheet();

  @override
  State<_AddPersonSheet> createState() => _AddPersonSheetState();
}

class _AddPersonSheetState extends State<_AddPersonSheet> {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  String? error;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Who’s joining?',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 6),
                  const Text('Add a friend to your group.'),
                  const SizedBox(height: 16),
                  const EditorialArtwork(asset: HisaabArt.sharing, height: 136),
                  const SizedBox(height: 16),
                  TextField(
                    controller: name,
                    maxLength: 100,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
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
                  const SizedBox(height: 16),
                  const _GroupNote(
                    icon: Icons.lightbulb_outline_rounded,
                    text:
                        'Start with a name. A verified email or a private invitation lets them claim their shared history. Adding a phone number does not give access.',
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  setState(() => error = 'Enter their name to add them.');
                  return;
                }
                Navigator.pop(context, {
                  'displayName': name.text.trim(),
                  if (email.text.trim().isNotEmpty) 'email': email.text.trim(),
                  if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
                });
              },
              child: const Text('Add person'),
            ),
          ),
        ],
      ),
    ),
  );
}
