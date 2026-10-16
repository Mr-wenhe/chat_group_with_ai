# 授权码（API 配置包）格式

用一串授权码一次性配置**聊天 / 语音 / 图像 / 搜索**四类服务的 API Key。App 里对应两个入口：**导入 API KEY** 与 **导出 API KEY**，两者共用本文描述的格式。

## 先说清楚它保护什么、不保护什么

**保护**：密钥不会以明文形式出现在配置包、聊天记录、截图或仓库里；随手转发的一串码不能被直接读懂。

**不保护**：解密口令是**编译进 App 的常量**。任何拿到 App 二进制的人都能把授权码解回明文密钥。

这是刻意取舍——用一个内置口令换「用户只需粘贴一串、不必额外记密码」的零摩擦分发。要真正的保密，必须让口令不随二进制分发（`--dart-define=BUNDLE_KEY_SECRET=...` 构建一份只给特定人用的 App，并让生成端用同一个口令）。

**因此请像对待密钥本身一样对待授权码**：不要发到公开渠道，不要提交进 git。

---

## 线格式

```
BBK1.<base64url_nopad( salt(16) || nonce(16) || ciphertext || mac(16) )>
```

- 解析前剥掉全部空白与换行，因此可以按 4/8 字符折行分发，也可以整段粘贴。
- `BBK1` 管**字节排布**，载荷里的 `"v"` 管 **JSON schema**。两者是独立闸门，任一不认识即整包拒绝，不做「尽力解析」。
- 每次生成都会换新的 salt 与 nonce，因此同一份配置每次得到的授权码都不同。

### 加密构造

用仓库已有的 `crypto` 包实现，未引入新的密码学依赖：

```
kEnc = HMAC-SHA256(secret, "bbk/enc" || salt)
kMac = HMAC-SHA256(secret, "bbk/mac" || salt)
keystream_i = HMAC-SHA256(kEnc, nonce || be32(i))
ciphertext  = plaintext XOR keystream
mac = HMAC-SHA256(kMac, "BBK1" || salt || nonce || ciphertext)[0..16]
```

即「HMAC 作伪随机函数的 CTR 密钥流」+「encrypt-then-MAC」。**先验 MAC（常量时间比较）再解密**：未经认证的密文一个字节都不会被解开。

实现见 `lib/core/bundle/api_bundle_codec.dart`。它**不 import Flutter**，App 与生成脚本共用同一份，避免两套实现漂移（漂移的表现是「生成的码自己解不开」，只能靠人肉比对密钥串才能发现）。

---

## 明文配置包

四段全部可选，缺哪段就不动哪类服务。

```jsonc
{
  "v": 1,
  "label": "内部分发包",            // 可选，预览标题
  "issuedAt": "2026-10-15T08:00:00Z", // 可选，仅展示

  "chat": [{
    "id": "cfg-a1b2",              // 可选；给了就按 id 覆盖，不给则按「服务商+模型+Base URL」匹配
    "name": "主力对话",             // 可选，默认回落服务商名
    "provider": "deepseek",         // 必填，ApiProvider 之一
    "modelName": "deepseek-chat",   // 可选，默认用该服务商的默认模型
    "customBaseUrl": "",            // provider 为 custom 时必填
    "apiProtocol": "openAiChatCompletions", // 可选，ApiProtocol 之一
    "apiKey": "sk-…",               // 必填
    "makeDefault": true             // 可选，设为默认聊天配置
  }],

  "voice": {
    "apiKey": "…",                                  // 必填
    "ttsResourceId": "seed-tts-1.0",                // 可选
    "asrResourceId": "volc.bigasr.sauc.duration",   // 可选
    "defaultVoiceId": "…"                           // 可选，未知音色会被忽略
  },

  "image": {
    "apiKey": "…",                       // 必填
    "baseUrl": "https://open.bigmodel.cn/api/paas/v4", // 必填
    "model": "glm-image",                // 必填
    "size": "1280x1280",                 // 可选
    "quality": "",                       // 可选，空串表示不发送该字段
    "disableWatermark": false            // 可选
  },

  "search": [{
    "id": "tavily-main",                 // 必填，需通过 id 规范化校验
    "name": "Tavily",                    // 必填
    "provider": "tavily",                // 必填，SearchProviderKind 之一
    "baseUrl": "https://api.tavily.com", // 固定端点的 provider 可省略
    "apiKey": "tvly-…",                  // 该 provider 需要凭据时必填
    "enabled": true,                     // 可选
    "isDefault": true                    // 可选
  }],

  // 智谱原生 Web Search 的凭据。与上面 `search` 里的条目是**两套不同的东西**：
  // 那条是「独立搜索 Provider」（Tavily / Brave / Gateway…），走
  // `SearchProviderConfigStore`；这条由 `ZhipuNativeSearchCredentialStore` 单独
  // 持有，在设置页也是另外一张卡片。两者都可以只配其中一个。
  "zhipuNativeSearch": {
    "apiKey": "…"                        // 必填
  }
}
```

**未知字段一律忽略**（前向兼容）。**缺必填 / 超长 / 类型不对**的条目会进入预览页的「跳过」行并给出原因，不阻断同段其余条目——一条坏的搜索配置不该挡住另外三类服务。

注意区分两类拒绝：

| 级别 | 判据 | 表现 |
|---|---|---|
| 整包拒绝 | 信封损坏、MAC 不匹配、载荷不是对象、`v` 不认识 | 报错，不进入预览 |
| 条目跳过 | 缺字段、超长、枚举值未知、端点不合法、匹配歧义 | 进预览的「跳过」行，带原因 |

---

## 生成

