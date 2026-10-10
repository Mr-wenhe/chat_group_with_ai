import 'package:chat_group/core/images/ip_image_prompt_builder.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/ai_character/ip_visual_description_llm.dart';

/// 生成 IP 形象所需的一次性草稿快照，与具体业务模型解耦。
///
/// 拼 prompt 要 [subject]，喂改写模型要 [facts]，落盘要 [ownerName] 与
/// [directoryId]，选聊天配置要 [apiConfigId] —— 五样必须出自**同一份草稿**，
/// 否则生成期间用户改了某个字段会拼出半新半旧的形象。所以由表单一次取出、
/// 整包传进来。
///
/// 单独成文件而不是留在面板里：它是「取素材」的数据载体，不是面板 UI，
/// 而角色表单与资料表单都只认它、不认面板内部。
class IpPortraitSource {
  const IpPortraitSource({
    required this.subject,
    required this.facts,
    required this.ownerName,
    required this.directoryId,
    this.apiConfigId = '',
  });

  factory IpPortraitSource.fromCharacter(AICharacter character) {
    return IpPortraitSource(
      subject: IpPortraitSubject.fromCharacter(character),
      facts: buildCharacterPortraitFacts(character),
      ownerName: character.name,
      directoryId: character.id,
      apiConfigId: character.apiConfigId,
    );
  }

  factory IpPortraitSource.fromUserProfile(UserProfile profile) {
    return IpPortraitSource(
      subject: IpPortraitSubject.fromUserProfile(profile),
      facts: buildUserProfilePortraitFacts(profile),
      ownerName: profile.displayName,
      // 单人信息卡是固定单例，`UserProfile.id` 就是 `me`；取它而不是写字面量，
      // 免得路径目录与资料卡 key 各写一份「me」。
      directoryId: profile.id,
      apiConfigId: profile.apiConfigId,
    );
  }

  final IpPortraitSubject subject;
  final String facts;
  final String ownerName;

  /// 落盘目录所含的主体 id。**只有 AI 角色分支会用到**——
  /// 真人分支固定写 `me` 的受管目录（见 `writeBytesToUserProfileDir`）。
  ///
  /// 随草稿一起快照，而不是让面板再收一个 `subjectId` 参数：那样面板在真人
  /// 分支上拿着一个恒为 `me`、又永不读取的必填参数，读代码的人会误以为它
  /// 决定落盘路径（实际分叉判据是 [IpPortraitSubject.describesAi]）。
  final String directoryId;

  /// 外观改写所用的聊天 `ApiConfig` id；'' = 不改写，直接走本地模板。
  final String apiConfigId;
}
