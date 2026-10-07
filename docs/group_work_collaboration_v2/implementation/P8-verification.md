# P8 命令日志摘要

临时原日志：`/tmp/chat-group-p8/`。此摘要保存全部开发检查日志的 SHA-256 与末尾结果，包括失败；该批历史检查的全量为 full-verified.log（2982通过），静态为 analyze-verified.log（无问题）；后续验收与复审结果见追加章节。没有采集实际群聊样本，本文件不能替代。

| 日志 | SHA-256 | 结果原文（末尾） |
| --- | --- | --- |
| affected-final.log | `c9874a28d2efe7bde83a9031e12a4bcb31477f0ef00d3d81d782e624ecb5442a` | 01:45 +1325 -3: Some tests failed. |
| affected.log | `f1052ba28cafdf93d8391f1438271f9aff566256725ef0f4242ce0f83f01294c` | 00:29 +476 -8: /Volumes/new_disk/work/flutter/chat_group/chat_group/test/work_mode/work_mode_v1_spec_guard_test.dart: direct-chat policy keeps private conversation identity isolated |
| analyze-complete.log | `0482be63a7bdcaff35bb9bdfad5968d6b8fb4e52ef5b6717a0a7d813d89aa851` | 4 issues found. (ran in 12.5s) |
| analyze-final-clean.log | `eb27820e7d776e7311d665d24f7c186dcb3f8e8d73e2d7818119bfbc3891ba5b` | No issues found! (ran in 8.7s) |
| analyze-final.log | `d4331e9d447e1f55e30d08586cb18562f30a282860d83dd475acbbc8557a6770` | 5 issues found. (ran in 12.3s) |
| analyze-first.log | `a355044c89a18407f4c03ac252d8c9eac24b2c9a3e28d27e194d153b23112156` | 2 issues found. (ran in 9.3s) |
| analyze-next.log | `4ef42bd03acfc4a24091c609e7165f082ce34eb47691000cfc52594e9fa328b8` | 2 issues found. (ran in 8.1s) |
| analyze-release-check.log | `5a045b24e5bb37d7a8c5a244155cad3c5a806fb1aac43f8f88988d2245dfce69` | No issues found! (ran in 6.1s) |
| analyze-verified.log | `4a3bf321b0e83af339c71fc0a3fc6d21d25f8cda5e1eb502f2cdf8eef20ec5e1` | No issues found! (ran in 8.0s) |
| backup-complete.log | `35b0a16faaa27af45bede8b4d119c2d69b0414456c971c28529702f3f58e92d8` | 00:03 +63: All tests passed! |
| backup-final-safe.log | `d90c974302fb96f79d631e85177af7ceb645fd7d823e23bc4d727dc303dab34a` | 00:03 +63: All tests passed! |
| backup-verified.log | `7365e1756b42aa572007d253579b0c7b506ad171773ffe88e5fd4ab813c2f909` | 00:08 +63: All tests passed! |
| codegen.log | `9b92a6febbc4948e7cd9847cb28489458a1fa090a8e4053b6bff095b74ad3462` | [INFO] Succeeded after 21.4s with 153 outputs (789 actions) |
| docx-final.log | `dae69afa4f0373c8567884ddb8ea2202f3bdaa7cced12c2113b70b642d54368e` | 00:01 +14: All tests passed! |
| focused-final.log | `abca9b2864d807900746a6030c8b90439113af06b6954faf03a07d67b68c5aac` | 01:03 +303 -1: Some tests failed. |
| focused-next.log | `f38d4885759d7ecf23dbd3476e384ece0bc0570e9c671dfd65f3ea14e32a6cdc` | 01:06 +293 -3: Some tests failed. |
| focused.log | `a5d1b1bd9655dd9901b07182770fe31cc907a8e0c63923e8f8820466665c2abe` | 01:03 +292 -4: Some tests failed. |
| format.log | `bfbda8c2e0c79941203b4e5a0755a501a1ea481346ccf0e6574333e89e2fc7fb` | Formatted 10 files (9 changed) in 0.31 seconds. |
| format2.log | `f2f04cec3a54f4494ce8281e01f2fd3729248d118bed3ad22ff9cb6efc312019` | Formatted 6 files (5 changed) in 0.26 seconds. |
| format3.log | `f7f53dc710b1acce3004fee8074ff4fedff6cb856e8e57c0327aea10a67e05e2` | Formatted 10 files (7 changed) in 0.29 seconds. |
| full-complete.log | `f7734abcbaad3a99cfed6b0b215a25bda26ca63c1cf8bf825d53ceafbbc8635b` | 03:09 +2981: All tests passed! |
| full-final.log | `19b322e0d86c4b5d72c741de743b938396ea6d974effa47561a1ed6e977663a6` | 03:17 +2980: All tests passed! |
| full-release-check.log | `06214c8757660908baef041d12aef6ebdd16fba5ad4921a9203e722f6dbb2032` | 03:29 +2981 -1: Some tests failed. |
| full-verified.log | `b0d5d3816724b8ae6d356c155ed172e1b8a8d786bf91e848e237b4dff89aab00` | 03:30 +2982: All tests passed! |
| p8-final.log | `0240775a12f1548f690b782a6fb3b1fa4d40b688382274b4333dead4ab1a9367` | 00:01 +12 -1: Some tests failed. |
| p8-next.log | `3f905953ee28b64b8d1e356be6ec39b2d7df488278e8217690a7b6d17530bc16` | 00:01 +7 -4: Some tests failed. |
| p8-third.log | `ff0037a0207a7b7e57c1267de4b6f81f95703b10cde13cf186fc9abeb85260f1` | 00:01 +10 -1: Some tests failed. |
| p8.log | `55772c8dea79f81f3d385521c94ca4514598f00f8d5c147be9387cc426e091bd` | 00:00 +0 -1: Some tests failed. |
| prerequisite.log | `726a115834b65231bf2a82a992af6695ab59912c1b6ef6f112e8be5fc01073d3` | 00:59 +164: All tests passed! |
| public-report-final.log | `06364368f3fc54919f07190c3898a15af85a7df472e744cd8866630fb4101c5c` | 00:01 +20: All tests passed! |
| recovery-complete.log | `fdfb5b4c08d511c21bf12b49fe79499f6a833ee8260aae14c6e43862c25dee01` | 00:00 +11: All tests passed! |
| regressions-fifth.log | `de11ae51626196222dafdf937ba6aea6b2676615662c90777f57e46c6eb430e2` | 00:07 +1 -1: Some tests failed. |
| regressions-fourth.log | `68629a9095be8dbfe2357c29fe2bba3900b0d063eec86283a275da681db03577` | 00:05 +1 -2: Some tests failed. |
| regressions-next.log | `d325b3f8bf300fed17f8b2f0cc44ccbc8eb607c15c422f5be666dffdd28adb63` | 00:05 +0 -3: Some tests failed. |
| regressions-third.log | `b8ec6bbe7ecae021201f8152f3681fcfa31fd285419a14bdfda29d08170a0b66` | 00:07 +0 -3: Some tests failed. |
| regressions.log | `78a98eb1fd6e77dae4d5726bc5ee0c7f5d6531f4390dea3dc016f5f7c08fcdcc` | 00:00 +0 -1: Some tests failed. |
| s8-v2-next.log | `9d326b55b81aa5f1dbe3c3a98bcf8a289c8c9b6c0b849c2571723761bb0add7c` | 00:07 +0 -1: Some tests failed. |
| s8-v2-paged.log | `f719baca5efa5a4a5619bf27ce6ec79572e9458df3b51dc3ea88b9d446162f3d` | 00:00 +0 -1: Some tests failed. |
| s8-v2.log | `9d326b55b81aa5f1dbe3c3a98bcf8a289c8c9b6c0b849c2571723761bb0add7c` | 00:07 +0 -1: Some tests failed. |
| slots-complete.log | `a39c421b0ac990afe5f4af2740fc6297f049fb36555f141ed8fd0336b7c334cb` | 00:00 +1: All tests passed! |
| slots-final.log | `11bb413fb36bb53292212584458b0008b9b8a068a904c27d0c12562af6f75e05` | 00:00 +0 -1: Some tests failed. |

