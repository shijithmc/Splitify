import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/demo_repository.dart';
import 'package:hisaab/core/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'expense edit delete restore and settlement dispute conserve balances',
    () async {
      final repo = await DemoRepository.open();
      final created = await repo.request('POST', '/groups', {
        'name': 'Test',
        'type': 'Other',
      });
      final gid = created['id'];
      final me = created['members'][0]['id'];
      final other = (await repo.request('POST', '/groups/$gid/members', {
        'displayName': 'Friend',
      }))['id'];
      final payload = {
        'id': 'e1',
        'description': 'Lunch',
        'date': '2026-09-26',
        'amountPaise': 10000,
        'payerId': me,
        'mode': 'Equal',
        'participants': [
          {'participantId': me, 'value': 1},
          {'participantId': other, 'value': 1},
        ],
      };
      final expense = await repo.request(
        'POST',
        '/groups/$gid/expenses',
        payload,
      );
      Group detail = Group.from(await repo.request('GET', '/groups/$gid'));
      expect(detail.netFor(me), 5000);
      expect(detail.netFor(other), -5000);
      final deleted = await repo.request('DELETE', '/groups/$gid/expenses/e1', {
        'version': expense['version'],
      });
      expect(
        Group.from(await repo.request('GET', '/groups/$gid')).netFor(me),
        0,
      );
      await repo.request('POST', '/groups/$gid/expenses/e1/restore', {
        'version': deleted['version'],
      });
      final paid = await repo.request('POST', '/groups/$gid/settlements', {
        'id': 'p1',
        'fromId': other,
        'toId': me,
        'amountPaise': 2000,
        'method': 'UPI',
      });
      expect(
        Group.from(await repo.request('GET', '/groups/$gid')).netFor(me),
        3000,
      );
      await repo.request('POST', '/groups/$gid/settlements/p1/dispute', {
        'version': paid['version'],
      });
      detail = Group.from(await repo.request('GET', '/groups/$gid'));
      expect(detail.netFor(me), 5000);
      expect(detail.netFor(other), -5000);
      await expectLater(
        repo.request('POST', '/groups/$gid/settlements/p1/dispute', {
          'version': paid['version'],
        }),
        throwsA(isA<ApiFailure>()),
      );
      final reopened = await DemoRepository.open();
      expect(
        Group.from(await reopened.request('GET', '/groups/$gid')).netFor(me),
        5000,
      );
    },
  );
}
