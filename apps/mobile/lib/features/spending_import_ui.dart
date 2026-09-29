import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/money.dart';
import '../core/spending.dart';
import '../core/spending_import.dart';
import 'shared.dart';

Future<void> openSpendingImport(
  BuildContext context,
  AppController controller,
) => openPage<void>(
  context,
  controller,
  _SpendingImportPage(controller: controller),
);

class _ImportSession {
  final AppController controller;
  final String account;
  final Object? repository;
  final SpendingController store;
  _ImportSession(this.controller)
    : account = controller.userId,
      repository = controller.repository,
      store = controller.spending;

  bool get current =>
      controller.spendingAvailable &&
      controller.userId == account &&
      identical(controller.repository, repository) &&
      identical(controller.spending, store);
  Listenable get changes => Listenable.merge([controller, store]);
}

class _ImportSessionSurface extends StatelessWidget {
  final _ImportSession session;
  final Widget child;
  final bool dialog;
  const _ImportSessionSurface({
    required this.session,
    required this.child,
    this.dialog = false,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session.changes,
    builder: (context, _) {
      if (session.current) return child;
      final close = TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      );
      if (dialog) {
        return AlertDialog(
          title: const Text('Session ended'),
          content: const Text('Sign in again to import private spending.'),
          actions: [close],
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Session ended')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Sign in again to import private spending.'),
              close,
            ],
          ),
        ),
      );
    },
  );
}

class _SpendingImportPage extends StatefulWidget {
  final AppController controller;
  const _SpendingImportPage({required this.controller});
  @override
  State<_SpendingImportPage> createState() => _SpendingImportPageState();
}

class _SpendingImportPageState extends State<_SpendingImportPage> {
  late final _ImportSession session;
  SpendingController get store => session.store;
  bool busy = false, smsOn = false;
  String? error, status;
  AppController get c => widget.controller;
  bool get current => mounted && session.current;
  @override
  void initState() {
    super.initState();
    session = _ImportSession(c);
    _status();
  }

