import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RootMerchantRule {
  final String keyword;
  final int categoryId;

  const RootMerchantRule(this.keyword, this.categoryId);

  Map<String, Object> toJson() => {
        'keyword': keyword,
        'categoryId': categoryId,
      };
}

class RootBillingSettings {
  static const preferencesKey = 'root_billing_settings_v1';
  final int? ledgerId;
  final int? wechatBalanceAccountId;
  final int? alipayBalanceAccountId;
  final List<RootMerchantRule> rules;

  const RootBillingSettings({
    this.ledgerId,
    this.wechatBalanceAccountId,
    this.alipayBalanceAccountId,
    this.rules = const [],
  });

  static Future<RootBillingSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferencesKey);
    if (raw == null) return const RootBillingSettings();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return RootBillingSettings(
        ledgerId: json['ledgerId'] as int?,
        wechatBalanceAccountId: json['wechatBalanceAccountId'] as int?,
        alipayBalanceAccountId: json['alipayBalanceAccountId'] as int?,
        rules: [
          for (final rule in json['rules'] as List? ?? [])
            RootMerchantRule(
                rule['keyword'] as String, rule['categoryId'] as int),
        ],
      );
    } on Object {
      // 配置损坏时停留在未配置状态，不猜账本或账户，不清空其他偏好。
      return const RootBillingSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        preferencesKey,
        jsonEncode({
          'ledgerId': ledgerId,
          'wechatBalanceAccountId': wechatBalanceAccountId,
          'alipayBalanceAccountId': alipayBalanceAccountId,
          'rules': rules.map((rule) => rule.toJson()).toList(),
        }));
  }
}
