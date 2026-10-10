/// 用户原话里点名的交付物范围。
///
/// 群任务 v2 默认要求软件合同带需求/技术/测试三份材料工作项，为的是留下过程
/// 证据。但当用户只用一句话要**一个**交付文件时（"生成一份 飞行棋游戏的HTML"），
/// 那三份材料把任务放大数倍却不增加任何验证力——验证力来自 `acceptances`、
/// `verificationCommands` 和独立审查，那三样不在这里放宽。
///
/// **默认判否是刻意的**：判错的方向必须偏保守。"没识别出单产物"只是回到旧行
/// 为；"误判成单产物"会让一个多产物任务绕过材料要求。所以单数判据写紧、并列
/// 判据写松。
library;

/// 交付物名词表。
///
/// 与 `WorkRoleRouter.requestsSoftwareImplementation` 里那份是同一套词汇，另
/// 外补了 README/CSS/样式这类"也算交付物"的词：那份表回答"是不是软件实现"，
/// 这份回答"交付了几个东西"。
const String _artifactNouns = '软件|程序|应用|游戏|网页|网站|代码|脚本|'
    '文档|报告|方案|说明|样式|样式表|readme|'
    'html|flutter|python|css|app|game|website|code|docx|pdf|markdown';

/// 单数量词本身（不含它后面的名词）。
const String _quantifierPattern =
    r'(?:一份|一个|单个|一张|一款|单一|\b(?:one|single)\b)';

/// 单数量词与产物名词必须落在同一小句里，中间只允许修饰语。
///
/// 中间不接受标点与并列连词，否则"生成一份。然后做网页"这种跨句会误判。
final RegExp _singularArtifact = RegExp(
  '$_quantifierPattern'
  r'\s*[^，,。；;、\n和与及]{0,24}'
  '(?:$_artifactNouns)',
  caseSensitive: false,
);

/// 连词之后另有一个产物名词，说明用户点名了不止一个交付物。
///
/// 允许连词与名词之间隔一小段修饰语（"和它的样式"），因为这一侧宽松是安全的：
/// 误判只会退回"要求材料"的旧行为。标点也算连词——"一份报告，说明文档"本身就是
/// 并列；但必须限定在同一小句内（连词后不接受句末标点），否则上一个句子里的
/// 连词会和下一句的名词拼到一起。
final RegExp _enumeratedArtifact = RegExp(
  r'(?:和|与|及|以及|、|还有|另外|另加|外加|并|并且|然后|再|同时|接着|之后|'
  r'跟|加上|,|，|\b(?:plus|and|then)\b)'
  r'[^，,。；;\n]{0,8}'
  '$_quantifierPattern?'
  r'\s*'
  '(?:$_artifactNouns)',
  caseSensitive: false,
);

/// 复数量词直接否决，不再看单数判据。
final RegExp _pluralArtifact = RegExp(
  r'多个|几种|几份|多份|两份|三份|\b(?:multiple|several|two|three)\b',
  caseSensitive: false,
);

/// 用户是否只点名了一个交付物。
///
/// 只读用户原话，不看模型提案：合同字段由协调成员填写，用它判定等于让被约束
/// 的一方自己决定要不要被约束。任何不确定都返回 `false`。
bool requestsSingleArtifact(String request) {
  if (request.trim().isEmpty) return false;
  final lower = request.toLowerCase();
  if (_pluralArtifact.hasMatch(lower)) return false;
  // 一句话里出现两处"单数量词 + 产物名词"，就是在点名两件东西，直接判非单产物。
  //
  // 并列判据落在**量词连产物**上，而不是逐个补连词表：用户写"生成一份报告，
  // 一份说明"用逗号、"生成一份报告并生成一份说明"用"并"、"先做一份文档，再做
  // 一份网页"用"再"——连词表永远补不完，而"两处量词 + 产物"是同一件事的直接
  // 证据。只数裸量词会把现场那句"创建一个目录，目录中的内容生成一份 飞行棋
  // 游戏的HTML"里的目录也算成一件交付物。
  final singularMatches = _singularArtifact.allMatches(lower).length;
  if (singularMatches == 0) return false;
  if (singularMatches > 1) return false;
  if (_enumeratedArtifact.hasMatch(lower)) return false;
  return true;
}
