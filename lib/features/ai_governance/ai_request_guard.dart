import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';

class AiRequestPreflight {
  final bool allowed;
  final ModelCapability? capability;
  final int inputTokens;
  final String? reason;
  final String? warning;

  /// 本次请求在 [AiRequestGuard] 中预留（reserve）的预估成本（微美元）。
  /// 网关在请求完成（成功或失败）后必须调用 [AiRequestGuard.release]
  /// 以相同数值释放，避免并发预留计数泄漏。
  final int reservedMicros;

  const AiRequestPreflight._({
    required this.allowed,
    required this.capability,
    required this.inputTokens,
    required this.reason,
    required this.warning,
    this.reservedMicros = 0,
  });

  factory AiRequestPreflight.allow(
    ModelCapability capability,
    int inputTokens, {
    String? warning,
    int reservedMicros = 0,
  }) {
    return AiRequestPreflight._(
      allowed: true,
      capability: capability,
      inputTokens: inputTokens,
      reason: null,
      warning: warning,
      reservedMicros: reservedMicros,
    );
  }

  factory AiRequestPreflight.block(
    String reason, {
    int reservedMicros = 0,
  }) =>
      AiRequestPreflight._(
        allowed: false,
        capability: null,
        inputTokens: 0,
        reason: reason,
        warning: null,
        reservedMicros: reservedMicros,
      );
}

class AiRequestGuard {
  final GovernancePersistence store;
  final ModelCapabilityRegistry registry;
  final DateTime Function() clock;

  AiRequestGuard({
    required this.store,
    required this.registry,
    required this.clock,
  });

  /// 内存预留计数器，用于在并发请求把成本写入账本之前“可见地”预留预估成本，
  /// 缓解软/硬预算在并发回合中被突破的竞态。键为预算作用域：
  /// `'global'` 覆盖全局每日/每月/自动聊天预算，`conversationId` 覆盖单会话预算。
  /// Dart 单线程且 [check] 内无 await，因此同步 += / -= 是原子的。
  final Map<String, int> _reservedMicros = {};

  void _reserve(String key, int micros) {
    _reservedMicros[key] = (_reservedMicros[key] ?? 0) + micros;
  }

  void _releaseReservation(String key, int micros) {
    final current = _reservedMicros[key] ?? 0;
    final next = current - micros;
    if (next <= 0) {
      _reservedMicros.remove(key);
    } else {
      _reservedMicros[key] = next;
    }
  }

  /// 请求完成（成功或失败）后由网关在 finally 中调用，扣减此前预留的成本。
  /// [conversationId] 应与 [check] 时传入的一致；[micros] 取
  /// [AiRequestPreflight.reservedMicros]。
  void release(String conversationId, int micros) {
    _releaseReservation('global', micros);
    if (conversationId.isNotEmpty) {
      _releaseReservation(conversationId, micros);
    }
  }

  /// 测试可见：当前仍被预留（未释放）的预算微元合计。
  ///
  /// 用于断言并发预留计数不会在请求被拦截/失败/成功后泄漏。理想情况下，
  /// 任意请求完成（含被治理拦截）后该值应回到 0。
  int get reservedMicrosTotal =>
      _reservedMicros.values.fold(0, (sum, value) => sum + value);

  ModelCapability capability(ApiProvider provider, String model) {
    return registry.resolve(
      provider: provider,
      modelId: model,
      custom: store.customCapability(provider.name, model),
    );
  }

