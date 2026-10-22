import 'package:path/path.dart' as p;
import 'work_artifact_delivery_guard.dart';

/// 旧值到新值之间的"变更连接"。
///
/// 中文是变更动词（"改名为""改成"…），英语是 `to` / `into` / `as`。动词前只允许
/// 空白、引号、括号与"的文件名"这类结构性字词，于是
/// "game.html 文件名，不要改成 game2.html" 里的逗号会直接断开匹配——名称共现
/// 因此成不了改名授权。
const String _changeLinkSource = r'[\s"‘’“”()（）]*'
    r'(?:(?:的)?(?:文件名|名称|名字|路径|格式|输出|产物|文件|的))*'
    r'[\s"‘’“”()（）]*'
    r'(?:改名为|改名成|改名|改称|更名(?:为|成)?|重命名(?:为|成)?|改成|改为|换成|换为'
    r'|替换(?:为|成)|变为|变成|调整为|修改(?:为|成)|切换(?:为|成)|to|into|as)'
    r'[\s"‘’“”()（）]*';

/// 否定或"保持原样"的语义。它出现在变更连接里就不是改名授权（"不要改成
/// game2.html"）；紧贴在旧值之前也一样（"保持 game.html 文件名"，见
/// [_prohibitionAdjacentBefore]）。
final RegExp _userProhibition = RegExp(
    r'不要|不用|不需要|不必|不想|无需|无须|禁止|不得|不许|不能|不可|不准|请勿|勿'
    r'|不改名|不改|不换|不动|不重命名'
    r'|别改|别换|别动|别把|别重|别用|别再'
    r'|保持|维持|沿用|保留|不变|照旧|原样|依旧'
    r"|do not|don't|dont|never|not\b|no need|keep|retain|unchanged",
    caseSensitive: false);

/// 紧贴在旧值**之前**的否定（"保持 game.html 文件名"）。
///
/// 必须紧贴旧值，但允许“不要把 X”或“don't rename X”的结构性连接。
/// “在保持内容不变的前提下
/// 把 game.html 改名为 game2.html"里的"保持"管的是内容，与改名无关，放宽成
/// "旧值所在从句出现否定就拦"会把这类正常改名句整句挡下来。
final RegExp _prohibitionAdjacent = RegExp(
    r'(?:不要|不用|不需要|不必|不想|无需|无须|禁止|不得|不许|不能|不可|不准|请勿|勿'
    r'|不改名|不改|不换|不动|不重命名'
    r'|别改|别换|别动|别把|别重|别用|别再'
    r'|保持|维持|沿用|保留|不变|照旧|原样|依旧'
    r"|do not|don't|dont|never|not\b|no need|keep|retain|unchanged)"
    r'[\s"‘’“”()（）的]*(?:把|将|让|rename\b|change\b|convert\b|replace\b|switch\b|turn\b)?'
    r'[\s"‘’“”()（）的]*$',
    caseSensitive: false);

/// 把变更放进"要不要做"的评估框架，而不是下达变更指令。
///
/// 判据是变更所在**从句**里的疑问或讨论标记："先讨论把 game.html 改名为
/// game2.html 是否合适"里那句改名只是被讨论的提议，用户并没有授权改名。
final RegExp _evaluationFrame = RegExp(
    r'是否|吗|？|\?|合不合适|妥不妥|该不该|可行性|先讨论|讨论一下|讨论下|评估一下|商量|询问',
    caseSensitive: false);

/// 紧跟在目标值之后的否定（"…改成 game2.html 是不允许的"）。
///
/// 只认紧邻的"是/就/也/都/则 + 否定"：放宽成"目标之后出现否定就算"会把下一个
/// 从句里的"内容保持不变"也当成禁止改名，把正常的改名句挡下来。
final RegExp _userPostProhibition =
    RegExp(r'^[\s"‘’“”()（）]*(?:是|就|也|都|则)?[\s"‘’“”()（）]*'
        r'(?:不行|不可|不允许|不被允许|不该|不应该|不能|禁止)');

/// 汉字与日文假名的范围，用来决定词元该按哪套词字符收边。
final RegExp _cjkCharacter =
    RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3040-\u30ff]');

bool statesWorkContractChange(String text,
    {required String from, required String to, required bool asFormat}) {
  if (!asFormat &&
      (text.contains('\\') || from.contains('\\') || to.contains('\\'))) {
    text = text.replaceAll('\\', '/');
    from = from.replaceAll('\\', '/');
    to = to.replaceAll('\\', '/');
  }
  final origins = workContractValueSpellings(from, asFormat: asFormat);
  final targets = workContractValueSpellings(to, asFormat: asFormat);
  if (origins.isEmpty || targets.isEmpty) return false;
  final lower = text.toLowerCase();
  final pattern = RegExp(
    '(?:${origins.map(_tokenSource).join('|')})'
    '($_changeLinkSource)'
    '(?:${targets.map(_tokenSource).join('|')})',
    unicode: true,
  );
  for (final match in pattern.allMatches(lower)) {
    if (_userProhibition.hasMatch(match.group(1)!)) continue;
    if (_prohibitionAdjacent.hasMatch(lower.substring(0, match.start))) {
      continue;
    }
    if (_userPostProhibition.hasMatch(_clauseAfter(lower, match.end))) {
      continue;
    }
    final clause = _clauseBefore(lower, match.start) +
        match.group(0)! +
        _clauseAfter(lower, match.end);
    if (_evaluationFrame.hasMatch(clause)) continue;
    return true;
  }
  return false;
}

