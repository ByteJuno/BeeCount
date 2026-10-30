import 'dart:convert';
import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/base_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/pages/automation/root_billing_page.dart';
import 'package:beecount/providers.dart';
import 'package:beecount/services/automation/root_billing_settings.dart';
import 'package:beecount/services/automation/root_billing_store.dart';
import 'package:beecount/services/platform/root_billing_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Repository extends Mock implements BaseRepository {}

class _Store extends Mock implements RootBillingStore {}

void main() {
  testWidgets(
      'Root feature starts disabled and cancelling consent keeps it off',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      RootBillingSettings.preferencesKey:
          jsonEncode({'ledgerId': 1, 'rules': []}),
    });
    final repo = _Repository();
    final store = _Store();
    when(() => repo.getAllLedgers()).thenAnswer((_) async => [
          Ledger(
            id: 1,
            name: '本地测试账本',
            currency: 'CNY',
            type: 'personal',
            createdAt: DateTime(2026, 10, 30),
            myRole: 'owner',
            memberCount: 1,
            isShared: false,
            monthStartDay: 1,
          )
        ]);
    when(() => repo.getAllAccounts()).thenAnswer((_) async => []);
    when(() => repo.getAllCategories()).thenAnswer((_) async => []);
    when(() => store.watchRecent()).thenAnswer((_) => Stream.value([]));
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      rootBillingStoreProvider.overrideWithValue(store),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RootBillingPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('本地测试账本'), findsOneWidget);
    final toggle = find.byType(Switch);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
