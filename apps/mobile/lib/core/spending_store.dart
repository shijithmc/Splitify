import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

/// Personal finances never enter the shared-expense repository. Only this
/// account-bound, authenticated ciphertext is written to disk.
class SpendingStore {
  final String account;
  final FlutterSecureStorage secure;
  final Directory? directoryOverride;
  final SecretKey? keyOverride;
  final _cipher = AesGcm.with256bits();
  Future<void> _writes = Future.value();
  Future<SecretKey>? _keyFuture;
  bool _closed = false;

  SpendingStore(
    this.account, {
    this.secure = const FlutterSecureStorage(),
    this.directoryOverride,
    this.keyOverride,
  }) {
    if (account.trim().isEmpty) throw ArgumentError('Account is required');
  }

  String get _accountHash => sha256.convert(utf8.encode(account)).toString();
  String get _keyName => 'hisaab.spending.key.$_accountHash';
  List<int> get _aad => utf8.encode('hisaab.spending.v1:$_accountHash');
  void _checkOpen() {
    if (_closed) throw StateError('Spending store closed');
  }

  Future<Directory> _directory() async {
    final root = directoryOverride ?? await getApplicationSupportDirectory();
    return Directory('${root.path}/personal-spending/$_accountHash');
  }

  Future<SecretKey> _key() => _keyFuture ??= () async {
    _checkOpen();
    if (keyOverride != null) return keyOverride!;
    final saved = await secure.read(key: _keyName);
    _checkOpen();
    if (saved != null) return SecretKey(base64Decode(saved));
    final key = await _cipher.newSecretKey();
    _checkOpen();
    await secure.write(
      key: _keyName,
      value: base64Encode(await key.extractBytes()),
    );
    _checkOpen();
    return key;
  }();

  Future<void> _serial(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<Json?> load() async {
    _checkOpen();
    await _writes;
    final file = File('${(await _directory()).path}/ledger.bin');
    _checkOpen();
    if (!await file.exists()) return null;
    final sealed = await file.readAsBytes();
    final plaintext = await _cipher.decrypt(
      SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16),
      secretKey: await _key(),
      aad: _aad,
    );
    _checkOpen();
    return object(jsonDecode(utf8.decode(plaintext)));
  }

  Future<void> save(Json value) {
    _checkOpen();
    // Snapshot before queuing: callers cannot mutate a pending write.
    final plaintext = utf8.encode(jsonEncode(value));
    return _serial(() async {
      _checkOpen();
      final box = await _cipher.encrypt(
        plaintext,
        secretKey: await _key(),
        aad: _aad,
      );
      _checkOpen();
      final directory = await _directory();
      await directory.create(recursive: true);
      if (Platform.isIOS) {
        await const MethodChannel(
          'app.hisaab/receipts',
        ).invokeMethod<void>('protectDraftDirectory', {'path': directory.path});
      }
      final temporary = File('${directory.path}/${const Uuid().v4()}.tmp');
      try {
        await temporary.writeAsBytes(box.concatenation(), flush: true);
        _checkOpen();
        await temporary.rename('${directory.path}/ledger.bin');
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }

  /// Stop queued writes immediately, then optionally destroy this account's
  /// ledger and key. A new session must create a new store instance.
  Future<void> close({bool delete = false}) async {
    _closed = true;
    await _writes;
    if (delete) {
      final directory = await _directory();
      if (await directory.exists()) await directory.delete(recursive: true);
      if (keyOverride == null) await secure.delete(key: _keyName);
      _keyFuture = null;
    }
  }
}
