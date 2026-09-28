import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../main.dart';
import 'shared.dart';
import 'receipts.dart';
import 'expense_calculator.dart';

class ExpensePage extends StatefulWidget {
  final AppController controller;
  final Group group;
  final Expense? expense;
  const ExpensePage({
    super.key,
    required this.controller,
    required this.group,
    this.expense,
  });
  @override
  State<ExpensePage> createState() => _ExpensePageState();
}

class _ExpensePageState extends State<ExpensePage> {
  final description = TextEditingController(), amount = TextEditingController();
  final Map<String, TextEditingController> allocations = {};
  final Set<String> selected = {};
  String mode = 'Equal', date = day(DateTime.now());
  String? payer, error;
  bool saving = false;
  final id = const Uuid().v4();
  Group get g => widget.group;
  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    mode = e?.mode ?? 'Equal';
    date = e?.date ?? date;
    payer =
        e?.payer ??
        g.participant(widget.controller.userId) ??
        g.members.firstOrNull?.id;
    description.text = e?.description ?? '';
    amount.text = e == null ? '' : decimal(e.amount);
    for (final member in g.members) {
      final old = e?.participants
          .where((p) => p['participantId'] == member.id)
          .firstOrNull;
      if ((e == null && !member.left && !member.deleted) || old != null) {
        selected.add(member.id);
      }
      allocations[member.id] = TextEditingController(
        text: old == null
            ? (mode == 'Shares' ? '1' : '')
            : mode == 'Percentage' || mode == 'Exact'
            ? decimal(old['value'])
            : '${old['value']}',
      );
    }
  }

  @override
  void dispose() {
    description.dispose();
    amount.dispose();
    for (final input in allocations.values) {
      input.dispose();
    }
    super.dispose();
  }

  Map<String, int> inputs() => {
    for (final member in selected)
      member: mode == 'Equal'
          ? 1
          : mode == 'Shares'
          ? int.tryParse(allocations[member]!.text) ?? 0
          : parsePaise(allocations[member]!.text, allowZero: true),
  };
  (Map<String, int>?, String?) preview() {
    try {
      return (splitAmount(parsePaise(amount.text), mode, inputs()), null);
    } on FormatException catch (e) {
      return (null, e.message);
    } catch (_) {
      return (null, 'Enter amounts for everyone in this split.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (shares, validation) = preview();
    final ordered = selected.toList()..sort();
    final payerName =
        payer != null && payer == g.participant(widget.controller.userId)
        ? 'you'
        : payer == null
        ? 'Choose a payer'
        : g.memberName(payer!);
    final splitSummary = mode == 'Equal' ? 'split equally' : '$mode split';
    final peopleSummary =
        '${selected.length} ${selected.length == 1 ? 'person' : 'people'}';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.expense == null ? 'Add an expense' : 'Edit expense'),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageBody(
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.people_outline,
                      size: 20,
                      color: HisaabColors.teal,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        g.name,
                        style: const TextStyle(color: HisaabColors.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      TextField(
                        controller: description,
                        maxLength: 100,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'What was it for?',
                          hintText: 'e.g. Dinner, groceries, taxi',
                          counterText: '',
                          prefixIcon: Icon(Icons.receipt_long_outlined),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const Divider(height: 1, indent: 48),
                      TextField(
                        controller: amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: HisaabColors.ink,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Total amount',
                          prefixIcon: const Icon(Icons.currency_rupee),
                          hintText: '0.00',
                          suffixIcon: IconButton(
                            tooltip: 'Open calculator',
                            onPressed: saving
                                ? null
                                : () async {
                                    final paise = await openPage<int>(
                                      context,
                                      widget.controller,
                                      ExpenseCalculatorPage(
                                        initialAmount: amount.text,
                                      ),
                                    );
                                    if (paise != null && mounted) {
                                      setState(
                                        () => amount.text = decimal(paise),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.calculate_outlined),
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: payer,
                        decoration: const InputDecoration(
                          labelText: 'Paid by',
                          prefixIcon: Icon(
                            Icons.account_balance_wallet_outlined,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.only(
                            top: 12,
                            bottom: 12,
                            right: 16,
                          ),
                        ),
                        items: g.members
                            .where((m) => !m.left || m.id == payer)
                            .map(
                              (m) => DropdownMenuItem(
                                value: m.id,
                                child: Text(
                                  m.userId == widget.controller.userId
                                      ? 'You'
                                      : m.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => payer = v),
                      ),
                      const Divider(height: 1, indent: 48),
                      ListTile(
                        leading: const Icon(Icons.calendar_today_outlined),
                        title: Text('Date · $date'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final chosen = await showDatePicker(
                            context: context,
                            initialDate: DateTime.parse(date),
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now(),
                          );
                          if (chosen != null && mounted) {
                            setState(() => date = day(chosen));
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SectionTitle('Split expense'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ['Equal', 'Exact', 'Percentage', 'Shares']
                      .map(
                        (s) => ChoiceChip(
                          label: Text(s),
                          selected: mode == s,
                          onSelected: (_) {
                            if (mode == s) return;
                            setState(() {
                              mode = s;
                              for (final entry in allocations.entries) {
                                entry.value.text = s == 'Shares' ? '1' : '';
                              }
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 8),
                if (mode == 'Equal')
                  Card(
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      title: Text('Split equally · $peopleSummary'),
                      leading: const Icon(Icons.people_outline),
                      children: g.members.map((m) {
                        final name = m.userId == widget.controller.userId
                            ? 'You'
                            : m.name;
                        return CheckboxListTile(
                          title: Text(name),
                          value: selected.contains(m.id),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: m.left || m.deleted
                              ? null
                              : (value) => setState(() {
                                  if (value == true) {
                                    selected.add(m.id);
                                  } else {
                                    selected.remove(m.id);
                                  }
                                }),
                        );
                      }).toList(),
                    ),
                  ),
                if (mode != 'Equal')
                  Card(
                    child: Column(
                      children: g.members.map((m) {
                        final included = selected.contains(m.id);
                        final name = m.userId == widget.controller.userId
                            ? 'You'
                            : m.name;
                        return Column(
                          children: [
                            if (m != g.members.first)
                              const Divider(height: 1, indent: 48),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 14, 8),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: included,
                                    semanticLabel: 'Include $name in split',
                                    onChanged: m.left || m.deleted
                                        ? null
                                        : (v) => setState(() {
                                            if (v == true) {
                                              selected.add(m.id);
                                            } else {
                                              selected.remove(m.id);
                                            }
                                          }),
                                  ),
                                  Expanded(
                                    child: Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (included) ...[
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 110,
                                      child: TextField(
                                        controller: allocations[m.id],
                                        keyboardType:
                                            TextInputType.numberWithOptions(
                                              decimal: mode != 'Shares',
                                            ),
                                        textAlign: TextAlign.end,
                                        decoration: InputDecoration(
                                          labelText: mode == 'Percentage'
                                              ? '$name %'
                                              : mode == 'Shares'
                                              ? '$name shares'
                                              : '$name amount',
                                          floatingLabelBehavior:
                                              FloatingLabelBehavior.always,
                                          hintText: mode == 'Shares'
                                              ? '1'
                                              : '0.00',
                                          prefixText: mode == 'Exact'
                                              ? '₹ '
                                              : null,
                                          suffixText: mode == 'Percentage'
                                              ? '%'
                                              : null,
                                          contentPadding: const EdgeInsets.all(
                                            12,
                                          ),
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              shares == null
                                  ? Icons.info_outline
                                  : Icons.check_circle_outline,
                              size: 20,
                              color: shares == null && amount.text.isNotEmpty
                                  ? HisaabColors.warning
                                  : HisaabColors.muted,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Split preview',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (amount.text.isEmpty)
                          const Text(
                            'Enter an amount to see what everyone owes.',
                          )
                        else if (validation != null)
                          Text(
                            validation,
                            style: const TextStyle(color: HisaabColors.warning),
                          )
                        else
                          ...shares!.entries.map(
                            (e) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      e.key ==
                                              g.participant(
                                                widget.controller.userId,
                                              )
                                          ? 'You'
                                          : g.memberName(e.key),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    money(e.value),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (shares != null && mode != 'Exact') ...[
                          Material(
                            color: Colors.transparent,
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text(
                                'How rounding works',
                                style: TextStyle(fontSize: 14),
                              ),
                              children: [
                                Text(
                                  'Any extra paisa is assigned in this order: ${ordered.where((pid) => mode != 'Percentage' || inputs()[pid]! > 0).map(g.memberName).join(' → ')}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (widget.expense == null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      onTap: () async {
                        final saved = await openPage<bool>(
                          context,
                          widget.controller,
                          ReceiptCapturePage(
                            controller: widget.controller,
                            group: g,
                          ),
                        );
                        if (saved == true && context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      leading: const Icon(Icons.attach_file_rounded),
                      title: const Text('Attach receipt'),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Align(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  decoration: const BoxDecoration(
                    color: HisaabColors.surface,
                    border: Border(top: BorderSide(color: HisaabColors.line)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              error!,
                              style: const TextStyle(color: clay),
                            ),
                          ),
                        ),
                      Text(
                        payer == null
                            ? 'Choose who paid'
                            : 'Paid by $payerName · $splitSummary',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: HisaabColors.muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed:
                            saving ||
                                payer == null ||
                                shares == null ||
                                description.text.trim().isEmpty ||
                                widget.controller.offline
                            ? null
                            : save,
                        icon: Icon(saving ? Icons.hourglass_top : Icons.check),
                        label: Text(saving ? 'Saving…' : 'Save expense'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      final e = widget.expense;
      if (description.text.trim().runes.length > 100) {
        throw ApiFailure(
          'Description must be at most 100 Unicode characters. Some emoji use more than one character.',
        );
      }
      final payload = {
        'id': e?.id ?? id,
        'description': description.text.trim(),
        'amountPaise': parsePaise(amount.text),
        'date': date,
        'payerId': payer,
        'mode': mode,
        'participants': inputs().entries
            .map((p) => {'participantId': p.key, 'value': p.value})
            .toList(),
        if (e != null) 'version': e.version,
      };
      await widget.controller.request(
        e == null ? 'POST' : 'PUT',
        '/groups/${g.id}/expenses${e == null ? '' : '/${e.id}'}',
        payload,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
