import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'receipt_drafts.dart';
import 'receipt_preview.dart';
import 'repository.dart';

class ReceiptCoordinator extends ChangeNotifier {
  final Repository repository;
  final String account;
  final bool Function() current;
  final bool Function() foreground;
  final ReceiptDraftStore store;
  final List<Json> drafts = [];
  Json allowance = {};
  double? uploadProgress;
  String? notice;
  Timer? _timer;
  Future<void>? _opening;
  bool _busy = false, _closed = false;
  ReceiptCoordinator({
    required this.repository,
    required this.account,
    required this.current,
    required this.foreground,
    ReceiptDraftStore? store,
  }) : store = store ?? ReceiptDraftStore(account);
  bool get demo => repository.isDemo;
  bool get active => !_closed && current();
  void _check() {
    if (!active) {
      throw ApiFailure(
        'Account changed. Sign in to reopen your drafts.',
        status: 401,
      );
    }
  }

  void _notify() {
    if (active) notifyListeners();
  }

  Future<void> initialize() => _opening ??= () async {
    final saved = await store.load();
    _check();
    for (final draft in saved) {
      final created = DateTime.tryParse(draft['createdAt'] ?? '');
      final expired =
          created != null &&
          DateTime.now().toUtc().difference(created).inDays >= 7;
      if (expired && draft['status'] != 'attached') {
        await store.remove(draft);
      } else {
        drafts.add(draft);
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (active && foreground()) unawaited(pump());
    });
    _notify();
    try {
      await refreshAllowance();
    } catch (_) {
      notice =
          'Offline capture is ready. Connect to upload and read your bill.';
    }
    unawaited(pump());
  }();
  Future<Json> request(
    String method,
    String path, [
    Json? data,
    String? key,
  ]) async {
    _check();
    final result = repository is ApiRepository
        ? await (repository as ApiRepository).receiptRequest(
            method,
            path,
            data,
            key ?? const Uuid().v4(),
          )
        : await repository.request(method, path, data);
    _check();
    return result;
  }

  Future<void> refreshAllowance() async {
    if (demo) {
      final used = drafts.where((d) => d['demoCounted'] == true).length;
      allowance = {
        'plan': 'free',
        'cap': 5,
        'used': used,
        'reserved': 0,
        'remaining': (5 - used).clamp(0, 5),
        'scanAvailable': used < 5,
        'consentVersion': 'receipt-ai-v1',
        'consentAccepted': true,
        'reason': used >= 5 ? 'scan_limit_reached' : null,
      };
    } else {
      allowance = await request('GET', '/receipts/allowance');
    }
    _notify();
  }

  Future<void> acceptConsent() async {
    if (!demo) {
      await request('PUT', '/receipts/consent', {
        'version': allowance['consentVersion'] ?? '2026-09-26-v1',
        'accepted': true,
      });
    }
    allowance['consentAccepted'] = true;
    _notify();
  }

  Future<Json> create(String groupId) async {
    await initialize();
    _check();
    final draft = newReceiptDraft(groupId);
    await store.save(draft);
    _check();
    drafts.add(draft);
    _notify();
    return draft;
  }

  Future<void> persist(Json draft) async {
    _check();
    await store.save(draft);
    _check();
    _notify();
  }

