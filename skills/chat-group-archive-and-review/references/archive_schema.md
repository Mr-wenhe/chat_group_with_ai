# Conversation Archive Schema

## Source

For this repository, the source of truth for dialogue is `data/messages.hive`.
`data/chat_groups.hive` supplies group metadata, and `data/ai_characters.hive`
supplies display-only participant metadata. Direct conversations use
`dm:{characterId}` as the message `groupId`.

Run:

```bash
dart run tool/archive_conversations.dart
```

Use `--data-dir` and `--output-dir` only when inspecting a copied dataset. Use
`--no-redact` only for a controlled, local forensic copy.

## Output

```text
docs/archive/conversations/
├── README.md       # human-readable index and privacy note
├── archive.json    # structured archive, schemaVersion = 1
└── *.md            # one file per group/direct/orphan conversation
```

`archive.json` contains `stats`, `privacy`, and `conversations`. Each
conversation contains `id`, `type`, `name`, `participants`, time bounds, and
messages. Each message contains sender display fields, content, timestamp,
reply/mention fields, and attachment metadata.

## Excluded fields

Never include `apiKey`, `apiProvider`, `modelName`, `apiConfigId`,
`customBaseUrl`, `AICharacter.systemPrompt`, `media.localPath`, or attachment
binary payloads in a review archive. Do not open `api_configs.hive` merely to
resolve display names.

The archive retains message正文 because it is the evidence under review. The
default exporter masks common `api_key=`, `token=`, `Bearer`, `sk-`, `ghp_`,
`github_pat_`, and similar patterns. Treat even the redacted archive as
sensitive because ordinary chat messages may contain personal data.
