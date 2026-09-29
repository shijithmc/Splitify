import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/features/group.dart';
import 'package:hisaab/main.dart';
import 'shell_usability_test.dart' show demo, summary;

void main() {
  testWidgets(
    'large group lists stay lazy and search reaches a distant group',
    (tester) async {
      final c = await demo(tester);
      c.tab = 1;
      c.groups = List.generate(200, (index) => summary('Trip $index', 'Trip'));
      await tester.pumpWidget(HisaabApp(controller: c));
      expect(find.widgetWithText(ListTile, 'Trip 199'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Trip 199');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Trip 199'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native tabs keep groups within reach and return after viewing a group',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // The compact hero and balances depend on the shipped font metrics.
      await tester.runAsync(() async {
        for (final family in ['Outfit', 'WorkSans']) {
          final loader = FontLoader(family);
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
          }
          await loader.load();
        }
      });
      final c = await demo(tester);
      await tester.pumpWidget(HisaabApp(controller: c));
      final isIOS =
          Theme.of(tester.element(find.byType(Scaffold).first)).platform ==
          TargetPlatform.iOS;
      expect(
        find.byType(CupertinoTabBar),
        isIOS ? findsOneWidget : findsNothing,
      );
      expect(find.byType(NavigationBar), isIOS ? findsNothing : findsOneWidget);
      // A useful group is visible without scrolling past a hero/dashboard.
      expect(find.text('Goa, here we come').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(find.text('Home sweet home').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Goa, here we come'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupPage), findsOneWidget);
      expect(find.text('Beachside dinner').hitTestable(), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(c.tab, 1);
      expect(find.text('Home sweet home').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}
