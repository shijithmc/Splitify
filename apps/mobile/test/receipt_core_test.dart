import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/receipt_drafts.dart';
import 'package:hisaab/core/receipt_images.dart';
import 'package:hisaab/core/receipt_preview.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final vectors = object(
    jsonDecode(
      File('../../test-vectors/receipt-splits.v1.json').readAsStringSync(),
    ),
  );
  for (final fixture in rows(vectors['cases'])) {
    test('receipt allocation: ${fixture['name']}', () {
      final result = estimateReceipt(object(fixture['review']));
      expect(result['shares'], fixture['expectedShares']);
      expect(result['differencePaise'], fixture['expectedDifferencePaise']);
      expect(
        object(
          result['shares'],
        ).values.fold<int>(0, (sum, value) => sum + (value as int)),
        fixture['review']['grandTotalPaise'],
      );
      for (final person in rows(result['people'])) {
        expect(
          person['totalPaise'],
          (person['itemsPaise'] as int) +
              rows(person['charges'])
                  .where((c) => c['includedInItemPrices'] != true)
                  .fold<int>(0, (sum, c) => sum + (c['amountPaise'] as int)),
        );
        expect(person['totalPaise'], greaterThanOrEqualTo(0));
      }
    });
  }
  test('large proportional products use exact wide intermediates', () {
    final review = {
      ...emptyReceiptReview(),
      'grandTotalPaise': 1000000000,
      'splitByItems': true,
      'items': [
        for (var i = 0; i < 150; i++)
          {
            'id': 'i$i',
            'lineTotalPaise': 1000000000,
            'assigneeIds': [i.isEven ? 'a' : 'b'],
          },
      ],
      'charges': <Json>[],
    };
    final result = estimateReceipt(review);
    expect(result['shares'], {'a': 500000000, 'b': 500000000});
  });
  test(
    'unassigned items block item split and edits invalidate review hashes',
    () {
      final review = {
        ...emptyReceiptReview(),
        'grandTotalPaise': 100,
        'splitByItems': true,
        'items': [
          {'id': 'one', 'lineTotalPaise': 100, 'assigneeIds': <String>[]},
        ],
      };
      expect(() => estimateReceipt(review), throwsFormatException);
      review['items'][0]['assigneeIds'] = ['a'];
      final hash = estimateReceipt(review)['reviewHash'];
      review['differenceAcknowledged'] = true;
      review['acknowledgedReviewHash'] = hash;
      expect(estimateReceipt(review)['reviewHash'], hash);
      review['items'][0]['name'] = 'Corrected';
      expect(estimateReceipt(review)['reviewHash'], isNot(hash));
    },
  );
  test('normalization resizes and removes text metadata', () {
    final source = img.Image(
      width: 2400,
      height: 1200,
      numChannels: 3,
      textData: {
        'Location': 'private-gps-canary',
        'Comment': 'private-phone-canary',
      },
    );
    img.fill(source, color: img.ColorRgb8(250, 245, 230));
    final normalized = normalizeReceiptImage({
      'bytes': Uint8List.fromList(img.encodePng(source)),
    });
    final output = img.decodeJpg(normalized)!;
    expect(output.width, 2048);
    expect(output.height, 1024);
    expect(output.textData, isNull);
    expect(latin1.decode(normalized), isNot(contains('private-gps-canary')));
    expect(normalized.length, lessThan(10 * 1024 * 1024));
  });
  test('bundled edge detector finds paper against a dark background', () {
    final bytes = Uint8List(160 * 200);
    for (var y = 25; y < 175; y++) {
      for (var x = 30; x < 130; x++) {
        bytes[y * 160 + x] = 255;
      }
    }
    final result = detectReceiptBounds(bytes, 160, 200, 160, 1)!;
    expect(result[0], closeTo(.1875, .06));
    expect(result[2], closeTo(.8125, .06));
    expect(detectReceiptBounds(Uint8List(160 * 200), 160, 200, 160, 1), isNull);
  });
  test(
    'encrypted drafts survive restart, isolate accounts and reject tampering',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hisaab-receipt-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = SecretKey(List<int>.generate(32, (i) => i));
      final store = ReceiptDraftStore(
        'a',
        directoryOverride: directory,
        keyOverride: key,
      );
      final draft = newReceiptDraft('group');
      draft['review'] = {'merchant': 'PRIVATE-MERCHANT-CANARY'};
      await store.save(draft);
      final image = Uint8List.fromList(utf8.encode('PRIVATE-IMAGE-CANARY'));
      await store.writeImage('image-1', image);
      final files = await directory
          .list(recursive: true)
          .where((f) => f is File)
          .cast<File>()
          .toList();
      for (final file in files) {
        expect(
          latin1.decode(await file.readAsBytes()),
          isNot(contains('PRIVATE-')),
        );
      }
      final reopened = ReceiptDraftStore(
        'a',
        directoryOverride: directory,
        keyOverride: key,
      );
      expect(
        (await reopened.load()).single['review']['merchant'],
        'PRIVATE-MERCHANT-CANARY',
      );
      expect(await reopened.image('image-1'), image);
      final other = ReceiptDraftStore(
        'b',
        directoryOverride: directory,
        keyOverride: key,
      );
      expect(await other.load(), isEmpty);
      final imageFile = files.singleWhere((f) => f.path.endsWith('.image'));
      final corrupted = await imageFile.readAsBytes();
      corrupted[20] ^= 1;
      await imageFile.writeAsBytes(corrupted);
      await expectLater(
        reopened.image('image-1'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await reopened.clear();
      expect(
        await ReceiptDraftStore(
          'a',
          directoryOverride: directory,
          keyOverride: key,
        ).load(),
        isEmpty,
      );
    },
  );
}
