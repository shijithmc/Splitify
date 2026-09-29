import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/spending.dart';
import 'group.dart';
import 'shared.dart';
import 'spending_import_ui.dart';
import 'spending_share.dart';

String _amount(int paise) => NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: paise % 100 == 0 ? 0 : 2,
).format(paise / 100);

String _date(Json transaction) {
  final date = DateTime.tryParse('${transaction['date']}');
  return date == null
      ? 'Date unavailable'
      : DateFormat('d MMM yyyy').format(date.toLocal());
}

String _accountLabel(Json transaction) {
  if (transaction['source'] == 'Cash') return 'Cash';
  final account = [
    if (transaction['bank'] != null) '${transaction['bank']}',
    if (transaction['accountLast4'] != null)
      '•• ${transaction['accountLast4']}',
  ].join(' ');
  return account.isEmpty ? 'Account not available' : account;
}

IconData _categoryIcon(String category) => switch (category.toLowerCase()) {
  final name when name.contains('food') => Icons.restaurant_rounded,
  final name when name.contains('grocer') => Icons.shopping_cart_outlined,
  final name when name.contains('travel') || name.contains('transport') =>
    Icons.train_outlined,
  final name when name.contains('shop') => Icons.shopping_bag_outlined,
  final name when name.contains('bill') => Icons.receipt_long_outlined,
  final name when name.contains('health') => Icons.favorite_border_rounded,
  final name when name.contains('entertain') => Icons.headphones_rounded,
  final name when name.contains('transfer') => Icons.swap_horiz_rounded,
  _ => Icons.category_outlined,
};

Color _categoryColor(String category) => switch (category.toLowerCase()) {
  final name when name.contains('food') => HisaabColors.peach,
  final name when name.contains('grocer') => HisaabColors.mint,
  final name when name.contains('travel') || name.contains('transport') =>
    HisaabColors.lime,
  _ => HisaabColors.lilac,
};

/// Private spending is a destination within Home, not a fifth navigation tab.
class SpendingHomeCard extends StatefulWidget {
  final AppController controller;
  const SpendingHomeCard({super.key, required this.controller});

  @override
  State<SpendingHomeCard> createState() => _SpendingHomeCardState();
}

class _SpendingHomeCardState extends State<SpendingHomeCard> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      if (!c.spendingAvailable) return const SizedBox.shrink();
      final spending = c.spending;
      return ListenableBuilder(
        listenable: spending,
        builder: (context, _) => Material(
          color: HisaabColors.lime,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('spending-home-card'),
            onTap: () => openPage(context, c, SpendingPage(controller: c)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Your spending',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const _PrivateLabel(compact: true),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final showArt =
                          constraints.maxWidth >= 290 &&
                          MediaQuery.textScalerOf(context).scale(16) < 24;
                      final content = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (spending.loaded &&
                              spending.dailyPaise != null) ...[
                            _Money(spending.dailyPaise!, size: 38),
                            const Text('Daily budget'),
                          ] else ...[
                            Text(
                              spending.loading
                                  ? 'Getting your spending…'
                                  : 'A little clarity, just for you.',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Track payments. Make room for what matters.',
                            ),
                          ],
                          const SizedBox(height: 12),
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  'View spending',
                                  style: TextStyle(
                                    color: HisaabColors.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(
                                Icons.arrow_forward_rounded,
                                color: HisaabColors.primary,
                                size: 20,
                              ),
                            ],
                          ),
                        ],
                      );
                      return showArt
                          ? Row(
                              children: [
                                Expanded(child: content),
                                const SizedBox(width: 12),
                                const _WalletArtwork(height: 112),
                              ],
                            )
                          : content;
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class SpendingPage extends StatefulWidget {
  final AppController controller;
  const SpendingPage({super.key, required this.controller});

  @override
  State<SpendingPage> createState() => _SpendingPageState();
}

