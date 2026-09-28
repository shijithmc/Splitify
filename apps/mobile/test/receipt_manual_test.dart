import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/receipt_drafts.dart';
import 'package:hisaab/core/receipts.dart';
import 'package:hisaab/core/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/receipt_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('new receipt drafts request manual attachment', () {
    expect(newReceiptDraft('group')['scanRequested'], isFalse);
  });

  test(
    'legacy queued scan preserves input and uploads as manual after restart',
    () async {
      final store = MemoryReceiptStore();
      final bytes = Uint8List.fromList([1, 2, 3]);
      final legacy = newReceiptDraft('group')
        ..['scanRequested'] = true
        ..['status'] = 'queued_upload'
        ..['consentIntent'] = 'old-consent'
        ..['consentKey'] = 'old-consent-command'
        ..['retryKey'] = 'old-retry-command'
        ..['retryVersion'] = 1
        ..['completeVersion'] = 1
        ..['review'] = {'merchant': 'Saved cafe', 'grandTotalPaise': 12000}
        ..['images'] = [
          {
            'id': 'photo',
            'contentType': 'image/jpeg',
            'sizeBytes': 3,
            'sha256': 'saved-checksum',
          },
        ];
      final originalCreateKey = legacy['createKey'];
      final originalCompleteKey = legacy['completeKey'];
      await store.save(legacy);
      await store.writeImage('photo', bytes);
      final calls = <http.Request>[];
      var created = false;
      final repository = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          calls.add(request);
          if (request.url.path == '/v1/groups/group/receipts') {
            final body = object(jsonDecode(request.body));
            created = true;
            expect(body['scanRequested'], isFalse);
            expect(body['id'], legacy['id']);
            expect(body['images'], legacy['images']);
            return http.Response(
              jsonEncode({
                'receipt': {
                  'id': legacy['id'],
                  'state': 'awaiting_upload',
                  'version': 2,
                },
                'uploads': [
                  {'id': 'photo', 'url': 'https://receipts.s3.example/photo'},
                ],
              }),
              200,
            );
          }
          if (request.url.host == 'receipts.s3.example') {
            expect(request.bodyBytes, bytes);
            return http.Response('', 200);
          }
          if (request.url.path.endsWith('/complete')) {
            expect(object(jsonDecode(request.body))['version'], 2);
            return http.Response('{"state":"validating","version":3}', 200);
          }
          if (request.method == 'GET' &&
              request.url.path == '/v1/receipts/${legacy['id']}') {
            if (!created) return http.Response('{"code":"not_found"}', 404);
            return http.Response(
              '{"groupId":"group","state":"manual_ready","version":4,"manualAvailable":true}',
              200,
            );
          }
          fail('Unexpected request: ${request.method} ${request.url.path}');
        }),
      );
      await repository.saveSession({
        'user': {'id': 'account'},
        'accessToken': 'test',
        'refreshToken': 'refresh',
      });
      var foreground = false;
      final coordinator = ReceiptCoordinator(
        repository: repository,
        account: 'account',
        current: () => true,
        foreground: () => foreground,
        store: store,
      );
      addTearDown(coordinator.dispose);
      addTearDown(repository.close);
      await coordinator.initialize();
      final draft = coordinator.drafts.single;
      expect(draft['scanRequested'], isFalse);
      expect(draft['createKey'], isNot(originalCreateKey));
      expect(draft['completeKey'], isNot(originalCompleteKey));
      expect(draft['completeVersion'], isNull);
      expect(draft['consentIntent'], isNull);
      expect(draft['consentKey'], isNull);
      expect(draft['retryKey'], isNull);
      expect(draft['retryVersion'], isNull);
      expect(draft['review'], legacy['review']);
      expect(await store.image('photo'), bytes);
      expect(calls, isEmpty);
      foreground = true;
      await coordinator.pump();
      expect(draft['status'], 'manual_ready');
      expect(draft['review'], legacy['review']);
      expect(calls, hasLength(5));
      expect(store.records[draft['id']]!['scanRequested'], isFalse);
    },
  );

  test(
    'legacy lost upload completion resumes the saved manual receipt',
    () async {
      final store = MemoryReceiptStore();
      final legacy = newReceiptDraft('group')
        ..['scanRequested'] = true
        ..['status'] = 'queued_upload'
        ..['images'] = [
          {'id': 'photo'},
        ]
        ..['review'] = {'merchant': 'Saved cafe', 'grandTotalPaise': 12000};
      await store.save(legacy);
      final calls = <http.Request>[];
      final repository = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          calls.add(request);
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/receipts/${legacy['id']}');
          return http.Response(
            '{"groupId":"group","state":"manual_ready","version":8,"manualAvailable":true}',
            200,
          );
        }),
      );
      var foreground = false;
      final coordinator = ReceiptCoordinator(
        repository: repository,
        account: 'account',
        current: () => true,
        foreground: () => foreground,
        store: store,
      );
      addTearDown(coordinator.dispose);
      addTearDown(repository.close);
      await coordinator.initialize();
      foreground = true;
      await coordinator.pump();
      expect(coordinator.drafts.single['status'], 'manual_ready');
      expect(coordinator.drafts.single['review'], legacy['review']);
      expect(coordinator.drafts.single['needsManualResume'], isNull);
      expect(calls, hasLength(2));
    },
  );

  test(
    'legacy upload resumes if worker finishes between preflight and create',
    () async {
      final store = MemoryReceiptStore();
      final legacy = newReceiptDraft('group')
        ..['scanRequested'] = true
        ..['status'] = 'queued_upload'
        ..['images'] = [
          {'id': 'photo'},
        ];
      await store.save(legacy);
      var attempts = 0;
      var reads = 0;
      final repository = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            attempts++;
            expect(request.url.path, '/v1/groups/group/receipts');
            expect(object(jsonDecode(request.body))['scanRequested'], isFalse);
            return http.Response('{"code":"receipt_exists"}', 409);
          }
          reads++;
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/receipts/${legacy['id']}');
          return http.Response(
            jsonEncode({
              'groupId': 'group',
              'state': reads == 1 ? 'awaiting_upload' : 'manual_ready',
              'version': reads == 1 ? 1 : 8,
              'manualAvailable': reads > 1,
            }),
            200,
          );
        }),
      );
      var foreground = false;
      final coordinator = ReceiptCoordinator(
        repository: repository,
        account: 'account',
        current: () => true,
        foreground: () => foreground,
        store: store,
      );
      addTearDown(coordinator.dispose);
      addTearDown(repository.close);
      await coordinator.initialize();
      foreground = true;
      await coordinator.pump();
      expect(coordinator.drafts.single['status'], 'manual_ready');
      expect(coordinator.drafts.single['error'], isNull);
      expect(attempts, 1);
      expect(reads, 3);
    },
  );

  test('historical extracted receipt retains its reviewed details', () async {
    final store = MemoryReceiptStore();
    final legacy = newReceiptDraft('group')
      ..['scanRequested'] = true
      ..['status'] = 'ready'
      ..['server'] = {
        'state': 'ready',
        'version': 5,
        'media': [
          {'id': 'saved-photo'},
        ],
      }
      ..['review'] = {'merchant': 'Historical cafe', 'grandTotalPaise': 45000};
    await store.save(legacy);
    final repository = ApiRepository(
      'https://api.invalid',
      client: MockClient((request) async {
        fail(
          'Ready historical receipts should not make requests during migration.',
        );
      }),
    );
    final coordinator = ReceiptCoordinator(
      repository: repository,
      account: 'account',
      current: () => true,
      foreground: () => true,
      store: store,
    );
    addTearDown(coordinator.dispose);
    addTearDown(repository.close);
    await coordinator.initialize();
    expect(coordinator.drafts.single['status'], 'ready');
    expect(coordinator.drafts.single['review'], legacy['review']);
    expect(coordinator.drafts.single['server'], legacy['server']);
  });
}
