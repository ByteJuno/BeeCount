import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Root 页面读取结果。只保留交易字段，不保存完整页面或截图。
class RootBillingCapture {
  final String packageName;
  final String observationId;
  final String kind;
  final int? amountCents;
  final String? tradeId;
  final String? merchant;
  final String? paymentMethod;
  final DateTime observedAt;
  final DateTime? happenedAt;

  const RootBillingCapture({
    required this.packageName,
    required this.observationId,
    required this.kind,
    required this.observedAt,
    this.amountCents,
    this.tradeId,
    this.merchant,
    this.paymentMethod,
    this.happenedAt,
  });

  // 有交易号时跨进程、跨页面保持稳定；不能用“金额 + 时间窗口”代替交易身份。
  String get eventKey => sha256
      .convert(utf8.encode(jsonEncode([
        packageName,
        kind,
        tradeId ?? observationId,
      ])))
      .toString();

  Map<String, Object?> toJson() => {
        'packageName': packageName,
        'observationId': observationId,
        'kind': kind,
        'amountCents': amountCents,
        'tradeId': tradeId,
        'merchant': merchant,
        'paymentMethod': paymentMethod,
        'observedAt': observedAt.toIso8601String(),
        'happenedAt': happenedAt?.toIso8601String(),
      };

  factory RootBillingCapture.fromJson(Map<String, dynamic> json) =>
      RootBillingCapture(
        packageName: json['packageName'] as String,
        observationId: json['observationId'] as String,
        kind: json['kind'] as String,
        amountCents: json['amountCents'] as int?,
        tradeId: json['tradeId'] as String?,
        merchant: json['merchant'] as String?,
        paymentMethod: json['paymentMethod'] as String?,
        observedAt: DateTime.parse(json['observedAt'] as String),
        happenedAt: DateTime.tryParse(json['happenedAt'] as String? ?? ''),
      );
}

/// 仅接受支付成功/详情页；不把付款输入页、聊天或处理中状态记成交易。
class RootBillingParser {
  static const supportedPackages = {
    'com.tencent.mm',
    'com.eg.android.AlipayGphone',
  };

  static RootBillingCapture? parse({
    required String packageName,
    required List<String> nodes,
    required String observationId,
    required DateTime observedAt,
  }) {
    if (!supportedPackages.contains(packageName)) return null;
    final lines = nodes
        .expand((node) => node.split(RegExp(r'[\r\n]+')))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && line.length <= 256)
        .toList();
    if (lines.isEmpty || lines.length > 512) return null;
    final text = lines.join('\n');
    if (RegExp(r'支付失败|付款失败|交易关闭|等待付款|待支付|正在付款|退款中').hasMatch(text)) {
      return null;
    }
    if (!RegExp(
            r'支付成功|付款成功|交易成功|支付完成|已支付|退款成功|已全额退款|退款到账|退还成功|转账成功|轉帳成功|提现成功|充值成功|还款成功|已收款')
        .hasMatch(text)) {
      return null;
    }
    final String kind;
    if (RegExp(r'退款|退还|退回').hasMatch(text)) {
      kind = 'refund';
    } else if (RegExp(r'转账|轉帳|提现|充值|还款|已收款|零钱通|余额宝').hasMatch(text)) {
      kind = 'transfer';
    } else if (RegExp(r'支付成功|付款成功|交易成功|支付完成|已支付').hasMatch(text)) {
      kind = 'expense';
    } else {
      return null;
    }

    // 明确的实付字段优先，余额、原价、优惠金额不能抢占实际付款金额。
    int? amount;
    for (final label in ['实付金额', '实际支付', '支付金额', '付款金额', '支出金额']) {
      amount = _money(_field(lines, [label]));
      if (amount != null) break;
    }
    if (amount == null) {
      final candidates = lines
          .where((line) => RegExp(r'^[\-−]?\s*[¥￥]').hasMatch(line))
          .map(_money)
          .whereType<int>()
          .toSet();
      if (candidates.length == 1) amount = candidates.single;
    }
    // 这一版本的页面规则仅适用于人民币，不能把外币符号当作人民币金额。
    if (RegExp(r'USD|HKD|EUR|美元|港币|港元|欧元|\$|€').hasMatch(text)) {
      amount = null;
    }

    final rawId = _field(lines, [
      if (kind == 'refund') '退款单号',
      '交易单号',
      '交易号',
      '支付宝交易号',
      '微信支付订单号',
      '支付单号',
    ]);
    final normalizedId = rawId?.replaceAll(RegExp(r'\s'), '');
    final tradeId = normalizedId != null &&
            RegExp(r'^[A-Za-z0-9_-]{12,64}$').hasMatch(normalizedId)
        ? normalizedId
        : null;
    final merchant = _field(lines, [
      '商户全称',
      '商户名称',
      '收款商户',
      '收款方',
      '商家名称',
      '交易对方',
    ]);
    final paymentMethod = _field(lines, ['付款方式', '支付方式', '付款账户']);
    final rawTime = _field(lines, ['支付时间', '付款时间', '交易时间', '创建时间']);
    final happenedAt = rawTime == null ? null : _time(rawTime);

    return RootBillingCapture(
      packageName: packageName,
      observationId: observationId,
      kind: kind,
      amountCents: amount,
      tradeId: tradeId,
      merchant: merchant,
      paymentMethod: paymentMethod,
      observedAt: observedAt,
      happenedAt: happenedAt,
    );
  }

  static String? _field(List<String> lines, List<String> labels) {
    for (final label in labels) {
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line == label && i + 1 < lines.length) return lines[i + 1];
        final match =
            RegExp('^${RegExp.escape(label)}[：:]\\s*(.+)\$').firstMatch(line);
        if (match != null) return match.group(1)!.trim();
      }
    }
    return null;
  }

  static int? _money(String? raw) {
    if (raw == null) return null;
    final match = RegExp(
            r'^[\-−]?\s*[¥￥]?\s*([0-9]{1,9}(?:,[0-9]{3})*)(?:\.([0-9]{1,2}))?\s*(?:元|CNY)?$')
        .firstMatch(raw.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!.replaceAll(',', ''));
    if (whole == null) return null;
    final cents = int.parse((match.group(2) ?? '').padRight(2, '0'));
    final amount = whole * 100 + cents;
    return amount > 0 ? amount : null;
  }

  static DateTime? _time(String raw) {
    final match = RegExp(
            r'(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?')
        .firstMatch(raw);
    if (match == null) return null;
    final values = [
      for (var i = 1; i <= 6; i++) int.parse(match.group(i) ?? '0')
    ];
    final result = DateTime(
        values[0], values[1], values[2], values[3], values[4], values[5]);
    if (result.year != values[0] ||
        result.month != values[1] ||
        result.day != values[2] ||
        values[3] > 23 ||
        values[4] > 59 ||
        values[5] > 59) {
      return null;
    }
    return result;
  }
}
