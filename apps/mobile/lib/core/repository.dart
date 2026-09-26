import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'models.dart';

abstract class Repository {
  bool get isDemo;
  bool get offline;
  Json? get session;
  Future<Json> request(String method, String path, [Json? data]);
  Future<void> close();
}

class ApiRepository implements Repository {
  final String baseUrl;
  final http.Client client;
  final FlutterSecureStorage storage;
  Json? _session;
  final Map<String, Json> _cache = {};
  Future<void>? _refreshing;
  bool _offline = false;
  bool _closed = false;
  final Map<String, String> _pendingKeys = {};
  ApiRepository(
    this.baseUrl, {
    http.Client? client,
    FlutterSecureStorage? storage,
  }) : client = client ?? http.Client(),
       storage = storage ?? const FlutterSecureStorage();
  @override
  bool get isDemo => false;
  @override
  bool get offline => _offline;
  @override
  Json? get session => _session;
  String get _account => _session?['user']?['id'] ?? '';
  Future<void> restore() async {
    final saved = await storage.read(key: 'hisaab.session');
    if (saved == null) return;
    _session = object(jsonDecode(saved));
    final cache = await storage.read(key: 'hisaab.cache.$_account');
    if (cache != null) {
      _cache.addAll(
        object(jsonDecode(cache)).map((k, v) => MapEntry(k, object(v))),
      );
    }
  }

  Future<void> saveSession(Json value) async {
    if (_account.isNotEmpty && _account != value['user']['id']) {
      await storage.delete(key: 'hisaab.cache.$_account');
    }
    _cache.clear();
    _pendingKeys.clear();
    _closed = false;
    _session = value;
    await storage.write(key: 'hisaab.session', value: jsonEncode(value));
  }