## Acceptance continuation command logs

| Log | SHA256 | Last result |
| --- | --- | --- |
| acceptance-affected.log | f9db95a62a0e18b53e765cb246ef58421e4b0844028c5eae1a759acc05782ae3 | 01:15 +94: All tests passed!                                                                                                                                                                            |
| acceptance-analyze-final.log | 974c9013889536b70cd2832ba4db69f565f0c1822c972b2fd430fffe6965995b | No issues found! (ran in 7.7s) |
| acceptance-analyze.log | 7f3c25e3ed19a2d64faf69c98e3ebee1db80b9a3e32fd7758111735640d694bf | No issues found! (ran in 11.1s) |
| acceptance-boundary.log | 6c123bee4a897a72e41436920a134a05cc3f6cd511c31d2c76e30d26df647987 | 00:09 +16: All tests passed!                                                                                                                                                                            |
| acceptance-full-final.log | 95ced434e372ef33e8794e89cf090256409efb71a535d225903670dd2f4a6cb4 | 02:24 +2984: All tests passed!                                                                                                                                                                          |
| acceptance-full.log | ed4b5b9b657c82f73361b59cea486df9d50911d85911c84ba0402968ad5ebea9 | 02:42 +2983 -1: Some tests failed.                                                                                                                                                                      |
| acceptance-import-chain.log | bce7b8a37daffbf2576d0e2352896ff218326ed97b2b04e98b36a8574437e9c4 | 00:04 +0 -1: Some tests failed. |
| acceptance-import-final.log | aa7e4750a69ae5a28ba2be871b02afbf14771eb5f902b3c10d8129a4f73798af | 00:01 +1: All tests passed! |
| acceptance-import-next.log | 79b30319263e728ddba4dd0e8c95817f7ec849f04a343d679034ad015dbe262e | 00:04 +0 -1: Some tests failed. |
| acceptance-lifecycle-isolated.log | 6973d3c7c9f60d8e2ffbe995a4514ae3a4b35a88350e36620964e106dfe710ae | 00:08 +8: All tests passed!                                                                                                                                                                             |
| acceptance-pandoc.log | 205199f9c1a1dc1ad0d770d65610610fc8440f4310ad2a9d0eab68485b87c502 | 真实 Pandoc DOCX 转换成功；ZIP/XML 校验通过；非群聊闭环。 |
| acceptance-rebind-state.log | 206211b264ccf20f5b82e80dabc8296f10fecec6e2bfee46f76be7224d62c37b | 00:00 +8: All tests passed! |
| acceptance-ui-build-fixed.log | f6b593c3432587a7c29fbb6c76d52593bcb38b8c5b72e6f64010bd28c51f8090 | ✓ Built build/macos/Build/Products/Debug/P8Acceptance.app |
| acceptance-ui-build.log | 534cf7e54a654378b1e49bfc88e2c1a7861a99f6b179467295d4633bd1316568 | Build process failed |
| acceptance-ui-pub.log | 8378d7597000280db6a15d61de4bc16359a114053b8509965dacd03d13ca3bdb | Try `flutter pub outdated` for more information. |


