import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'receipts.dart';
import 'shared.dart';

class ReceiptThumbnail extends StatefulWidget {
  final AppController controller;
  final String receiptId;
  const ReceiptThumbnail({
    super.key,
    required this.controller,
    required this.receiptId,
  });
  @override
  State<ReceiptThumbnail> createState() => _ReceiptThumbnailState();
}

class _ReceiptThumbnailState extends State<ReceiptThumbnail>
    with WidgetsBindingObserver {
  Uint8List? bytes;
  late final String account;
  @override
  void initState() {
    super.initState();
    account = widget.controller.userId;
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  Future<void> load() async {
    try {
      final service = widget.controller.receipts;
      final status = await service.get(widget.receiptId);
      final first = rows(status['media']).firstOrNull;
      if (first == null || status['imagesRemoved'] == true) return;
      final loaded = await service.media(
        widget.receiptId,
        first,
        thumbnail: true,
      );
      if (mounted && widget.controller.userId == account) {
        setState(() => bytes = loaded);
      }
    } catch (_) {
      if (mounted) setState(clear);
    }
  }

  void clear() {
    if (bytes != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes!));
      bytes = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (mounted) setState(clear);
    } else {
      load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 52,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: bytes == null || widget.controller.userId != account
          ? const ColoredBox(
              color: HisaabColors.lilac,
              child: Icon(
                Icons.receipt_long_outlined,
                color: HisaabColors.primary,
              ),
            )
          : Image.memory(
              bytes!,
              fit: BoxFit.cover,
              semanticLabel: 'Shared bill thumbnail',
            ),
    ),
  );
}

class ReceiptViewerPage extends StatefulWidget {
  final AppController controller;
  final Group group;
  final String receiptId;
  final Expense? expense;
  final bool editOnOpen;
  const ReceiptViewerPage({
    super.key,
    required this.controller,
    required this.group,
    required this.receiptId,
    this.expense,
    this.editOnOpen = false,
  });
  @override
  State<ReceiptViewerPage> createState() => _ReceiptViewerPageState();
}

