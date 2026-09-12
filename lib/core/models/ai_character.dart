import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';
import 'tool_permission.dart';

part 'ai_character.g.dart';

@HiveType(typeId: 24)
enum CharacterGender {
  @HiveField(0)
  male,

  @HiveField(1)
  female;

  String get label => this == CharacterGender.male ? '男' : '女';
}

@HiveType(typeId: 0)
class AICharacter extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String avatar;

  @HiveField(3)
  int age;

  @HiveField(4)
  String role;

  @HiveField(5)
  List<String> personalityTags;

  @HiveField(6)
  String systemPrompt;

  @HiveField(7)
  String memorySummary;

  @HiveField(8)
  String apiKey;

  @HiveField(9)
  String apiProvider;

  @HiveField(10)
  String modelName;

  @HiveField(11)
  String customBaseUrl;

  @HiveField(12)
  int hourlyReplyLimit;

  @HiveField(13)
  int hourlyReplyCount;

  @HiveField(14)
  DateTime? lastReplyTimestamp;

  @HiveField(15)
  bool isActive;

  @HiveField(16)
  final DateTime createdAt;

  @HiveField(17)
  String apiConfigId;

  @HiveField(18, defaultValue: true)
  bool agenticEnabled;

  @HiveField(19, defaultValue: [])
  List<String> skillIds;

  @HiveField(20, defaultValue: [
    ToolPermission.skillCreate,
    ToolPermission.skillDownload,
  ])
  List<ToolPermission> toolPermissions;

  /// 创建后不可变。缺少该字段的旧记录兼容读取为女；迁移是否完成必须
  /// 由版本化迁移状态判断，不能由这个兼容默认值推断。
  @HiveField(21, defaultValue: CharacterGender.female)
  final CharacterGender gender;

  /// Deleted snapshots from before gender was stored keep their identity but
  /// must not present the Hive compatibility default as a known gender.
  ///
  /// This is persisted for imported snapshots so a pending migration cannot
  /// accidentally turn the compatibility value into a confirmed choice.
  @HiveField(22, defaultValue: false)
  final bool hasKnownGender;

  /// 角色朗读回复用的音色 id（见 `voice.md` / [VoicePreset]）。
  /// 为空表示未指定：群聊语音播报时回落到语音服务配置的“默认音色”。
  @HiveField(23, defaultValue: '')
  String voiceId;

  /// 是否允许该角色参与用户回合的联网搜索。
  ///
  /// 搜索 Provider 仍由全局联网治理设置决定；此字段只控制角色是否
  /// 可以消费本回合的搜索证据，默认关闭以兼容已有角色。
  @HiveField(24, defaultValue: false)
  bool webSearchEnabled;

  /// 是否允许角色在用户未主动发消息时发起私信，默认开启以保持原有行为。
  @HiveField(25, defaultValue: true)
  bool proactiveChatEnabled;

  AICharacter({
    String? id,
    required this.name,
    required this.avatar,
    required this.age,
    required this.role,
    required this.personalityTags,
    required this.systemPrompt,
    this.memorySummary = '',
    required this.apiKey,
    required this.apiProvider,
    String? modelName,
    this.customBaseUrl = '',
    this.hourlyReplyLimit = 60,
    this.hourlyReplyCount = 0,
    this.lastReplyTimestamp,
    this.isActive = true,
    DateTime? createdAt,
    String? apiConfigId,
    this.agenticEnabled = true,
    List<String>? skillIds,
    List<ToolPermission>? toolPermissions,
    this.gender = CharacterGender.female,
    this.hasKnownGender = true,
    this.voiceId = '',
    this.webSearchEnabled = false,
    this.proactiveChatEnabled = true,
  })  : id = id ?? const Uuid().v4(),
        modelName = modelName ?? ApiProvider.defaultModels[apiProvider] ?? '',
        createdAt = createdAt ?? DateTime.now(),
        apiConfigId = apiConfigId ?? '',
        skillIds = skillIds ?? const [],
        toolPermissions = toolPermissions ??
            const [ToolPermission.skillCreate, ToolPermission.skillDownload];

  /// Creates the replacement object used by the one migration path allowed to
  /// resolve gender. Ordinary edits must keep the saved object's gender.
  AICharacter withGender(
    CharacterGender value, {
    bool hasKnownGender = true,
  }) {
    return AICharacter(
      id: id,
      name: name,
      avatar: avatar,
      age: age,
      role: role,
      personalityTags: List<String>.from(personalityTags),
      systemPrompt: systemPrompt,
      memorySummary: memorySummary,
      apiKey: apiKey,
      apiProvider: apiProvider,
      modelName: modelName,
      customBaseUrl: customBaseUrl,
      hourlyReplyLimit: hourlyReplyLimit,
      hourlyReplyCount: hourlyReplyCount,
      lastReplyTimestamp: lastReplyTimestamp,
      isActive: isActive,
      createdAt: createdAt,
      apiConfigId: apiConfigId,
      agenticEnabled: agenticEnabled,
      skillIds: List<String>.from(skillIds),
      toolPermissions: List<ToolPermission>.from(toolPermissions),
      gender: value,
      hasKnownGender: hasKnownGender,
      voiceId: voiceId,
      webSearchEnabled: webSearchEnabled,
      proactiveChatEnabled: proactiveChatEnabled,
    );
  }

  String get displayGenderLabel => hasKnownGender ? gender.label : '未知';

  // Active legacy records need a deterministic prompt fallback while storage
  // is still migrating; deleted snapshots remain visibly unknown and never
  // become prompt participants.
  String get _promptGenderLabel =>
      hasKnownGender || isActive ? gender.label : displayGenderLabel;

  String get promptIdentity => '$name，$age岁，性别$_promptGenderLabel，身份是$role';

  String get rolePlaySystemPrompt {
    final prompt = systemPrompt.trim().isEmpty ? null : systemPrompt;
    return [
      '你是$promptIdentity。',
      '角色性别为$_promptGenderLabel，请保持称谓和角色表现与该设定一致。',
      if (prompt != null) prompt,
    ].join('\n');
  }
}