```bash
dart run scripts/generate_api_bundle.dart --in payload.json
dart run scripts/generate_api_bundle.dart --in payload.json --out bundle.txt
dart run scripts/generate_api_bundle.dart --in payload.json --secret '自定义口令'
dart run scripts/generate_api_bundle.dart --decode bundle.txt   # 回环校验
```

口令来源优先级：`--secret` → 环境变量 `BUNDLE_KEY_SECRET` → App 内置口令。

App 侧用 `--dart-define=BUNDLE_KEY_SECRET=...` 覆盖（变量名相同，但机制不同：脚本读环境变量，App 读编译期常量）。**自定义口令必须两端一致**，否则 App 解不开。

脚本**不打印明文密钥**，只打印服务清单、密钥指纹与跳过原因。指纹是 `sha256(密钥)` 的前 8 位十六进制，App 的预览页显示同一套值——可以三方对照（生成端 ←→ 预览 ←→ 手上原值）。

> 枚举取值（`provider` / `apiProtocol` / 搜索 `provider`）由 App 侧校验，脚本只做 JSON 结构与必需字段检查。脚本会提示服务商名是否在内置列表里，但不会因为不在就拒绝生成——这样你仍然可以在 App 端看到明确的「跳过」原因。

---

## 导入

入口：**开始使用 → 创建 API 配置**（直接进「API KEY 设置」页），顶部「批量配置」分组；也可从 **设置 → API KEY 设置 → 批量配置** 进入。两条路到的是同一页。

刻意**不做**启动时的自动弹窗：一个没配任何东西的用户，第一眼看到的是一个他不知道该拿什么来填的输入框；而从「创建 API 配置」进来的人，手上正好有那串码。

导入流程是**先预览再确认**：解析后列出「将新增 X 条、覆盖 Y 条、跳过 Z 条」以及每条的详情与密钥指纹，用户点确认才写入。

预览**绝不读取安全存储里的旧密钥做比较**，也**绝不显示密钥的任何字符**（打码尾部也不行——那仍泄露长度与结尾字符）。

---

## 导出

**设置 → API KEY 设置 → 批量配置 → 导出 API KEY**，点「生成 API KEY」即可把本机已配好的四类服务打成一串授权码，在其它客户端用「导入 API KEY」贴上就完成配置。

粒度：

- **聊天**：导出**全部已绑定密钥**的配置（不只是默认那条），并带上各自的 `id`，因此在同一台机器上导入时按 id 精确覆盖，而在别的机器上则按原样重建。
- **语音 / 图像**：各自最多一条（它们本来就是全局单配置）。
- **搜索**：两类凭据都会导出——`search` 段里只导出**带令牌**的独立提供方（无令牌的那几个 DuckDuckGo / 内置没有可分享的秘密，塞进包里只是噪声），另外**单独**导出「智谱原生 Web Search」（`zhipuNativeSearch` 段）。这两条是并行的，只配了其中一个也能正常导出；早先只覆盖前者，把搜索配成智谱原生的用户会导出一个不含任何搜索凭据的包。
- **默认聊天配置**的指向会跟着走（写进 `makeDefault`）。

导出侧在交付前会**自己先解析一遍**生成的载荷（`ApiBundle.parse`）。生成一份导入侧不肯接受的配置包，用户要等拿到另一台机器上才发现「校验失败」，而那时已经无从回查是哪一项写坏了。

导出页不显示明文，只给清单与密钥指纹——和生成工具、导入预览显示的是同一套值，可以三方对照。

**未能导出的项会单独列出并说明原因**（通常是密钥读不出来），不静默跳过。用户以为导全了、实际少一条，等对方发现某个功能用不了时，已经分不清是导出漏了还是对方配错了。

---

## 落点（重要）

导入不新造任何凭据通道，四类服务各自复用既有的绑定路径：

| 服务 | 元数据 | 密钥 |
|---|---|---|
| 聊天 | Hive `api_configs`（`ApiConfig`） | `CredentialRepository`，id = `credential.api-config.{configId}` |
| 语音 | `app_settings` 的 `volc_voice_service` 单 Map | `credential.api-config.voice.volcengine` |
| 图像 | `app_settings` 的 `image_generation_service` 单 Map | `credential.api-config.image.openai-compatible` |
| 搜索（独立 Provider） | `app_settings` 的 `web_search_provider_configs_v1` | `credential.web-search.{id}`（独立命名空间） |
| 搜索（智谱原生） | `app_settings` 的 `zhipu_native_search_credential_v1` | `credential.web-search.zhipu-native-search` |

元数据里只有 `apiKeyBound` / `hasCredential` 这类布尔位，**明文密钥绝不进 `app_settings`**——那个 box 受 git 跟踪。

平台差异沿用既有设计，不由本特性决定：macOS 的凭据落本地 Hive（`DebugCredentialCache.isPrimaryStore`），其余平台走系统安全存储（非 release 叠一层调试镜像）。**Web 端整体拒绝导入**：浏览器没有可供凭据安全落地的边界。

---

## 已知边界

- **非 release 下不能声称「绝无明文」**：凭据写不进安全存储时，既有实现会把明文留在该记录自己的 Hive 字段里（这是既有行为，不是导入功能引入的）。导入结果里对这种情况有单独的文案说明。
- **不做整体回滚**：导入按条进行，已写好的条目不会因为后面某条失败而撤销。做不到回滚不是偷懒——已写入安全存储的密钥无法「撤销写入」，唯一等效的动作是删掉它，而那会顺手删掉用户原本可用的旧 Key，把「导入失败」升级成「原来能用现在不能用了」。
- **覆盖聊天配置时沿用原 id**：`AICharacter.apiConfigId` 指着它，换 id 会造出「角色指向一个不存在的配置」。
- **匹配到多条现有配置时跳过而不是猜**：猜错的代价是改掉用户另一套配置，而用户看不出来是被谁改的。请给配置包里的条目写上 `id`。
