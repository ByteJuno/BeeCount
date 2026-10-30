import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test(
      'upgrading v33 creates Root receipts and preserves existing transactions',
      () async {
    final raw = sqlite.sqlite3.openInMemory();
    final seed = BeeDatabase.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false));
    final repo = LocalRepository(seed);
    final ledgerId =
        await repo.createLedger(name: 'Existing ledger', currency: 'CNY');
    final transactionId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 18.5,
      happenedAt: DateTime(2026, 10, 29),
    );
    // v34 only adds this table; removing it recreates the v33 schema.
    await seed.customStatement('DROP TABLE root_billing_events');
    await seed.customStatement('PRAGMA user_version = 33');
    await seed.close();

    final upgraded = BeeDatabase.forTesting(NativeDatabase.opened(raw));
    try {
      final existing =
          await LocalRepository(upgraded).getTransactionById(transactionId);
      expect(existing?.amount, 18.5);
      expect(existing?.ledgerId, ledgerId);
      expect(await upgraded.select(upgraded.rootBillingEvents).get(), isEmpty);
      final version =
          await upgraded.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 34);
    } finally {
      await upgraded.close();
    }
  });
}
