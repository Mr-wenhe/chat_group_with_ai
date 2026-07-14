# Conversation Review Checklist

## Evidence pass

- [ ] Record total messages, conversations, groups, direct chats, and time range.
- [ ] Count user and AI messages separately.
- [ ] Count exact duplicate user requests.
- [ ] Group near-duplicates by intent (same file path, same deliverable, same complaint).
- [ ] Capture feedback about waiting, missing output, context loss, style mismatch, and inconsistent facts.
- [ ] Inspect AI repetition separately from user repetition.

## Problem taxonomy

| Category | Typical evidence | Likely diagnostic question |
|---|---|---|
| Routing | User explicitly asks for file/tool work but receives ordinary chat | Did work mode trigger and select an executor? |
| Execution | User repeats the same write request | Was a write tool actually called, or only promised? |
| Visibility | “还没好吗 / 放哪了 / 看不到” | Was path, progress, and completion evidence surfaced? |
| Context | “还记得吗 / 忘记了 / 前后对不上” | Was relevant history retrieved and bounded? |
| Style | “太专业 / AI 味” | Did persona/style policy override the user’s requested tone? |
| Fact/time | Multiple tests of current time or dates | Was a real clock/time tool used, with timezone stated? |
| Generation quality | Same generic opener or topic prompt repeated | Are auto-chat eligibility, deduplication, and topic fit working? |
| Scope drift | Long banter after a concrete task | Did the system return to the requested deliverable? |

## Report rules

- Separate user frustration from product defects; repeated user input is a symptom, not proof of one root cause.
- Prefer counts and representative examples over adjectives such as “很差” or “很卡”.
- Link every finding to a conversation archive file and, when applicable, a source/test file.
- Assign priority by user impact and recurrence: P0 blocked delivery, P1 repeated failure, P2 quality/performance, P3 polish.
- For each recommendation include a measurable exit condition.

## Final verification

- [ ] Re-run the archive script and ensure the message/conversation counts are stable.
- [ ] Parse `archive.json` with `jq` or a Dart decoder.
- [ ] Check every Markdown link in `README.md` points to an existing file.
- [ ] Run `flutter analyze` and relevant tests after code changes.
- [ ] Report excluded data and remaining uncertainty explicitly.