class _SpendingPageState extends State<SpendingPage> {
  late final SpendingController spending;
  late final String owner;
  late final Object? repository;
  final search = TextEditingController();
  int tab = 0;
  String category = 'All';
  bool busy = false;
  AppController get c => widget.controller;
  bool get current =>
      c.spendingAvailable &&
      c.userId == owner &&
      identical(c.repository, repository);

  @override
  void initState() {
    super.initState();
    owner = c.userId;
    repository = c.repository;
    spending = c.spending;
    _initialize();
  }

  Future<void> _initialize() async {
    await spending.initialize();
    if (mounted && current) await c.refreshSpendingLinks();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || !current) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted && current) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        title: 'HiSaab personal spending',
        files: [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(spending.exportCsv())),
            mimeType: 'text/csv',
            name: 'hisaab-personal-spending.csv',
          ),
        ],
        fileNameOverrides: const ['hisaab-personal-spending.csv'],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  });

  Future<void> _clear() async {
    final accepted = await confirm(
      context,
      'Delete private spending?',
      'This removes your personal transactions, budgets and category rules from this device and stops SMS tracking. Group expenses you already shared remain in their groups. An interrupted share may also exist there; check Groups before importing and sharing it again.',
      action: 'Delete private data',
    );
    if (!mounted || !accepted || !current) return;
    await _run(() async {
      await c.clearPrivateSpending();
      if (mounted && current) message(context, 'Private spending deleted');
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, spending]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Your spending'),
        actions: current
            ? [
                TextButton(
                  onPressed: busy ? null : () => openSpendingImport(context, c),
                  child: const Text('Import'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Spending options',
                  onSelected: (value) {
                    if (value == 'export') {
                      _export();
                    } else {
                      _clear();
                    }
                  },
                  enabled: !busy && spending.loaded,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'export', child: Text('Export CSV')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete private data'),
                    ),
                  ],
                ),
              ]
            : null,
      ),
      body: !current
          ? const Center(child: Text('Sign in again to see your spending.'))
          : !spending.loaded
          ? Center(
              child: spending.error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(spending.error!),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: spending.initialize,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
            )
          : PageBody(
              children: [
                const _PrivateLabel(),
                if (c.demo)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Demo · Sample data, session only',
                      style: TextStyle(color: HisaabColors.muted, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < 3; i++)
                        Padding(
                          padding: EdgeInsets.only(right: i == 2 ? 0 : 8),
                          child: ChoiceChip(
                            label: Text(
                              ['Overview', 'Transactions', 'Budgets'][i],
                            ),
                            selected: tab == i,
                            showCheckmark: false,
                            selectedColor: HisaabColors.primary,
                            labelStyle: TextStyle(
                              color: tab == i ? Colors.white : HisaabColors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            onSelected: (_) => setState(() => tab = i),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (busy) const LinearProgressIndicator(),
                if (tab == 0) ..._overview(),
                if (tab == 1) ..._transactions(),
                if (tab == 2) ..._budgets(),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _cash(context, c, spending),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add cash expense'),
                ),
                const SizedBox(height: 16),
                const _Note(
                  icon: Icons.lock_outline_rounded,
                  text:
                      'Personal payments stay on this device. You choose what to share with a group.',
                ),
              ],
            ),
    ),
  );

  List<Widget> _overview() => [
    _dailyCard(),
    const SizedBox(height: 10),
    _Note(
      icon: Icons.schedule_rounded,
      text: spending.lastImport == null
          ? 'Add cash or import payments to get started.'
          : 'Last import · ${DateFormat('d MMM, h:mm a').format(spending.lastImport!.toLocal())}',
    ),
    Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${DateFormat('MMMM').format(DateTime.now())} budgets',
              style: const TextStyle(
                fontFamily: 'Outfit',
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => tab = 2),
            child: const Text('Edit'),
          ),
        ],
      ),
    ),
    if (spending.budgets.isEmpty)
      _ActionCard(
        title: 'Give your month a little shape',
        body: 'Choose category limits to see your daily budget.',
        icon: Icons.pie_chart_outline_rounded,
        action: 'Set a budget',
        onPressed: () => _editBudget(context, c, spending),
      )
    else ...[
      Text(
        '${_amount(spending.spendingPaise)} spent · ${_amount(spending.budgetPaise)} budget',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 10),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              for (final entry in spending.budgets.entries.take(3))
                _BudgetRow(
                  category: entry.key,
                  spent: spending.spentFor(entry.key),
                  budget: entry.value,
                ),
            ],
          ),
        ),
      ),
    ],
    SectionTitle(
      'Recent payments',
      trailing: TextButton(
        onPressed: () => setState(() => tab = 1),
        child: const Text('See all'),
      ),
    ),
    if (spending.transactions.isEmpty)
      _ActionCard(
        title: 'Start with one small step',
        body: 'Import your payments or add your first cash expense.',
        icon: Icons.receipt_long_outlined,
        action: 'Import payments',
        onPressed: () => openSpendingImport(context, c),
      )
    else
      for (final transaction in spending.transactions.take(3))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _TransactionRow(
            transaction: transaction,
            onTap: () => _open(transaction),
          ),
        ),
  ];

  void _explainDailyBudget() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('How it’s calculated'),
      content: const Text(
        'Daily budget is your remaining category budget divided by the days until your next chosen payday, rounded down. It uses this month’s included spending. Shared payments count only your confirmed share.\n\nThis is a planning guide, not your bank balance or a guarantee of what you can afford. Missing payments can change the amount.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Got it'),
        ),
      ],
    ),
  );

  Widget _dailyCard() {
    final daily = spending.dailyPaise;
    final contents = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Daily budget',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'How it’s calculated',
              onPressed: _explainDailyBudget,
              icon: const Icon(Icons.info_outline_rounded, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (daily == null)
          Text(
            'Make room for today.',
            style: Theme.of(context).textTheme.headlineMedium,
          )
        else
          _Money(daily, size: 48),
        const SizedBox(height: 6),
        Text(
          daily == null
              ? 'Set category budgets and your payday to see your daily amount.'
              : '${_amount(spending.remainingPaise)} left · ${spending.daysToPayday} days to payday',
        ),
        if (spending.remainingPaise < 0 && spending.budgetPaise > 0)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'You’re over your monthly budget.',
              style: TextStyle(color: HisaabColors.warning),
            ),
          ),
      ],
    );
    return Container(
      key: const Key('spending-daily-budget'),
      decoration: BoxDecoration(
        color: HisaabColors.lime,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showArt =
              constraints.maxWidth >= 300 &&
              MediaQuery.textScalerOf(context).scale(16) < 22 &&
              (daily == null || _amount(daily).length < 10);
          return showArt
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: contents),
                    const SizedBox(width: 8),
                    const _WalletArtwork(height: 128),
                  ],
                )
              : contents;
        },
      ),
    );
  }

  List<Widget> _transactions() {
    final query = search.text.trim().toLowerCase();
    final transactions = spending.transactions
        .where(
          (t) =>
              (category == 'All' || t['category'] == category) &&
              '${t['title']} ${t['bank'] ?? ''} ${t['category']}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return [
      TextField(
        controller: search,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Search payments',
          prefixIcon: Icon(Icons.search_rounded),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: category,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Category'),
        items: ['All', ...spending.categories]
            .map(
              (value) => DropdownMenuItem(
                value: value,
                child: Text(value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: (value) => setState(() => category = value ?? 'All'),
      ),
      const SizedBox(height: 16),
      Text(
        '${transactions.length} ${transactions.length == 1 ? 'payment' : 'payments'}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 10),
      if (transactions.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No payments here yet. Try another search or import your first payment.',
            textAlign: TextAlign.center,
          ),
        ),
      for (final transaction in transactions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _TransactionRow(
            transaction: transaction,
            onTap: () => _open(transaction),
          ),
        ),
    ];
  }

  List<Widget> _budgets() => [
    Text(
      'A plan that feels like you',
      style: Theme.of(context).textTheme.headlineMedium,
    ),
    const SizedBox(height: 8),
    const Text('Monthly category limits, with room for real life.'),
    const SizedBox(height: 16),
    Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const Icon(Icons.calendar_month_outlined),
        title: const Text('Your payday'),
        subtitle: Text(
          spending.payday == null
              ? 'Set your usual day of the month'
              : 'Day ${spending.payday} of each month',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _editPayday(context, c, spending),
      ),
    ),
    const SizedBox(height: 12),
    for (final entry in spending.budgets.entries)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _editBudget(context, c, spending, category: entry.key),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: _BudgetRow(
                category: entry.key,
                spent: spending.spentFor(entry.key),
                budget: entry.value,
                editing: true,
              ),
            ),
          ),
        ),
      ),
    if (spending.budgets.isEmpty)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Choose your first category below. You can adjust it anytime.',
        ),
      ),
    OutlinedButton.icon(
      onPressed: () => _editBudget(context, c, spending),
      icon: const Icon(Icons.add_rounded),
      label: const Text('Add category budget'),
    ),
    const SizedBox(height: 12),
    const _Note(
      icon: Icons.info_outline_rounded,
      text:
          'Budgets reset each calendar month. Your payday sets the daily calculation; it does not change the budget period.',
    ),
  ];

  void _open(Json transaction) => openPage(
    context,
    c,
    SpendingTransactionPage(
      controller: c,
      transactionId: transaction['id'] as String,
    ),
  );
}

