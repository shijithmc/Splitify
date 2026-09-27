import 'dart:convert';
import 'dart:typed_data';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/receipt_drafts.dart';
import 'package:hisaab/core/receipts.dart';

class MemoryReceiptStore extends ReceiptDraftStore {
  MemoryReceiptStore() : super('demo-you');
  final records = <String, Json>{};
  final images = <String, Uint8List>{};
  @override
  Future<void> save(Json draft) async =>
      records[draft['id']] = object(jsonDecode(jsonEncode(draft)));
  @override
  Future<List<Json>> load() async => records.values.toList();
  @override
  Future<void> writeImage(String id, Uint8List bytes) async {
    images[id] = bytes;
  }

  @override
  Future<Uint8List> image(String id) async => images[id]!;
  @override
  Future<void> removeImage(String id) async {
    images.remove(id);
  }

  @override
  Future<void> remove(Json draft) async {
    records.remove(draft['id']);
    for (final media in rows(draft['images'])) {
      images.remove(media['id']);
    }
  }

  @override
  Future<void> clear() async {
    records.clear();
    images.clear();
  }
}

class ReceiptTestController extends AppController {
  ReceiptCoordinator? receiptOverride;
  @override
  ReceiptCoordinator get receipts => receiptOverride ?? super.receipts;
}
