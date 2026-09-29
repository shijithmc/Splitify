import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../core/ads.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/phone_auth.dart';
import 'group.dart';
import 'settings.dart';
import 'shared.dart';
import 'receipts.dart';
import 'receipt_viewer.dart';
import 'phone_sign_in.dart';

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
  final _groupSearch = TextEditingController();
  String _groupFilter = 'All';
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
    _groupSearch.dispose();
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
          centerTitle: false,
          titleSpacing: c.tab == 0 ? 0 : 20,
          leadingWidth: c.tab == 0 ? 68 : null,
          leading: c.tab == 0
              ? Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: IconButton(
                    tooltip: 'View account',
                    onPressed: () => _selectTab(3),
                    icon: CircleAvatar(
                      backgroundColor: HisaabColors.peach,
                      foregroundColor: HisaabColors.ink,
                      child: Text(
                        _firstName().characters.first.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                )
              : null,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  [
                    "Hey, ${_firstName()}",
                    'Your people',
                    'The latest',
                    'Account',
                  ][c.tab],
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: c.tab == 0 ? null : 'Outfit',
                    fontSize: c.tab == 0 ? 17 : 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (c.demo) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: HisaabColors.mint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'DEMO',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (c.tab == 0)
              IconButton(
                tooltip: 'View activity',
                onPressed: () => _selectTab(2),
                icon: const Icon(Icons.notifications_none_rounded),
              ),
            if (c.tab == 1)
              OutlinedButton.icon(
                onPressed: c.offline ? null : () => createGroup(context, c),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
              ),
            if (c.tab != 1)
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
                  title: const Text('You’re offline · showing saved balances'),
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
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.tab < 3)
              Material(
                key: const Key('expense-dock'),
                color: HisaabColors.surface,
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: SizedBox(
                          width: double.infinity,
                          child: FloatingActionButton.extended(
                            onPressed: c.offline ? null : () => _addExpense(),
                            backgroundColor: c.offline
                                ? HisaabColors.line
                                : HisaabColors.primary,
                            foregroundColor: c.offline
                                ? HisaabColors.muted
                                : Colors.white,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add expense'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            _navigationBar(),
          ],
        ),
      );
    },
  );

  void _selectTab(int tab) {
    FocusScope.of(context).unfocus();
    c.selectTab(tab);
  }

  Widget _navigationBar() {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return CupertinoTabBar(
        currentIndex: c.tab,
        onTap: _selectTab,
        activeColor: HisaabColors.primary,
        inactiveColor: HisaabColors.muted,
        backgroundColor: HisaabColors.surface,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.house),
            activeIcon: Icon(CupertinoIcons.house_fill),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person_2),
            activeIcon: Icon(CupertinoIcons.person_2_fill),
            label: 'Groups',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.clock),
            activeIcon: Icon(CupertinoIcons.clock_fill),
            label: 'Activity',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.person_crop_circle),
            activeIcon: Icon(CupertinoIcons.person_crop_circle_fill),
            label: 'Account',
          ),
        ],
      );
    }
    return NavigationBar(
      selectedIndex: c.tab,
      onDestinationSelected: _selectTab,
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
          icon: Icon(Icons.history_outlined),
          selectedIcon: Icon(Icons.history),
          label: 'Activity',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: 'Account',
        ),
      ],
    );
  }

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

  String _firstName() {
    final name = (c.user['displayName'] as String?)?.trim();
    return name == null || name.isEmpty
        ? 'there'
        : name.split(RegExp(r'\s+')).first;
  }

  Widget _home() {
    final net = c.balances['netPaise'] as int? ?? 0;
    final owed = c.balances['owedPaise'] as int? ?? 0;
    final owing = c.balances['owingPaise'] as int? ?? 0;
    final activeGroups = c.groups.where((g) => !g.archived).toList();
    return PageBody(
      key: const PageStorageKey('home'),
      children: [
        if (c.groups.isEmpty && owed == 0 && owing == 0) ...[
          EmptyCard(
            icon: Icons.people_outline,
            illustrationAsset: HisaabArt.welcome,
            title: 'Your next shared moment starts here.',
            body: 'Create a group for a trip, a home, or just the two of you.',
            action: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: c.offline ? null : () => createGroup(context, c),
                  child: const Text('Create a group'),
                ),
                TextButton(
                  onPressed: c.offline ? null : () => joinInvite(context, c),
                  child: const Text('Join an invitation'),
                ),
              ],
            ),
          ),
        ] else ...[
          Text(
            'Made for\nsharing.',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 340 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              return EditorialArtwork(
                asset: HisaabArt.sharing,
                height: compact ? 112 : 156,
                borderRadius: BorderRadius.zero,
              );
            },
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            decoration: BoxDecoration(
              color: HisaabColors.mint,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _balanceTotals(owed, owing),
                if (net == 0 && (owed > 0 || owing > 0)) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Your balances cancel out overall',
                    style: TextStyle(fontSize: 13, color: HisaabColors.muted),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (activeGroups.isNotEmpty)
                      FilledButton.icon(
                        onPressed: c.offline
                            ? null
                            : () => _groupAction(attachReceipt: false),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: HisaabColors.ink,
                          side: const BorderSide(color: HisaabColors.muted),
                          minimumSize: const Size(136, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          shape: const StadiumBorder(),
                        ),
                        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                        iconAlignment: IconAlignment.end,
                        label: const Text('Settle up'),
                      ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _groupSearch.clear();
                          _groupFilter = activeGroups.isEmpty
                              ? 'Archived'
                              : 'All';
                        });
                        _selectTab(1);
                      },
                      child: const Text('View balances'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (activeGroups.isNotEmpty)
            SectionTitle(
              'Your groups',
              trailing: TextButton.icon(
                onPressed: () => _selectTab(1),
                icon: const Icon(Icons.chevron_right_rounded, size: 18),
                iconAlignment: IconAlignment.end,
                label: const Text('See all'),
              ),
            ),
          ...activeGroups.take(2).map(_groupTile),
          if (activeGroups.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: c.offline
                    ? null
                    : () => _groupAction(attachReceipt: true),
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: const Text('Attach receipt'),
              ),
            ),
        ],
        if (rows(c.balances['friends']).isNotEmpty) ...[
          const SectionTitle('Balances with friends'),
          Card(
            child: Column(
              children: rows(c.balances['friends']).map((f) {
                final value = f['netPaise'] as int;
                final name = f['displayName'] as String;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: HisaabColors.lilac,
                    foregroundColor: HisaabColors.primary,
                    child: Text(name.characters.firstOrNull ?? '?'),
                  ),
                  title: Text(name),
                  subtitle: Text(
                    value == 0
                        ? 'No net balance'
                        : '${value > 0 ? 'Owes you' : 'You owe'} ${money(value.abs())}',
                    style: TextStyle(
                      color: value < 0
                          ? HisaabColors.warning
                          : HisaabColors.positive,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
        if (c.activity.isNotEmpty) ...[
          SectionTitle(
            'Recent',
            trailing: TextButton(
              onPressed: () => _selectTab(2),
              child: const Text('See all'),
            ),
          ),
          ...c.activity.take(2).map(_activityTile),
        ],
      ],
    );
  }

  Widget _balanceTotals(int owed, int owing) => LayoutBuilder(
    builder: (context, constraints) {
      final style = Theme.of(context).textTheme.displaySmall!.copyWith(
        fontSize: 32,
        color: HisaabColors.balanceAmount,
      );
      final scaler = MediaQuery.textScalerOf(context);
      final columnWidth = (constraints.maxWidth - 28) / 2;
      bool fitsColumn(int amount) {
        final painter = TextPainter(
          text: TextSpan(text: money(amount), style: style),
          textScaler: scaler,
          textDirection: Directionality.of(context),
          maxLines: 1,
        )..layout();
        final fits = painter.width <= columnWidth;
        painter.dispose();
        return fits;
      }

      final owedAmount = _balanceAmount('You are owed', owed, style);
      final owingAmount = _balanceAmount('You owe', owing, style);
      if (constraints.maxWidth < 280 ||
          scaler.scale(1) > 1.3 ||
          !fitsColumn(owed) ||
          !fitsColumn(owing)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            owedAmount,
            const SizedBox(height: 16),
            const Divider(color: HisaabColors.fieldBorder),
            const SizedBox(height: 16),
            owingAmount,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: owedAmount),
            const VerticalDivider(width: 28, color: HisaabColors.fieldBorder),
            Expanded(child: owingAmount),
          ],
        ),
      );
    },
  );

  Widget _balanceAmount(String label, int amount, TextStyle style) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          money(amount),
          key: ValueKey('home-balance-$label'),
          style: style,
        ),
      ),
    ],
  );

  Future<void> _groupAction({required bool attachReceipt}) async {
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
                    attachReceipt
                        ? 'Choose a group for this receipt'
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
        attachReceipt
            ? ReceiptCapturePage(controller: c, group: detail)
            : SettlementPage(controller: c, group: detail),
      );
      if (c.userId == account) await c.refresh();
    });
  }

  Widget _groupTile(Group g) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.3;
      final artworkWidth = compact ? 68.0 : 90.0;
      return Material(
        color: HisaabColors.surface,
        child: Column(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              horizontalTitleGap: 14,
              minVerticalPadding: 10,
              leading: SizedBox(
                width: artworkWidth,
                child: EditorialArtwork(
                  asset: HisaabArt.forGroup(g.type),
                  height: 64,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              title: Text(
                g.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${g.type == 'Direct' ? 'Friend' : g.type} · ${g.count} people${g.archived ? ' · Archived' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    g.net == 0
                        ? 'No net balance'
                        : '${g.net > 0 ? 'You’re owed' : 'You owe'} ${money(g.net.abs())}',
                    style: TextStyle(
                      color: g.net < 0
                          ? HisaabColors.warning
                          : HisaabColors.positive,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () =>
                  openPage(context, c, GroupPage(controller: c, groupId: g.id)),
            ),
            const Divider(),
          ],
        ),
      );
    },
  );

  Widget _groups() {
    final query = _groupSearch.text.trim().toLowerCase();
    final visible = c.groups.where((g) {
      final matchesFilter = switch (_groupFilter) {
        'Groups' => !g.archived && g.type != 'Direct',
        'Friends' => !g.archived && g.type == 'Direct',
        'Archived' => g.archived,
        _ => !g.archived,
      };
      return matchesFilter && g.name.toLowerCase().contains(query);
    }).toList();
    return PageBody(
      key: const PageStorageKey('groups'),
      children: [
        const Text(
          'Little moments. Shared together.',
          style: TextStyle(color: HisaabColors.muted),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _groupSearch,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search groups and friends',
            prefixIcon: const Icon(Icons.search_rounded),
            filled: true,
            fillColor: HisaabColors.line,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: const BorderSide(color: HisaabColors.primary),
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_groupSearch.clear),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ['All', 'Groups', 'Friends', 'Archived']
              .map(
                (filter) => ChoiceChip(
                  label: Text(filter),
                  showCheckmark: false,
                  selected: _groupFilter == filter,
                  onSelected: (_) => setState(() => _groupFilter = filter),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        if (visible.isNotEmpty && query.isEmpty && _groupFilter == 'All')
          LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 340 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              return EditorialArtwork(
                asset: HisaabArt.together,
                height: compact ? 96 : 140,
                borderRadius: BorderRadius.zero,
              );
            },
          ),
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
            illustrationAsset: HisaabArt.welcome,
            title: 'No groups yet',
            body:
                'Create a group for a trip or home, or split directly with a friend.',
            action: FilledButton(
              onPressed: c.offline ? null : () => createGroup(context, c),
              child: const Text('Create a group'),
            ),
          ),
        if (c.groups.isNotEmpty && visible.isEmpty)
          EmptyCard(
            icon: Icons.search_off,
            illustrationAsset: _groupFilter == 'Archived'
                ? HisaabArt.trip
                : HisaabArt.together,
            title: query.isNotEmpty ? 'No matches' : 'Nothing here yet',
            body: query.isNotEmpty
                ? 'Try another name or choose a different filter.'
                : _groupFilter == 'Archived'
                ? 'Archived groups stay here so you can revisit their history.'
                : _groupFilter == 'Friends'
                ? 'Use New to start sharing expenses with a friend.'
                : 'Use New to create a group, or check another filter.',
            action: query.isNotEmpty
                ? TextButton(
                    onPressed: () => setState(() {
                      _groupSearch.clear();
                      _groupFilter = 'All';
                    }),
                    child: const Text('Clear search and filters'),
                  )
                : null,
          ),
        ...visible.map(_groupTile),
        Center(
          child: TextButton.icon(
            onPressed: c.offline ? null : () => joinInvite(context, c),
            icon: const Icon(Icons.link_rounded, size: 20),
            label: const Text('Join an invitation'),
          ),
        ),
      ],
    );
  }

  Widget _activity() => PageBody(
    key: const PageStorageKey('activity'),
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'Your shared moments, in order.',
              style: TextStyle(color: HisaabColors.muted),
            ),
          ),
          const SizedBox(width: 16),
          const SizedBox(
            width: 90,
            child: EditorialArtwork(asset: HisaabArt.receipt, height: 80),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (c.activity.isEmpty)
        const EmptyCard(
          icon: Icons.receipt_long_outlined,
          illustrationAsset: HisaabArt.receipt,
          title: 'No activity yet',
          body: 'Your shared story starts with the first expense.',
        ),
      ...c.activity.map(_activityTile),
    ],
  );

  Widget _activityTile(Json a) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: (a['kind'] as String).contains('Payment')
            ? HisaabColors.mint
            : HisaabColors.peach,
        child: Icon(
          (a['kind'] as String).contains('Payment')
              ? Icons.check_rounded
              : Icons.receipt_long_outlined,
          color: HisaabColors.ink,
        ),
      ),
      title: Text(a['description']),
      subtitle: Text(
        '${a['actorName'] ?? (a['actorId'] == c.userId ? 'You' : 'A member')} · ${c.groups.where((g) => g.id == a['groupId']).firstOrNull?.name ?? 'Shared activity'} · ${(a['createdAt'] as String).split('T').first}${activityChangeSummary(a).isEmpty ? '' : '\n${activityChangeSummary(a)}'}',
      ),
      onTap: () =>
          openPage(context, c, GroupPage(controller: c, groupId: a['groupId'])),
    ),
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
                leading: GroupArtwork(type: g.type, size: 48),
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
                  asset: HisaabArt.welcome,
                  height: (MediaQuery.sizeOf(context).height * .34).clamp(
                    180,
                    300,
                  ),
                  borderRadius: BorderRadius.circular(26),
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 24),
                Text(
                  'Good times.\nShared fairly.',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Trips, dinners and everyday life. Keep money simple.',
                  style: TextStyle(
                    color: HisaabColors.muted,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => setState(() => signingIn = true),
                  child: const Text('Get started'),
                ),
                TextButton(
                  onPressed: () => setState(() => signingIn = true),
                  child: const Text('Already have an account? Sign in'),
                ),
              ] else ...[
                const EditorialArtwork(asset: HisaabArt.sharing, height: 185),
                const SizedBox(height: 24),
                Text(
                  'Welcome to Hisaab',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Your groups, together in one place.',
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
                  style: FilledButton.styleFrom(
                    backgroundColor: HisaabColors.ink,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: AppConfig.configured
                      ? () => widget.controller.login('apple')
                      : null,
                  icon: const Icon(Icons.apple),
                  label: const Text('Continue with Apple'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: AppConfig.configured
                      ? () => widget.controller.login('google')
                      : null,
                  icon: const Icon(Icons.g_mobiledata, size: 26),
                  label: const Text('Continue with Google'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: AppConfig.configured
                      ? () => widget.controller.loginPhone(
                          (repo) => Navigator.of(context).push<Json>(
                            MaterialPageRoute(
                              builder: (_) => PhoneSignInPage(
                                service: PhoneAuthService(
                                  repo,
                                  isCurrent: () =>
                                      mounted && !widget.controller.signedIn,
                                ),
                              ),
                            ),
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.phone_outlined),
                  label: const Text('Continue with phone'),
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

Future<void> createGroup(BuildContext context, AppController c) async {
  final result = await showModalBottomSheet<Json>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _CreateGroupSheet(),
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

class _CreateGroupSheet extends StatefulWidget {
  const _CreateGroupSheet();
  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  final _form = GlobalKey<FormState>();
  final _nameKey = GlobalKey();
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  String _type = 'Home';

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) {
      _nameFocus.requestFocus();
      Scrollable.ensureVisible(_nameKey.currentContext!);
      return;
    }
    Navigator.pop(context, {'name': _name.text.trim(), 'type': _type});
  }

  @override
  Widget build(BuildContext context) => _GroupFormSheet(
    title: _type == 'Direct' ? 'Add a friend' : 'New group',
    action: _type == 'Direct' ? 'Add friend' : 'Create group',
    onSubmit: _submit,
    children: [
      EditorialArtwork(asset: HisaabArt.forGroup(_type), height: 150),
      const SizedBox(height: 24),
      Form(
        key: _form,
        child: TextFormField(
          key: _nameKey,
          controller: _name,
          focusNode: _nameFocus,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: _type == 'Direct' ? 'Friend’s name' : 'Group name',
            hintText: _type == 'Direct' ? 'e.g. Maya' : 'e.g. Sunday brunch',
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? _type == 'Direct'
                    ? 'Enter your friend’s name.'
                    : 'Give your group a name.'
              : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'What’s this group for?',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final type in const [
            ('Home', 'Home', Icons.home_rounded),
            ('Trip', 'Trip', Icons.beach_access_rounded),
            ('Couple', 'Couple', Icons.favorite_rounded),
            ('Other', 'Other', Icons.more_horiz_rounded),
            ('Direct', 'Friend', Icons.people_rounded),
          ])
            ChoiceChip(
              key: ValueKey('group-type-${type.$1}'),
              selected: _type == type.$1,
              showCheckmark: false,
              avatar: Icon(type.$3, size: 20),
              label: Text(type.$2),
              onSelected: (_) => setState(() => _type = type.$1),
            ),
        ],
      ),
      const SizedBox(height: 24),
      const _GroupFormNotice(
        icon: Icons.info_outline_rounded,
        text: 'All balances in INR (₹)',
      ),
      if (_type == 'Direct') ...[
        const SizedBox(height: 12),
        const _GroupFormNotice(
          icon: Icons.person_add_alt_1_rounded,
          text: 'Save your friend a spot. Invite them when you’re ready.',
        ),
      ],
    ],
  );
}

Future<void> joinInvite(BuildContext context, AppController c) async {
  final token = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _JoinInviteSheet(),
  );
  if (token == null || !context.mounted) return;
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

class _JoinInviteSheet extends StatefulWidget {
  const _JoinInviteSheet();
  @override
  State<_JoinInviteSheet> createState() => _JoinInviteSheetState();
}

class _JoinInviteSheetState extends State<_JoinInviteSheet> {
  final _form = GlobalKey<FormState>();
  final _link = TextEditingController();
  String? _token;
  bool _reviewing = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  String? _invitationToken(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    try {
      final queryToken = uri.queryParameters['token'];
      final token =
          queryToken ?? (uri.hasScheme ? uri.pathSegments.lastOrNull : raw);
      return token == null || token.trim().isEmpty ? null : token.trim();
    } on FormatException {
      return null;
    }
  }

  void _submit() {
    if (_reviewing) {
      Navigator.pop(context, _token);
      return;
    }
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _token = _invitationToken(_link.text);
      _reviewing = true;
    });
  }

  @override
  Widget build(BuildContext context) => _GroupFormSheet(
    title: _reviewing ? 'Your invitation' : 'Join your people',
    action: _reviewing ? 'Accept invitation' : 'Review invitation',
    onSubmit: _submit,
    children: [
      const EditorialArtwork(asset: HisaabArt.together, height: 160),
      const SizedBox(height: 24),
      Text(
        _reviewing ? 'You’re invited' : 'There’s a place for you',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 10),
      const Text(
        'Join your friends and keep shared expenses in one place.',
        style: TextStyle(color: HisaabColors.muted, height: 1.5),
      ),
      const SizedBox(height: 24),
      if (!_reviewing)
        Form(
          key: _form,
          child: TextFormField(
            key: const Key('invitation-link'),
            controller: _link,
            maxLength: 2048,
            maxLines: 3,
            minLines: 1,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Invitation link or token',
              hintText: 'Paste the invitation shared with you',
              prefixIcon: Icon(Icons.link_rounded),
              counterText: '',
            ),
            validator: (value) => _invitationToken(value ?? '') == null
                ? 'Paste a complete invitation link or token.'
                : null,
            onFieldSubmitted: (_) => _submit(),
          ),
        )
      else ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Invitation link',
                  style: TextStyle(color: HisaabColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  _link.text.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const _GroupFormNotice(
          icon: Icons.person_outline_rounded,
          text:
              'Accepting adds you to the shared group. If this invitation is for an existing member, you’ll claim that member’s expense history and balances.',
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => _reviewing = false),
          child: const Text('Change invitation'),
        ),
      ],
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Not now'),
      ),
    ],
  );
}

class _GroupFormSheet extends StatelessWidget {
  final String title, action;
  final VoidCallback onSubmit;
  final List<Widget> children;
  const _GroupFormSheet({
    required this.title,
    required this.action,
    required this.onSubmit,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .9,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 24, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: onSubmit, child: Text(action)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _GroupFormNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  const _GroupFormNotice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: HisaabColors.lilac,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(icon, size: 22, color: HisaabColors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(height: 1.5, fontSize: 13)),
        ),
      ],
    ),
  );
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
