import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/storage/credential_repository.dart';

import 'database_service.dart';

/// 图像服务配置读写 + IP 形象受管文件的路径换算。
///
/// 单独用 extension 而不是塞进 `database_service.dart`：后者已超 500 行红线，
/// 本域的读写自成一块，不必再加重主文件。
extension ImageServiceSettingsAccess on DatabaseService {
  // 仅非 Release 使用；不得加入备份/导出白名单。
  static const _imageApiKeyDebugFallbackKey = 'image_api_key_debug_only';

  /// 全局图像服务配置。见 [imageServiceSettingsKey]。
  ///
  /// API Key 不在此处：`apiKeyBound` 仅表示已绑定；密钥本尊在安全存储
  /// （经 CredentialRepository 以 [imageServiceCredentialId] 存取）。
  ImageServiceConfig get imageServiceConfig {
    return ImageServiceConfig.fromMap(
      appSettingsBox.get(imageServiceSettingsKey),
    );
  }

  Future<void> saveImageServiceConfig(ImageServiceConfig config) async {
    await appSettingsBox.put(imageServiceSettingsKey, config.toMap());
  }

  /// 优先从安全存储读取图像 API Key；非 Release 才读取调试回退。
  ///
  /// [credentials] 仅供测试注入内存 store；生产调用一律走默认安全存储。
  Future<String?> readImageApiKey({CredentialRepository? credentials}) async {
    final result = await (credentials ?? CredentialRepository())
        .read(imageServiceCredentialId);
    if (result.isAvailable) return result.value;
    if (!kReleaseMode) {
      final fallback =
          appSettingsBox.get(_imageApiKeyDebugFallbackKey)?.toString() ?? '';
      if (fallback.isNotEmpty) return fallback;
    }
    return null;
  }