  AiRequestPreflight check({
    required ApiProvider provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required int maxTokens,
    required bool streaming,
    required bool requiresTools,
    required bool userInitiated,
  }) {
    final capability = this.capability(provider, model);
    final inputTokens = estimateTokens(messages);
    if (streaming && !capability.supportsStreaming) {
      return AiRequestPreflight.block('模型能力未知或未声明支持流式输出');
    }
    if (_containsImage(messages) && !capability.supportsVision) {
      return AiRequestPreflight.block('模型 ${capability.modelId} 不支持图片输入');
    }
    if (requiresTools && !capability.supportsTools) {
      return AiRequestPreflight.block('模型 ${capability.modelId} 未声明工具能力');
    }
    if (maxTokens > capability.maxOutput) {
      return AiRequestPreflight.block(
        '请求输出上限 $maxTokens 超过模型上限 ${capability.maxOutput}',
      );
    }
    if (inputTokens + maxTokens > capability.contextWindow) {
      return AiRequestPreflight.block(
        '估算上下文 ${inputTokens + maxTokens} Token 超过模型上限 '
        '${capability.contextWindow}',
      );
    }

    final settings = store.budgetSettings;
    final disabled = switch (purpose) {
      AiRequestPurpose.autoChat when !settings.autoChatEnabled => '自动聊天预算已关闭',
      AiRequestPurpose.proactive when !settings.proactiveEnabled => '主动消息预算已关闭',
      AiRequestPurpose.summary when !settings.summaryEnabled => '记忆摘要预算已关闭',
      _ => null,
    };
    if (disabled != null) return AiRequestPreflight.block(disabled);

    // 连接测试只用于验证 Key 是否有效，跳过全部预算（软+硬上限）检查，
    // 仍保留 vision/streaming/size 等基本守卫（连接测试通常无图片）。
    if (purpose == AiRequestPurpose.connectionTest) {
      return AiRequestPreflight.allow(capability, inputTokens);
    }

    final price = capability.price;
    if (price == null || price.currency != 'USD') {
      return AiRequestPreflight.allow(
        capability,
        inputTokens,
        warning: '价格未知，仅记录 Token，无法执行金额预算',
      );
    }
    final projected = price.estimateMicros(
      inputTokens: inputTokens,
      cachedInputTokens: 0,
      outputTokens: maxTokens,
    );
    final now = clock();
    final entries = store.ledgerEntries;

    // 并发可见预留：在判定通过前把本次预估成本同步计入内存计数器，
    // 使同时进行的其他 check 能“看见”这笔尚未落账本的预留，缓解软/硬
    // 上限在并发回合中被突破的竞态。Dart 单线程且 check 内无 await，
    // 同步 += / -= 是原子的。
    final int reservedMicros = projected;
    _reserve('global', projected);
    if (conversationId.isNotEmpty) _reserve(conversationId, projected);

    final checks = <(String, int?, int)>[
      (
        '全局每日预算',
        settings.dailyHardLimitMicros,
        _spent(entries, now, day: true) + (_reservedMicros['global'] ?? 0),
      ),
      (
        '全局每月预算',
        settings.monthlyHardLimitMicros,
        _spent(entries, now, month: true) + (_reservedMicros['global'] ?? 0),
      ),
      if (conversationId.isNotEmpty)
        (
          '当前会话预算',
          settings.conversationHardLimitMicros,
          _spent(entries, now, conversationId: conversationId) +
              (_reservedMicros[conversationId] ?? 0),
        ),
      if (purpose == AiRequestPurpose.autoChat)
        (
          '自动聊天每日预算',
          settings.autoChatDailyHardLimitMicros,
          _spent(
                entries,
                now,
                day: true,
                originPurpose: AiRequestPurpose.autoChat,
              ) +
              (_reservedMicros['global'] ?? 0),
        ),
    ];
    String? warning;
    for (final check in checks) {
      final limit = check.$2;
      if (limit == null) continue;
      // check.$3 已包含本次预留（见上面的 _reserve），无需再叠加 projected。
      final after = check.$3;
      if (after > limit && !(userInitiated && settings.allowUserOverride)) {
        return AiRequestPreflight.block(
          '${check.$1}硬上限已达到',
          reservedMicros: reservedMicros,
        );
      }
      if (after * 100 >= limit * settings.softThresholdPercent) {
        warning = '${check.$1}已达到软阈值';
      }
    }
    return AiRequestPreflight.allow(
      capability,
      inputTokens,
      warning: warning,
      reservedMicros: reservedMicros,
    );
  }

  int _spent(
    List<UsageLedgerEntry> entries,
    DateTime now, {
    bool day = false,
    bool month = false,
    String? conversationId,
    AiRequestPurpose? originPurpose,
  }) {
    return entries.where((entry) {
      if (entry.currency != 'USD' || entry.estimatedCostMicros == null) {
        return false;
      }
      final local = entry.timestamp.toLocal();
      if (day &&
          (local.year != now.year ||
              local.month != now.month ||
              local.day != now.day)) {
        return false;
      }
      if (month && (local.year != now.year || local.month != now.month)) {
        return false;
      }
      if (conversationId != null && entry.conversationId != conversationId) {
        return false;
      }
      if (originPurpose != null && entry.originPurpose != originPurpose) {
        return false;
      }
      return true;
    }).fold(0, (sum, entry) => sum + entry.estimatedCostMicros!);
  }

  static int estimateTokens(List<Map<String, dynamic>> messages) {
    int characters(Object? value) {
      if (value is String) return value.length;
      if (value is List) {
        return value.fold(0, (sum, item) => sum + characters(item));
      }
      if (value is Map) {
        return value.entries.fold(
          0,
          (sum, item) => sum + characters(item.key) + characters(item.value),
        );
      }
      return value?.toString().length ?? 0;
    }

    final count = messages.fold<int>(0, (sum, item) => sum + characters(item));
    return (count / 4).ceil();
  }

  static bool _containsImage(Object? value) {
    if (value is Map) {
      if (value['type'] == 'image_url') return true;
      return value.values.any(_containsImage);
    }
    return value is List && value.any(_containsImage);
  }
}