class _ReceiptViewerPageState extends State<ReceiptViewerPage>
    with WidgetsBindingObserver {
  Json? status;
  String? error;
  late final String account;
  final images = <String, Uint8List>{};
  bool loading = true, busy = false, foreground = true;
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    account = c.userId;
    WidgetsBinding.instance.addObserver(this);
    load().then((_) {
      if (mounted && widget.editOnOpen && status != null) edit();
    });
  }

  void clear() {
    for (final bytes in images.values) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(bytes));
    }
    images.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      if (mounted) {
        setState(() {
          clear();
          status = null;
        });
      }
    } else {
      load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clear();
    super.dispose();
  }

  Future<void> load() async {
    if (account != c.userId || !c.signedIn) return;
    try {
      final service = c.receipts;
      final latest = await service.get(widget.receiptId);
      if (!mounted || account != c.userId || !foreground) return;
      clear();
      setState(() {
        status = latest;
        error = null;
        loading = false;
      });
      for (final media in rows(latest['media'])) {
        if (latest['imagesRemoved'] == true) break;
        final bytes = await service.media(widget.receiptId, media);
        if (!mounted || account != c.userId || !foreground) return;
        setState(() => images[media['id']] = bytes);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          clear();
          status = null;
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  Future<void> edit() async {
    final expense = widget.expense;
    if (expense == null || status == null) return;
    final revision = object(status!['review']);
    final document = object(revision['review']);
    if (document.isEmpty) {
      message(context, 'This receipt has no reviewed breakdown.');
      return;
    }
    final draft = {
      'id': widget.receiptId,
      'expenseId': expense.id,
      'groupId': widget.group.id,
      'images': <Json>[],
      'server': status,
      'status': 'editing',
      'review': jsonDecode(jsonEncode(document)),
      'saveKey': const Uuid().v4(),
      'editingExpense': expense.json,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await c.receipts.initialize();
    c.receipts.drafts.removeWhere((d) => d['id'] == widget.receiptId);
    c.receipts.drafts.add(draft);
    await c.receipts.persist(draft);
    if (!mounted) return;
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReceiptReviewPage(
          controller: c,
          group: widget.group,
          draft: draft,
          expense: expense,
        ),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  Future<void> flag() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('What doesn’t match?'),
        children: [
          for (final reason in {
            'total': 'Total amount',
            'items': 'Items or assignments',
            'image': 'Bill image',
            'other': 'Something else',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, reason.key),
              child: Text(reason.value),
            ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    await act(context, () async {
      if (!c.demo) {
        await c.receipts.request(
          'POST',
          '/groups/${widget.group.id}/expenses/${widget.expense?.id ?? status?['expenseId']}/receipt-flags',
          {'reason': reason},
        );
      }
      if (mounted) {
        message(
          context,
          c.demo
              ? 'Demo only — no mismatch report was sent.'
              : 'Reported to the payer. Balances are unchanged.',
        );
      }
    });
  }

  Future<void> remove() async {
    if (!await confirm(
      context,
      'Remove bill images?',
      'This removes the images for everyone in the group. The expense and itemised breakdown stay. This cannot be undone.',
      action: 'Remove images',
    )) {
      return;
    }
    if (!mounted) return;
    await act(context, () async {
      setState(() => busy = true);
      try {
        await c.receipts.removeImages(widget.receiptId, status!['version']);
        clear();
        await load();
      } finally {
        if (mounted) setState(() => busy = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      if (account != c.userId || !c.signedIn) {
        return const Scaffold(
          body: Center(child: Text('Sign in to view this receipt.')),
        );
      }
      final revision = object(status?['review']),
          document = object(revision['review']);
      final items = rows(document['items']),
          charges = rows(document['charges']);
      final ownId = widget.group.participant(account);
      final participant =
          widget.expense?.payer == ownId ||
          widget.expense?.shares.containsKey(ownId) == true;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Shared bill'),
          actions: [
            IconButton(
              tooltip: 'Refresh receipt',
              onPressed: load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : status == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error ??
                        'Receipt hidden while the app is in the background.',
                  ),
                ),
              )
            : PageBody(
                children: [
                  Text(
                    document['merchant'] ?? 'Bill image',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 18,
                        color: HisaabColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Visible to current ${widget.group.type == 'Direct' ? 'participants' : 'group members'} · Review ${status!['revision'] ?? 0}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: HisaabColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (document['grandTotalPaise'] != null) ...[
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: HisaabColors.mint,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Reviewed bill total'),
                          const SizedBox(height: 6),
                          Text(
                            money(document['grandTotalPaise']),
                            style: Theme.of(context).textTheme.headlineLarge
                                ?.copyWith(color: HisaabColors.teal),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.group.name,
                            style: const TextStyle(color: HisaabColors.teal),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (status!['imagesRemoved'] == true)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'The images were removed. The accounting breakdown is retained.',
                      ),
                    ),
                  if (status!['imagesRemoved'] != true)
                    ...rows(status!['media']).map(
                      (media) => Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: ColoredBox(
                            color: HisaabColors.line,
                            child: SizedBox(
                              height: 380,
                              child: images[media['id']] == null
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : InteractiveViewer(
                                      minScale: 1,
                                      maxScale: 8,
                                      child: Image.memory(
                                        images[media['id']]!,
                                        fit: BoxFit.contain,
                                        semanticLabel:
                                            'Original shared receipt, pinch to zoom',
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (images.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Pinch the image to zoom in',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: HisaabColors.muted,
                        ),
                      ),
                    ),
                  if (items.isNotEmpty) ...[
                    const SectionTitle('Reviewed items'),
                    Card(
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < items.length;
                            index++
                          ) ...[
                            if (index > 0)
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                            _ReceiptDetailRow(
                              title:
                                  '${items[index]['name']} × ${items[index]['quantity']}',
                              subtitle:
                                  (items[index]['assigneeIds'] as List? ?? [])
                                      .cast<String>()
                                      .map(widget.group.memberName)
                                      .join(', '),
                              amount: money(items[index]['lineTotalPaise']),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (charges.isNotEmpty) ...[
                    const SectionTitle('Tax, charges & discounts'),
                    Card(
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < charges.length;
                            index++
                          ) ...[
                            if (index > 0)
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                            _ReceiptDetailRow(
                              title: charges[index]['name'],
                              subtitle:
                                  charges[index]['includedInItemPrices'] == true
                                  ? 'Included in prices'
                                  : null,
                              amount: money(charges[index]['amountPaise']),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (object(revision['shares']).isNotEmpty) ...[
                    const SectionTitle('Confirmed shares'),
                    Card(
                      color: HisaabColors.lilac,
                      child: Column(
                        children: object(revision['shares']).entries
                            .map(
                              (entry) => _ReceiptDetailRow(
                                title: widget.group.memberName(entry.key),
                                amount: money(entry.value),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (participant)
                    TextButton.icon(
                      onPressed: busy ? null : flag,
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('This doesn’t match the bill'),
                    ),
                  if (participant &&
                      widget.expense?.deleted == false &&
                      !widget.group.archived)
                    OutlinedButton.icon(
                      onPressed: busy ? null : edit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit reviewed expense'),
                    ),
                  if (status!['imagesRemoved'] != true &&
                      rows(status!['media']).isNotEmpty)
                    TextButton.icon(
                      onPressed: busy ? null : remove,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove bill images for everyone'),
                    ),
                ],
              ),
      );
    },
  );
}

class _ReceiptDetailRow extends StatelessWidget {
  final String title, amount;
  final String? subtitle;
  const _ReceiptDetailRow({
    required this.title,
    required this.amount,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 14,
                    color: HisaabColors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          flex: 2,
          child: Text(
            amount,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}