/// 用户可能写出的该值拼写。
///
/// 格式词按别名族展开（用户写 "Word"、合同写 `docx` 是同一个交付格式），
/// 其余字段只有原值本身。
List<String> workContractValueSpellings(String value,
    {required bool asFormat}) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return const [];
  final spellings = <String>{normalized};
  if (asFormat) {
    final canonical = WorkArtifactDeliveryGuard.formatAliases[normalized];
    if (canonical != null) {
      spellings.addAll(WorkArtifactDeliveryGuard.formatAliases.entries
          .where((entry) => entry.value == canonical)
          .map((entry) => entry.key.trim().toLowerCase()));
    }
  }
  return spellings.toList();
}

/// 值的匹配源，两侧都要求独立成词。
///
/// 拉丁词元只看 **ASCII** 词字符：中文里名称与汉字直接相邻是正常写法
/// （"把game.html改名为game2.html"），把相邻汉字也算词字符会让这类句子永远
/// 点不到名。CJK 词元仍按 Unicode 词字符收边，否则"软件"会点着"软件开发"。
String _tokenSource(String token) {
  final normalized = token.trim().toLowerCase();
  if (_cjkCharacter.hasMatch(normalized) &&
      (normalized.contains('.') || normalized.contains('/'))) {
    // Chinese filenames may follow 把/将, but cannot match another filename's suffix.
    return r'(?:(?<![\p{L}\p{N}_])|(?<=把)|(?<=将))'
        '${RegExp.escape(normalized)}'
        r'(?![A-Za-z0-9_])';
  }
  final edge = _cjkCharacter.hasMatch(normalized) &&
          !normalized.contains('.') &&
          !normalized.contains('/')
      ? r'[\p{L}\p{N}_]'
      : r'[A-Za-z0-9_]';
  return '(?<!$edge)${RegExp.escape(normalized)}(?!$edge)';
}

/// [index] 之前、最近一个句读之后的文本。
String _clauseBefore(String lower, int index) {
  final start =
      lower.substring(0, index).lastIndexOf(RegExp(r'[，,。；;！!？?：:\n]'));
  return lower.substring(start + 1, index);
}

/// [index] 之后、最近一个句读之前的文本。
String _clauseAfter(String lower, int index) {
  final end = lower.substring(index).indexOf(RegExp(r'[，,。；;！!？?：:\n]'));
  return end < 0 ? lower.substring(index) : lower.substring(index, index + end);
}

/// Uses the path's own syntax so imported Windows paths compare consistently too.
p.Context _artifactPathContext(String path) => p.Context(
    style: RegExp(r'^[A-Za-z]:[\\/]|^[\\/]{2}').hasMatch(path.trim())
        ? p.Style.windows
        : p.style);

/// Windows keys ignore case; POSIX keys preserve it.
String workArtifactPathKey(String path) {
  final context = _artifactPathContext(path);
  final input = context.style == p.Style.windows
      ? path.trim().replaceAll('/', '\\')
      : path.trim();
  final normalized = context.normalize(input).replaceAll('\\', '/');
  return context.style == p.Style.windows
      ? normalized.toLowerCase()
      : normalized;
}

/// Follows explicit file renames in user order; mentions and prohibitions do not authorize changes.
String rewrittenWorkArtifactPath(String scope, String original) {
  final context = _artifactPathContext(original);
  final windows = context.style == p.Style.windows;
  String nativePath(String value) =>
      windows ? value.replaceAll('/', '\\') : value;
  if (windows) scope = scope.replaceAll('\\', '/');
  var path = context.normalize(nativePath(original));
  var cursor = 0;
  while (cursor < scope.length) {
    final sources = <String>{
      path.replaceAll('\\', '/'),
      context.basename(path)
    };
    for (var directory = context.dirname(path);
        directory != context.dirname(directory);
        directory = context.dirname(directory)) {
      sources.add(directory.replaceAll('\\', '/'));
    }
    final pattern = RegExp(
        '(${sources.map(_tokenSource).join('|')})$_changeLinkSource'
        r'([^\s，,；;。！？!?“”"‘’<>]+?\.(?:html?|md|txt|json|pdf|docx|xlsx|pptx)(?![A-Za-z0-9_])|(?:[A-Za-z]:/|//|/)[^\s，,；;。！？!?“”"‘’<>]+)',
        caseSensitive: false,
        unicode: true);
    final match = pattern.firstMatch(scope.substring(cursor));
    if (match == null) break;
    final from = nativePath(match.group(1)!);
    final target = nativePath(match.group(2)!);
    final start = cursor + match.start;
    final end = cursor + match.end;
    final clause = _clauseBefore(scope, start) +
        match.group(0)! +
        _clauseAfter(scope, end);
    if (statesWorkContractChange(clause,
        from: from, to: target, asFormat: false)) {
      if (context.equals(from, path) ||
          context.equals(from, context.basename(path))) {
        path = context.normalize(context.isAbsolute(target)
            ? target
            : context.join(context.dirname(path), target));
      } else if (context.isAbsolute(target)) {
        path = context.normalize(
            context.join(target, context.relative(path, from: from)));
      }
    }
    cursor = end;
  }
  return path;
}
