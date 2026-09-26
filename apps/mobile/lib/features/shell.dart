import 'dart:async';
import 'package:flutter/material.dart';
import '../core/ads.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../main.dart';
import 'group.dart';
import 'settings.dart';
import 'shared.dart';

class AppShell extends StatefulWidget {
  final AppController controller;
  const AppShell({super.key, required this.controller});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  Timer? _poll;
  bool _active = true;
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
      if (c.loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (!c.signedIn) return Welcome(controller: c);
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
              const Icon(Icons.blur_circular_rounded, size: 30),
              const SizedBox(width: 8),
              const Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'hisaab',
                    style: TextStyle(
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
                color: const Color(0xFFE2ECCC),
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
        floatingActionButton: c.tab < 2
            ? FloatingActionButton.extended(
                onPressed: c.offline ? null : () => _addExpense(),
                icon: const Icon(Icons.add),
                label: const Text('Add expense'),
                backgroundColor: green,
                foregroundColor: Colors.white,
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: c.tab,
          onDestinationSelected: c.selectTab,
          backgroundColor: cream,
          indicatorColor: const Color(0xFFDCE8D5),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.space_dashboard_outlined),
              selectedIcon: Icon(Icons.space_dashboard_rounded),
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
  Widget _home() {
    final net = c.balances['netPaise'] as int? ?? 0;
    return PageBody(
      children: [
        const SizedBox(height: 8),
        Text(
          'A little clarity. A lot less awkward.',
          style: TextStyle(color: ink.withValues(alpha: .65), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Text(
          'Hey, ${c.user['displayName'] ?? 'friend'} 👋',
          style: const TextStyle(
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.account_balance_wallet_outlined,
                    color: Color(0xFFCDDEB2),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      net >= 0 ? 'Overall, you are owed' : 'Overall, you owe',
                      style: const TextStyle(
                        color: Color(0xFFD1E1CE),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  money(net.abs()),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 43,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -2,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: Color(0xFF436052)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _metric(
                      'You are owed',
                      c.balances['owedPaise'] ?? 0,
                      Icons.south_west,
                    ),
                  ),
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
        SectionTitle(
          'Your circles',
          trailing: TextButton(
            onPressed: () => c.selectTab(1),
            child: const Text('See all →'),
          ),
        ),
        if (c.groups.isEmpty)
          const EmptyCard(
            icon: Icons.people_outline,
            title: 'Good company, clear tabs',
            body: 'Create a group or add a friend to split your first expense.',
          )
        else
          ...c.groups.where((g) => !g.archived).take(3).map(_groupTile),
        SectionTitle('Between friends'),
        if (rows(c.balances['friends']).isEmpty)
          const Text('All clear. Your shared balances will appear here.')
        else
          Card(
            child: Column(
              children: rows(c.balances['friends'])
                  .map(
                    (f) => ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFE9EBDD),
                        child: Text(
                          (f['displayName'] as String).characters.first,
                        ),
                      ),
                      title: Text(f['displayName']),
                      subtitle: Text(
                        (f['netPaise'] as int) >= 0 ? 'owes you' : 'you owe',
                      ),
                      trailing: Text(
                        money((f['netPaise'] as int).abs()),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: (f['netPaise'] as int) >= 0 ? green : clay,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFE9EEDD),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const Icon(Icons.spa_outlined, size: 28),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'More memories.\nFewer money conversations.',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 65),
      ],
    );
  }

  Widget _metric(String label, int amount, IconData icon) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: const Color(0xFFCDDEB2), size: 15),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFD1E1CE), fontSize: 12),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FittedBox(
        child: Text(
          money(amount),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 19,
          ),
        ),
      ),
    ],
  );
  Widget _groupTile(Group g) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 12,
        ),
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: g.type == 'Trip'
                ? const Color(0xFFEAE4D6)
                : const Color(0xFFDDE9DC),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(groupIcon(g.type), color: ink),
        ),
        title: Text(
          g.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${g.type == 'Direct' ? 'Friend' : g.type} · ${g.count} people${g.archived ? ' · Archived' : ''}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              g.net == 0
                  ? 'Settled up'
                  : g.net > 0
                  ? 'you get back'
                  : 'you owe',
              style: TextStyle(color: g.net < 0 ? clay : green, fontSize: 11),
            ),
            if (g.net != 0)
              Text(
                money(g.net.abs()),
                style: TextStyle(
                  color: g.net < 0 ? clay : green,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        onTap: () =>
            openPage(context, c, GroupPage(controller: c, groupId: g.id)),
      ),
    ),
  );
  Widget _groups() => PageBody(
    children: [
      SectionTitle(
        'Groups & friends',
        trailing: IconButton(
          tooltip: 'Create group or friend',
          onPressed: c.offline ? null : () => createGroup(context, c),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ),
      const Text('Shared plans. One place for every rupee.'),
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
          title: 'Start your first circle',
          body: 'Home, holidays, your person, or just a friend.',
          action: FilledButton(
            onPressed: () => createGroup(context, c),
            child: const Text('Create a group'),
          ),
        ),
      ...c.groups.map(_groupTile),
      const SizedBox(height: 85),
    ],
  );
  Widget _activity() => PageBody(
    children: [
      const SectionTitle('The paper trail'),
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
              backgroundColor: const Color(0xFFE8EDDF),
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
  int page = 0;
  final pager = PageController();
  final cards = [
    (
      'Good times.\nClear tabs.',
      'From chai runs to Goa trips, keep the money simple and the friendships easy.',
      Icons.local_cafe_outlined,
    ),
    (
      'Every rupee,\nfairly shared.',
      'Split equally, by exact amounts, percentages or shares. See every paisa before you save.',
      Icons.pie_chart_outline,
    ),
    (
      'Your people.\nOn the same page.',
      'Track shared balances, record a payment, and get back to making memories.',
      Icons.people_outline,
    ),
  ];
  @override
  void dispose() {
    pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                children: [
                  const Row(
                    children: [
                      Icon(Icons.blur_circular_rounded, size: 33),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'hisaab',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),
                  SizedBox(
                    height: 350,
                    child: PageView.builder(
                      controller: pager,
                      onPageChanged: (p) => setState(() => page = p),
                      itemCount: 3,
                      itemBuilder: (context, i) => SingleChildScrollView(
                        child: Column(
                          children: [
                            Container(
                              height: 125,
                              width: 125,
                              decoration: BoxDecoration(
                                color: const Color(0xFFDFE8D4),
                                borderRadius: BorderRadius.circular(40),
                              ),
                              child: Icon(cards[i].$3, size: 60, color: ink),
                            ),
                            const SizedBox(height: 26),
                            Text(
                              cards[i].$1,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 38,
                                height: 1.08,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -1.5,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              cards[i].$2,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.6,
                                color: Color(0xFF65746A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      3,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: page == i ? 24 : 6,
                        height: 6,
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: page == i ? green : const Color(0xFFD3D8C9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (widget.controller.pendingInvite != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text(
                        'Invitation saved. Sign in to join your circle.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (widget.controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        widget.controller.error!,
                        style: const TextStyle(color: clay),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: AppConfig.configured
                          ? () => widget.controller.login('google')
                          : null,
                      icon: const Icon(Icons.g_mobiledata, size: 26),
                      label: const Text('Continue with Google'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: AppConfig.configured
                          ? () => widget.controller.login('apple')
                          : null,
                      icon: const Icon(Icons.apple),
                      label: const Text('Continue with Apple'),
                    ),
                  ),
                  if (AppConfig.demoEnabled) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: widget.controller.startDemo,
                      child: const Text('Explore the local demo →'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    AppConfig.configured
                        ? 'Your shared expenses stay private. Always.'
                        : 'Local preview · sign-in needs provider configuration.\nDemo data stays on this device.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6C796D),
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
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
