import 'dart:async';
import 'package:flutter/material.dart';
import '../core/ads.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../main.dart';
import 'group.dart';
import 'settings.dart';
import 'shared.dart';
import 'receipts.dart';
import 'receipt_viewer.dart';

class AppShell extends StatefulWidget {
  final AppController controller;
  const AppShell({super.key, required this.controller});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  Timer? _poll;
  bool _active = true;
  bool _openingNotification = false;
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_active && c.signedIn && c.protectedDepth == 0 && !c.demo) {
        c.refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    c.setForeground(_active);
    if (_active && c.signedIn) c.refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      if (!c.signedIn) {
        return Stack(
          children: [
            Welcome(controller: c),
            if (c.loading) ...[
              const ModalBarrier(dismissible: false, color: Color(0x66FFFFFF)),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        );
      }
      if (c.loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (c.pendingNotification != null &&
          !_openingNotification &&
          c.protectedDepth == 0) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _openNotification(),
        );
      }
      final pages = [
        _home(),
        _groups(),
        _activity(),
        SettingsPage(controller: c),
      ];
      return Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(
                Icons.people_outline_rounded,
                size: 28,
                color: HisaabColors.primary,
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'hisaab.',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                      fontSize: 27,
                    ),
                  ),
                ),
              ),
              if (c.demo) ...[
                const SizedBox(width: 12),
                const Chip(
                  label: Text(
                    'DEMO',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Join an invitation',
              onPressed: () => joinInvite(context, c),
              icon: const Icon(Icons.link),
            ),
            const SizedBox(width: 10),
          ],
        ),
        body: Column(
          children: [
            if (c.pendingInvite != null && !c.demo)
              Material(
                color: HisaabColors.mint,
                child: ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: const Text('A private invitation is ready'),
                  trailing: TextButton(
                    onPressed: c.offline
                        ? null
                        : () async {
                            final accepted = await confirm(
                              context,
                              'Join this invitation?',
                              'Accept to join the shared circle. If this invitation is for an existing member, you will claim their expense history and balances.',
                              action: 'Accept invitation',
                            );
                            if (!context.mounted) return;
                            if (!accepted) {
                              await c.dismissInvite();
                              return;
                            }
                            await act(context, () async {
                              final joined = await c.request(
                                'POST',
                                '/invites/accept',
                                {'token': c.pendingInvite},
                              );
                              await c.dismissInvite();
                              await c.refresh();
                              if (context.mounted) {
                                await openPage(
                                  context,
                                  c,
                                  GroupPage(
                                    controller: c,
                                    groupId: joined['id'],
                                  ),
                                );
                              }
                            });
                          },
                    child: const Text('Review'),
                  ),
                ),
              ),
            if (c.offline)
              Material(
                color: const Color(0xFFFFE4B7),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.cloud_off_outlined),
                  title: const Text('Offline · saved data is read-only'),
                  trailing: TextButton(
                    onPressed: c.refresh,
                    child: const Text('Retry'),
                  ),
                ),
              ),
            if (c.error != null)
              Material(
                color: const Color(0xFFFFE4DD),
                child: ListTile(
                  dense: true,
                  title: Text(c.error!),
                  trailing: IconButton(
                    tooltip: 'Retry',
                    onPressed: c.refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: c.refresh,
                child: pages[c.tab],
              ),
            ),
            if (c.tab < 3)
              SafeBanner(
                key: ValueKey(c.tab),
                controller: c,
                route: ['home', 'groups', 'activity'][c.tab],
              ),
          ],
        ),
        floatingActionButton: c.tab == 1
            ? FloatingActionButton.extended(
                onPressed: c.offline ? null : () => _addExpense(),
                icon: const Icon(Icons.add),
                label: const Text('Add expense'),
                backgroundColor: HisaabColors.lime,
                foregroundColor: HisaabColors.primary,
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: c.tab,
          onDestinationSelected: c.selectTab,
          backgroundColor: const Color(0xFFFFFEF9),
          indicatorColor: HisaabColors.mint,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'Groups',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Activity',
            ),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
          ],
        ),
      );
    },
  );

  Future<void> _openNotification() async {
    if (!mounted || _openingNotification || c.protectedDepth != 0) return;
    final payload = c.takeNotification();
    if (payload == null || payload['account'] != c.userId) return;
    _openingNotification = true;
    final account = c.userId;
    try {
      final group = Group.from(
        await c.request('GET', '/groups/${payload['groupId']}'),
      );
      if (!mounted || c.userId != account) return;
      final id = payload['receiptId'];
      if (id is String && id.isNotEmpty) {
        final status = await c.receipts.get(id);
        if (!mounted || c.userId != account) return;
        if (status['expenseId'] == null) {
          await openPage(
            context,
            c,
            ReceiptCapturePage(controller: c, group: group, receiptId: id),
          );
        } else {
          final expense = Expense(
            await c.request(
              'GET',
              '/groups/${group.id}/expenses/${status['expenseId']}',
            ),
          );
          if (!mounted || c.userId != account) return;
          await openPage(
            context,
            c,
            ReceiptViewerPage(
              controller: c,
              group: group,
              receiptId: id,
              expense: expense,
            ),
          );
        }
      } else {
        await openPage(context, c, GroupPage(controller: c, groupId: group.id));
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      _openingNotification = false;
    }
  }

  Widget _home() {
    final net = c.balances['netPaise'] as int? ?? 0;
    final name = c.user['displayName'] as String? ?? 'friend';
    final activeGroups = c.groups.where((g) => !g.archived).toList();
    return PageBody(
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'LET’S MAKE ROOM FOR GOOD TIMES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: .7,
                      color: HisaabColors.muted,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Hey, $name',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filledTonal(
              tooltip: 'Open your profile',
              onPressed: () => c.selectTab(3),
              icon: Text(
                name.characters.firstOrNull ?? '?',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(21),
          decoration: BoxDecoration(
            color: HisaabColors.primary,
            borderRadius: BorderRadius.circular(25),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'YOUR OVERALL BALANCE',
                      style: TextStyle(
                        color: Color(0xFFE2EBCA),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF345B44),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: const Text(
                      'INR',
                      style: TextStyle(color: Color(0xFFEAF2CD), fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  money(net.abs()),
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    color: HisaabColors.balanceAmount,
                    fontSize: 49,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -1.9,
                    height: 1.05,
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Text(
                net == 0
                    ? 'You’re all square overall'
                    : net > 0
                    ? 'You’re owed overall'
                    : 'You owe overall',
                style: const TextStyle(color: Color(0xFFE4ECCF), fontSize: 14),
              ),
              const SizedBox(height: 21),
              const Divider(color: Color(0xFF4C6C50)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      'You get back',
                      c.balances['owedPaise'] ?? 0,
                      Icons.south_west,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: _metric(
                      'You owe',
                      c.balances['owingPaise'] ?? 0,
                      Icons.north_east,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _quickAction(
              'Add expense',
              Icons.add_rounded,
              const Color(0xFFDDEAAB),
              () => _addExpense(),
            ),
            _quickAction(
              'Scan bill',
              Icons.document_scanner_outlined,
              HisaabColors.peach,
              () => _groupAction(scan: true),
            ),
            _quickAction(
              'Settle up',
              Icons.arrow_outward_rounded,
              HisaabColors.lilac,
              () => _groupAction(scan: false),
            ),
          ],
        ),
        SectionTitle(
          'Your people, your plans',
          trailing: TextButton(
            onPressed: () => c.selectTab(1),
            child: const Text('See all →'),
          ),
        ),
        if (activeGroups.isEmpty)
          EmptyCard(
            icon: Icons.people_outline,
            illustrationAsset: 'assets/illustrations/shared-home.png',
            title: 'Bring your people',
            body:
                'Create your first group and keep everyone’s share in one place.',
            action: FilledButton(
              onPressed: c.offline ? null : () => createGroup(context, c),
              child: const Text('Create a group'),
            ),
          )
        else ...[
          _momentsBanner(),
          ...activeGroups.take(3).map(_groupTile),
        ],
        const SectionTitle('Between friends'),
        if (rows(c.balances['friends']).isEmpty)
          const Text('All clear. Your shared balances will appear here.')
        else
          Card(
            child: Column(
              children: rows(c.balances['friends']).map((f) {
                final value = f['netPaise'] as int;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: HisaabColors.lilac,
                    child: Text(
                      (f['displayName'] as String).characters.firstOrNull ??
                          '?',
                    ),
                  ),
                  title: Text(f['displayName']),
                  subtitle: Text(
                    '${value >= 0 ? 'Owes you' : 'You owe'} ${money(value.abs())}',
                    style: TextStyle(
                      color: value >= 0
                          ? HisaabColors.positive
                          : HisaabColors.warning,
                      fontSize: 14,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _momentsBanner() => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.only(right: 14),
    decoration: BoxDecoration(
      color: HisaabColors.illustrationBackground,
      borderRadius: BorderRadius.circular(20),
    ),
    clipBehavior: Clip.antiAlias,
    child: Row(
      children: [
        const Expanded(
          child: EditorialArtwork(
            asset: 'assets/illustrations/moments.png',
            height: 112,
            borderRadius: BorderRadius.zero,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text.rich(
              const TextSpan(
                text: 'Collect moments.\n',
                children: [
                  TextSpan(
                    text: 'We’ll keep the totals.',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: HisaabColors.primary,
                    ),
                  ),
                ],
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _quickAction(
    String label,
    IconData icon,
    Color color,
    VoidCallback action,
  ) => Expanded(
    child: TextButton(
      onPressed: c.offline ? null : action,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(icon, size: 24, color: HisaabColors.primary),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: HisaabColors.muted),
          ),
        ],
      ),
    ),
  );

  Future<void> _groupAction({required bool scan}) async {
    final active = c.groups.where((g) => !g.archived).toList();
    if (active.isEmpty) {
      await createGroup(context, c);
      return;
    }
    final chosen = active.length == 1
        ? active.single
        : await showModalBottomSheet<Group>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    scan
                        ? 'Which bill are we splitting?'
                        : 'Choose a group to settle up',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  ...active.map(
                    (g) => ListTile(
                      leading: GroupArtwork(type: g.type, size: 48),
                      title: Text(g.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, g),
                    ),
                  ),
                ],
              ),
            ),
          );
    if (chosen == null || !mounted) return;
    final account = c.userId;
    await act(context, () async {
      final detail = Group.from(await c.request('GET', '/groups/${chosen.id}'));
      if (!mounted || c.userId != account) return;
      await openPage(
        context,
        c,
        scan
            ? ReceiptCapturePage(controller: c, group: detail)
            : SettlementPage(controller: c, group: detail),
      );
      if (c.userId == account) await c.refresh();
    });
  }

  Widget _metric(String label, int amount, IconData icon) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: const Color(0xFFDEE8CD), size: 15),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFDEE8CD), fontSize: 14),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      FittedBox(
        child: Text(
          money(amount),
          style: const TextStyle(
            fontFamily: 'Outfit',
            color: Color(0xFFF8FFE5),
            fontWeight: FontWeight.w500,
            fontSize: 21,
          ),
        ),
      ),
    ],
  );

  Widget _groupTile(Group g) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: HisaabColors.line)),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () =>
            openPage(context, c, GroupPage(controller: c, groupId: g.id)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              GroupArtwork(type: g.type),
              const SizedBox(width: 12),
              Expanded(child: _groupCopy(g)),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: HisaabColors.muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _groupCopy(Group g, {bool featured = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        g.name,
        style: TextStyle(
          fontFamily: featured ? 'Outfit' : 'WorkSans',
          fontSize: featured ? 23 : 16,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '${g.type == 'Direct' ? 'Friend' : g.type} · ${g.count} people${g.archived ? ' · Archived' : ''}',
        style: const TextStyle(fontSize: 14, color: HisaabColors.muted),
      ),
      const SizedBox(height: 5),
      Text(
        g.net == 0
            ? 'Settled up'
            : '${g.net > 0 ? 'You get back' : 'You owe'} ${money(g.net.abs())}',
        style: TextStyle(
          color: g.net < 0 ? HisaabColors.warning : HisaabColors.positive,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );

  Widget _featuredGroup(Group g) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      color: HisaabColors.illustrationBackground,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            openPage(context, c, GroupPage(controller: c, groupId: g.id)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EditorialArtwork(
              asset: g.type == 'Home'
                  ? 'assets/illustrations/shared-home.png'
                  : 'assets/illustrations/moments.png',
              height: 196,
              borderRadius: BorderRadius.zero,
              fit: BoxFit.cover,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
              child: Row(
                children: [
                  Expanded(child: _groupCopy(g, featured: true)),
                  const SizedBox(width: 12),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: HisaabColors.lime,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_forward,
                      color: HisaabColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _groups() => PageBody(
    children: [
      SectionTitle(
        'Life, in good company',
        trailing: IconButton(
          tooltip: 'Create group or friend',
          onPressed: c.offline ? null : () => createGroup(context, c),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ),
      const Text('Little circles. Big memories.'),
      const SizedBox(height: 20),
      if (c.invites.isNotEmpty) ...[
        const SectionTitle('Waiting for you'),
        ...c.invites.map(
          (invite) => Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: const Icon(Icons.mail_outline),
              title: Text(invite['groupName'] ?? 'A shared circle'),
              subtitle: const Text('Invitation to your verified email'),
              trailing: TextButton(
                onPressed: c.offline
                    ? null
                    : () => act(context, () async {
                        final joined = await c.request(
                          'POST',
                          '/invites/accept',
                          {'token': invite['token']},
                        );
                        await c.refresh();
                        if (mounted) {
                          await openPage(
                            context,
                            c,
                            GroupPage(controller: c, groupId: joined['id']),
                          );
                        }
                      }),
                child: const Text('Join'),
              ),
            ),
          ),
        ),
      ],
      if (c.groups.isEmpty)
        EmptyCard(
          icon: Icons.group_add_outlined,
          illustrationAsset: 'assets/illustrations/shared-home.png',
          title: 'Start your first circle',
          body: 'Home, holidays, your person, or just a friend.',
          action: FilledButton(
            onPressed: c.offline ? null : () => createGroup(context, c),
            child: const Text('Create a group'),
          ),
        ),
      if (c.groups.isNotEmpty) ...[
        _featuredGroup(c.groups.first),
        ...c.groups.skip(1).map(_groupTile),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: c.offline ? null : () => createGroup(context, c),
          icon: const Icon(Icons.add),
          label: const Text('Create a new group'),
        ),
      ],
      const SizedBox(height: 85),
    ],
  );
  Widget _activity() => PageBody(
    children: [
      const SectionTitle('The latest'),
      const Text('A little history keeps everyone on the same page.'),
      const SizedBox(height: 22),
      if (c.activity.isEmpty)
        const EmptyCard(
          icon: Icons.receipt_long_outlined,
          title: 'A fresh start',
          body: 'Expenses and payments will show up here.',
        ),
      ...c.activity.map(
        (a) => Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: CircleAvatar(
              backgroundColor: HisaabColors.mint,
              child: Icon(
                (a['kind'] as String).contains('Payment')
                    ? Icons.check
                    : Icons.receipt_long_outlined,
                color: green,
              ),
            ),
            title: Text(a['description']),
            subtitle: Text(
              '${a['actorName'] ?? (a['actorId'] == c.userId ? 'You' : 'A member')} · ${c.groups.where((g) => g.id == a['groupId']).firstOrNull?.name ?? 'Shared activity'} · ${(a['createdAt'] as String).split('T').first}${activityChangeSummary(a).isEmpty ? '' : '\n${activityChangeSummary(a)}'}',
            ),
            onTap: () => openPage(
              context,
              c,
              GroupPage(controller: c, groupId: a['groupId']),
            ),
          ),
        ),
      ),
    ],
  );
  Future<void> _addExpense() async {
    final active = c.groups.where((g) => !g.archived).toList();
    if (active.isEmpty) {
      await createGroup(context, c);
      return;
    }
    if (active.length == 1) {
      if (mounted) {
        await openPage(
          context,
          c,
          GroupPage(controller: c, groupId: active.first.id, addOnOpen: true),
        );
      }
      return;
    }
    final group = await showModalBottomSheet<Group>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Where does this expense belong?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            ...active.map(
              (g) => ListTile(
                leading: Icon(groupIcon(g.type)),
                title: Text(g.name),
                onTap: () => Navigator.pop(context, g),
              ),
            ),
          ],
        ),
      ),
    );
    if (group != null && mounted) {
      await openPage(
        context,
        c,
        GroupPage(controller: c, groupId: group.id, addOnOpen: true),
      );
    }
  }
}

IconData groupIcon(String type) => switch (type) {
  'Trip' => Icons.beach_access_outlined,
  'Home' => Icons.home_outlined,
  'Couple' => Icons.favorite_outline,
  'Direct' => Icons.local_cafe_outlined,
  _ => Icons.people_outline,
};

class Welcome extends StatefulWidget {
  final AppController controller;
  const Welcome({super.key, required this.controller});
  @override
  State<Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<Welcome> {
  bool signingIn = false;

  @override
  Widget build(BuildContext context) {
    final showProviders = signingIn || widget.controller.error != null;
    return PopScope(
      canPop: !showProviders,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            signingIn = false;
            widget.controller.error = null;
          });
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: PageBody(
            children: [
              const SizedBox(height: 16),
              Row(
                children: [
                  if (showProviders)
                    IconButton(
                      tooltip: 'Back to welcome',
                      onPressed: () => setState(() {
                        signingIn = false;
                        widget.controller.error = null;
                      }),
                      icon: const Icon(Icons.arrow_back),
                    ),
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: HisaabColors.mint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.people_outline_rounded,
                      color: HisaabColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text.rich(
                        TextSpan(
                          text: 'hisaab',
                          style: TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 29,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1,
                            color: HisaabColors.primary,
                          ),
                          children: [
                            TextSpan(
                              text: '.',
                              style: TextStyle(color: HisaabColors.positive),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (!showProviders) ...[
                EditorialArtwork(
                  asset: 'assets/illustrations/moments.png',
                  height: 245,
                  borderRadius: BorderRadius.circular(26),
                  fit: BoxFit.cover,
                ),
                const SizedBox(height: 24),
                const Text(
                  'SPLIT THE BILL. KEEP THE GOOD VIBES.',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: HisaabColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                Text.rich(
                  const TextSpan(
                    text: 'More memories.\n',
                    children: [
                      TextSpan(
                        text: 'Less money talk.',
                        style: TextStyle(color: Color(0xFF658447)),
                      ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'From your first coffee to your next big trip. Keep every share simple, fair, and together.',
                  style: TextStyle(
                    color: HisaabColors.muted,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                const Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    _WelcomeBenefit('Unlimited expenses'),
                    _WelcomeBenefit('Free core'),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => setState(() => signingIn = true),
                  child: const Text('Find your people'),
                ),
                TextButton(
                  onPressed: () => setState(() => signingIn = true),
                  child: const Text('Already have an account? Sign in'),
                ),
              ] else ...[
                const EditorialArtwork(
                  asset: 'assets/illustrations/moments.png',
                  height: 135,
                ),
                const SizedBox(height: 24),
                Text(
                  'Your people.\nAll in one place.',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Sign in to keep your shared expenses and receipts together across devices.',
                  style: TextStyle(color: HisaabColors.muted),
                ),
                const SizedBox(height: 24),
                if (widget.controller.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      widget.controller.error!,
                      style: const TextStyle(color: HisaabColors.warning),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: AppConfig.configured
                      ? () => widget.controller.login('google')
                      : null,
                  icon: const Icon(Icons.g_mobiledata, size: 26),
                  label: const Text('Continue with Google'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: AppConfig.configured
                      ? () => widget.controller.login('apple')
                      : null,
                  icon: const Icon(Icons.apple),
                  label: const Text('Continue with Apple'),
                ),
              ],
              if (widget.controller.pendingInvite != null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Invitation saved. Sign in to join your circle.'),
                ),
              if (AppConfig.demoEnabled) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => act(context, widget.controller.startDemo),
                  child: const Text('Explore the local demo →'),
                ),
              ],
              if (showProviders || !AppConfig.configured) ...[
                const SizedBox(height: 12),
                Text(
                  AppConfig.configured
                      ? 'Your shared expenses stay private.'
                      : 'Local preview · sign-in needs provider configuration.\nDemo data stays on this device.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: HisaabColors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeBenefit extends StatelessWidget {
  final String label;
  const _WelcomeBenefit(this.label);
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.check_rounded, size: 18, color: HisaabColors.positive),
      const SizedBox(width: 5),
      Text(
        label,
        style: const TextStyle(fontSize: 14, color: HisaabColors.positive),
      ),
    ],
  );
}

Future<void> createGroup(BuildContext context, AppController c) async {
  final name = TextEditingController();
  var type = 'Home';
  final result = await showDialog<Json>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Make a new circle'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: type == 'Direct' ? 'Friend’s name' : 'Group name',
                  hintText: 'e.g. Sunday brunch',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: ['Home', 'Trip', 'Couple', 'Other', 'Direct']
                    .map(
                      (t) => DropdownMenuItem(
                        value: t,
                        child: Text(t == 'Direct' ? 'Direct friend' : t),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => type = v!),
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
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(context, {
                  'name': name.text.trim(),
                  'type': type,
                });
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  if (result == null || !context.mounted) return;
  await act(context, () async {
    final g = await c.request('POST', '/groups', result);
    if (result['type'] == 'Direct') {
      await c.request('POST', '/groups/${g['id']}/members', {
        'displayName': result['name'],
      });
    }
    await c.refresh();
    if (context.mounted) {
      await openPage(context, c, GroupPage(controller: c, groupId: g['id']));
    }
  });
}

Future<void> joinInvite(BuildContext context, AppController c) async {
  final raw = await askText(
    context,
    'Join your people',
    'Paste invitation link or token',
    maxLength: 2048,
  );
  if (raw == null || !context.mounted) return;
  final uri = Uri.tryParse(raw);
  final token =
      uri?.queryParameters['token'] ??
      (uri?.hasScheme == true ? uri!.pathSegments.last : raw);
  await act(context, () async {
    final group = await c.request('POST', '/invites/accept', {'token': token});
    await c.refresh();
    if (context.mounted) {
      await openPage(
        context,
        c,
        GroupPage(controller: c, groupId: group['id']),
      );
    }
  });
}

String activityChangeSummary(Json activity) {
  final changes = object(activity['changes']);
  final before = object(changes['before']), after = object(changes['after']);
  if (before.isEmpty || after.isEmpty) return '';
  final text = <String>[];
  if (before['amountPaise'] != after['amountPaise']) {
    text.add(
      'Amount: ${money(before['amountPaise'])} → ${money(after['amountPaise'])}',
    );
  }
  if (before['date'] != after['date']) {
    text.add('Date: ${before['date']} → ${after['date']}');
  }
  if (before['payerId'] != after['payerId']) text.add('Payer changed');
  if (before['mode'] != after['mode']) {
    text.add('Split: ${before['mode']} → ${after['mode']}');
  }
  final oldShares = object(before['shares']),
      newShares = object(after['shares']);
  if (oldShares.length != newShares.length ||
      oldShares.entries.any((e) => newShares[e.key] != e.value)) {
    text.add('Split allocations changed');
  }
  if (changes['descriptionChanged'] == true) text.add('Description edited');
  if (before['deletedAt'] != after['deletedAt']) {
    text.add(
      after['deletedAt'] == null ? 'Expense restored' : 'Expense deleted',
    );
  }
  return text.join('\n');
}
