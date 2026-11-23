import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';

void main() {
  test('public network requests do not require workspace execution', () {
    for (final request in [
      'Search Flutter documentation, read and download https://example.com/README.md',
      'Fresh acceptance run: search the official Python repository README, read the result, and download the original file',
      "Retry the ordinary-chat acceptance. Search for official Flutter SDK documentation and the Flutter project's public README without a target URL or site: filter. If the first search yields no useful source, try one broader query. Read a returned source and extract one checkable fact. Then download the original README from the official project's own source unchanged as qa-sensenova-dm-ordinary-v3-20261120.md and attach it. Report real receipt IDs, source URLs, retrieval time, fact, byte count, and SHA-256. Use at most two searches; stop and report actual failures, never invent evidence.",
      'Search the official Flutter repository README, read and download the original, attach it here, and do not access local files',
      'Search the public web for the official Flutter GitHub repository README. Do not use a target URL from this message. Read the strongest official search result and extract one verifiable fact about supported desktop platforms. Then locate and download the official repository\'s raw plain-text README unchanged as qa-st-dm-20261119-r1.md, and attach it to your final reply. Return the actual search query, source IDs and URLs, read receipt and fact, download receipt, filename, byte count, and SHA-256. Distinguish any publication/update date from search time. Do not use shell or Work mode. If the model or any web step fails, name the phase and exact error. Stop after one completed attempt.',
      'Continue from the official Flutter README found in the previous search. Download the raw README.md unchanged from that official repository revision and attach the downloaded file to this reply. Report the exact saved filename and byte size. Do not create or edit a replacement file.',
      'Search the public web for the official Flutter GitHub README; this message contains no target URL. Read the official result and report one exact, verifiable fact with its source link. Then download the raw README.md unchanged from the official repository revision found in search, attach it to your final reply, and report the exact filename, byte length, and SHA-256. Do not access or modify workspace files. If any phase fails, name the phase and exact error.',
      '根据刚才的官方 README，下载原始文件并作为附件回复；不要创建或修改替代文件。',
      'Search public sources; do not read or write workspace files',
      '搜索公开资料并读取网页正文，不要访问本地文件',
      '搜索资料并读取网页正文',
      '下载 https://example.com/file.pdf',
      '阅读 https://example.com/UI/project/code 后总结',
    ]) {
      expect(WorkModePolicy.looksLikeWorkRequest(request), isFalse,
          reason: request);
    }
  });
  test('mixed local execution and network requests retain the work-mode gate',
      () {
    for (final request in [
      '下载 https://example.com/script.sh 然后运行',
      '搜索资料并修改本地项目',
      'Search documentation and write code',
      'Search documentation and run tests',
      'Download the public README and create a local summary file',
      '下载公开 README，并创建本地摘要文件',
      'Search for instructions, then read files from my desktop folder',
      r'Read https://example.com and edit C:\work\main.dart',
      '读取本地代码',
    ]) {
      expect(WorkModePolicy.looksLikeWorkRequest(request), isTrue,
          reason: request);
    }
  });
}