  /// 绑定图像 API Key 到安全存储，并刷新 [ImageServiceConfig.apiKeyBound]。
  ///
  /// [apiKey] 必须是调用方本次要保存的明文（弹窗新输入直接传入），
  /// **禁止**为「先测试一下」而临时写入/回读/删除安全存储。
  /// 返回 null 表示成功；否则为失败原因文案（由调用方展示）。
  ///
  /// [credentials] 仅供测试注入内存 store；生产调用一律走默认安全存储。
  Future<String?> bindImageApiKey(
    String apiKey, {
    CredentialRepository? credentials,
  }) async {
    if (kIsWeb) return 'Web 端不支持图像服务。';
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) return 'API Key 不能为空';
    final result = await (credentials ?? CredentialRepository()).save(
      imageServiceCredentialId,
      trimmed,
    );
    if (result.isSuccess) {
      if (!kReleaseMode) {
        await appSettingsBox.delete(_imageApiKeyDebugFallbackKey);
      }
      await saveImageServiceConfig(
        imageServiceConfig.copyWith(apiKeyBound: true),
      );
      return null;
    }
    // macOS 开发签名等环境可能无法写入 Keychain；仅非 Release 回退。
    if (!kReleaseMode) {
      await appSettingsBox.put(_imageApiKeyDebugFallbackKey, trimmed);
      await saveImageServiceConfig(
        imageServiceConfig.copyWith(apiKeyBound: true),
      );
      return null;
    }
    return switch (result.failure) {
      CredentialFailure.permissionDenied => '系统拒绝保存凭据（权限/锁定）',
      CredentialFailure.unavailable => '当前环境无可用安全存储',
      _ => '凭据保存失败，请重试',
    };
  }

  /// 从安全存储移除图像 API Key，并更新 [ImageServiceConfig.apiKeyBound]。
  ///
  /// [credentials] 仅供测试注入内存 store；生产调用一律走默认安全存储。
  Future<String?> unbindImageApiKey({CredentialRepository? credentials}) async {
    final result = await (credentials ?? CredentialRepository())
        .delete(imageServiceCredentialId);
    if (!result.isSuccess) {
      // 不可宣称解绑成功：安全存储里的旧凭据可能仍可读。
      return switch (result.failure) {
        CredentialFailure.permissionDenied => '系统拒绝删除凭据（权限/锁定）',
        CredentialFailure.unavailable => '当前环境无可用安全存储',
        _ => '凭据删除失败，请重试',
      };
    }
    if (!kReleaseMode) {
      await appSettingsBox.delete(_imageApiKeyDebugFallbackKey);
    }
    await saveImageServiceConfig(
      imageServiceConfig.copyWith(apiKeyBound: false),
    );
    return null;
  }

  /// 把 [DatabaseService.writeBytesToAiCharacterDir] 返回的绝对路径换算为
  /// 受管相对路径（相对 ai-processing 根，统一 `/` 分隔）。不在根下时返回 null。
  String? aiCharacterMediaRelPath(String absolutePath) {
    final root = _aiProcessingRootSync;
    if (root == null) return null;
    final normalizedRoot =
        _normalizeSeparators(root).replaceAll(RegExp(r'/+$'), '').toLowerCase();
    final normalizedPath = _normalizeSeparators(
      Directory(absolutePath).absolute.path,
    );
    if (!normalizedPath.toLowerCase().startsWith('$normalizedRoot/')) {
      return null;
    }
    return normalizedPath.substring(normalizedRoot.length + 1);
  }

  /// 把 IP 形象受管相对路径解析为绝对路径。
  ///
  /// 越界（含 `..` 或绝对路径）或文件不存在返回 null —— 调用方据此回落文本头像，
  /// 因此跨设备还原丢文件、用户改了 ai-processing 目录都不会崩溃。
  String? resolveAiCharacterMediaPath(String relPath) {
    final trimmed = relPath.trim();
    if (trimmed.isEmpty) return null;
    // 相对路径绝不允许跳出根目录（用户可控字符串，按不可信输入处理）。
    if (trimmed.contains('..') || _hasDrivePrefix(trimmed)) return null;
    final root = _aiProcessingRootSync;
    if (root == null) return null;
    final candidate = File(
        '${root.replaceAll(RegExp(r'/+$'), '')}/${_normalizeSeparators(trimmed)}');
    return candidate.existsSync() ? candidate.absolute.path : null;
  }

  /// `CharacterAvatar.imagePath` 的取值入口。
  ///
  /// 仅当角色**启用**了 IP 形象时才解析；未启用 / 未生成 / 文件缺失 /
  /// 角色已删除一律返回 null，渲染层据此回落文本头像。
  String? characterAvatarPath(AICharacter? character) {
    if (character == null || !character.avatarFromIpImage) return null;
    return resolveAiCharacterMediaPath(character.ipImageRelPath);
  }

  /// `CharacterAvatar.image` 的取值入口：在 [characterAvatarPath] 之上再做
  /// 一次存在性检查并构造 [FileImage]。
  ///
  /// 存在性检查放在数据层而不是 widget 层，是为了让 `CharacterAvatar` 保持
  /// 纯展示（测试可注入 `MemoryImage`，`testWidgets` 的 FakeAsync 区里也不会
  /// 因 `FileImage` 真实解码卡死）。不可读一律返回 null，静默回落文本。
  ImageProvider? characterAvatarImage(AICharacter? character) {
    if (character == null || !character.avatarFromIpImage) return null;
    return characterMediaImage(character.ipImageRelPath);
  }

  /// 不看 [AICharacter.avatarFromIpImage] 开关，直接按相对路径出图。
  ///
  /// 供「IP 形象」面板的预览使用：生成出来但**尚未**「设为头像」的图也要能看见，
  /// 否则用户无法在开开关之前确认生成结果。
  ImageProvider? characterMediaImage(String relPath) {
    final path = resolveAiCharacterMediaPath(relPath);
    if (path == null || kIsWeb) return null;
    try {
      return File(path).existsSync() ? FileImage(File(path)) : null;
    } on Object {
      return null;
    }
  }

  /// best-effort 删除受管相对路径对应文件；越界或不存在静默返回。
  ///
  /// 调用方（角色删除、重新生成、放弃未保存草稿）都不应因删文件失败而中断主流程。
  Future<void> deleteAiCharacterFile(String relPath) async {
    final absolute = resolveAiCharacterMediaPath(relPath);
    if (absolute == null) return;
    try {
      final file = File(absolute);
      if (await file.exists()) await file.delete();
    } on Object {
      // 留孤儿文件可接受：该目录在 media/ 之外，ManagedMediaStore 的 GC 不会碰。
    }
  }

  /// 与 [DatabaseService.aiProcessingDir] 同源的**同步**根路径解析。
  ///
  /// 渲染层在 `build()` 里同步解析头像路径，无法 await；无法同步确定时返回
  /// null，调用方回落文本头像。与异步版本的差异仅出现在「无 HOME 且未设置
  /// 自定义目录」的少数环境（此时异步版会抛 [StateError]），回落文本是可接受行为。
  String? get _aiProcessingRootSync {
    final saved = aiProcessingDirPath;
    if (saved != null && saved.trim().isNotEmpty) {
      return Directory(saved).absolute.path;
    }
    try {
      return DatabaseService.defaultAiProcessingDirectoryPath(
        userHomePath: _platformUserHomePathSync(),
      );
    } on StateError {
      return null;
    }
  }
}

/// 与 `DatabaseService._platformUserHomePath` 同规则的用户目录解析。
/// 抽成顶层函数是因为该私有方法无法从 extension 访问，而两处必须同源。
String? _platformUserHomePathSync() {
  for (final key in const ['HOME', 'USERPROFILE']) {
    final value = Platform.environment[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final homeDrive = Platform.environment['HOMEDRIVE']?.trim();
  final homePath = Platform.environment['HOMEPATH']?.trim();
  if (homeDrive != null &&
      homeDrive.isNotEmpty &&
      homePath != null &&
      homePath.isNotEmpty) {
    return '$homeDrive$homePath';
  }
  return null;
}

String _normalizeSeparators(String path) => path.replaceAll('\\', '/');

bool _hasDrivePrefix(String path) =>
    path.length >= 2 && path[1] == ':' && _isAsciiLetter(path[0]);

bool _isAsciiLetter(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}
