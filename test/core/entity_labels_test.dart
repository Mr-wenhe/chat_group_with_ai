import 'package:chat_group/core/text/entity_labels.dart';
import 'package:flutter_test/flutter_test.dart';

const _memberId = 'e1f80660-581f-488b-b8e6-94cb63192ec1';
const _taskId = 'ab12cd34-1111-4222-8333-444455556666';
const _groupId = 'a1b2c3d4-5555-4666-8777-888899990000';
const _foreignId = 'deadbeef-0000-4000-8000-000000000000'; // 不是任何实体

void main() {
  test('已解析的 id 换成名字', () {
    final labels = EntityLabels.fixed(const {_memberId: '产品经理'});
    expect(
      labels.humanize('成员 $_memberId：成员当前资格或配置不可用。'),
      '成员 产品经理：成员当前资格或配置不可用。',
    );
  });

  test('未解析的 id 只压短码，不猜名字', () {
    final labels = EntityLabels.fixed(const {_memberId: '产品经理'});
    expect(labels.humanize('引用 $_foreignId 无效'), '引用 未知对象（deadbeef） 无效');
  });

  test('一条文案里多个 id 各自解析', () {
    final labels =
        EntityLabels.fixed(const {_memberId: '产品经理', _taskId: '任务 #ab12cd34'});
    expect(
      labels.humanize('$_memberId 负责 $_taskId'),
      '产品经理 负责 任务 #ab12cd34',
    );
  });

  test('名字含特殊字符原样插入，且不被当成新 token', () {
    final labels = EntityLabels.fixed(const {_memberId: r'小明$ <b>"引号"'});
    expect(labels.humanize('成员 $_memberId 发言'), r'成员 小明$ <b>"引号" 发言');
  });

  test('dm: 会话整体解析，不与群 id 混为一谈', () {
    final labels = EntityLabels.fixed(const {
      'dm:e1f80660-581f-488b-b8e6-94cb63192ec1': '与「产品经理」的私聊',
      _groupId: '「CUA QA 1002」',
    });
    expect(
      labels.humanize('dm:e1f80660-581f-488b-b8e6-94cb63192ec1 与 $_groupId'),
      '与「产品经理」的私聊 与 「CUA QA 1002」',
    );
  });

  test('无 token 的文本原样返回（含短码文本不被二次处理）', () {
    final labels = EntityLabels.fixed(const {_memberId: '产品经理'});
    expect(labels.humanize('任务 #ab12cd34 仍在队列'), '任务 #ab12cd34 仍在队列');
  });

  test('短码规则：8 位以内原样，超出取前 8 位，dm: 前缀不计入', () {
    expect(EntityLabels.shortCode('abcdefgh'), 'abcdefgh');
    expect(EntityLabels.shortCode(_memberId), 'e1f80660');
    expect(EntityLabels.shortCode('dm:$_memberId'), 'e1f80660');
  });

  test('labelFor 在无人认领时给出带短码的未知名', () {
    expect(EntityLabels.none().labelFor(_foreignId), '未知对象（deadbeef）');
  });

  test('resolveOrNull 只解析不兜底，供需要区分「没有名字」的派生逻辑使用', () {
    final labels = EntityLabels.fixed(const {_memberId: '产品经理'});
    expect(labels.resolveOrNull(_memberId), '产品经理');
    expect(labels.resolveOrNull(_foreignId), isNull);
  });

  test('looksLikeUuid 只认整串 UUID', () {
    expect(looksLikeUuid(_memberId), isTrue);
    expect(looksLikeUuid('成员 $_memberId 发言'), isFalse);
    expect(looksLikeUuid('产品经理'), isFalse);
  });

  test('withResolver 追加一族领域解析器，且不动原有解析结果', () {
    final labels = EntityLabels.fixed(const {_memberId: '产品经理'});
    final merged = labels.withResolver(
      (id) => id == _taskId ? '第 1 轮候选' : null,
    );

    expect(
      merged.humanize('$_memberId 的 $_taskId 已冻结'),
      '产品经理 的 第 1 轮候选 已冻结',
    );
    // 原实例不受影响（withResolver 返回新实例，不改前者）。
    expect(labels.humanize('$_memberId 的 $_taskId 已冻结'), '产品经理 的 未知对象（ab12cd34） 已冻结');
  });
}
