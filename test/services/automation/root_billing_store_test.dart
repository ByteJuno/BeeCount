import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/automation/root_billing_capture.dart';
import 'package:beecount/services/automation/root_billing_settings.dart';
import 'package:beecount/services/automation/root_billing_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BeeDatabase db;
  late LocalRepository repo;
  late RootBillingStore store;
  late RootBillingSettings settings;
  late int ledgerId;
  late int categoryId;
  late int accountId;
  final now = DateTime(2026, 10, 30, 12);

  RootBillingCapture capture({
    String? id = '420000000000000000001',
    String kind = 'expense',
    DateTime? time,
    String merchant = '测试咖啡店',
    String method = '零钱',
  }) =>
      RootBillingCapture(
        packageName: 'com.tencent.mm',
        observationId: 'visit-1',
        kind: kind,
        observedAt: now,
        happenedAt: time ?? now,
        amountCents: 3990,
        tradeId: id,
        merchant: merchant,
        paymentMethod: method,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    store = RootBillingStore(db, repo);
    ledgerId = await repo.createLedger(name: 'Root test', currency: 'CNY');
    categoryId = await repo.createCategory(name: '测试餐饮', kind: 'expense');
    accountId = await repo.createAccount(
        ledgerId: ledgerId, name: '测试微信零钱', type: 'cash', currency: 'CNY');
    settings = RootBillingSettings(
        ledgerId: ledgerId,
        wechatBalanceAccountId: accountId,
        rules: [RootMerchantRule('咖啡', categoryId)]);
  });

  tearDown(() => db.close());

  test('replaying one transaction 30 times creates exactly one row', () async {
    for (var i = 0; i < 30; i++) {
      final result = await store.ingest(capture(), settings);
      expect(result.inserted, i == 0);
      expect(result.status, 'saved');
    }
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(1));
  });

  test('same amount with two transaction IDs creates two payments', () async {
    await store.ingest(capture(), settings);
    await store.ingest(capture(id: '420000000000000000002'), settings);
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(2));
  });

  test('concurrent delivery is also idempotent', () async {
    await Future.wait(
        List.generate(5, (_) => store.ingest(capture(), settings)));
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(1));
  });

  test('controller recreation does not reset deduplication', () async {
    await store.ingest(capture(), settings);
    final recreated = RootBillingStore(db, LocalRepository(db));
    expect((await recreated.ingest(capture(), settings)).inserted, isFalse);
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(1));
  });

  test('replay never overwrites a user-corrected category', () async {
    final result = await store.ingest(capture(), settings);
    final changed = await repo.createCategory(name: '手动修正', kind: 'expense');
    await repo.updateTransaction(
        id: result.transactionId!,
        type: 'expense',
        amount: 39.9,
        categoryId: changed,
        accountId: accountId);
    await store.ingest(capture(), settings);
    expect((await repo.getTransactionById(result.transactionId!))!.categoryId,
        changed);
  });

  test('deleted transactions are not resurrected by replay', () async {
    final result = await store.ingest(capture(), settings);
    await repo.deleteTransaction(result.transactionId!);
    await store.ingest(capture(), settings);
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  for (final kind in ['refund', 'transfer']) {
    test('$kind is kept for review without changing balance', () async {
      final result = await store.ingest(capture(kind: kind), settings);
      expect(result.status, 'pending');
      expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
      final event = await db.select(db.rootBillingEvents).getSingle();
      expect(event.reason, kind);
    });
  }

  test('missing transaction identity is not guessed from time and amount',
      () async {
    expect((await store.ingest(capture(id: null), settings)).status, 'pending');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  test('historical payment does not become a new expense', () async {
    expect(
        (await store.ingest(
                capture(time: now.subtract(const Duration(days: 1))), settings))
            .status,
        'pending');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  test('no merchant rule means review, not a guessed category', () async {
    expect((await store.ingest(capture(merchant: '未知商户'), settings)).status,
        'pending');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  test('ambiguous equal-length category rules do not silently pick one',
      () async {
    final other = await repo.createCategory(name: '另一个分类', kind: 'expense');
    final ambiguous = RootBillingSettings(
        ledgerId: ledgerId,
        wechatBalanceAccountId: accountId,
        rules: [
          RootMerchantRule('咖啡', categoryId),
          RootMerchantRule('测试', other)
        ]);
    expect((await store.ingest(capture(), ambiguous)).status, 'pending');
  });

  test('longest explicit merchant rule takes precedence', () async {
    final other = await repo.createCategory(name: '具体分类', kind: 'expense');
    final specific = RootBillingSettings(
        ledgerId: ledgerId,
        wechatBalanceAccountId: accountId,
        rules: [
          RootMerchantRule('咖啡', categoryId),
          RootMerchantRule('测试咖啡店', other)
        ]);
    final result = await store.ingest(capture(), specific);
    expect((await repo.getTransactionById(result.transactionId!))!.categoryId,
        other);
  });

  test('card payments never fall back to the configured balance account',
      () async {
    final result =
        await store.ingest(capture(method: '中国工商银行(1234)'), settings);
    expect(result.status, 'pending');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  test('configured bank name and last four digits select the card', () async {
    final bankId = await repo.createAccount(
        ledgerId: ledgerId,
        name: '测试工行卡',
        type: 'bank',
        bankName: '中国工商银行',
        cardLastFour: '1234');
    final result =
        await store.ingest(capture(method: '中国工商银行(1234)'), settings);
    expect((await repo.getTransactionById(result.transactionId!))!.accountId,
        bankId);
  });

  test('settings retain explicit rules and account mappings', () async {
    await settings.save();
    final restored = await RootBillingSettings.load();
    expect(restored.ledgerId, ledgerId);
    expect(restored.wechatBalanceAccountId, accountId);
    expect(restored.rules.single.keyword, '咖啡');
  });

  test('a later detail page can complete a pending payment', () async {
    final incomplete = RootBillingCapture(
        packageName: 'com.tencent.mm',
        observationId: 'visit-1',
        kind: 'expense',
        observedAt: now,
        tradeId: capture().tradeId,
        amountCents: 3990);
    expect((await store.ingest(incomplete, settings)).status, 'pending');
    expect((await store.ingest(capture(), settings)).status, 'saved');
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(1));
    expect(await db.select(db.rootBillingEvents).get(), hasLength(1));
  });

  test('conflicting amounts on an uncommitted payment remain for review',
      () async {
    final incomplete = RootBillingCapture(
        packageName: 'com.tencent.mm',
        observationId: 'visit-1',
        kind: 'expense',
        observedAt: now,
        tradeId: capture().tradeId,
        amountCents: 4990);
    await store.ingest(incomplete, settings);
    expect((await store.ingest(capture(), settings)).status, 'pending');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
    expect((await db.select(db.rootBillingEvents).getSingle()).reason,
        'conflictingData');
  });

  test('an ignored result never starts recording after a rule change',
      () async {
    await store.ingest(capture(), RootBillingSettings(ledgerId: ledgerId));
    await store.ignore(capture().eventKey);
    expect((await store.ingest(capture(), settings)).status, 'ignored');
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
  });

  test('a failed receipt write rolls back the expense and can retry once',
      () async {
    await db.customStatement(
        'CREATE TRIGGER reject_root_event BEFORE INSERT ON root_billing_events '
        "BEGIN SELECT RAISE(ABORT, 'test receipt failure'); END");
    await expectLater(
        store.ingest(capture(), settings), throwsA(isA<Exception>()));
    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
    expect(await db.select(db.rootBillingEvents).get(), isEmpty);
    await db.customStatement('DROP TRIGGER reject_root_event');
    await store.ingest(capture(), settings);
    expect(await repo.getTransactionsByLedger(ledgerId), hasLength(1));
  });
}