class SpendingTransactionPage extends StatefulWidget {
  final AppController controller;
  final String transactionId;
  const SpendingTransactionPage({
    super.key,
    required this.controller,
    required this.transactionId,
  });

  @override
  State<SpendingTransactionPage> createState() =>
      _SpendingTransactionPageState();
}

class _SpendingTransactionPageState extends State<SpendingTransactionPage> {
  late final SpendingController spending;
  late final String owner;
  late final Object? repository;
  bool busy = false;
  AppController get c => widget.controller;
  bool get current =>
      c.spendingAvailable &&
      c.userId == owner &&
      identical(c.repository, repository);

  @override
  void initState() {
    super.initState();
    owner = c.userId;
    repository = c.repository;
    spending = c.spending;
    c.refreshSpendingLinks();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || !current) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted && current) message(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _category(Json transaction) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => _SessionSurface(
        controller: c,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .65,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text(
                'Choose a category',
                style: Theme.of(ctx).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Future payments to the same merchant will use your choice.',
              ),
              const SizedBox(height: 12),
              for (final category in spending.categories)
                ListTile(
                  minVerticalPadding: 12,
                  leading: _CategoryBadge(category),
                  title: Text(category),
                  trailing: transaction['category'] == category
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(ctx, category),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || chosen == null || !current) return;
    await _run(
      () => spending.update(widget.transactionId, {'category': chosen}),
    );
  }

  Future<void> _remove() async {
    final accepted = await confirm(
      context,
      'Delete this private payment?',
      'This removes it from personal spending. Any group expense already shared remains in its group.',
      action: 'Delete payment',
    );
    if (!mounted || !accepted || !current) return;
    await _run(() async {
      await spending.remove(widget.transactionId);
      if (mounted && current) Navigator.pop(context);
    });
  }

  Future<void> _reviewRefund(Json transaction) => showDialog<void>(
    context: context,
    builder: (_) => _SessionSurface(
      controller: c,
      dialog: true,
      child: _RefundDialog(spending: spending, transaction: transaction),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, spending]),
    builder: (context, _) {
      final transaction = current
          ? spending.transactions
                .where((t) => t['id'] == widget.transactionId)
                .firstOrNull
          : null;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Your spending'),
          actions: transaction == null
              ? null
              : [
                  IconButton(
                    tooltip: 'Delete private payment',
                    onPressed: busy ? null : _remove,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
        ),
        body: transaction == null
            ? const Center(
                child: Text('This private payment is no longer available.'),
              )
            : PageBody(
                children: [
                  const Center(child: _PrivateLabel()),
                  const SizedBox(height: 8),
                  const EditorialArtwork(asset: HisaabArt.receipt, height: 152),
                  Text(
                    '${transaction['title']}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  _Money(
                    transaction['amountPaise'] as int,
                    size: 44,
                    centered: true,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${transaction['kind'] == 'debit'
                        ? 'Payment'
                        : transaction['kind'] == 'credit'
                        ? 'Money received'
                        : transaction['kind'] == 'refund'
                        ? 'Refund'
                        : 'Transfer'} · ${_date(transaction)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          leading: _CategoryBadge('${transaction['category']}'),
                          title: const Text('Category'),
                          subtitle: Text('${transaction['category']}'),
                          trailing: const Icon(Icons.edit_outlined, size: 20),
                          onTap: busy ? null : () => _category(transaction),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.credit_card_rounded,
                          label: 'Paid with',
                          value: _accountLabel(transaction),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        _InfoRow(
                          icon: Icons.chat_bubble_outline_rounded,
                          label: 'Source',
                          value: '${transaction['source']}',
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                  const SizedBox(height: 14),
                  if (transaction['kind'] == 'refund') ...[
                    Container(
                      decoration: BoxDecoration(
                        color: HisaabColors.mint,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Review refund',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Choose how much belongs to your personal budget. For a shared purchase, review the group expense too.',
                          ),
                          const SizedBox(height: 10),
                          Text(
                            transaction['refundBudgetPaise'] == null
                                ? 'Not counted in budgets until reviewed.'
                                : 'Personal refund ${_amount(transaction['refundBudgetPaise'] as int)}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => _reviewRefund(transaction),
                            child: const Text('Set personal refund'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (transaction['expenseId'] != null) ...[
                    Container(
                      decoration: BoxDecoration(
                        color: transaction['linkNeedsReview'] == true
                            ? HisaabColors.peach
                            : HisaabColors.mint,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            transaction['linkNeedsReview'] == true
                                ? 'Review this shared payment'
                                : 'Shared with your group',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            transaction['excluded'] == true
                                ? 'This payment is excluded from budgets. Your group expense is unchanged.'
                                : transaction['linkNeedsReview'] == true
                                ? 'Group expense changed. Full payment counted until reviewed.'
                                : 'Your budget counts ${_amount(transaction['sharePaise'] as int)}. Your bank details stay private.',
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _run(() async {
                                    await openPage(
                                      context,
                                      c,
                                      GroupPage(
                                        controller: c,
                                        groupId:
                                            transaction['groupId'] as String,
                                      ),
                                    );
                                    if (mounted && current) {
                                      await c.refreshSpendingLinks();
                                    }
                                  }),
                            child: const Text('View group'),
                          ),
                        ],
                      ),
                    ),
                  ] else if (transaction['kind'] == 'debit') ...[
                    Container(
                      decoration: BoxDecoration(
                        color: HisaabColors.peach,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          if (MediaQuery.textScalerOf(context).scale(16) < 24)
                            const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: SizedBox(
                                width: 74,
                                child: EditorialArtwork(
                                  asset: HisaabArt.sharing,
                                  height: 72,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  transaction['pendingShare'] != null
                                      ? 'One more step to share'
                                      : 'Was this a shared moment?',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  transaction['pendingShare'] != null
                                      ? 'Check your earlier share before changing this payment.'
                                      : 'Add it to a group and split the cost.',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => _run(
                              () => shareSpendingTransaction(
                                context,
                                c,
                                transaction,
                              ),
                            ),
                      child: Text(
                        transaction['pendingShare'] != null
                            ? 'Finish sharing'
                            : 'Add to a group',
                      ),
                    ),
                    if (transaction['pendingShare'] == null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _run(
                                () => shareSpendingTransaction(
                                  context,
                                  c,
                                  transaction,
                                  linkExisting: true,
                                ),
                              ),
                        child: const Text('Link existing expense'),
                      ),
                  ],
                  const SizedBox(height: 12),
                  Card(
                    child: SwitchListTile.adaptive(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      title: const Text('Exclude from budgets'),
                      subtitle: const Text(
                        'Keep the payment in your history without counting it as spending.',
                      ),
                      value: transaction['excluded'] == true,
                      onChanged: busy
                          ? null
                          : (value) => _run(
                              () => spending.update(widget.transactionId, {
                                'excluded': value,
                              }),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _Note(
                    icon: Icons.lock_outline_rounded,
                    text:
                        'Private until you choose to share. Your group only sees the expense details you confirm.',
                  ),
                ],
              ),
      );
    },
  );
}

/// The illustration includes generous empty canvas; crop that canvas in the
/// layout so its character remains legible at card size.
class _WalletArtwork extends StatelessWidget {
  final double height;
  const _WalletArtwork({required this.height});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 100,
    height: height,
    child: ClipRect(
      child: Transform.scale(
        scale: 2,
        child: Image.asset(
          HisaabArt.wallet,
          fit: BoxFit.contain,
          cacheWidth: 600,
          excludeFromSemantics: true,
        ),
      ),
    ),
  );
}

class _Money extends StatelessWidget {
  final int paise;
  final double size;
  final bool centered;
  const _Money(this.paise, {this.size = 40, this.centered = false});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final value = _amount(paise);
      final style = TextStyle(
        fontFamily: 'Outfit',
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 1.12,
        letterSpacing: -.8,
        color: HisaabColors.ink,
      );
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final fitted = painter.width > constraints.maxWidth
          ? (size * constraints.maxWidth / painter.width).clamp(24.0, size)
          : size;
      painter.dispose();
      return Semantics(
        label: '${decimal(paise)} rupees',
        excludeSemantics: true,
        child: Text(
          value,
          style: style.copyWith(fontSize: fitted),
          textAlign: centered ? TextAlign.center : TextAlign.start,
        ),
      );
    },
  );
}

class _PrivateLabel extends StatelessWidget {
  final bool compact;
  const _PrivateLabel({this.compact = false});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(
        Icons.lock_outline_rounded,
        size: 16,
        color: HisaabColors.muted,
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          compact ? 'Only you' : 'Private to you',
          style: const TextStyle(color: HisaabColors.muted, fontSize: 13),
        ),
      ),
    ],
  );
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Note({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: HisaabColors.muted),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ],
  );
}

class _CategoryBadge extends StatelessWidget {
  final String category;
  const _CategoryBadge(this.category);
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: _categoryColor(category),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        _categoryIcon(category),
        size: 23,
        color: category.toLowerCase().contains('food')
            ? HisaabColors.primary
            : HisaabColors.deep,
      ),
    ),
  );
}

