import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../main.dart';
import 'shared.dart';
import 'receipts.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.expense == null ? 'Add an expense' : 'Edit expense'),
      ),
      body: PageBody(
        children: [
          const Text(
            'Little expenses.\nShared fairly.',
            style: TextStyle(
              fontSize: 29,
              height: 1.15,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 26),
          if (widget.expense == null) ...[
            OutlinedButton.icon(
              onPressed: () async {
                final saved = await openPage<bool>(
                  context,
                  widget.controller,
                  ReceiptCapturePage(controller: widget.controller, group: g),
                );
                if (saved == true && context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Scan bill'),
            ),
            const SizedBox(height: 18),
          ],
          TextField(
            controller: description,
            maxLength: 100,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What was it for?',
              hintText: 'e.g. Dinner by the beach',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              labelText: 'Total amount',
              prefixText: '₹ ',
              suffixText: 'INR',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: payer,
                  decoration: const InputDecoration(labelText: 'Paid by'),
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
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final chosen = await showDatePicker(
                      context: context,
                      initialDate: DateTime.parse(date),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                    );
                    if (chosen != null) setState(() => date = day(chosen));
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 17),
                  label: Text(date, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SectionTitle('How are we splitting?'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ['Equal', 'Exact', 'Percentage', 'Shares']
                .map(
                  (s) => ChoiceChip(
                    label: Text(s),
                    selected: mode == s,
                    onSelected: (_) => setState(() {
                      mode = s;
                      for (final entry in allocations.entries) {
                        entry.value.text = s == 'Shares' ? '1' : '';
                      }
                    }),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          ...g.members.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: selected.contains(m.id),
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
                          m.userId == widget.controller.userId ? 'You' : m.name,
                        ),
                      ),
                      if (mode != 'Equal' && selected.contains(m.id))
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: allocations[m.id],
                            keyboardType: TextInputType.numberWithOptions(
                              decimal: mode != 'Shares',
                            ),
                            textAlign: TextAlign.end,
                            decoration: InputDecoration(
                              hintText: mode == 'Shares' ? '1' : '0.00',
                              prefixText: mode == 'Exact' ? '₹ ' : null,
                              suffixText: mode == 'Percentage' ? '%' : null,
                              contentPadding: const EdgeInsets.all(12),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: shares == null
                  ? const Color(0xFFF4E7D7)
                  : const Color(0xFFE5EDDC),
              borderRadius: BorderRadius.circular(20),
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
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Split preview',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (validation != null)
                  Text(validation)
                else
                  ...shares!.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Expanded(child: Text(g.memberName(e.key))),
                          Text(
                            money(e.value),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (shares != null && mode != 'Exact') ...[
                  const Divider(height: 28),
                  Text(
                    'Remainder order: ${ordered.where((pid) => mode != 'Percentage' || inputs()[pid]! > 0).map(g.memberName).join(' → ')}',
                    style: const TextStyle(fontSize: 11, height: 1.6),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Any extra paisa goes in this fixed order.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(error!, style: const TextStyle(color: clay)),
            ),
          const SizedBox(height: 26),
          FilledButton.icon(
            onPressed:
                saving ||
                    shares == null ||
                    description.text.trim().isEmpty ||
                    widget.controller.offline
                ? null
                : save,
            icon: Icon(saving ? Icons.hourglass_top : Icons.check),
            label: Text(saving ? 'Saving…' : 'Save expense'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Everyone in this split can see the expense and its history.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF6C796D)),
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
