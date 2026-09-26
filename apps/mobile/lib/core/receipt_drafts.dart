import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

/// Draft manifests and normalized image bytes are encrypted before disk writes.
/// Each account has an independent random key held by Keychain/Keystore.
class ReceiptDraftStore {
  final String account;
  final FlutterSecureStorage secure;
  final Directory? directoryOverride;
  final SecretKey? keyOverride;
  final _cipher = AesGcm.with256bits();
  Future<void> _writes = Future.value();
  Future<SecretKey>? _keyFuture;
  bool _closed = false;
  ReceiptDraftStore(
    this.account, {
    this.secure = const FlutterSecureStorage(),
    this.directoryOverride,
    this.keyOverride,
  });
  String get _accountHash => sha256.convert(utf8.encode(account)).toString();
  String get _keyName => 'hisaab.receipts.key.$_accountHash';
  Future<Directory> _directory() async {
    final root = directoryOverride ?? await getApplicationSupportDirectory();
    return Directory('${root.path}/receipt-drafts/$_accountHash');
  }

  Future<SecretKey> _key() => _keyFuture ??= () async {
    if (keyOverride != null) return keyOverride!;
    final saved = await secure.read(key: _keyName);
    if (saved != null) return SecretKey(base64Decode(saved));
    final key = await _cipher.newSecretKey();
    if (_closed) throw StateError('Draft store closed');
    await secure.write(
      key: _keyName,
      value: base64Encode(await key.extractBytes()),
    );
    return key;
  }();

  void _identifier(String id) {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(id)) {
      throw ArgumentError('Invalid draft identifier');
    }
  }

  Future<File> _file(String id, String suffix) async {
    _identifier(id);
    return File('${(await _directory()).path}/$id.$suffix');
  }

  Future<void> _write(File file, List<int> plaintext) async {
    if (_closed) throw StateError('Draft store closed');
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: await _key(),
      aad: utf8.encode(_accountHash),
    );
    if (_closed) throw StateError('Draft store closed');
    await file.parent.create(recursive: true);
    if (Platform.isIOS) {
      await const MethodChannel(
        'app.hisaab/receipts',
      ).invokeMethod<void>('protectDraftDirectory', {'path': file.parent.path});
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(box.concatenation(), flush: true);
    if (_closed) {
      await temporary.delete();
      return;
    }
    await temporary.rename(file.path);
  }

  Future<Uint8List> _read(File file) async {
    if (_closed) throw StateError('Draft store closed');
    final sealed = await file.readAsBytes();
    final bytes = await _cipher.decrypt(
      SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16),
      secretKey: await _key(),
      aad: utf8.encode(_accountHash),
    );
    if (_closed) throw StateError('Draft store closed');
    return Uint8List.fromList(bytes);
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(Json draft) {
    final frozen = utf8.encode(jsonEncode(draft));
    return _serial(
      () async => _write(await _file(draft['id'], 'draft'), frozen),
    );
  }

  Future<void> writeImage(String id, Uint8List bytes) =>
      _serial(() async => _write(await _file(id, 'image'), bytes));
  Future<Uint8List> image(String id) async => _read(await _file(id, 'image'));
  Future<void> removeImage(String id) => _serial(() async {
    final file = await _file(id, 'image');
    if (await file.exists()) await file.delete();
  });
  Future<List<Json>> load() async {
    await _writes;
    final directory = await _directory();
    if (!await directory.exists()) return [];
    final drafts = <Json>[];
    await for (final file in directory.list()) {
      if (file is File && file.path.endsWith('.draft')) {
        drafts.add(object(jsonDecode(utf8.decode(await _read(file)))));
      }
    }
    return drafts;
  }

  Future<void> remove(Json draft) => _serial(() async {
    final files = [
      await _file(draft['id'], 'draft'),
      for (final media in rows(draft['images']))
        await _file(media['id'], 'image'),
    ];
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
  });
  Future<void> clear() async {
    _closed = true;
    await _writes;
    final directory = await _directory();
    if (await directory.exists()) await directory.delete(recursive: true);
    if (keyOverride == null) await secure.delete(key: _keyName);
    _keyFuture = null;
  }
}

Json newReceiptDraft(String groupId, {String? expenseId}) => {
  'id': const Uuid().v4(),
  'expenseId': expenseId ?? const Uuid().v4(),
  'groupId': groupId,
  'images': <Json>[],
  'status': 'capture',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'createKey': const Uuid().v4(),
  'completeKey': const Uuid().v4(),
  'saveKey': const Uuid().v4(),
  'scanRequested': true,
};