class _BudgetRow extends StatelessWidget {
  final String category;
  final int spent, budget;
  final bool editing;
  const _BudgetRow({
    required this.category,
    required this.spent,
    required this.budget,
    this.editing = false,
  });
  @override
  Widget build(BuildContext context) {
    final ratio = budget > 0 ? spent / budget : 0.0;
    final color = ratio >= 1
        ? HisaabColors.warning
        : ratio >= .8
        ? HisaabColors.primary
        : HisaabColors.positive;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryBadge(category),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        category,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (editing)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(Icons.edit_outlined, size: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_amount(spent)} / ${_amount(budget)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 7),
                Semantics(
                  label:
                      '$category budget ${(ratio * 100).round()} percent used',
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(8),
                    backgroundColor: HisaabColors.lilac,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ratio >= 1
                      ? spent == budget
                            ? 'Budget reached'
                            : '${_amount(spent - budget)} over budget'
                      : '${(ratio * 100).round()}% used',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ratio >= .8 ? color : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  final Json transaction;
  final VoidCallback onTap;
  const _TransactionRow({required this.transaction, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CategoryBadge('${transaction['category']}'),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${transaction['title']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${transaction['category']} · ${_date(transaction)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${transaction['kind'] == 'credit' || transaction['kind'] == 'refund' ? '+' : ''}${_amount(transaction['amountPaise'] as int)}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (transaction['excluded'] == true)
                    const Text(
                      'Excluded from budgets',
                      style: TextStyle(fontSize: 13, color: HisaabColors.muted),
                    ),
                  if (transaction['kind'] == 'refund')
                    Text(
                      transaction['refundBudgetPaise'] == null
                          ? 'Refund · Needs review'
                          : 'Personal refund ${_amount(transaction['refundBudgetPaise'] as int)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: transaction['refundBudgetPaise'] == null
                            ? HisaabColors.warning
                            : HisaabColors.positive,
                      ),
                    ),
                  if (transaction['expenseId'] != null)
                    Text(
                      transaction['linkNeedsReview'] == true
                          ? 'Group expense changed · review needed'
                          : 'Your share ${_amount(transaction['sharePaise'] as int)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: HisaabColors.positive,
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 10),
              child: Icon(Icons.chevron_right_rounded, size: 20),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ActionCard extends StatelessWidget {
  final String title, body, action;
  final IconData icon;
  final VoidCallback onPressed;
  const _ActionCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.action,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: HisaabColors.primary),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body),
          const SizedBox(height: 8),
          TextButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(16) >= 23;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: HisaabColors.muted),
            const SizedBox(width: 12),
            if (stacked)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(value),
                  ],
                ),
              )
            else ...[
              SizedBox(
                width: 74,
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(value)),
            ],
          ],
        );
      },
    ),
  );
}

