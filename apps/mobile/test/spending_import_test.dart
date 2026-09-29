import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/spending_import.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final when = DateTime.utc(2026, 9, 29, 9, 30);

  group('financial SMS parser', () {
    test(
      'all supported sender aliases parse a structured debit without raw data',
      () {
        final senders = [
          'SBIINB',
          'HDFCBK',
          'ICICIB',
          'AXISBK',
          'KOTAKB',
          'PNBSMS',
          'BOBTXN',
          'CANBNK',
          'UNIONB',
          'IDFCFB',
          'YESBNK',
          'INDUSB',
          'AUBANK',
          'FEDBNK',
          'PAYTMB',
        ];
        for (final sender in senders) {
          final row = parseFinancialSms(
            'INR 1,250.50 debited from a/c XX1234 at Swiggy on 29-09-2026. UPI Ref 123456789012. Avl Bal INR 8,700.',
            sender: 'VM-$sender',
            date: when,
          )!;
          expect(row['amountPaise'], 125050, reason: sender);
          expect(row['title'], 'Swiggy');
          expect(row['category'], 'Food & cafés');
          expect(row['accountLast4'], '1234');
          expect(row['reference'], '123456789012');
          expect(row['kind'], 'debit');
          expect(row.containsKey('body'), isFalse);
          expect(row.containsKey('sender'), isFalse);
        }
      },
    );
    test('ignores OTP, personal, failed, pending, upcoming and bills due', () {
      for (final body in [
        'OTP 834781 for INR 500 debited from a/c 1234',
        'INR 500 debit failed',
        'INR 500 paid pending',
        'INR 500 will be debited tomorrow',
        'Your card minimum due INR 500. You spent INR 900.',
        'UPI request received for INR 500',
        'Your INR 500 purchase declined',
      ]) {
        expect(
          parseFinancialSms(body, sender: 'VM-HDFCBK', date: when),
          isNull,
          reason: body,
        );
      }
      expect(
        parseFinancialSms(
          'INR 500 paid to me',
          sender: '+919999999999',
          date: when,
        ),
        isNull,
      );
      expect(
        parseFinancialSms('Good morning', sender: 'VM-HDFCBK', date: when),
        isNull,
      );
    });
    test('requires recognized sender even if body claims a bank name', () {
      expect(
        parseFinancialSms(
          'HDFC INR 500 debited from a/c1234',
          sender: 'VM-UNKNOWN',
          date: when,
        ),
        isNull,
      );
    });
    test('credit, refund, explicit own-transfer and P2P are distinct', () {
      expect(
        parseFinancialSms(
          'INR 52,000 credited to a/c1234 from ACME on 29-09-2026',
          sender: 'VM-SBIINB',
          date: when,
        )!['kind'],
        'credit',
      );
      expect(
        parseFinancialSms(
          'INR 500 refund credited to a/c1234 from Amazon on 29-09-2026',
          sender: 'VM-HDFCBK',
          date: when,
        )!['kind'],
        'refund',
      );
      expect(
        parseFinancialSms(
          'INR 500 debited from a/c1234 for self transfer',
          sender: 'VM-HDFCBK',
          date: when,
        )!['kind'],
        'transfer',
      );
      expect(
        parseFinancialSms(
          'INR 500 withdrawn from a/c1234 at ATM',
          sender: 'VM-HDFCBK',
          date: when,
        )!['kind'],
        'transfer',
      );
      final p2p = parseFinancialSms(
        'INR 500 transferred to Asha via UPI from a/c1234',
        sender: 'VM-HDFCBK',
        date: when,
      )!;
      expect(p2p['kind'], 'debit');
      expect(p2p['title'], 'Transfer to Asha');
      expect(p2p['category'], 'Other');
    });
    test('unknown UPI merchant remains spending, not an excluded transfer', () {
      final row = parseFinancialSms(
        'INR 500 debited from a/c1234 to ACME on 29-09-2026 via UPI',
        sender: 'VM-HDFCBK',
        date: when,
      )!;
      expect(row['kind'], 'debit');
      expect(row['category'], 'Other');
    });
    test('reference identity survives repeated notification timestamps', () {
      const sms =
          'Rs. 120.00 paid at Coffee Cafe on 29-09-2026 from a/c1234. UPI Ref 123456789012';
      final a = parseFinancialSms(sms, sender: 'VM-HDFCBK', date: when)!;
      final b = parseFinancialSms(
        sms,
        sender: 'VM-HDFCBK',
        date: when.add(const Duration(minutes: 1)),
      )!;
      expect(a['importId'], b['importId']);
      expect(
        parseFinancialSms(
          sms.replaceFirst('120.00', '130.00'),
          sender: 'VM-HDFCBK',
          date: when,
        )!['importId'],
        isNot(a['importId']),
      );
    });
    test(
      'amounts use integer paise and reject invalid precision or ambiguity',
      () {
        expect(
          parseFinancialSms(
            'INR 1.05 debited from a/c1234',
            sender: 'VM-HDFCBK',
            date: when,
          )!['amountPaise'],
          105,
        );
        expect(
          parseFinancialSms(
            'INR 0 debited from a/c1234',
            sender: 'VM-HDFCBK',
            date: when,
          ),
          isNull,
        );
        expect(
          parseFinancialSms(
            'INR 1.999 debited from a/c1234',
            sender: 'VM-HDFCBK',
            date: when,
          ),
          isNull,
        );
        expect(
          parseFinancialSms(
            'INR 500 debited and INR 500 credited',
            sender: 'VM-HDFCBK',
            date: when,
          ),
          isNull,
        );
      },
    );
  });

  test('SMS never guesses transaction amount from an available balance', () {
    expect(
      parseFinancialSms(
        'Avl Bal INR 9000. INR 500 debited from a/c1234',
        sender: 'VM-HDFCBK',
        date: when,
      ),
      isNull,
    );
    final row = parseFinancialSms(
      'INR 500 debited at MERCHANT123456789012 on 29-09-2026',
      sender: 'VM-HDFCBK',
      date: when,
    )!;
    expect(row['title'], 'MERCHANT••••');
  });

  group('statement imports', () {
    test(
      'reads quoted commas, escaped quotes, Indian dates and debit/credit columns',
      () {
        final rows = parseCsv(
          'Date,Description,Debit,Credit,Account\r\n29/09/2026,"Cafe, \\"Main\\"",125.50,,123456789012\r\n30/09/2026,Salary,,50000,123456789012'
              .replaceAll('\\"', '""'),
        );
        expect(rows, hasLength(2));
        expect(rows[0]['title'], 'Cafe, "Main"');
        expect(rows[0]['amountPaise'], 12550);
        expect(rows[0]['accountLast4'], '9012');
        expect(rows[0]['date'], startsWith('2026-09-29'));
        expect(rows[1]['kind'], 'credit');
      },
    );
    test('explicit type and amount CSV round trips four kinds', () {
      final rows = parseCsv(
        'Date,Description,Amount,Type\n2026-09-29,Coffee,120.50,debit\n2026-09-29,Salary,50000,credit\n2026-09-29,Amazon,499,refund\n2026-09-29,My bank,3000,transfer',
      );
      expect(rows.map((r) => r['kind']), [
        'debit',
        'credit',
        'refund',
        'transfer',
      ]);
      expect(rows.first['amountPaise'], 12050);
    });
    test(
      'signed amounts are explicit but unsigned ambiguous values rejected',
      () {
        expect(
          parseCsv(
            'Date,Description,Amount\n2026-09-29,Coffee,-120',
          ).single['kind'],
          'debit',
        );
        expect(
          parseCsv(
            'Date,Description,Amount\n2026-09-29,Refund,+120',
          ).single['kind'],
          'credit',
        );
        expect(
          () => parseCsv('Date,Description,Amount\n2026-09-29,Coffee,120'),
          throwsFormatException,
        );
      },
    );
    test('rejects malformed rows instead of partially importing', () {
      for (final csv in [
        'Date,Description,Debit,Credit\n31/02/2026,Coffee,120,',
        'Date,Description,Debit,Credit\n2026-02-30,Coffee,120,',
        'Date,Description,Debit,Credit\n2026-09-29,Coffee,120,120',
        'Date,Description,Debit,Credit\n2026-09-29,Coffee,120.001,',
        'Date,Description,Amount,Type\n2026-09-29,Coffee,120',
        'Date,Description,Amount,Type\n2026-09-29,"Coffee,120,debit',
      ]) {
        expect(() => parseCsv(csv), throwsFormatException, reason: csv);
      }
    });
    test('protects imported labels and strips full account digits', () {
      final row = parseCsv(
        'Date,Description,Amount,Type\n2026-09-29,=SUM(A1) 123456789012,120,debit',
      ).single;
      expect(row['title'], "'=SUM(A1) ••••");
    });
    test('IDs are stable on reimport and do not merge different references', () {
      const csv =
          'Date,Description,Amount,Type,Reference\n2026-09-29,Coffee,120,debit,ABC123\n2026-09-29,Coffee,120,debit,ABC124';
      final rows = parseCsv(csv);
      expect(rows[0]['importId'], isNot(rows[1]['importId']));
      expect(rows, parseCsv(csv));
    });
    test(
      'PDF text parses explicit financial directions and ignores balances',
      () {
        final rows = parseStatementText(
          'Statement September\n29/09/2026 Coffee Cafe 120.50 DR 10,000.00\n30/09/2026 Salary 50,000.00 CR\n30/09/2026 Closing balance 59,879.50 CR',
        );
        expect(rows, hasLength(2));
        expect(rows.first['amountPaise'], 12050);
        expect(rows.first['title'], 'Coffee Cafe');
        expect(rows.last['kind'], 'credit');
      },
    );
    test(
      'PDF without reliable transaction direction fails with fallback guidance',
      () {
        expect(
          () => parseStatementText('29/09/2026 Coffee 120.00 10000.00'),
          throwsFormatException,
        );
        expect(
          () => parseStatementText('Opening balance Rs 10000'),
          throwsFormatException,
        );
      },
    );
  });

  test('CSV preserves optional structured bank identity', () {
    final bank = parseCsv(
      'Date,Description,Amount,Type,Bank,Account,Reference\n2026-09-29,Coffee,120,debit,HDFC,1234,ABC123',
    ).single;
    expect(bank['bank'], 'HDFC');
    expect(bank['accountLast4'], '1234');
    expect(bank['reference'], 'ABC123');
    final blank = parseCsv(
      'Date,Description,Amount,Type,Bank\n2026-09-29,Coffee,120,debit,',
    ).single;
    expect(blank.containsKey('bank'), isFalse);
  });

  test('statement titles and merchant keys support non-Latin text', () {
    final row = parseCsv(
      'Date,Description,Amount,Type\n2026-09-29,चाय,20,debit',
    ).single;
    expect(row['title'], 'चाय');
    expect(row['merchantKey'], isNotEmpty);
    final symbol = parseCsv(
      'Date,Description,Amount,Type\n2026-09-29,☕,20,debit',
    ).single;
    expect(symbol.containsKey('merchantKey'), isFalse);
    expect(symbol['importId'], isNot(row['importId']));
  });

  test(
    'mixed supported and unsupported PDF rows do not import a partial ledger',
    () {
      expect(
        () => parseStatementText(
          '29/09/2026 Coffee 120.00 DR\n30/09/2026 Amazon 500.00 9980.00',
        ),
        throwsFormatException,
      );
    },
  );

  group('native contract', () {
    const channel = MethodChannel('test.hisaab/spending');
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'smsEnabled' => true,
              'importSms' => {
                'transactions': [
                  {'importId': 'stable', 'amountPaise': 12000},
                ],
                'unrecognizedCount': 2,
                'truncated': true,
              },
              'pdfText' => '29/09/2026 Coffee 120.00 DR',
              _ => null,
            };
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    test(
      'non-Android never requests SMS permission or invokes SMS channel',
      () async {
        final service = SpendingImportService(channel: channel, android: false);
        expect(service.supportsSms, isFalse);
        await service.configureOwner('someone');
        expect(await service.smsEnabled(), isFalse);
        expect(await service.importSms(requestPermission: true), isEmpty);
        await service.disableSms();
        expect(calls, isEmpty);
      },
    );
    test(
      'hashes owner, never prompts on background refresh, ACKs structured IDs',
      () async {
        final service = SpendingImportService(channel: channel, android: true);
        await service.configureOwner('private-user');
        expect(calls.single.arguments, {
          'owner': sha256.convert(utf8.encode('private-user')).toString(),
        });
        expect(await service.smsEnabled(), isTrue);
        expect(await service.importSms(), hasLength(1));
        expect(calls.last.arguments, {
          'requestPermission': false,
          'generation': null,
          'owner': sha256.convert(utf8.encode('private-user')).toString(),
        });
        expect(service.unrecognizedCount, 2);
        expect(service.truncated, isTrue);
        await service.acknowledgeSms();
        expect(calls.last.method, 'acknowledgeSms');
        expect((calls.last.arguments as Map)['ids'], ['stable']);
        await service.clearImportedData();
        expect(service.unrecognizedCount, 0);
        expect(service.truncated, isFalse);
        await service.configureOwner(null);
        expect(calls.last.arguments, {'owner': null});
      },
    );
    test(
      'permission request needs explicit flag and PDF uses password channel',
      () async {
        final service = SpendingImportService(channel: channel, android: true);
        await service.importSms(requestPermission: true);
        expect(calls.last.arguments, {
          'requestPermission': true,
          'owner': null,
          'generation': null,
        });
        await service.pdfText(
          '/tmp/statement.pdf',
          password: 'private-password',
        );
        expect(calls.last.arguments, {
          'path': '/tmp/statement.pdf',
          'password': 'private-password',
        });
      },
    );
    test('disable and clear carry owner and consent generation', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'setOwner' => 7,
              'disableSms' => 8,
              'clearImportedData' => 9,
              _ => null,
            };
          });
      final service = SpendingImportService(channel: channel, android: true);
      await service.configureOwner('first-user');
      await service.disableSms();
      expect((calls.last.arguments as Map)['generation'], 7);
      expect(
        (calls.last.arguments as Map)['owner'],
        sha256.convert(utf8.encode('first-user')).toString(),
      );
      await service.clearImportedData();
      expect((calls.last.arguments as Map)['generation'], 8);
    });

    test('account changes discard late native imports and old ACKs', () async {
      final pending = Completer<Map<String, dynamic>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'importSms') return pending.future;
            return null;
          });
      final service = SpendingImportService(channel: channel, android: true);
      await service.configureOwner('first-user');
      final import = service.importSms();
      await service.configureOwner('second-user');
      pending.complete({
        'transactions': [
          {'importId': 'old-owner'},
        ],
        'unrecognizedCount': 100,
      });
      expect(await import, isEmpty);
      expect(service.unrecognizedCount, 0);
      await service.acknowledgeSms();
      expect(calls.where((c) => c.method == 'acknowledgeSms'), isEmpty);
    });

    test(
      'native password errors propagate for UI retry without retaining credentials',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async {
              throw PlatformException(
                code: 'pdf_password',
                message: 'Correct password needed.',
              );
            });
        expect(
          () => SpendingImportService(
            channel: channel,
            android: false,
          ).pdfText('/tmp/protected.pdf'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'pdf_password',
            ),
          ),
        );
      },
    );
  });
}
