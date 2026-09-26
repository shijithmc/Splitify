import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
    try {
      final session = await _send('POST', '/auth/refresh', {
        'refreshToken': _session!['refreshToken'],
      }, const Uuid().v4());
      _session = session;
      await storage.write(key: 'hisaab.session', value: jsonEncode(session));
    } finally {
      _refreshing = null;
    }
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
