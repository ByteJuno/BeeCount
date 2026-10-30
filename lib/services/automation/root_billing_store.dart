import 'dart:convert';

import 'package:drift/drift.dart' as d;

import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import 'root_billing_capture.dart';
import 'root_billing_settings.dart';

class RootBillingResult {
  final String status;
  final int? transactionId;
  final bool inserted;

  const RootBillingResult(this.status, this.transactionId, this.inserted);
}

/// 本机凭据和交易共用数据库事务，重试/进程重建不能再次生成同一笔账。
class RootBillingStore {
  final BeeDatabase db;
  final BaseRepository repo;

  RootBillingStore(this.db, this.repo);

  Future<RootBillingResult> ingest(
    RootBillingCapture capture,
    RootBillingSettings settings,
  ) async {
    final ledgerId = settings.ledgerId;
    if (ledgerId == null) {
      throw StateError('Root billing ledger is not configured');
    }
    return db.transaction(() async {
      final previous = await (db.select(db.rootBillingEvents)
            ..where((event) => event.eventKey.equals(capture.eventKey)))
          .getSingleOrNull();
      if (previous != null &&
          (previous.status != 'pending' || previous.ledgerId != ledgerId)) {
        // 后来的页面解析不覆盖已经入账的金额或用户修正的分类。
        return RootBillingResult(
            previous.status, previous.transactionId, false);
      }
      final ledger = await repo.getLedgerById(ledgerId);
      if (ledger == null || ledger.isShared || ledger.currency != 'CNY') {
        throw StateError('Root billing requires a personal CNY ledger');
      }
      String? conflict;
      if (previous != null) {
        final old = RootBillingCapture.fromJson(
            jsonDecode(previous.payloadJson) as Map<String, dynamic>);
        if (previous.reason == 'conflictingData' ||
            (old.amountCents != null &&
                capture.amountCents != null &&
                old.amountCents != capture.amountCents)) {
          conflict = 'conflictingData';
        }
        capture = RootBillingCapture(
          packageName: capture.packageName,
          observationId: capture.observationId,
          kind: capture.kind,
          observedAt: capture.observedAt,
          amountCents: capture.amountCents ?? old.amountCents,
          tradeId: capture.tradeId,
          merchant: capture.merchant ?? old.merchant,
          paymentMethod: capture.paymentMethod ?? old.paymentMethod,
          happenedAt: capture.happenedAt ?? old.happenedAt,
        );
      }
      final reason = conflict ?? await _reviewReason(capture, settings);
      int? transactionId;
      if (reason == null) {
        transactionId = await repo.addTransaction(
          ledgerId: ledgerId,
          type: 'expense',
          amount: capture.amountCents! / 100,
          categoryId: await _category(capture, settings),
          accountId: await _account(capture, settings),
          happenedAt: capture.happenedAt!,
          note: capture.merchant,
          currencyCode: 'CNY',
        );
      }
      final status = transactionId == null ? 'pending' : 'saved';
      final row = RootBillingEventsCompanion.insert(
        eventKey: capture.eventKey,
        ledgerId: ledgerId,
        payloadJson: jsonEncode(capture.toJson()),
        status: status,
        reason: d.Value(reason),
        transactionId: d.Value(transactionId),
        createdAt: previous?.createdAt ?? capture.observedAt,
      );
      await db.into(db.rootBillingEvents).insertOnConflictUpdate(row);
      return RootBillingResult(
          status, transactionId, previous == null || transactionId != null);
    });
  }

  Future<String?> _reviewReason(
      RootBillingCapture capture, RootBillingSettings settings) async {
    if (capture.kind != 'expense') return capture.kind;
    if (capture.tradeId == null) return 'missingIdentity';
    if (capture.amountCents == null || capture.amountCents! <= 0) {
      return 'missingAmount';
    }
    if (capture.merchant == null) return 'missingMerchant';
    final happenedAt = capture.happenedAt;
    if (happenedAt == null ||
        capture.observedAt.difference(happenedAt) >
            const Duration(minutes: 10) ||
        happenedAt.difference(capture.observedAt) >
            const Duration(minutes: 2)) {
      // 浏览历史账单不等于发生新交易，旧账单只生成待确认项。
      return 'missingRecentTime';
    }
    if (await _account(capture, settings) == null) return 'missingAccount';
    if (await _category(capture, settings) == null) return 'missingCategory';
    return null;
  }

  Future<int?> _category(
      RootBillingCapture capture, RootBillingSettings settings) async {
    final merchant = capture.merchant?.toLowerCase();
    if (merchant == null) return null;
    final rules = settings.rules
        .where((rule) =>
            rule.keyword.trim().isNotEmpty &&
            merchant.contains(rule.keyword.trim().toLowerCase()))
        .toList()
      ..sort(
          (a, b) => b.keyword.trim().length.compareTo(a.keyword.trim().length));
    if (rules.isEmpty) return null;
    final longest = rules.first.keyword.trim().length;
    final matches = rules
        .where((rule) => rule.keyword.trim().length == longest)
        .map((rule) => rule.categoryId)
        .toSet();
    if (matches.length != 1) return null;
    final categories = await repo.getAllCategories();
    return categories.any((category) =>
            category.id == matches.single && category.kind == 'expense')
        ? matches.single
        : null;
  }

  Future<int?> _account(
      RootBillingCapture capture, RootBillingSettings settings) async {
    final method = capture.paymentMethod;
    if (method == null) return null;
    final accounts = (await repo.getAllAccounts())
        .where((account) => !account.hidden && account.currency == 'CNY')
        .toList();
    int? mapped;
    if (capture.packageName == 'com.tencent.mm' && method == '零钱') {
      mapped = settings.wechatBalanceAccountId;
    } else if (capture.packageName == 'com.eg.android.AlipayGphone' &&
        (method == '余额' || method == '账户余额')) {
      mapped = settings.alipayBalanceAccountId;
    }
    if (mapped != null) {
      return accounts.any((account) => account.id == mapped) ? mapped : null;
    }
    final tail = RegExp(r'(?:尾号\s*|[（(])([0-9]{4})[）)]?').firstMatch(method);
    if (tail == null) return null;
    final matched = accounts
        .where((account) =>
            account.cardLastFour == tail.group(1) &&
            account.bankName != null &&
            account.bankName!.isNotEmpty &&
            method.contains(account.bankName!))
        .toList();
    return matched.length == 1 ? matched.single.id : null;
  }

  Stream<List<RootBillingEvent>> watchRecent() =>
      (db.select(db.rootBillingEvents)
            ..orderBy([(event) => d.OrderingTerm.desc(event.createdAt)])
            ..limit(50))
          .watch();

  Future<void> ignore(String key) async {
    await (db.update(db.rootBillingEvents)
          ..where((event) =>
              event.eventKey.equals(key) & event.status.equals('pending')))
        .write(const RootBillingEventsCompanion(status: d.Value('ignored')));
  }
}
