import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/receipt_images.dart';
import '../core/receipt_drafts.dart';
import '../core/receipt_preview.dart';
import '../core/receipts.dart';
import '../main.dart';
import 'receipt_camera.dart';
import 'settings.dart';
import 'shared.dart';

class ReceiptCapturePage extends StatefulWidget {
  final AppController controller;
  final Group group;
  final String? receiptId;
  const ReceiptCapturePage({
    super.key,
    required this.controller,
    required this.group,
    this.receiptId,
  });
  @override
  State<ReceiptCapturePage> createState() => _ReceiptCapturePageState();
}

class _ReceiptCapturePageState extends State<ReceiptCapturePage>
    with WidgetsBindingObserver {
  AppController get c => widget.controller;
  late final ReceiptCoordinator receipts;
  Json? draft;
  String? error;
  bool loading = true, picking = false, consent = false;
  bool foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    receipts = c.receipts;
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => foreground = state == AppLifecycleState.resumed);
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(receipts.refreshAllowance().catchError((Object _) {}));
      unawaited(receipts.pump());
    }
  }

  Future<void> load() async {
    try {
      await receipts.initialize();
      try {
        await receipts.refreshAllowance();
      } catch (_) {}
      final old = receipts.drafts.where(
        (d) => d['groupId'] == widget.group.id && d['status'] != 'attached',
      );
      if (widget.receiptId != null) {
        draft = old.where((d) => d['id'] == widget.receiptId).firstOrNull;
        if (draft == null) {
          final server = await receipts.get(widget.receiptId!);
          final restored = newReceiptDraft(widget.group.id);
          restored['id'] = widget.receiptId;
          restored['server'] = server;
          restored['status'] = server['state'];
          final document = object(object(server['extraction'])['document']);
          if (document.isNotEmpty) restored['review'] = document;
          receipts.drafts.add(restored);
          await receipts.persist(restored);
          draft = restored;
        }
      }
      draft ??= old.firstOrNull;
      draft ??= await receipts.create(widget.group.id);
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> capture() async {
    if (picking) return;
    final value = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => const ReceiptCameraPage()),
    );
    if (!mounted) return;
    if (value == 'gallery') {
      await pick(false);
      return;
    }
    if (value is Uint8List) {
      await act(context, () => receipts.addImage(draft!, value));
    }
  }

  Future<void> pick(bool pdf) async {
    if (picking) return;
    setState(() => picking = true);
    File? temporary;
    try {
      final selection = await FilePicker.pickFile(
        type: pdf ? FileType.custom : FileType.image,
        allowedExtensions: pdf ? ['pdf'] : null,
      );
      if (selection == null) return;
      var path = selection.path;
      if (path == null) {
        final folder = Directory(
          '${(await getTemporaryDirectory()).path}/hisaab-receipt-imports',
        );
        await folder.create(recursive: true);
        final extension =
            selection.extension?.toLowerCase() ?? (pdf ? 'pdf' : 'jpg');
        if (![
          'pdf',
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
        ].contains(extension)) {
          throw ApiFailure('Choose JPEG, PNG, HEIC, or PDF.');
        }
        temporary = File('${folder.path}/${const Uuid().v4()}.$extension');
        final sink = temporary.openWrite();
        var length = 0;
        try {
          await for (final chunk in selection.readAsByteStream()) {
            length += chunk.length;
            if (length > 60 * 1024 * 1024) {
              throw ApiFailure('Choose a file below 60 MB.');
            }
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        path = temporary.path;
      }
      final images = await importReceiptFile(path);
      if (rows(draft!['images']).length + images.length > 3) {
        throw ApiFailure(
          'A bill can have at most three images. Remove a photo before importing these pages.',
        );
      }
      for (final bytes in images) {
        if (!mounted) return;
        final chosen = pdf
            ? bytes
            : await Navigator.push<Uint8List>(
                context,
                MaterialPageRoute(
                  builder: (_) => ReceiptCropPage(bytes: bytes),
                ),
              );
        if (chosen != null) await receipts.addImage(draft!, chosen);
      }
      // The picker owns its temporary copy. The original gallery/document file
      // is not removed; only plugin-generated cache files are cleared.
      await FilePicker.clearTemporaryFiles();
    } catch (e) {
      if (mounted) {
        message(
          context,
          e is PlatformException
              ? e.message ?? 'This file could not be read.'
              : e,
        );
      }
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> start(bool scan) async {
    await act(context, () async {
      if (scan && receipts.allowance['consentAccepted'] != true) {
        if (!consent) {
          throw ApiFailure(
            'Accept the processing notice, or choose manual entry.',
          );
        }
        draft!['consentIntent'] =
            receipts.allowance['consentVersion'] ?? '2026-09-26-v1';
        await receipts.persist(draft!);
      }
      await receipts.queue(draft!, scan: scan);
    });
  }

  Future<void> review() async {
    draft!['review'] ??= emptyReceiptReview();
    await receipts.persist(draft!);
    if (!mounted) return;
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ReceiptReviewPage(
          controller: c,
          group: widget.group,
          draft: draft!,
          expense: draft!['editingExpense'] == null
              ? null
              : Expense(object(draft!['editingExpense'])),
        ),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([receipts, c]),
    builder: (context, _) {
      if (!receipts.active) {
        return const Scaffold(
          body: Center(child: Text('Sign in to reopen your receipt drafts.')),
        );
      }
      if (!foreground) {
        return const Scaffold(
          body: Center(
            child: Text('Receipt hidden while the app is in the background.'),
          ),
        );
      }
      final state = draft?['status'] ?? 'capture';
      final server = object(draft?['server']);
      final images = rows(draft?['images']);
      final remaining = receipts.allowance['remaining'];
      final cap = receipts.allowance['cap'];
      final capturing =
          server.isEmpty && !['queued_upload', 'processing'].contains(state);
      final processing = ['queued_upload', 'processing'].contains(state);
      final editable =
          [
            'ready',
            'manual_ready',
            'failed',
            'unreadable',
            'editing',
          ].contains(state) &&
          (c.demo ||
              server['manualAvailable'] == true ||
              rows(server['media']).isNotEmpty);
      return Scaffold(
        appBar: AppBar(title: const Text('Snap & Split')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : draft == null
            ? Center(child: Text(error ?? 'Unable to open drafts.'))
            : PageBody(
                children: [
                  const Text(
                    'One bill.\nEveryone’s share.',
                    style: TextStyle(
                      fontSize: 31,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    c.demo
                        ? 'LOCAL DEMO · No image is sent to Google.'
                        : 'Review every amount before it changes a balance.',
                  ),
                  const SizedBox(height: 14),
                  if (remaining != null)
                    Text(
                      '$remaining of $cap scans left this month · resets in IST',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  if (receipts.allowance['reserved'] is int &&
                      receipts.allowance['reserved'] > 0)
                    Text(
                      '${receipts.allowance['reserved']} scan(s) in progress',
                    ),
                  if (receipts.notice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        receipts.notice!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: clay)),
                  if (draft!['error'] != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '${draft!['error']}\nYour encrypted draft is kept. Retry when connected.',
                        style: const TextStyle(color: clay),
                      ),
                    ),
                  const SizedBox(height: 18),
                  if (images.isNotEmpty)
                    SizedBox(
                      height: 190,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: images.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, i) => SizedBox(
                          width: 130,
                          child: Column(
                            children: [
                              Expanded(
                                child: FutureBuilder<Uint8List>(
                                  future: receipts.store.image(images[i]['id']),
                                  builder: (context, snapshot) =>
                                      snapshot.hasData
                                      ? Image.memory(
                                          snapshot.data!,
                                          fit: BoxFit.contain,
                                          semanticLabel: 'Bill image ${i + 1}',
                                        )
                                      : const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                ),
                              ),
                              if (capturing)
                                TextButton(
                                  onPressed: () async {
                                    draft!['images'] = images
                                        .where(
                                          (m) => m['id'] != images[i]['id'],
                                        )
                                        .toList();
                                    await receipts.persist(draft!);
                                    await receipts.store.removeImage(
                                      images[i]['id'],
                                    );
                                  },
                                  child: Text('Remove ${i + 1}'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (capturing) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Flatten your bill, avoid glare, and include the total. Up to three photos or the first three PDF pages.',
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: picking || images.length >= 3
                              ? null
                              : capture,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Camera'),
                        ),
                        OutlinedButton.icon(
                          onPressed: picking || images.length >= 3
                              ? null
                              : () => pick(false),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Gallery'),
                        ),
                        OutlinedButton.icon(
                          onPressed: picking || images.length >= 3
                              ? null
                              : () => pick(true),
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('PDF'),
                        ),
                      ],
                    ),
                    if (picking)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: LinearProgressIndicator(),
                      ),
                    const SizedBox(height: 20),
                    if (!c.demo &&
                        receipts.allowance['consentAccepted'] != true)
                      Card(
                        child: CheckboxListTile(
                          value: consent,
                          title: const Text(
                            'Allow Google AI to read this bill',
                          ),
                          subtitle: const Text(
                            'Bill images may contain names, phone numbers, addresses, and payment details. Google processes the image to extract items and totals. Only your current group members can see the saved receipt. You can enter it manually without AI.',
                          ),
                          onChanged: (value) =>
                              setState(() => consent = value == true),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (receipts.allowance['scanAvailable'] == false) ...[
                      Text(
                        receipts.allowance['reason'] != 'scan_limit_reached'
                            ? 'Bill scanning is temporarily unavailable. You can still enter an expense manually with its photos.'
                            : cap == 100
                            ? 'Monthly scan allowance reached. It resets next month; manual entry remains available.'
                            : 'Your free scan allowance is used. Premium includes up to 100 scans per month.',
                      ),
                      if (cap != 100 &&
                          receipts.allowance['reason'] == 'scan_limit_reached')
                        TextButton(
                          onPressed: () async {
                            await openPage(
                              context,
                              c,
                              PremiumPage(controller: c),
                            );
                            try {
                              await receipts.refreshAllowance();
                            } catch (_) {}
                          },
                          child: const Text('See Premium'),
                        ),
                    ] else
                      FilledButton.icon(
                        onPressed:
                            images.isEmpty ||
                                picking ||
                                (!c.demo &&
                                    receipts.allowance['consentAccepted'] !=
                                        true &&
                                    !consent)
                            ? null
                            : () => start(true),
                        icon: const Icon(Icons.document_scanner_outlined),
                        label: Text(
                          c.offline
                              ? 'Queue scan for when online'
                              : 'Read bill',
                        ),
                      ),
                    TextButton(
                      onPressed: images.isEmpty || picking
                          ? null
                          : () => start(false),
                      child: const Text('Enter manually with these photos'),
                    ),
                    if (c.demo)
                      TextButton.icon(
                        onPressed: () async {
                          final example = await receipts.sample(
                            widget.group.id,
                            widget.group.members
                                .where((m) => !m.left && !m.deleted)
                                .map((m) => m.id)
                                .toList(),
                          );
                          if (mounted) setState(() => draft = example);
                        },
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: const Text('Try the sample itemised bill'),
                      ),
                  ],
                  if (processing) ...[
                    const SizedBox(height: 22),
                    LinearProgressIndicator(value: receipts.uploadProgress),
                    const SizedBox(height: 14),
                    Text(
                      state == 'queued_upload'
                          ? 'Will upload when connected and Hisaab is open.'
                          : 'Reading your bill… You can leave this screen; your draft is kept.',
                    ),
                    TextButton(
                      onPressed: () => receipts.pump(),
                      child: const Text('Retry connection'),
                    ),
                    if (server['manualAvailable'] == true ||
                        rows(server['media']).isNotEmpty)
                      TextButton(
                        onPressed: review,
                        child: const Text('Enter manually with the photo'),
                      ),
                  ],
                  if (state == 'not_bill')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: Text(
                        'This doesn’t look like a bill — try another photo or enter manually. This image cannot be attached and will be deleted within 24 hours.',
                      ),
                    ),
                  if (state == 'unreadable')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'This bill was hard to read. Flatten it, avoid glare, and try a clearer photo.',
                      ),
                    ),
                  if (state == 'failed')
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Column(
                        children: [
                          const Text(
                            'Couldn’t read the bill. Enter the details manually; your photo stays attached.',
                          ),
                          if ((server['attempts'] as int? ?? 0) < 3)
                            TextButton(
                              onPressed: () =>
                                  act(context, () => receipts.retry(draft!)),
                              child: const Text('Try reading again'),
                            ),
                        ],
                      ),
                    ),
                  if (editable)
                    FilledButton.icon(
                      onPressed: review,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(
                        state == 'ready'
                            ? 'Review items & split'
                            : 'Enter details manually',
                      ),
                    ),
                  if (!capturing)
                    TextButton(
                      onPressed: () async {
                        final next = await receipts.create(widget.group.id);
                        if (mounted) setState(() => draft = next);
                      },
                      child: const Text('Capture a new bill'),
                    ),
                  if (receipts.drafts
                          .where(
                            (d) =>
                                d['groupId'] == widget.group.id &&
                                d['status'] != 'attached',
                          )
                          .length >
                      1) ...[
                    const SectionTitle('Saved drafts'),
                    ...receipts.drafts
                        .where(
                          (d) =>
                              d['groupId'] == widget.group.id &&
                              d['status'] != 'attached' &&
                              d['id'] != draft!['id'],
                        )
                        .map(
                          (d) => ListTile(
                            leading: const Icon(Icons.drafts_outlined),
                            title: Text(
                              object(d['review'])['merchant'] ?? 'Bill draft',
                            ),
                            subtitle: Text(
                              '${d['status']} · ${rows(d['images']).length} image(s)',
                            ),
                            onTap: () => setState(() => draft = d),
                            trailing: IconButton(
                              tooltip: 'Discard local draft',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  act(context, () => receipts.discard(d)),
                            ),
                          ),
                        ),
                  ],
                ],
              ),
      );
    },
  );
}

class ReceiptReviewPage extends StatefulWidget {
  final AppController controller;
  final Group group;
  final Json draft;
  final Expense? expense;
  const ReceiptReviewPage({
    super.key,
    required this.controller,
    required this.group,
    required this.draft,
    this.expense,
  });
  @override
  State<ReceiptReviewPage> createState() => _ReceiptReviewPageState();
}

class _ReceiptReviewPageState extends State<ReceiptReviewPage>
    with WidgetsBindingObserver {
  AppController get c => widget.controller;
  Group get g => widget.group;
  Json get draft => widget.draft;
  late Json review;
  Json? preview;
  Expense? refreshedExpense;
  Expense? get expense => refreshedExpense ?? widget.expense;
  Json? conflict;
  int formRevision = 0;
  String mode = 'Equal';
  String? payer, error;
  bool busy = false, showImage = false;
  String? duplicateWarning;
  final selected = <String>{};
  final values = <String, String>{};
  late final String account;
  bool foreground = true;
  void accountChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => foreground = state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    c.removeListener(accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    account = c.userId;
    c.addListener(accountChanged);
    WidgetsBinding.instance.addObserver(this);
    review = object(draft['review']);
    payer = draft['payer'] ?? expense?.payer ?? g.participant(c.userId);
    mode = draft['mode'] ?? expense?.mode ?? 'Equal';
    preview = draft['preview'] == null ? null : object(draft['preview']);
    conflict = draft['conflict'] == null ? null : object(draft['conflict']);
    for (final m in g.members.where((m) => !m.left && !m.deleted)) {
      if (expense == null) selected.add(m.id);
      values[m.id] = '1';
    }
    for (final p in expense?.participants ?? <Json>[]) {
      selected.add(p['participantId']);
      values[p['participantId']] = mode == 'Exact' || mode == 'Percentage'
          ? decimal(p['value'])
          : '${p['value']}';
    }
    if (draft['selected'] is List) {
      selected.clear();
      selected.addAll((draft['selected'] as List).cast<String>());
    }
    values.addAll(object(draft['values']).map((k, v) => MapEntry(k, '$v')));
    draft['review'] = review;
  }

  void changed([VoidCallback? change]) {
    setState(() {
      change?.call();
      review['differenceAcknowledged'] = false;
      review.remove('acknowledgedReviewHash');
      preview = null;
      draft.remove('preview');
      duplicateWarning = null;
      error = null;
      draft['review'] = review;
      draft['payer'] = payer;
      draft['mode'] = mode;
      draft['selected'] = selected.toList();
      draft['values'] = values;
    });
    unawaited(
      c.receipts.persist(draft).catchError((Object e) {
        if (mounted) setState(() => error = '$e');
      }),
    );
  }

  Map<String, int> inputs() => {
    for (final id in selected)
      id: mode == 'Equal'
          ? 1
          : mode == 'Shares'
          ? int.tryParse(values[id] ?? '') ?? 0
          : parsePaise(values[id] ?? '', allowZero: true),
  };
  Map<String, int> shares() => review['splitByItems'] == true
      ? object(preview?['shares']).map((k, v) => MapEntry(k, v as int))
      : splitAmount(review['grandTotalPaise'] ?? 0, mode, inputs());
  Future<void> calculate() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (conflict != null) {
        throw ApiFailure(
          'Review the latest version before recalculating your draft.',
        );
      }
      if ((review['merchant'] as String? ?? '').trim().isEmpty) {
        throw ApiFailure('Enter the merchant or a description.');
      }
      if (review['sourceCurrency'] != 'INR' &&
          review['convertedToInr'] != true) {
        throw ApiFailure(
          'Enter manually converted INR amounts and confirm the conversion.',
        );
      }
      if (review['splitByItems'] != true) shares();
      final result = await c.receipts.preview(draft);
      if (!c.demo) {
        final duplicates = await c.receipts.request(
          'POST',
          '/receipts/${draft['id']}/duplicate-check',
          review,
        );
        final prior = rows(
          duplicates['items'],
        ).where((e) => e['expenseId'] != draft['expenseId']).firstOrNull;
        duplicateWarning = prior == null
            ? null
            : 'Possible duplicate — already added by ${g.memberName(prior['addedBy'])}. Check before saving.';
      }
      draft['preview'] = result;
      await c.receipts.persist(draft);
      if (mounted) setState(() => preview = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (preview == null) {
        throw ApiFailure('Calculate and review the split first.');
      }
      if (expense == null && payer != g.participant(c.userId)) {
        throw ApiFailure(
          'The payer must confirm this scanned bill from their own account.',
        );
      }
      if (preview!['requiresDifferenceAcknowledgement'] == true &&
          review['differenceAcknowledged'] != true) {
        throw ApiFailure('Confirm the difference or correct the amounts.');
      }
      if (review['sourceCurrency'] != 'INR' &&
          review['convertedToInr'] == true &&
          review['acknowledgedReviewHash'] != preview!['reviewHash']) {
        throw ApiFailure(
          'Confirm your manual INR conversion after reviewing this split.',
        );
      }
      final allocations = shares();
      final payload = {
        'description': (review['merchant'] as String)
            .trim()
            .runes
            .take(100)
            .map(String.fromCharCode)
            .join(),
        'amountPaise': review['grandTotalPaise'],
        'date': review['date'],
        'payerId': payer,
        'mode': review['splitByItems'] == true ? 'Exact' : mode,
        'participants':
            (review['splitByItems'] == true ? allocations : inputs()).entries
                .map((e) => {'participantId': e.key, 'value': e.value})
                .toList(),
        if (expense != null) 'version': expense!.version,
      };
      await c.receipts.persist(draft);
      await c.receipts.save(draft, payload, edit: expense != null);
      await c.refresh();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
      if (e is ApiFailure && e.status == 409) {
        try {
          final latest = await c.receipts.get(draft['id']);
          final latestExpense = expense == null
              ? null
              : await c.receipts.request(
                  'GET',
                  '/groups/${g.id}/expenses/${expense!.id}',
                );
          draft['conflictingReview'] = jsonDecode(jsonEncode(review));
          draft['conflict'] = {'server': latest, 'expense': latestExpense};
          draft.remove('preview');
          await c.receipts.persist(draft);
          if (mounted) {
            setState(() {
              conflict = object(draft['conflict']);
              preview = null;
              error =
                  'This expense changed. Your proposed edits are kept. Review the latest version before saving again.';
            });
          }
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reviewLatest() async {
    final latest = object(conflict?['server']);
    final latestExpense = object(conflict?['expense']);
    final confirmed = object(object(latest['review'])['review']);
    if (confirmed.isEmpty) {
      if (!await confirm(
        context,
        'Review latest receipt state?',
        'The receipt status changed. Recheck the bill and calculate a new preview before confirming.',
      )) {
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      if (latestExpense.isNotEmpty) refreshedExpense = Expense(latestExpense);
      if (confirmed.isNotEmpty) {
        review = object(jsonDecode(jsonEncode(confirmed)));
      }
      review['differenceAcknowledged'] = false;
      review.remove('acknowledgedReviewHash');
      draft['server'] = latest;
      draft['review'] = review;
      if (latestExpense.isNotEmpty) draft['editingExpense'] = latestExpense;
      payer = expense?.payer ?? payer;
      mode = expense?.mode ?? mode;
      if (expense != null) {
        selected.clear();
        for (final p in expense!.participants) {
          selected.add(p['participantId']);
          values[p['participantId']] = mode == 'Exact' || mode == 'Percentage'
              ? decimal(p['value'])
              : '${p['value']}';
        }
      }
      preview = null;
      draft.remove('preview');
      draft.remove('savePayload');
      draft.remove('conflict');
      draft['saveKey'] = const Uuid().v4();
      conflict = null;
      formRevision++;
      error =
          'Latest version loaded. Check its items and assignments, then calculate again.';
      draft['payer'] = payer;
      draft['mode'] = mode;
      draft['selected'] = selected.toList();
      draft['values'] = values;
    });
    await c.receipts.persist(draft);
  }

  @override
  Widget build(BuildContext context) {
    if (!c.signedIn || c.userId != account || !foreground) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Receipt hidden. Return to your signed-in account to review it.',
          ),
        ),
      );
    }
    final items = rows(review['items']), charges = rows(review['charges']);
    final locked = draft['savePayload'] != null;
    return Scaffold(
      key: ValueKey('receipt-review-$formRevision'),
      appBar: AppBar(title: const Text('Review your bill')),
      body: PageBody(
        children: [
          const Text(
            'Check it. Then split it.',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (conflict != null)
            FilledButton.icon(
              onPressed: busy ? null : reviewLatest,
              icon: const Icon(Icons.refresh),
              label: const Text('Review latest version'),
            ),
          const Text(
            'AI can misread a bill. Check the image, amounts, and people before confirming.',
          ),
          ..._warnings(
            object(object(draft['server'])['extraction'])['warnings'],
          ),
          if (locked)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'A save is awaiting confirmation. Retry the same save before changing this draft.',
                style: TextStyle(color: clay),
              ),
            ),
          if (rows(draft['images']).isNotEmpty ||
              rows(object(draft['server'])['media']).isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() => showImage = !showImage),
              icon: const Icon(Icons.receipt_long_outlined),
              label: Text(showImage ? 'Hide bill image' : 'Check bill image'),
            ),
          if (showImage)
            ...rows(draft['images']).map(
              (image) => SizedBox(
                height: 250,
                child: FutureBuilder<Uint8List>(
                  future: c.receipts.store.image(image['id']),
                  builder: (context, snapshot) => snapshot.hasData
                      ? InteractiveViewer(
                          maxScale: 6,
                          child: Image.memory(snapshot.data!),
                        )
                      : const Center(child: CircularProgressIndicator()),
                ),
              ),
            ),
          if (showImage && rows(draft['images']).isEmpty)
            ...rows(object(draft['server'])['media']).map(
              (image) => SizedBox(
                height: 250,
                child: FutureBuilder<Uint8List>(
                  future: c.receipts.media(draft['id'], image),
                  builder: (context, snapshot) => snapshot.hasData
                      ? InteractiveViewer(
                          maxScale: 6,
                          child: Image.memory(snapshot.data!),
                        )
                      : Center(
                          child: Text(
                            snapshot.hasError
                                ? '${snapshot.error}'
                                : 'Loading private image…',
                          ),
                        ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: review['merchant'] ?? '',
            maxLength: 200,
            enabled: !locked,
            decoration: const InputDecoration(
              labelText: 'Merchant / description',
            ),
            onChanged: (v) => changed(() => review['merchant'] = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: review['sourceCurrency'] ?? 'INR',
                  enabled: !locked,
                  maxLength: 3,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Bill currency'),
                  onChanged: (v) =>
                      changed(() => review['sourceCurrency'] = v.toUpperCase()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: locked
                      ? null
                      : () async {
                          final selected = await showDatePicker(
                            context: context,
                            initialDate:
                                DateTime.tryParse(review['date'] ?? '') ??
                                DateTime.now(),
                            firstDate: DateTime(1900),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (selected != null) {
                            changed(() => review['date'] = day(selected));
                          }
                        },
                  icon: const Icon(Icons.calendar_today, size: 17),
                  label: Text(review['date'] ?? 'Bill date'),
                ),
              ),
            ],
          ),
          if (review['sourceCurrency'] != 'INR') ...[
            const Text(
              'Foreign bill: Hisaab saves INR only. Convert each item, charge, and total yourself. No exchange rate is applied.',
              style: TextStyle(color: clay),
            ),
            TextFormField(
              initialValue: review['sourceGrandTotal'] ?? '',
              enabled: !locked,
              decoration: const InputDecoration(
                labelText: 'Original bill total',
              ),
              onChanged: (v) => changed(() => review['sourceGrandTotal'] = v),
            ),
            TextFormField(
              initialValue: review['sourceSubtotal'] ?? '',
              enabled: !locked,
              decoration: const InputDecoration(
                labelText: 'Original bill subtotal (optional)',
              ),
              onChanged: (v) => changed(
                () => review['sourceSubtotal'] = v.trim().isEmpty
                    ? null
                    : v.trim(),
              ),
            ),
            CheckboxListTile(
              value: review['convertedToInr'] == true,
              title: const Text('I entered converted INR amounts'),
              onChanged: locked
                  ? null
                  : (v) => changed(() => review['convertedToInr'] = v == true),
            ),
          ],
          const SizedBox(height: 12),
          _amountField(
            'Bill subtotal (INR)',
            'subtotalPaise',
            optional: true,
            locked: locked,
          ),
          const SizedBox(height: 12),
          _amountField('Grand total (INR)', 'grandTotalPaise', locked: locked),
          const SectionTitle('Items'),
          if (items.isEmpty)
            const Text(
              'No item breakdown yet. Add items or split the grand total.',
            ),
          ...items.asMap().entries.map((entry) {
            final item = entry.value;
            final low =
                item['confidence'] == null || (item['confidence'] as num) < .8;
            final assigned = (item['assigneeIds'] as List? ?? [])
                .cast<String>();
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                      low
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      color: low ? clay : green,
                    ),
                    title: Text('${item['name']} × ${item['quantity']}'),
                    subtitle: Text(
                      '${money(item['lineTotalPaise'] ?? 0)}${low ? ' · Check this reading' : ''}${item['transliteration'] == null ? '' : '\n${item['transliteration']}'}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Edit item',
                      onPressed: locked ? null : () => editItem(entry.key),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                  if (review['splitByItems'] == true)
                    ListTile(
                      dense: true,
                      title: Text(
                        item['ignored'] == true
                            ? 'Ignored zero-price item'
                            : assigned.isEmpty
                            ? 'Unassigned — choose who shared this'
                            : assigned.map(g.memberName).join(', '),
                        style: TextStyle(
                          color: assigned.isEmpty && item['ignored'] != true
                              ? clay
                              : null,
                        ),
                      ),
                      trailing: const Icon(Icons.people_outline),
                      onTap: locked ? null : () => assign(entry.key),
                    ),
                ],
              ),
            );
          }),
          TextButton.icon(
            onPressed: locked || items.length >= 150
                ? null
                : () => editItem(null),
            icon: const Icon(Icons.add),
            label: const Text('Add item'),
          ),
          const SectionTitle('Tax, charges & discounts'),
          ...charges.asMap().entries.map(
            (entry) => Card(
              child: ListTile(
                title: Text(
                  '${entry.value['name']} · ${money(entry.value['amountPaise'] ?? 0)}',
                ),
                subtitle: Text(
                  '${entry.value['confidence'] == null || (entry.value['confidence'] as num) < .8 ? 'Check this reading · ' : ''}${entry.value['includedInItemPrices'] == true
                      ? 'Already included in item prices'
                      : object(entry.value['weights']).isEmpty
                      ? 'Proportional to each person’s items'
                      : 'Custom allocation weights'}',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: locked ? null : () => editCharge(entry.key),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: locked || charges.length >= 20
                ? null
                : () => editCharge(null),
            icon: const Icon(Icons.add),
            label: const Text('Add tax / charge / discount'),
          ),
          const SectionTitle('Who paid and how to split'),
          DropdownButtonFormField<String>(
            initialValue: payer,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Paid by'),
            items: g.members
                .where((m) => !m.left && !m.deleted)
                .map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(m.userId == c.userId ? 'You' : m.name),
                  ),
                )
                .toList(),
            onChanged: locked ? null : (v) => changed(() => payer = v),
          ),
          if (expense == null && payer != g.participant(c.userId))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'The selected payer must confirm a scanned expense from their own account.',
                style: TextStyle(color: clay),
              ),
            ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Split total')),
              ButtonSegment(value: true, label: Text('Split by items')),
            ],
            selected: {review['splitByItems'] == true},
            onSelectionChanged: locked
                ? null
                : (s) => changed(() => review['splitByItems'] = s.first),
          ),
          if (review['splitByItems'] != true) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: ['Equal', 'Exact', 'Percentage', 'Shares']
                  .map(
                    (value) => ChoiceChip(
                      label: Text(value),
                      selected: mode == value,
                      onSelected: locked
                          ? null
                          : (_) => changed(() {
                              mode = value;
                              for (final id in values.keys) {
                                values[id] = value == 'Shares' ? '1' : '';
                              }
                            }),
                    ),
                  )
                  .toList(),
            ),
            ...g.members
                .where((m) => !m.left && !m.deleted)
                .map(
                  (member) => Row(
                    children: [
                      Checkbox(
                        value: selected.contains(member.id),
                        onChanged: locked
                            ? null
                            : (v) => changed(() {
                                if (v == true) {
                                  selected.add(member.id);
                                } else {
                                  selected.remove(member.id);
                                }
                              }),
                      ),
                      Expanded(child: Text(member.name)),
                      if (mode != 'Equal' && selected.contains(member.id))
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            key: ValueKey('$mode-${member.id}'),
                            initialValue: values[member.id],
                            enabled: !locked,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: mode == 'Exact'
                                  ? '₹'
                                  : mode == 'Percentage'
                                  ? '%'
                                  : 'Shares',
                            ),
                            onChanged: (v) =>
                                changed(() => values[member.id] = v),
                          ),
                        ),
                    ],
                  ),
                ),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: busy || locked ? null : calculate,
            icon: const Icon(Icons.calculate_outlined),
            label: Text(busy ? 'Checking…' : 'Calculate & check split'),
          ),
          if (preview != null) ...[
            const SectionTitle('Final breakdown'),
            ..._warnings(preview!['warnings']),
            if (duplicateWarning != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  duplicateWarning!,
                  style: const TextStyle(color: clay),
                ),
              ),
            if (preview!['sourceDifference'] != null)
              Text(
                'Original ${review['sourceCurrency']} bill difference: ${preview!['sourceDifference']}',
                style: const TextStyle(color: clay),
              ),
            if (preview!['differencePaise'] != 0)
              Text(
                'Difference from bill total: ${money(preview!['differencePaise'])}',
                style: const TextStyle(color: clay),
              ),
            if (preview!['requiresDifferenceAcknowledgement'] == true)
              CheckboxListTile(
                value: review['differenceAcknowledged'] == true,
                title: const Text(
                  'Use grand total, split difference proportionally',
                ),
                onChanged: (v) async {
                  setState(() {
                    review['differenceAcknowledged'] = v == true;
                    review['acknowledgedReviewHash'] = v == true
                        ? preview!['reviewHash']
                        : null;
                  });
                  await c.receipts.persist(draft);
                },
              ),
            if (review['sourceCurrency'] != 'INR' &&
                review['convertedToInr'] == true)
              CheckboxListTile(
                value:
                    review['acknowledgedReviewHash'] == preview!['reviewHash'],
                title: const Text('I reviewed and confirm this INR conversion'),
                onChanged: (v) async {
                  setState(
                    () => review['acknowledgedReviewHash'] = v == true
                        ? preview!['reviewHash']
                        : null,
                  );
                  await c.receipts.persist(draft);
                },
              ),
            if (review['splitByItems'] == true)
              ...rows(preview!['people']).map(
                (person) => Card(
                  child: ListTile(
                    title: Text(g.memberName(person['participantId'])),
                    subtitle: Text(
                      'Items ${money(person['itemsPaise'])}${rows(person['charges']).map((part) => '\n${part['kind']}: ${money(part['amountPaise'])}${part['includedInItemPrices'] == true ? ' (included)' : ''}').join()}',
                    ),
                    trailing: Text(
                      money(person['totalPaise']),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              )
            else
              ...shares().entries.map(
                (part) => ListTile(
                  title: Text(g.memberName(part.key)),
                  trailing: Text(money(part.value)),
                ),
              ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(error!, style: const TextStyle(color: clay)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed:
                busy ||
                    preview == null ||
                    (expense == null && payer != g.participant(c.userId))
                ? null
                : save,
            icon: const Icon(Icons.check),
            label: Text(
              locked ? 'Retry confirmed save' : 'Confirm & save expense',
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'This confirmation updates the group’s balances. Photos and the reviewed breakdown stay with the expense.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  List<Widget> _warnings(dynamic codes) => (codes as List? ?? []).map((value) {
    final code = '$value';
    final text = switch (code) {
      'merchant_uncertain' => 'Check the merchant name against the image.',
      'date_missing_confirm_today' =>
        'The bill date was unclear. Confirm or correct the displayed date.',
      'total_uncertain' =>
        'The grand total was unclear. Check it carefully before saving.',
      'overlap_review' =>
        'Photos overlap. Check that each item appears only once.',
      'grand_total_only' =>
        'Only the grand total is available. No complete item breakdown was extracted.',
      'subtotal_mismatch' =>
        'The item sum differs from the printed subtotal. Review the items and subtotal.',
      'quantity_price_mismatch' =>
        'A quantity × unit price differs from its line total. Check the item.',
      'review_uncertain_fields' =>
        'Some fields need review. Check every highlighted amount.',
      'source_reconciliation_mismatch' =>
        'The original-currency amounts do not reconcile.',
      _ => code.replaceAll('_', ' '),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: clay, size: 19),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: const TextStyle(color: clay)),
            ),
          ],
        ),
      ),
    );
  }).toList();

  Widget _amountField(
    String label,
    String field, {
    bool optional = false,
    required bool locked,
  }) => TextFormField(
    initialValue: review[field] == null ? '' : decimal(review[field]),
    enabled: !locked,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, prefixText: '₹ '),
    onChanged: (value) {
      try {
        final amount = value.trim().isEmpty && optional
            ? null
            : parsePaise(value, allowZero: true);
        changed(() => review[field] = amount);
      } catch (_) {
        changed(() => review[field] = null);
      }
    },
  );

  Future<void> assign(int index) async {
    final items = rows(review['items']);
    final item = items[index];
    final ids = (item['assigneeIds'] as List? ?? []).cast<String>().toSet();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Who shared ${item['name']}?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                ...g.members
                    .where((m) => !m.left && !m.deleted)
                    .map(
                      (m) => CheckboxListTile(
                        value: ids.contains(m.id),
                        title: Text(m.name),
                        onChanged: (v) => update(() {
                          if (v == true) {
                            ids.add(m.id);
                          } else {
                            ids.remove(m.id);
                          }
                        }),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      changed(() {
        item['assigneeIds'] = ids.toList()..sort();
        items[index] = item;
        review['items'] = items;
      });
    }
  }

  Future<void> editItem(int? index) async {
    final items = rows(review['items']);
    final prior = index == null
        ? <String, dynamic>{
            'id': const Uuid().v4(),
            'quantity': '1',
            'lineTotalPaise': 0,
            'unitPricePaise': 0,
            'assigneeIds': <String>[],
          }
        : items[index];
    final name = TextEditingController(text: prior['name'] ?? ''),
        quantity = TextEditingController(text: prior['quantity']),
        price = TextEditingController(text: decimal(prior['unitPricePaise'])),
        total = TextEditingController(text: decimal(prior['lineTotalPaise'])),
        sourcePrice = TextEditingController(
          text: prior['sourceUnitPrice'] ?? '',
        ),
        sourceTotal = TextEditingController(
          text: prior['sourceLineTotal'] ?? '',
        ),
        transliteration = TextEditingController(
          text: prior['transliteration'] ?? '',
        );
    var ignored = prior['ignored'] == true;
    final result = await showDialog<Json>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(index == null ? 'Add item' : 'Edit item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Original item name',
                  ),
                ),
                TextField(
                  controller: transliteration,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'English transliteration (optional)',
                  ),
                ),
                TextField(
                  controller: quantity,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                TextField(
                  controller: price,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Unit price (INR)',
                  ),
                ),
                TextField(
                  controller: total,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Line total (INR)',
                  ),
                ),
                if (review['sourceCurrency'] != 'INR') ...[
                  TextField(
                    controller: sourcePrice,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          'Original unit price (${review['sourceCurrency']})',
                    ),
                  ),
                  TextField(
                    controller: sourceTotal,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          'Original line total (${review['sourceCurrency']})',
                    ),
                  ),
                ],
                CheckboxListTile(
                  value: ignored,
                  title: const Text('Ignore this zero-price item'),
                  onChanged: (v) => update(() => ignored = v == true),
                ),
              ],
            ),
          ),
          actions: [
            if (index != null)
              TextButton(
                onPressed: () => Navigator.pop(context, {'delete': true}),
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  if (name.text.trim().isEmpty ||
                      !RegExp(
                        r'^\d{1,6}(\.\d{1,3})?$',
                      ).hasMatch(quantity.text) ||
                      double.parse(quantity.text) <= 0) {
                    throw const FormatException(
                      'Enter an item name and a positive quantity.',
                    );
                  }
                  final amount = parsePaise(total.text, allowZero: true);
                  if (ignored && amount != 0) {
                    throw const FormatException(
                      'Only a zero-price item can be ignored.',
                    );
                  }
                  Navigator.pop(context, {
                    ...prior,
                    'name': name.text.trim(),
                    'quantity': quantity.text,
                    'unitPricePaise': parsePaise(price.text, allowZero: true),
                    'lineTotalPaise': amount,
                    'sourceUnitPrice': sourcePrice.text.trim().isEmpty
                        ? null
                        : sourcePrice.text.trim(),
                    'sourceLineTotal': sourceTotal.text.trim().isEmpty
                        ? null
                        : sourceTotal.text.trim(),
                    'ignored': ignored,
                    'transliteration': transliteration.text.trim().isEmpty
                        ? null
                        : transliteration.text.trim(),
                    'confidence': 1.0,
                  });
                } catch (e) {
                  message(context, e);
                }
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    for (final input in [
      name,
      quantity,
      price,
      total,
      transliteration,
      sourcePrice,
      sourceTotal,
    ]) {
      input.dispose();
    }
    if (result != null) {
      changed(() {
        if (result['delete'] == true) {
          items.removeAt(index!);
        } else if (index == null) {
          items.add(result);
        } else {
          items[index] = result;
        }
        review['items'] = items;
      });
    }
  }

  Future<void> editCharge(int? index) async {
    final charges = rows(review['charges']);
    final prior = index == null
        ? <String, dynamic>{
            'id': const Uuid().v4(),
            'name': '',
            'kind': 'Tax',
            'amountPaise': 0,
          }
        : charges[index];
    final name = TextEditingController(text: prior['name']),
        amount = TextEditingController(
          text: decimal((prior['amountPaise'] as int).abs()),
        ),
        sourceAmount = TextEditingController(text: prior['sourceAmount'] ?? '');
    var kind = prior['kind'] as String,
        negative = (prior['amountPaise'] as int) < 0,
        included = prior['includedInItemPrices'] == true;
    var custom = object(prior['weights']).isNotEmpty;
    final weights = {
      for (final m in g.members.where((m) => !m.left && !m.deleted))
        m.id: TextEditingController(
          text: '${object(prior['weights'])[m.id] ?? 1}',
        ),
    };
    final result = await showDialog<Json>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Tax or charge'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Name (CGST, tip, discount…)',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  items:
                      [
                            'Tax',
                            'Service',
                            'Discount',
                            'Tip',
                            'RoundOff',
                            'Adjustment',
                            'Other',
                          ]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) => update(() {
                    kind = value!;
                    if (kind == 'Discount') negative = true;
                  }),
                ),
                TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Amount in INR'),
                ),
                if (review['sourceCurrency'] != 'INR')
                  TextField(
                    controller: sourceAmount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: InputDecoration(
                      labelText:
                          'Original signed amount (${review['sourceCurrency']})',
                    ),
                  ),
                CheckboxListTile(
                  value: negative,
                  title: const Text('Subtract this amount'),
                  onChanged: (v) => update(() => negative = v == true),
                ),
                CheckboxListTile(
                  value: included,
                  title: const Text('Already included in item prices'),
                  onChanged: (v) => update(() => included = v == true),
                ),
                SwitchListTile(
                  value: custom,
                  title: const Text('Override proportional allocation'),
                  onChanged: (v) => update(() => custom = v),
                ),
                if (custom)
                  ...weights.entries.map(
                    (entry) => TextField(
                      controller: entry.value,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText:
                            '${g.memberName(entry.key)} · weight (0 excludes)',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (index != null)
              TextButton(
                onPressed: () => Navigator.pop(context, {'delete': true}),
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  if (name.text.trim().isEmpty) {
                    throw const FormatException('Enter a charge name.');
                  }
                  final values = {
                    for (final entry in weights.entries)
                      if ((int.tryParse(entry.value.text) ?? -1) > 0)
                        entry.key: int.parse(entry.value.text),
                  };
                  if (custom &&
                      (values.isEmpty ||
                          weights.values.any(
                            (v) =>
                                int.tryParse(v.text) == null ||
                                int.parse(v.text) < 0 ||
                                int.parse(v.text) > 10000,
                          ))) {
                    throw const FormatException(
                      'Use weights from 0 to 10,000, with at least one positive weight.',
                    );
                  }
                  Navigator.pop(context, {
                    ...prior,
                    'name': name.text.trim(),
                    'kind': kind,
                    'amountPaise':
                        parsePaise(amount.text, allowZero: true) *
                        (negative ? -1 : 1),
                    'includedInItemPrices': included,
                    'sourceAmount': sourceAmount.text.trim().isEmpty
                        ? null
                        : sourceAmount.text.trim(),
                    'weights': custom ? values : null,
                    'confidence': 1.0,
                  });
                } catch (e) {
                  message(context, e);
                }
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    amount.dispose();
    sourceAmount.dispose();
    for (final input in weights.values) {
      input.dispose();
    }
    if (result != null) {
      changed(() {
        if (result['delete'] == true) {
          charges.removeAt(index!);
        } else if (index == null) {
          charges.add(result);
        } else {
          charges[index] = result;
        }
        review['charges'] = charges;
      });
    }
  }
}
