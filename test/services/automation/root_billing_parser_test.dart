import 'package:beecount/services/automation/root_billing_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 30, 12);
  RootBillingCapture? parse(List<String> nodes,
          {String package = 'com.tencent.mm'}) =>
      RootBillingParser.parse(
          packageName: package,
          nodes: nodes,
          observationId: 'visit-1',
          observedAt: now);
  List<String> payment({String id = '420000000000000000001'}) => [
        '支付成功',
        '￥39.90',
        '商户名称',
        '测试咖啡店',
        '付款方式',
        '零钱',
        '交易单号',
        id,
        '支付时间',
        '2026-10-30 12:00:00',
      ];

  test('extracts actual payment fields without cloud AI', () {
    final result = parse(payment())!;
    expect(result.amountCents, 3990);
    expect(result.merchant, '测试咖啡店');
    expect(result.paymentMethod, '零钱');
    expect(result.tradeId, '420000000000000000001');
    expect(result.happenedAt, now);
    expect(result.kind, 'expense');
  });

  test('same trade keeps its identity across different page visits', () {
    final first = parse(payment())!;
    final second = RootBillingParser.parse(
        packageName: 'com.tencent.mm',
        nodes: payment(),
        observationId: 'another-visit',
        observedAt: now)!;
    expect(first.eventKey, second.eventKey);
  });

  test('two same-amount payments with different IDs remain different', () {
    expect(parse(payment())!.eventKey,
        isNot(parse(payment(id: '420000000000000000002'))!.eventKey));
  });

  test('merchant order numbers cannot replace platform transaction identity',
      () {
    final nodes =
        payment().map((line) => line == '交易单号' ? '订单号' : line).toList();
    expect(parse(nodes)!.tradeId, isNull);
    expect(
        parse([...nodes, '支付宝交易号', '202610302200000000001'],
                package: 'com.eg.android.AlipayGphone')!
            .tradeId,
        '202610302200000000001');
  });

  test('actual paid amount takes precedence over coupon and original price',
      () {
    final result = parse([
      ...payment(),
      '原价',
      '￥50.00',
      '优惠',
      '￥10.10',
      '实付金额',
      '39.90元',
    ])!;
    expect(result.amountCents, 3990);
  });

  test('conflicting unlabeled currency amounts stay ambiguous', () {
    expect(parse([...payment(), '￥50.00'])!.amountCents, isNull);
  });

  test('balance field is not used as the payment amount', () {
    final result =
        parse(['支付成功', '余额', '999.00', '交易单号', '420000000000000000001'])!;
    expect(result.amountCents, isNull);
  });

  test('supports inline labels and exact cents', () {
    final result = parse(
        ['支付成功', '实付金额：0.01元', '商户名称: 测试店', '交易单号：420000000000000000001'])!;
    expect(result.amountCents, 1);
    expect(result.merchant, '测试店');
    expect(result.tradeId, '420000000000000000001');
  });

  for (final text in ['待支付', '支付失败', '正在付款', '交易关闭', '退款中']) {
    test('rejects incomplete or failed status: $text', () {
      expect(parse([...payment(), text]), isNull);
    });
  }

  test('does not treat arbitrary chat messages as payment results', () {
    expect(parse(['请给我转账', '￥20.00']), isNull);
    expect(parse(payment(), package: 'com.example.chat'), isNull);
  });

  test('refund is explicitly separated from an ordinary income', () {
    expect(parse([...payment(), '退款成功'])!.kind, 'refund');
  });

  test('transfer and repayment are separated from expenses', () {
    for (final title in ['转账成功', '提现成功', '还款成功']) {
      expect(parse([title, '￥20.00'])!.kind, 'transfer');
    }
  });

  test('foreign currency is not recorded as CNY', () {
    expect(parse([...payment(), '币种', 'USD'])!.amountCents, isNull);
  });

  test('invalid dates are not normalized into a different month', () {
    final result = parse(['支付成功', '￥10.00', '支付时间', '2026-02-31 12:00:00'])!;
    expect(result.happenedAt, isNull);
  });

  test('capture JSON roundtrip preserves the stable identity', () {
    final original = parse(payment())!;
    expect(RootBillingCapture.fromJson(original.toJson()).eventKey,
        original.eventKey);
  });
}