## 2026-10-02 复审修复与提交前校验

修复明确否定改名被识别为授权、历史窗口误删任务成员加入授权、旧交付签字膨胀模型上下文、旧需求/团队版本的提案签字挤占当前容量。继续复审时补齐缺少答复凭据的决策不得被裁剪放行、人工审查授权保留、当前反对意见与采纳前提案签字保留等边界。

模型输入与权威保存分离：群讨论、执行提示和任务摘要只发送当前门禁需要的签字及最新候选；完整历史仍由任务检查点、公开消息与版本文件保存。签字容量与提示投影共用当前版本筛选，签字同键归档改为线性扫描并保持原顺序。新增 12 个自动回归场景。

范围包括全部未提交改动及相关调用链。按此前用户约定，未调用真实模型、未运行实机交互或真实游戏验收；以下通过只代表开发检查，不代表真实群聊闭环验收。

| 命令 | 结果 | 临时日志 SHA-256 |
| --- | --- | --- |
| `dart run build_runner build --delete-conflicting-outputs` | 成功，93 outputs | `f15117b7ec7d00d8a5562f04b369664ec7a3a377ae7d98152306b60ee94213a2` |
| `flutter analyze --no-pub` | No issues found | `897a20bf8aca3e14929d638fbde0f4bc66d17ca542f01738e80b2a242e37000a` |
| `flutter test --no-pub --timeout 30s --reporter expanded` | 3022 passed | `d6b9a6549fbf24494ae19b49a4db3e9e928b5a326f92df1f0aca8e53c7415245` |
| `flutter test --no-pub --timeout 30s --reporter expanded test/work_mode/work_discussion_v2_test.dart test/work_mode/work_collaboration_state_test.dart` | 62 passed（最终代码） | `6d1d2516f2a5c26842d2a90a28dfd411fa02513cae62d6480d6ed31a6bd44689` |
| `cd gateway && npm test` | 25 passed | `4784e4b2fc03287859ec0c87f6834beba0890d163470cb3cd4f33338cdfab308` |
| `flutter build macos --debug --no-pub` | 成功构建 伴伴.app；未启动实机交互 | `fc4fb058f6e0b878390c14b14342c85b2146643dd298a174fbac740df6bc084f` |
| `git diff --check HEAD` | 通过 | 无输出 |

上述日志路径为 `/tmp/chat-group-fix-*.log`。初次定向检查曾因新增测试 part 指令的位置不合法失败，已移动到 import 后；初次静态检查的两处缺少花括号提示也已修复。最终定向、静态、全量和构建结果如上，未隐藏前序失败。