  Future<void> _status() async {
    try {
      final enabled = !c.demo && await c.spendingImports.smsEnabled();
      if (current) setState(() => smsOn = enabled);
    } catch (_) {
      /* PDF and CSV remain available without a platform bridge. */
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
      status = null;
    });
    try {
      await action();
    } catch (e) {
      if (current) {
        setState(
          () => error = e is PlatformException
              ? e.message ?? 'Import unavailable.'
              : '$e',
        );
      }
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _ImportSessionSurface(
    session: session,
    child: Scaffold(
      appBar: AppBar(title: const Text('Import your spending')),
      body: PageBody(
        children: [
          const EditorialArtwork(asset: HisaabArt.wallet, height: 130),
          Text(
            'A clearer picture, privately.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Personal spending stays encrypted on this phone. It is not uploaded to HiSaab or shared with your groups.',
          ),
          const SizedBox(height: 16),
          if (c.spendingImports.supportsSms)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Bank SMS',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'SMS access lets HiSaab scan your inbox on this phone. We extract supported bank transactions and discard personal messages and OTPs. Raw messages are never saved or uploaded.',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Start with the last 90 days, then capture new bank alerts in the background. Transaction details remain here until you delete them. You can stop SMS capture at any time.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: busy || c.demo
                          ? null
                          : () => _run(() async {
                              final count = await c.syncSpendingSms(
                                requestPermission: true,
                              );
                              if (!current) return;
                              await _status();
                              if (!current) return;
                              final unmatched =
                                  c.spendingImports.unrecognizedCount;
                              setState(
                                () => status =
                                    '$count new transactions imported.'
                                    '${unmatched > 0 ? ' $unmatched financial messages were not understood. Use a statement or add them manually.' : ''}'
                                    '${c.spendingImports.truncated ? ' Import reached its safety limit. Import a statement for older records.' : ''}',
                              );
                            }),
                      child: Text(
                        smsOn
                            ? 'Refresh bank SMS'
                            : 'Agree & enable SMS tracking',
                      ),
                    ),
                    if (c.demo)
                      const Text(
                        'SMS tracking needs a signed-in account. You can try a statement or cash entry in the demo.',
                      ),
                    if (smsOn)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _run(() async {
                                await c.spendingImports.disableSms();
                                await _status();
                                if (current) {
                                  setState(
                                    () => status =
                                        'SMS capture stopped. Existing transactions are kept.',
                                  );
                                }
                              }),
                        child: const Text('Stop SMS capture'),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Use a statement',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Import a CSV or text-based PDF and review the transactions before saving. Password-protected PDFs are supported on iOS and Android 15 or later. Scans and unsupported bank layouts need a CSV export instead.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _run(() => _pick(false)),
                    icon: const Icon(Icons.table_chart_outlined),
                    label: const Text('Choose CSV'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _run(() => _pick(true)),
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('Choose PDF'),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Supported CSV format'),
                    children: const [
                      SelectableText(
                        'Date,Description,Amount,Type\n2026-09-20,Coffee,120.00,debit\n\nOr Date,Description,Debit,Credit\nUse yyyy-MM-dd or dd/MM/yyyy dates.\nAmounts are in rupees. Maximum 2 MB / 5,000 rows.',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'After you save, the import copy and any PDF password are discarded. Use Export CSV in Your spending for a spreadsheet record. CSV export does not restore budgets or group links. Reinstalling or changing phones does not restore this private ledger.',
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                status!,
                style: const TextStyle(color: HisaabColors.positive),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: const TextStyle(color: HisaabColors.warning),
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> _pick(bool pdf) async {
    if (!current) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: [pdf ? 'pdf' : 'csv'],
    );
    if (!current || picked == null) {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
      return;
    }
    final path = picked.path;
    if (path == null) {
      throw const FormatException('Choose a file saved on this device.');
    }
    final file = File(path);
    List<Json> records;
    try {
      if (await file.length() > (pdf ? 20 : 2) * 1024 * 1024) {
        throw FormatException('Choose a file below ${pdf ? 20 : 2} MB.');
      }
      if (!current) return;
      if (pdf) {
        String? password;
        String? extracted;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            extracted = await c.spendingImports.pdfText(
              path,
              password: password,
            );
            break;
          } on PlatformException catch (e) {
            if (e.code != 'pdf_password' || !current) rethrow;
            password = await _password(attempt > 0);
            if (password == null || !current) return;
          }
        }
        if (extracted == null) {
          throw const FormatException(
            'Could not unlock this PDF. Check its password and try again.',
          );
        }
        records = parseStatementText(extracted);
      } else {
        records = parseCsv(utf8.decode(await file.readAsBytes()));
      }
    } finally {
      // file_picker owns temporary import copies; never delete the user's file.
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
    }
    if (!mounted || !current) return;
    final reviewed = await Navigator.of(context).push<List<Json>>(
      MaterialPageRoute(
        builder: (_) => _ImportReview(records: records, session: session),
      ),
    );
    if (!current || reviewed == null) return;
    final count = await store.importRows(reviewed);
    if (current) {
      setState(
        () => status =
            '$count new transactions saved. ${reviewed.length - count} duplicates skipped.',
      );
    }
  }

  Future<String?> _password(bool retry) async {
    if (!current) return null;
    String value = '';
    return showDialog<String>(
      context: context,
      builder: (context) => _ImportSessionSurface(
        session: session,
        dialog: true,
        child: AlertDialog(
          scrollable: true,
          title: Text(
            retry ? 'Check the PDF password' : 'Unlock this statement',
          ),
          content: TextField(
            obscureText: true,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (text) {
              if (current) value = text;
            },
            decoration: const InputDecoration(
              labelText: 'PDF password',
              helperText: 'Used only on this phone; never stored.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (current) Navigator.pop(context, value);
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportReview extends StatefulWidget {
  final List<Json> records;
  final _ImportSession session;
  const _ImportReview({required this.records, required this.session});
  @override
  State<_ImportReview> createState() => _ImportReviewState();
}

class _ImportReviewState extends State<_ImportReview> {
  late final Set<int> selected = {
    for (var i = 0; i < widget.records.length; i++) i,
  };
  @override
  Widget build(BuildContext context) => _ImportSessionSurface(
    session: widget.session,
    child: Scaffold(
      appBar: AppBar(title: const Text('Review import')),
      body: ListView.builder(
        itemCount: widget.records.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '${widget.records.length} transactions found. Check the dates and amounts. Only selected transactions will be saved privately.\n\nStatements without bank, account and reference identifiers may overlap your SMS history. Deselect payments already imported.',
              ),
            );
          }
          final recordIndex = index - 1;
          final row = widget.records[recordIndex];
          return CheckboxListTile(
            value: selected.contains(recordIndex),
            onChanged: (value) => setState(() {
              if (value == true) {
                selected.add(recordIndex);
              } else {
                selected.remove(recordIndex);
              }
            }),
            title: Text(row['title']),
            subtitle: Text(
              '${day(DateTime.parse(row['date']).toLocal())} · ${row['kind']} · ${money(row['amountPaise'])}',
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () {
                  if (!widget.session.current) return;
                  Navigator.pop(context, [
                    for (final index in selected.toList()..sort())
                      widget.records[index],
                  ]);
                },
          child: Text('Save ${selected.length} transactions'),
        ),
      ),
    ),
  );
}