  Future<void> addImage(Json draft, Uint8List bytes) async {
    _check();
    if (draft['server'] != null) {
      throw ApiFailure('Start a new draft to replace uploaded images.');
    }
    if (rows(draft['images']).length >= 3) {
      throw ApiFailure('Use at most three images per bill.');
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw ApiFailure('Image exceeds 10 MB after compression.');
    }
    final id = const Uuid().v4();
    await store.writeImage(id, bytes);
    _check();
    draft['images'] = [
      ...rows(draft['images']),
      {
        'id': id,
        'contentType': 'image/jpeg',
        'sizeBytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      },
    ];
    await persist(draft);
  }

  Future<void> queue(Json draft, {required bool scan}) async {
    _check();
    if (rows(draft['images']).isEmpty) {
      throw ApiFailure('Add a photo or a PDF first.');
    }
    if (scan &&
        allowance['consentAccepted'] != true &&
        draft['consentIntent'] == null) {
      throw ApiFailure('Accept the Google processing notice before scanning.');
    }
    draft['scanRequested'] = scan;
    if (draft['consentIntent'] != null) {
      draft['consentKey'] ??= const Uuid().v4();
    }
    draft['status'] = 'queued_upload';
    draft.remove('error');
    await persist(draft);
    unawaited(pump());
  }

  Future<void> pump() async {
    if (_busy || !active || !foreground()) return;
    _busy = true;
    try {
      for (final draft in List<Json>.from(drafts)) {
        if (!active || !foreground()) break;
        try {
          if (draft['status'] == 'queued_upload') await _upload(draft);
          final server = object(draft['server']);
          if (!demo &&
              server.isNotEmpty &&
              ['processing', 'queued_upload'].contains(draft['status'])) {
            final status = await request('GET', '/receipts/${draft['id']}');
            draft['server'] = status;
            final state = status['state'];
            if ([
              'ready',
              'manual_ready',
              'failed',
              'unreadable',
              'not_bill',
              'expired',
              'cancelled',
            ].contains(state)) {
              draft['status'] = state;
              final extraction = object(status['extraction']);
              if (state == 'ready' && draft['review'] == null) {
                draft['review'] = object(extraction['document']);
                notice = 'Your receipt is ready to review.';
              }
            } else if (state == 'attached') {
              // An ambiguous save response may have committed already. Keep
              // its persisted UUID/body available for a safe confirmation retry.
              draft['status'] = 'ready';
            } else {
              draft['status'] = 'processing';
            }
            draft.remove('error');
            if (state == 'not_bill') {
              for (final media in rows(draft['images'])) {
                await store.removeImage(media['id']);
              }
              draft['images'] = <Json>[];
            }
            await persist(draft);
            if ([
              'ready',
              'manual_ready',
              'failed',
              'unreadable',
              'not_bill',
            ].contains(state)) {
              try {
                await refreshAllowance();
              } catch (_) {}
            }
          }
        } catch (error) {
          if (!active) break;
          draft['error'] = '$error';
          await persist(draft);
        }
      }
    } finally {
      _busy = false;
      uploadProgress = null;
      _notify();
    }
  }

  Future<void> _upload(Json draft) async {
    if (demo) {
      draft['status'] = 'manual_ready';
      draft['server'] = {
        'id': draft['id'],
        'groupId': draft['groupId'],
        'state': 'manual_ready',
        'version': 1,
        'media': draft['images'],
        'manualAvailable': true,
      };
      draft['review'] ??= emptyReceiptReview();
      notice =
          'Local demo: enter this photo manually, or use the sample bill. No AI service is called.';
      await persist(draft);
      return;
    }
    if (draft['scanRequested'] == true && draft['consentIntent'] != null) {
      await request('PUT', '/receipts/consent', {
        'version': draft['consentIntent'],
        'accepted': true,
      }, draft['consentKey'] ??= const Uuid().v4());
      allowance['consentAccepted'] = true;
    }
    // Replaying create refreshes upload grants without creating a second receipt.
    final created =
        await request('POST', '/groups/${draft['groupId']}/receipts', {
          'id': draft['id'],
          'scanRequested': draft['scanRequested'],
          'images': draft['images'],
        }, draft['createKey']);
    draft['server'] = object(created['receipt']);
    await persist(draft);
    final uploads = rows(created['uploads']);
    for (var i = 0; i < uploads.length; i++) {
      final upload = uploads[i];
      final bytes = await store.image(upload['id']);
      _check();
      await (repository as ApiRepository).uploadReceipt(upload, bytes, (
        fraction,
      ) {
        uploadProgress = (i + fraction) / uploads.length;
        _notify();
      });
      _check();
    }
    if (object(draft['server'])['state'] == 'awaiting_upload') {
      draft['completeVersion'] ??= object(draft['server'])['version'];
      await persist(draft);
      final completed = await request(
        'POST',
        '/receipts/${draft['id']}/complete',
        {'version': draft['completeVersion']},
        draft['completeKey'],
      );
      draft['server'] = {...object(draft['server']), ...completed};
    }
    draft['status'] = 'processing';
    await persist(draft);
  }

  Future<void> retry(Json draft) async {
    final status = await get(draft['id']);
    final key = draft['retryKey'] ??= const Uuid().v4();
    draft['retryVersion'] ??= status['version'];
    await persist(draft);
    Json result;
    try {
      result = await request('POST', '/receipts/${draft['id']}/retry', {
        'version': draft['retryVersion'],
      }, key);
    } on ApiFailure catch (error) {
      if (error.status >= 400 && error.status < 500 && error.status != 401) {
        draft.remove('retryKey');
        draft.remove('retryVersion');
        await persist(draft);
      }
      rethrow;
    }
    draft['server'] = {...status, ...result};
    draft['status'] = 'processing';
    draft.remove('retryKey');
    draft.remove('retryVersion');
    await persist(draft);
    unawaited(pump());
  }

  Future<Json> preview(Json draft) async {
    _check();
    final review = object(draft['review']);
    if (demo) return estimateReceipt(review);
    return request('POST', '/receipts/${draft['id']}/preview', review);
  }

  Future<Json> get(String id) async {
    if (!demo) return request('GET', '/receipts/$id');
    await initialize();
    _check();
    final draft = drafts.where((d) => d['id'] == id).firstOrNull;
    if (draft == null) throw ApiFailure('Receipt unavailable.', status: 404);
    return {
      ...object(draft['server']),
      'media': draft['images'],
      'review': {'review': draft['review'], 'shares': draft['shares']},
    };
  }

  Future<Uint8List> media(
    String id,
    Json image, {
    bool thumbnail = false,
  }) async {
    _check();
    if (demo) return store.image(image['id']);
    final grant = await request('POST', '/receipts/$id/media-ticket');
    final size =
        (thumbnail ? image['thumbnailSizeBytes'] : image['sizeBytes']) as int;
    if (size <= 0 || size > 10 * 1024 * 1024) {
      throw ApiFailure('Invalid receipt image size.');
    }
    final output = BytesBuilder(copy: false);
    for (var offset = 0; offset < size;) {
      _check();
      final length = (size - offset).clamp(1, 1048576);
      final bytes = await (repository as ApiRepository).receiptBytes(
        '/receipts/$id/media/${image['id']}?ticket=${Uri.encodeQueryComponent(grant['ticket'])}&thumbnail=$thumbnail&offset=$offset&length=$length',
      );
      if (bytes.length != length) {
        throw ApiFailure('Image download was interrupted. Retry.');
      }
      output.add(bytes);
      offset += bytes.length;
    }
    _check();
    return output.takeBytes();
  }

  Future<void> removeImages(String id, int version) async {
    if (!demo) {
      await request('DELETE', '/receipts/$id/images', {'version': version});
      return;
    }
    final draft = drafts.firstWhere((d) => d['id'] == id);
    await store.remove(draft);
    draft['images'] = <Json>[];
    draft['server'] = {...object(draft['server']), 'imagesRemoved': true};
    await persist(draft);
  }

  Future<void> save(Json draft, Json expense, {bool edit = false}) async {
    _check();
    final path =
        '/groups/${draft['groupId']}/expenses${edit ? '/${draft['expenseId']}' : ''}';
    final payload = {
      ...expense,
      'id': draft['expenseId'],
      'receipt': {
        'receiptId': draft['id'],
        'version': object(draft['server'])['version'],
        'review': draft['review'],
        'payerConfirmed': true,
      },
    };
    // Once submitted, lock the exact body and UUID until an unambiguous result.
    draft['savePayload'] ??= payload;
    await persist(draft);
    try {
      final saved = await request(
        edit ? 'PUT' : 'POST',
        path,
        object(draft['savePayload']),
        draft['saveKey'],
      );
      if (demo) {
        draft['status'] = 'attached';
        draft['shares'] = saved['shares'];
        draft['server'] = {
          ...object(draft['server']),
          'state': 'attached',
          'expenseId': saved['id'],
          'revision': saved['version'],
        };
        await persist(draft);
      } else {
        await store.remove(draft);
        drafts.remove(draft);
        _notify();
      }
    } on ApiFailure catch (error) {
      if (error.status >= 400 && error.status < 500 && error.status != 401) {
        draft.remove('savePayload');
        draft['saveKey'] = const Uuid().v4();
        await persist(draft);
      }
      rethrow;
    }
  }

  Future<void> discard(Json draft) async {
    _check();
    await store.remove(draft);
    drafts.remove(draft);
    _notify();
  }

  Future<Json> sample(String groupId, List<String> participants) async {
    final draft = await create(groupId);
    final receipt = img.Image(width: 700, height: 1000, numChannels: 3);
    img.fill(receipt, color: img.ColorRgb8(253, 249, 235));
    const lines = [
      'HISAAB DEMO BILL',
      'Sunday Cafe',
      '-------------------------',
      'Paneer tikka        480.00',
      'Naan basket         180.00',
      'Lime soda x 2       160.00',
      'Subtotal            820.00',
      'CGST                  20.50',
      'SGST                  20.50',
      'TOTAL                861.00',
      '',
      'Sample only - no AI call',
    ];
    for (var i = 0; i < lines.length; i++) {
      img.drawString(
        receipt,
        lines[i],
        font: img.arial24,
        x: 35,
        y: 55 + i * 66,
        color: img.ColorRgb8(32, 51, 42),
      );
    }
    await addImage(
      draft,
      Uint8List.fromList(img.encodeJpg(receipt, quality: 88)),
    );
    draft['review'] = {
      ...emptyReceiptReview(),
      'merchant': 'Sunday Cafe',
      'grandTotalPaise': 86100,
      'subtotalPaise': 82000,
      'splitByItems': true,
      'items': [
        for (final item in [
          ('Paneer tikka', 48000, '1'),
          ('Naan basket', 18000, '1'),
          ('Lime soda', 16000, '2'),
        ])
          {
            'id': const Uuid().v4(),
            'name': item.$1,
            'quantity': item.$3,
            'unitPricePaise': item.$2 ~/ int.parse(item.$3),
            'lineTotalPaise': item.$2,
            'assigneeIds': participants,
            'ignored': false,
            'confidence': item.$1 == 'Lime soda' ? .6 : .98,
          },
      ],
      'charges': [
        for (final name in ['CGST', 'SGST'])
          {
            'id': const Uuid().v4(),
            'name': name,
            'kind': 'Tax',
            'amountPaise': 2050,
            'includedInItemPrices': false,
          },
      ],
    };
    draft['status'] = 'ready';
    draft['demoCounted'] = true;
    draft['server'] = {
      'id': draft['id'],
      'groupId': groupId,
      'version': 1,
      'state': 'ready',
      'media': draft['images'],
    };
    await persist(draft);
    await refreshAllowance();
    return draft;
  }

  Future<void> endSession() async {
    _closed = true;
    _timer?.cancel();
    drafts.clear();
    await store.clear();
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
