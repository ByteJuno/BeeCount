import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../automation/root_billing_capture.dart';
import '../automation/root_billing_settings.dart';
import '../automation/root_billing_store.dart';
import '../billing/post_processor.dart';
import '../system/logger_service.dart';

const rootBillingAvailable =
    !bool.fromEnvironment('GOOGLE_PLAY', defaultValue: false);

class RootBillingStatus {
  final bool running;
  final bool supported;
  final String code;

  const RootBillingStatus({
    this.running = false,
    this.supported = true,
    this.code = 'stopped',
  });
}

final rootBillingStatusProvider =
    StateProvider<RootBillingStatus>((ref) => const RootBillingStatus());

final rootBillingStoreProvider = Provider<RootBillingStore>((ref) =>
    RootBillingStore(
        ref.watch(databaseProvider), ref.watch(repositoryProvider)));

final rootBillingControllerProvider = Provider<RootBillingController>((ref) {
  final controller = RootBillingController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Native 和前台共享同一个 ProviderContainer/Drift 连接，落库后正常刷新与同步。
class RootBillingController {
  static const _channel = MethodChannel('com.tntlikely.beecount/root_billing');
  final Ref _ref;
  Future<void> _pending = Future.value();

  RootBillingController(this._ref) {
    if (Platform.isAndroid && rootBillingAvailable) {
      _channel.setMethodCallHandler(_handle);
    }
  }

  Future<void> refreshStatus() async {
    if (!Platform.isAndroid || !rootBillingAvailable) return;
    final status = await _channel.invokeMapMethod<String, dynamic>('status');
    if (status != null) _updateStatus(status);
  }

  Future<void> start() async {
    if (!Platform.isAndroid || !rootBillingAvailable) {
      throw UnsupportedError('Root billing is unavailable in this build');
    }
    final settings = await RootBillingSettings.load();
    if (settings.ledgerId == null) {
      throw StateError('Root billing is not configured');
    }
    await _channel.invokeMethod<void>('start');
    await refreshStatus();
  }

  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    await refreshStatus();
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map);
    if (call.method == 'statusChanged') {
      _updateStatus(args);
      return null;
    }
    if (call.method != 'capture') throw MissingPluginException();
    // 一次只有一个入账工作流；前一个失败不会阻断下一个任务。
    final work = _pending.then((_) => _capture(args));
    _pending = work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    await work;
    return true;
  }

  void _updateStatus(Map<String, dynamic> args) {
    final previous = _ref.read(rootBillingStatusProvider);
    _ref.read(rootBillingStatusProvider.notifier).state = RootBillingStatus(
      running: args['running'] == true,
      supported: args['supported'] as bool? ?? previous.supported,
      code: args['status'] as String? ?? 'stopped',
    );
  }

  Future<void> _capture(Map<String, dynamic> args) async {
    final capture = RootBillingParser.parse(
      packageName: args['packageName'] as String,
      nodes: (args['nodes'] as List).cast<String>(),
      observationId: args['observationId'] as String,
      observedAt:
          DateTime.fromMillisecondsSinceEpoch(args['observedAt'] as int),
    );
    if (capture == null) return;
    final settings = await RootBillingSettings.load();
    final result =
        await _ref.read(rootBillingStoreProvider).ingest(capture, settings);
    if (result.inserted && result.transactionId != null) {
      try {
        await PostProcessor.runR(_ref, ledgerId: settings.ledgerId!);
      } catch (_) {
        // 已提交的交易不会因同步失败而重新入账；同步队列负责后续重试。
        logger.warning('RootBilling', '本地入账完成，后处理等待重试');
      }
    }
  }

  void dispose() {
    if (Platform.isAndroid && rootBillingAvailable) {
      _channel.setMethodCallHandler(null);
    }
  }
}