  Future<Json> _send(String method, String path, Json? data, String key) async {
    if (_closed) {
      throw ApiFailure('Session ended. Please sign in again.', status: 401);
    }
    final request = http.Request(method, Uri.parse('$baseUrl/v1$path'));
    request.headers.addAll({
      'Content-Type': 'application/json',
      if (_session != null)
        'Authorization': 'Bearer ${_session!['accessToken']}',
      if (method != 'GET') 'Idempotency-Key': key,
    });
    if (data != null) request.body = jsonEncode(data);
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 12));
    if (_closed) {
      throw ApiFailure('Session ended. Please sign in again.', status: 401);
    }
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : object(jsonDecode(response.body));
    if (response.statusCode >= 400) {
      throw ApiFailure(
        decoded['message'] ?? 'Request failed. Please try again.',
        code: decoded['code'] ?? 'request_failed',
        status: response.statusCode,
      );
    }
    return decoded;
  }

  Future<void> _refresh() async {
    final previous = _session;
    try {
      final session = await _send('POST', '/auth/refresh', {
        'refreshToken': _session!['refreshToken'],
      }, const Uuid().v4());
      if (_closed ||
          !identical(previous, _session) ||
          session['user']?['id'] != previous?['user']?['id']) {
        throw ApiFailure('Account changed. Please sign in again.', status: 401);
      }
      _session = session;
      await storage.write(key: 'hisaab.session', value: jsonEncode(session));
    } finally {
      _refreshing = null;
    }
  }

  /// Receipt drafts persist their own command UUIDs. Sensitive receipt reads
  /// deliberately bypass the general offline JSON cache.
  Future<Json> receiptRequest(
    String method,
    String path,
    Json? data,
    String key,
  ) async {
    final account = _account;
    try {
      Json result;
      try {
        result = await _send(method, path, data, key);
      } on ApiFailure catch (error) {
        if (error.status != 401 || _session == null) rethrow;
        await (_refreshing ??= _refresh());
        result = await _send(method, path, data, key);
      }
      if (_closed || account != _account) {
        throw ApiFailure('Account changed.', status: 401);
      }
      _offline = false;
      return result;
    } on SocketException {
      return _networkFailure(method, path);
    } on http.ClientException {
      return _networkFailure(method, path);
    } on TimeoutException {
      return _networkFailure(method, path);
    }
  }

  Future<void> uploadReceipt(
    Json upload,
    Uint8List bytes,
    void Function(double) progress,
  ) async {
    final account = _account;
    if (_closed || account.isEmpty) {
      throw ApiFailure('Sign in again.', status: 401);
    }
    var uri = Uri.parse(upload['url']);
    final api = Uri.parse(baseUrl);
    final localUpload =
        !uri.hasScheme &&
        !uri.hasAuthority &&
        uri.path.startsWith('/v1/receipts/');
    if (localUpload) uri = api.resolveUri(uri);
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            uri.host == api.host &&
            api.scheme == 'http')) {
      throw ApiFailure('Unsafe receipt upload URL.');
    }
    final request = http.StreamedRequest(upload['method'] ?? 'PUT', uri);
    request.contentLength = bytes.length;
    request.headers.addAll(
      object(upload['headers']).map((k, v) => MapEntry(k, '$v')),
    );
    if (localUpload) {
      request.headers['Authorization'] = 'Bearer ${_session?['accessToken']}';
    }
    // Upload authorization is supplied by the server; never forward our session
    // to S3 or another upload origin.
    final response = client.send(request);
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      if (_closed || account != _account) {
        await request.sink.close();
        throw ApiFailure('Account changed.', status: 401);
      }
      final end = (offset + 65536).clamp(0, bytes.length);
      request.sink.add(bytes.sublist(offset, end));
      progress(end / bytes.length);
    }
    await request.sink.close();
    final result = await response.timeout(const Duration(seconds: 90));
    await result.stream.drain<void>();
    if (_closed || account != _account) {
      throw ApiFailure('Account changed.', status: 401);
    }
    if (result.statusCode >= 400) {
      throw ApiFailure(
        'Upload expired or failed. Retry when connected.',
        code: 'upload_failed',
      );
    }
  }

  Future<Uint8List> receiptBytes(String path) async {
    final account = _account;
    Future<http.Response> send() async => client
        .get(
          Uri.parse('$baseUrl/v1$path'),
          headers: {
            'Authorization': 'Bearer ${_session?['accessToken']}',
            'Cache-Control': 'no-store',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (_closed || account.isEmpty) {
      throw ApiFailure('Sign in again.', status: 401);
    }
    var result = await send();
    if (result.statusCode == 401 && !_closed) {
      await (_refreshing ??= _refresh());
      result = await send();
    }
    if (_closed || account != _account) {
      throw ApiFailure('Account changed.', status: 401);
    }
    if (result.statusCode >= 400) {
      throw ApiFailure(
        'Receipt image is unavailable. Refresh to check access.',
        status: result.statusCode,
      );
    }
    if (result.bodyBytes.length > 1048576) {
      throw ApiFailure('Receipt image response exceeded its limit.');
    }
    return result.bodyBytes;
  }

  @override
  Future<Json> request(String method, String path, [Json? data]) async {
    if (_offline && method != 'GET') {
      throw ApiFailure(
        'You are offline. Refresh before making changes.',
        code: 'offline',
      );
    }
    final command = jsonEncode([method, path, data]);
    final key = method == 'GET'
        ? const Uuid().v4()
        : _pendingKeys.putIfAbsent(command, () => const Uuid().v4());
    try {
      Json value;
      try {
        value = await _send(method, path, data, key);
      } on ApiFailure catch (error) {
        if (error.status != 401 ||
            _session == null ||
            path.startsWith('/auth/')) {
          rethrow;
        }
        await (_refreshing ??= _refresh());
        value = await _send(method, path, data, key);
      }
      _offline = false;
      _pendingKeys.remove(command);
      if (method == 'GET' && _account.isNotEmpty) {
        _cache[path] = value;
        await storage.write(
          key: 'hisaab.cache.$_account',
          value: jsonEncode(_cache),
        );
      }
      return value;
    } on SocketException {
      return _networkFailure(method, path);
    } on http.ClientException {
      return _networkFailure(method, path);
    } on TimeoutException {
      return _networkFailure(method, path);
    }
  }

  Json _networkFailure(String method, String path) {
    _offline = true;
    if (method == 'GET' && _cache.containsKey(path)) return _cache[path]!;
    throw ApiFailure(
      'Connection unavailable. Saved data is read-only; refresh to reconnect.',
      code: 'offline',
    );
  }

  @override
  Future<void> close() async {
    final account = _account;
    _closed = true;
    _session = null;
    _cache.clear();
    _pendingKeys.clear();
    await storage.delete(key: 'hisaab.session');
    if (account.isNotEmpty) await storage.delete(key: 'hisaab.cache.$account');
    client.close();
  }
}