Future<void> _cash(
  BuildContext context,
  AppController controller,
  SpendingController spending,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => _SessionSurface(
    controller: controller,
    child: _CashSheet(spending: spending),
  ),
);

/// A modal keeps its original owner even if authentication changes underneath.
class _SessionSurface extends StatefulWidget {
  final AppController controller;
  final Widget child;
  final bool dialog;
  const _SessionSurface({
    required this.controller,
    required this.child,
    this.dialog = false,
  });
  @override
  State<_SessionSurface> createState() => _SessionSurfaceState();
}

class _SessionSurfaceState extends State<_SessionSurface> {
  late final String account;
  late final Object? repository;
  @override
  void initState() {
    super.initState();
    // Capture eagerly; a lazy field first read after sign-out could bind to the
    // new identity instead of the account that opened this form.
    account = widget.controller.userId;
    repository = widget.controller.repository;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final current =
          widget.controller.spendingAvailable &&
          widget.controller.userId == account &&
          identical(widget.controller.repository, repository);
      if (current) return widget.child;
      final close = TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      );
      if (widget.dialog) {
        return AlertDialog(
          title: const Text('Session ended'),
          content: const Text('Sign in again to edit your private spending.'),
          actions: [close],
        );
      }
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Sign in again to edit your private spending.'),
            const SizedBox(height: 16),
            close,
          ],
        ),
      );
    },
  );
}

