import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'money.dart';
import 'repository.dart';

/// An isolated, clearly labelled local playground. Never called by ApiRepository.
class DemoRepository implements Repository {
  Json state;
  DemoRepository._(this.state);
  static Future<DemoRepository> open() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('hisaab.demo.v1');
    final repo = DemoRepository._(
      raw == null
          ? {
              'groups': <dynamic>[],
              'expenses': <dynamic>[],
              'settlements': <dynamic>[],
              'activity': <dynamic>[],
              'preferences': {
                'expenses': true,
                'payments': true,
                'invites': true,
              },
            }
          : object(jsonDecode(raw)),
    );
    if (raw == null) await repo._seed();
    return repo;
  }

  @override
  bool get isDemo => true;
  @override
  bool get offline => false;
  @override
  Json get session => {
    'user': {
      'id': 'demo-you',
      'displayName': 'Aarav',
      'email': 'demo@example.invalid',
    },
    'entitlement': {'adFree': false, 'status': 'Free'},
  };
  List<dynamic> list(String key) => state[key] as List<dynamic>;
  Future<void> _save() async => (await SharedPreferences.getInstance())
      .setString('hisaab.demo.v1', jsonEncode(state));
  Json _group(String id) => object(
    list('groups').firstWhere(
      (g) => g['id'] == id,
      orElse: () => throw ApiFailure('Group not found.'),
    ),
  );
  void _put(String collection, Json record) {
    final index = list(collection).indexWhere((v) => v['id'] == record['id']);
    if (index >= 0) {
      list(collection)[index] = record;
    } else {
      list(collection).add(record);
    }
  }

  Json _detail(Json g) {
    final members = rows(g['members']);
    final pairs = {for (final m in members) m['id'] as String: <String, int>{}};
    void change(String from, String to, int amount) {
      if (from == to) return;
      pairs[from]![to] = (pairs[from]![to] ?? 0) + amount;
      pairs[to]![from] = (pairs[to]![from] ?? 0) - amount;
    }

    for (final e in list(
      'expenses',
    ).where((e) => e['groupId'] == g['id'] && e['deletedAt'] == null)) {
      object(
        e['shares'],
      ).forEach((id, amount) => change(e['payerId'], id, amount as int));
    }
    for (final p in list(
      'settlements',
    ).where((p) => p['groupId'] == g['id'] && p['disputed'] == false)) {
      change(p['fromId'], p['toId'], p['amountPaise']);
    }
    final balances = [
      for (final entry in pairs.entries)
        {
          'participantId': entry.key,
          'netPaise': entry.value.values.fold<int>(0, (a, b) => a + b),
          'counterparties': entry.value,
        },
    ];
    final me = members.firstWhere((m) => m['userId'] == 'demo-you')['id'];
    return {
      ...g,
      'balances': balances,
      'memberCount': members.length,
      'netPaise': balances.firstWhere(
        (b) => b['participantId'] == me,
      )['netPaise'],
    };
  }

  void _activity(
    String groupId,
    String kind,
    String entityId,
    String description,
  ) {
    list('activity').insert(0, {
      'id': const Uuid().v4(),
      'groupId': groupId,
      'kind': kind,
      'actorId': 'demo-you',
      'entityId': entityId,
      'description': description,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _version(Json record, Json data) {
    if (record['version'] != data['version']) {
      throw ApiFailure('This expense changed — review latest', status: 409);
    }
  }

  @override
  Future<Json> request(String method, String path, [Json? data]) async {
    final value = data ?? {};
    final uri = Uri.parse(path);
    final parts = uri.path.split('/').where((s) => s.isNotEmpty).toList();
    if (method == 'GET' && path == '/me') {
      return {
        'user': session['user'],
        'entitlement': session['entitlement'],
        'preferences': state['preferences'],
      };
    }
    if (path == '/me/preferences') {
      state['preferences'] = value;
      await _save();
      return value;
    }
    if (method == 'DELETE' && path == '/me') {
      await (await SharedPreferences.getInstance()).remove('hisaab.demo.v1');
      return {'status': 'Deleted'};
    }
    if (path == '/auth/sign-out') return {};
    if (path.startsWith('/billing')) return object(session['entitlement']);
    if (path == '/invites' && method == 'GET') return {'items': []};
    if (path == '/activity') return {'items': list('activity')};
    if (path == '/balances') {
      final friends = <String, Json>{};
      for (final raw in list('groups')) {
        final g = Group.from(_detail(object(raw)));
        final me = g.participant('demo-you')!;
        for (final p in g.pairs(me).entries) {
          final member = g.members.firstWhere((m) => m.id == p.key);
          final key = member.userId ?? member.id;
          friends[key] = {
            'id': key,
            'displayName': member.name,
            'netPaise': (friends[key]?['netPaise'] ?? 0) + p.value,
          };
        }
      }
      final amounts = friends.values.map((f) => f['netPaise'] as int);
      return {
        'netPaise': amounts.fold<int>(0, (a, b) => a + b),
        'owedPaise': amounts.where((v) => v > 0).fold<int>(0, (a, b) => a + b),
        'owingPaise': -amounts
            .where((v) => v < 0)
            .fold<int>(0, (a, b) => a + b),
        'friends': friends.values.toList(),
      };
    }
    if (path == '/groups') {
      if (method == 'GET') {
        return {
          'items': list('groups').map((g) => _detail(object(g))).toList(),
        };
      }
      final id = const Uuid().v4();
      final group = {
        'id': id,
        'name': value['name'],
        'type': value['type'],
        'version': 1,
        'archived': false,
        'creatorId': 'demo-you',
        'members': [
          {
            'id': '$id-you',
            'userId': 'demo-you',
            'displayName': 'You',
            'isPlaceholder': false,
            'isDeleted': false,
            'isExternal': false,
            'hasLeft': false,
          },
        ],
      };
      _put('groups', group);
      _activity(id, 'GroupCreated', id, 'Group created');
      await _save();
      return _detail(group);
    }
    if (parts.firstOrNull == 'groups' && parts.length >= 2) {
      var group = _group(parts[1]);
      if (parts.length == 2) {
        if (method == 'GET') return _detail(group);
        _version(group, value);
        if (method == 'DELETE') {
          if (Group.from(_detail(group)).balances.any(
            (b) => object(b['counterparties']).values.any((v) => v != 0),
          )) {
            throw ApiFailure('Settle outstanding balances before deleting.');
          }
          list('groups').removeWhere((g) => g['id'] == group['id']);
          await _save();
          return {};
        }
        group = {...group, ...value, 'version': group['version'] + 1};
        _put('groups', group);
        await _save();
        return _detail(group);
      }
      final resource = parts[2];
      if (resource == 'activity') {
        return {
          'items': list(
            'activity',
          ).where((a) => a['groupId'] == group['id']).toList(),
        };
      }
      if (method != 'GET' && group['archived'] == true) {
        throw ApiFailure('Reopen this group before making changes.');
      }
      if (resource == 'members') {
        if (rows(group['members']).length >=
            (group['type'] == 'Direct' ? 2 : 50)) {
          throw ApiFailure('This group has reached its member limit.');
        }
        final member = {
          'id': const Uuid().v4(),
          'displayName': value['displayName'],
          'isPlaceholder': true,
          'isDeleted': false,
          'isExternal': false,
          'hasLeft': false,
        };
        group['members'] = [...rows(group['members']), member];
        group['version']++;
        _put('groups', group);
        await _save();
        return member;
      }
      if (resource == 'invites') {
        throw ApiFailure(
          'Sharing live invitations needs a signed-in account. Demo data stays on this device.',
        );
      }
      if (resource == 'leave') {
        throw ApiFailure(
          'This demo account created the group. Archive it to keep its history.',
        );
      }
      if (resource == 'expenses') {
        if (method == 'GET') {
          final all =
              list(
                  'expenses',
                ).where((e) => e['groupId'] == group['id']).toList()
                ..sort((a, b) => b['date'].compareTo(a['date']));
          final offset = int.tryParse(uri.queryParameters['cursor'] ?? '') ?? 0;
          return {
            'items': all.skip(offset).take(25).toList(),
            'nextCursor': all.length > offset + 25 ? '${offset + 25}' : null,
          };
        }
        Json? old;
        if (parts.length >= 4) {
          old = object(list('expenses').firstWhere((e) => e['id'] == parts[3]));
          _version(old, value);
        }
        Json expense;
        if (method == 'DELETE' || parts.last == 'restore') {
          if (parts.last == 'restore' &&
              DateTime.now()
                      .difference(DateTime.parse(old!['deletedAt']))
                      .inDays >=
                  30) {
            throw ApiFailure('The 30-day restore window has ended.');
          }
          expense = {
            ...old!,
            'deletedAt': method == 'DELETE'
                ? DateTime.now().toUtc().toIso8601String()
                : null,
            'version': old['version'] + 1,
          };
        } else {
          final inputs = {
            for (final p in rows(value['participants']))
              p['participantId'] as String: p['value'] as int,
          };
          final shares = splitAmount(
            value['amountPaise'],
            value['mode'],
            inputs,
          );
          expense = {
            ...value,
            'groupId': group['id'],
            'shares': shares,
            'version': old == null ? 1 : old['version'] + 1,
            'createdBy': 'demo-you',
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          };
        }
        _put('expenses', expense);
        _activity(
          group['id'],
          'ExpenseChanged',
          expense['id'],
          old == null ? 'Expense added' : 'Expense updated',
        );
        await _save();
        return expense;
      }
      if (resource == 'settlements') {
        if (method == 'GET') {
          return {
            'items': list(
              'settlements',
            ).where((s) => s['groupId'] == group['id']).toList(),
          };
        }
        Json settlement;
        if (parts.last == 'dispute') {
          final old = object(
            list('settlements').firstWhere((s) => s['id'] == parts[3]),
          );
          _version(old, value);
          if (old['toId'] !=
              Group.from(_detail(group)).participant('demo-you')) {
            throw ApiFailure('Only the receiver can dispute a payment.');
          }
          if (old['disputed'] == true) {
            throw ApiFailure('This payment has already been disputed.');
          }
          settlement = {
            ...old,
            'disputed': true,
            'version': old['version'] + 1,
          };
        } else {
          final g = Group.from(_detail(group));
          final owed = -(g.pairs(value['fromId'])[value['toId']] ?? 0);
          if (value['amountPaise'] <= 0 || value['amountPaise'] > owed) {
            throw ApiFailure('Payment must not exceed the outstanding debt.');
          }
          settlement = {
            ...value,
            'groupId': g.id,
            'version': 1,
            'disputed': false,
            'createdBy': 'demo-you',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          };
        }
        _put('settlements', settlement);
        _activity(
          group['id'],
          'PaymentChanged',
          settlement['id'],
          'Payment recorded or disputed',
        );
        await _save();
        return settlement;
      }
    }
    throw ApiFailure(
      'This action needs a signed-in account. Demo data stays on this device.',
    );
  }

  @override
  Future<void> close() async {}
  Future<void> _seed() async {
    for (final item in [
      ('Goa, here we come', 'Trip'),
      ('Home sweet home', 'Home'),
      ('Weekend catch-ups', 'Direct'),
    ]) {
      final g = await request('POST', '/groups', {
        'name': item.$1,
        'type': item.$2,
      });
      final a = await request('POST', '/groups/${g['id']}/members', {
        'displayName': 'Meera',
      });
      final b = item.$2 == 'Direct'
          ? null
          : await request('POST', '/groups/${g['id']}/members', {
              'displayName': 'Rohan',
            });
      final me = rows(g['members']).first['id'];
      await request('POST', '/groups/${g['id']}/expenses', {
        'id': const Uuid().v4(),
        'description': item.$2 == 'Trip'
            ? 'Beachside dinner'
            : item.$2 == 'Home'
            ? 'Groceries for the week'
            : 'Coffee & conversations',
        'amountPaise': item.$2 == 'Trip'
            ? 246000
            : item.$2 == 'Home'
            ? 186000
            : 64000,
        'date': day(DateTime.now()),
        'payerId': item.$2 == 'Home' ? a['id'] : me,
        'mode': 'Equal',
        'participants': [
          {'participantId': me, 'value': 1},
          {'participantId': a['id'], 'value': 1},
          if (b != null) {'participantId': b['id'], 'value': 1},
        ],
      });
    }
  }
}
