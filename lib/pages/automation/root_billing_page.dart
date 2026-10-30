import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/automation/root_billing_capture.dart';
import '../../services/automation/root_billing_settings.dart';
import '../../services/platform/root_billing_controller.dart';
import '../../widgets/ui/ui.dart';

class RootBillingPage extends ConsumerStatefulWidget {
  const RootBillingPage({super.key});

  @override
  ConsumerState<RootBillingPage> createState() => _RootBillingPageState();
}

class _RootBillingPageState extends ConsumerState<RootBillingPage>
    with WidgetsBindingObserver {
  List<Ledger> _ledgers = [];
  List<Account> _accounts = [];
  List<Category> _categories = [];
  List<RootMerchantRule> _rules = [];
  int? _ledgerId;
  int? _wechatId;
  int? _alipayId;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(repositoryProvider);
      final settings = await RootBillingSettings.load();
      final ledgers = (await repo.getAllLedgers())
          .where((ledger) => !ledger.isShared && ledger.currency == 'CNY')
          .toList();
      final accounts = (await repo.getAllAccounts())
          .where((account) => !account.hidden && account.currency == 'CNY')
          .toList();
      final categories = (await repo.getAllCategories())
          .where((category) => category.kind == 'expense')
          .toList();
      await ref.read(rootBillingControllerProvider).refreshStatus();
      if (!mounted) return;
      setState(() {
        _ledgers = ledgers;
        _accounts = accounts;
        _categories = categories;
        _rules = settings.rules.toList();
        _ledgerId = ledgers.any((ledger) => ledger.id == settings.ledgerId)
            ? settings.ledgerId
            : null;
        _wechatId = accounts
                .any((account) => account.id == settings.wechatBalanceAccountId)
            ? settings.wechatBalanceAccountId
            : null;
        _alipayId = accounts
                .any((account) => account.id == settings.alipayBalanceAccountId)
            ? settings.alipayBalanceAccountId
            : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        showToast(context, AppLocalizations.of(context).rootBillingFailed);
      }
    }
  }

  Future<void> _save() => RootBillingSettings(
        ledgerId: _ledgerId,
        wechatBalanceAccountId: _wechatId,
        alipayBalanceAccountId: _alipayId,
        rules: _rules,
      ).save();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(rootBillingControllerProvider).refreshStatus();
    }
  }

  Future<void> _toggle(bool enable) async {
    final l10n = AppLocalizations.of(context);
    if (enable) {
      final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.rootBillingTitle),
          content: Text(l10n.rootBillingConsent),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.commonConfirm)),
          ],
        ),
      );
      if (consent != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final controller = ref.read(rootBillingControllerProvider);
      if (enable) {
        await _save();
        await Permission.notification.request();
        await controller.start();
      } else {
        await controller.stop();
      }
    } on PlatformException catch (error) {
      if (mounted) {
        showToast(
            context,
            error.code == 'READER_BUSY'
                ? l10n.rootBillingReaderBusy
                : error.code == 'READER_UNAVAILABLE'
                    ? l10n.rootBillingReaderUnavailable
                    : l10n.rootBillingFailed);
      }
    } catch (_) {
      if (mounted) showToast(context, l10n.rootBillingFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addRule() async {
    final l10n = AppLocalizations.of(context);
    final text = TextEditingController();
    int? categoryId;
    final rule = await showDialog<RootMerchantRule>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
                title: Text(l10n.rootBillingAddRule),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: text,
                      maxLength: 80,
                      decoration:
                          InputDecoration(labelText: l10n.rootBillingMerchant),
                      onChanged: (_) => setDialogState(() {})),
                  DropdownButtonFormField<int>(
                    value: categoryId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: l10n.categoryTitle),
                    items: [
                      for (final category in _categories)
                        DropdownMenuItem(
                            value: category.id, child: Text(category.name))
                    ],
                    onChanged: (value) =>
                        setDialogState(() => categoryId = value),
                  ),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.commonCancel)),
                  FilledButton(
                    onPressed: categoryId == null || text.text.trim().isEmpty
                        ? null
                        : () => Navigator.pop(context,
                            RootMerchantRule(text.text.trim(), categoryId!)),
                    child: Text(l10n.commonSave),
                  ),
                ],
              )),
    );
    // 等对话框退场后再释放，避免仍在退场树中的 TextField 读取已释放 controller。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
    if (rule != null && mounted) {
      setState(() {
        _rules.removeWhere((existing) => existing.keyword == rule.keyword);
        _rules.add(rule);
      });
      await _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(rootBillingStatusProvider);
    final editable = !_loading && !_busy && !status.running;
    return Scaffold(
      body: Column(children: [
        PrimaryHeader(title: l10n.rootBillingTitle, showBack: true),
        Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(l10n.rootBillingDescription),
                      const SizedBox(height: 12),
                      Card(
                          child: SwitchListTile(
                        title: Text(l10n.rootBillingTitle),
                        subtitle: Text(!status.supported
                            ? l10n.rootBillingUnsupported
                            : status.code == 'captureFailed'
                                ? l10n.rootBillingFailed
                                : status.running
                                    ? l10n.rootBillingRunning
                                    : l10n.rootBillingStopped),
                        value: status.running,
                        onChanged:
                            _busy || !status.supported || _ledgerId == null
                                ? null
                                : _toggle,
                      )),
                      if (!editable)
                        Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(l10n.rootBillingStopToEdit)),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: _ledgerId,
                        isExpanded: true,
                        decoration:
                            InputDecoration(labelText: l10n.rootBillingLedger),
                        items: [
                          for (final ledger in _ledgers)
                            DropdownMenuItem(
                                value: ledger.id, child: Text(ledger.name))
                        ],
                        onChanged: !editable
                            ? null
                            : (value) async {
                                setState(() => _ledgerId = value);
                                await _save();
                              },
                      ),
                      const SizedBox(height: 12),
                      _accountPicker(l10n.rootBillingWechatAccount, _wechatId,
                          editable, (value) => _wechatId = value),
                      const SizedBox(height: 12),
                      _accountPicker(l10n.rootBillingAlipayAccount, _alipayId,
                          editable, (value) => _alipayId = value),
                      const SizedBox(height: 8),
                      Text(l10n.rootBillingBankAccountHint),
                      const SizedBox(height: 20),
                      Row(children: [
                        Expanded(
                            child: Text(l10n.rootBillingRules,
                                style:
                                    Theme.of(context).textTheme.titleMedium)),
                        IconButton(
                            onPressed: editable && _categories.isNotEmpty
                                ? _addRule
                                : null,
                            tooltip: l10n.rootBillingAddRule,
                            icon: const Icon(Icons.add)),
                      ]),
                      for (final rule in _rules)
                        ListTile(
                          title: Text(rule.keyword),
                          subtitle: Text(_categories
                                  .where((category) =>
                                      category.id == rule.categoryId)
                                  .map((category) => category.name)
                                  .firstOrNull ??
                              l10n.rootBillingUnassigned),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: l10n.commonDelete,
                              onPressed: !editable
                                  ? null
                                  : () async {
                                      setState(() => _rules.remove(rule));
                                      await _save();
                                    }),
                        ),
                      Text(l10n.rootBillingRulesHint),
                      const SizedBox(height: 24),
                      Text(l10n.rootBillingHistory,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      StreamBuilder<List<RootBillingEvent>>(
                        stream:
                            ref.watch(rootBillingStoreProvider).watchRecent(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Text(l10n.rootBillingFailed);
                          }
                          final events = snapshot.data ?? [];
                          if (events.isEmpty) {
                            return Text(l10n.rootBillingNoEvents);
                          }
                          return Column(children: [
                            for (final event in events) _eventTile(event, l10n)
                          ]);
                        },
                      ),
                    ],
                  )),
      ]),
    );
  }

  Widget _accountPicker(
      String label, int? value, bool editable, void Function(int?) update) {
    final l10n = AppLocalizations.of(context);
    return DropdownButtonFormField<int>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem<int>(
            value: null, child: Text(l10n.rootBillingUnassigned)),
        for (final account in _accounts)
          DropdownMenuItem(value: account.id, child: Text(account.name)),
      ],
      onChanged: !editable
          ? null
          : (value) async {
              setState(() => update(value));
              await _save();
            },
    );
  }

  Widget _eventTile(RootBillingEvent event, AppLocalizations l10n) {
    final capture = RootBillingCapture.fromJson(
        jsonDecode(event.payloadJson) as Map<String, dynamic>);
    final reason = switch (event.reason) {
      'refund' => l10n.rootBillingReviewRefund,
      'transfer' => l10n.rootBillingReviewTransfer,
      'missingIdentity' => l10n.rootBillingReviewIdentity,
      'missingAmount' => l10n.rootBillingReviewAmount,
      'missingMerchant' => l10n.rootBillingReviewMerchant,
      'missingRecentTime' => l10n.rootBillingReviewTime,
      'missingAccount' => l10n.rootBillingReviewAccount,
      'missingCategory' => l10n.rootBillingReviewCategory,
      'conflictingData' => l10n.rootBillingReviewConflict,
      _ => l10n.rootBillingPending,
    };
    final amount = capture.amountCents == null
        ? ''
        : ' ¥${(capture.amountCents! / 100).toStringAsFixed(2)}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(event.status == 'saved'
          ? Icons.check_circle_outline
          : Icons.pending_outlined),
      title: Text('${capture.merchant ?? l10n.rootBillingUnassigned}$amount'),
      subtitle: Text(event.status == 'saved'
          ? l10n.rootBillingSaved
          : event.status == 'ignored'
              ? l10n.rootBillingIgnored
              : reason),
      trailing: event.status != 'pending'
          ? null
          : IconButton(
              icon: const Icon(Icons.close),
              tooltip: l10n.rootBillingIgnore,
              onPressed: () =>
                  ref.read(rootBillingStoreProvider).ignore(event.eventKey),
            ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