class _RefundDialog extends StatefulWidget {
  final SpendingController spending;
  final Json transaction;
  const _RefundDialog({required this.spending, required this.transaction});
  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  late final amount = TextEditingController(
    text: widget.transaction['refundBudgetPaise'] == null
        ? ''
        : decimal(widget.transaction['refundBudgetPaise'] as int),
  );
  bool saving = false;
  String? error;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    int value;
    final bankAmount = widget.transaction['amountPaise'] as int;
    try {
      value = parsePaise(amount.text, allowZero: true);
      if (value > bankAmount) throw const FormatException();
    } catch (_) {
      setState(
        () => error = 'Enter an amount from ₹0 to ${_amount(bankAmount)}.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.spending.update(widget.transaction['id'] as String, {
        'refundBudgetPaise': value,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set personal refund'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bank refund: ${_amount(widget.transaction['amountPaise'] as int)}. Enter only the amount that belongs to your budget. Use ₹0 if none belongs to you.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amount,
            enabled: !saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Personal refund amount',
              prefixText: '₹ ',
              errorText: error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Saving…' : 'Save personal refund'),
      ),
    ],
  );
}

class _CashSheet extends StatefulWidget {
  final SpendingController spending;
  const _CashSheet({required this.spending});
  @override
  State<_CashSheet> createState() => _CashSheetState();
}

class _CashSheetState extends State<_CashSheet> {
  final title = TextEditingController();
  final amount = TextEditingController();
  final form = GlobalKey<FormState>();
  late String category = widget.spending.categories.first;
  DateTime date = DateTime.now();
  bool saving = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    amount.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.spending.add({
        'title': title.text.trim(),
        'amountPaise': parsePaise(amount.text),
        'date': day(date),
        'category': category,
        'source': 'Cash',
        'kind': 'debit',
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'A little cash, accounted for',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text('Private to you. You can share it with a group later.'),
            const SizedBox(height: 20),
            TextFormField(
              controller: amount,
              autofocus: true,
              enabled: !saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '₹ ',
              ),
              validator: (value) {
                try {
                  parsePaise(value ?? '');
                  return null;
                } catch (_) {
                  return 'Enter an amount between ₹0.01 and ₹1,00,00,000.';
                }
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: title,
              enabled: !saving,
              maxLength: 100,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What was it for?',
                hintText: 'Coffee with a friend',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Give this payment a short name.'
                  : null,
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: widget.spending.categories
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text(value, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: saving
                  ? null
                  : (value) => setState(() => category = value!),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (mounted && selected != null) {
                        setState(() => date = selected);
                      }
                    },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(DateFormat('d MMM yyyy').format(date)),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: const TextStyle(color: HisaabColors.warning),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(saving ? 'Saving…' : 'Save cash expense'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _editBudget(
  BuildContext context,
  AppController controller,
  SpendingController spending, {
  String? category,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SessionSurface(
    controller: controller,
    dialog: true,
    child: _BudgetDialog(spending: spending, category: category),
  ),
);

class _BudgetDialog extends StatefulWidget {
  final SpendingController spending;
  final String? category;
  const _BudgetDialog({required this.spending, this.category});
  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late String category = widget.category ?? widget.spending.categories.first;
  late final amount = TextEditingController(
    text: widget.category == null
        ? ''
        : decimal(widget.spending.budgets[category] ?? 0),
  );
  bool saving = false;
  String? error;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  Future<void> save({bool remove = false}) async {
    if (saving) return;
    int value;
    try {
      value = remove ? 0 : parsePaise(amount.text);
    } catch (_) {
      setState(() => error = 'Enter a monthly limit greater than ₹0.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.spending.setBudget(category, value);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.category == null ? 'Add a monthly budget' : 'Edit monthly budget',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: category,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category'),
            items: widget.spending.categories
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(value, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: saving || widget.category != null
                ? null
                : (value) => setState(() {
                    category = value!;
                    final existing = widget.spending.budgets[category];
                    amount.text = existing == null ? '' : decimal(existing);
                  }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amount,
            enabled: !saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Monthly limit',
              prefixText: '₹ ',
              errorText: error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.category != null)
        TextButton(
          onPressed: saving ? null : () => save(remove: true),
          child: const Text('Remove'),
        ),
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Saving…' : 'Save budget'),
      ),
    ],
  );
}

Future<void> _editPayday(
  BuildContext context,
  AppController controller,
  SpendingController spending,
) => showDialog<void>(
  context: context,
  builder: (_) => _SessionSurface(
    controller: controller,
    dialog: true,
    child: _PaydayDialog(spending: spending),
  ),
);

class _PaydayDialog extends StatefulWidget {
  final SpendingController spending;
  const _PaydayDialog({required this.spending});
  @override
  State<_PaydayDialog> createState() => _PaydayDialogState();
}

class _PaydayDialogState extends State<_PaydayDialog> {
  late final input = TextEditingController(
    text: widget.spending.payday?.toString() ?? '',
  );
  bool saving = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = int.tryParse(input.text.trim());
    if (value == null || value < 1 || value > 31) {
      setState(() => error = 'Choose a day from 1 to 31.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.spending.setPayday(value);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('When is payday?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose your usual day of the month. Shorter months use their last day.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            enabled: !saving,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Day of month',
              hintText: 'For example, 28',
              errorText: error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? 'Saving…' : 'Save payday'),
      ),
    ],
  );
}
