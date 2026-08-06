# Stage 11: Global Permanent Memory Audit UI — Design Spec

> Milestone D · Stage 11 · 2026-08-06

## 1. Goal

Replace the conversation-scoped `MemoryManagementPage` with a global `GlobalMemoryAuditPage` that audits all `PermanentMemory` records. Old model data (`CharacterMemory` / `GroupMemory` / `RelationshipState` / `AICharacter.memorySummary`) moves to a read-only "Migration Diagnostic" collapsible at the bottom.

## 2. Data Boundary

- **Page reads all `PermanentMemory` from `db.permanentMemoryBox`.**
- `conversationId` is an initial filter only; it never restricts data visibility.
- Memory ownership is determined by `observerCharacterId`, not by conversation.
- `subjectIds` empty = self-growth memory.
- Status filtering: only `active` records enter the Prompt; `superseded` and `invalidated` are audit-only.

## 3. Entry Points

| Entry | Route | Initial Filter |
|-------|-------|----------------|
| Chat room AppBar memory button | `MemoryManagementPage(conversationId: widget.groupId)` | `originConversationId` = `widget.groupId` |
| Settings page | `MemoryManagementPage()` | None (show all) |

Both open the same `GlobalMemoryAuditPage` widget. The page name `MemoryManagementPage` is kept to minimize churn in `ChatRoomPage` call sites, but the widget is conceptually the global audit page.

## 4. Filter Model (`MemoryAuditFilter`)

New file: `lib/features/memory/memory_audit_filter.dart`

```dart
class MemoryAuditFilter {
  final String? observerCharacterId;
  final SubjectFilter subjectFilter;
  final MemoryOriginType? originType;
  final String? originConversationId;
  final MemoryStatus? status;
  final MemoryKind? memoryKind;
  final bool? pinnedOnly; // null = all, true = pinned only, false = unpinned only

  MemoryAuditFilter({
    this.observerCharacterId,
    this.subjectFilter = SubjectFilter.all,
    this.originType,
    this.originConversationId,
    this.status,
    this.memoryKind,
    this.pinnedOnly,
  });

  MemoryAuditFilter copyWith({...});

  bool get isEmpty => [...]
}
```

`SubjectFilter` enum: `all`, `aboutMe(user)`, `aboutCharacter(String characterId)`, `selfGrowth(empty subjects)`.

Filtering logic is a pure function applied to the full memory list; it never mutates or restricts the underlying data.

## 5. List Display

Each memory card shows:

| Field | Display |
|-------|---------|
| Observer name | From `AICharacter` box; deleted = 「已删除角色」 |
| MemoryKind | Chip label: 知/偏好/承诺/经历/关系/成长/指令 |
| Content | Full text |
| Subject names | 「我」 for user, character name for AI IDs, 「已删除角色」 for missing |
| Status | Badge: active/superseded/invalidated |
| Importance | Numeric 0-100 |
| Confidence | Decimal 0-1 |
| Explicitly requested | Icon indicator |
| Pinned | Pin icon |
| Occurred at | `yyyy-MM-dd HH:mm` |
| Origin type | group/direct/manual/legacyMigration |
| Origin name | `originNameSnapshot` |
| Source messages | 「N 条证据」 or 「无原始消息」 |
| Supersedes | List of replaced IDs |
| Superseded by | Computed by scanning all active records' `supersedesIds` |

### Source Traceability

- `sourceMessageIds` non-empty + message exists in `messageBox`: show 「查看原消息」 button that calls `loadMessagesAround` and navigates to chat room with highlight.
- `sourceMessageIds` non-empty + message missing: button disabled, tooltip 「原消息已不可用」, show `originNameSnapshot`.
- `legacyMigration` + `sourceMessageIds` empty: show badge 「旧版迁移记录，无原始消息证据」, never fabricate message IDs.

## 6. Manual Correction (Edit)

Editing a memory never overwrites the original content in place. Instead:

1. Create new `PermanentMemory`:
   - `observerCharacterId` = original's
   - `kind` = original's
   - `subjectIds` = original's (editable)
   - `originType` = `manual`
   - `confidence` = `1.0`
   - `sourceMessageIds` = `[]`
   - `supersedesIds` = `[original.id]`
   - `status` = `active`
   - `pinned` = `false` (default)
   - `content` = user's corrected text
2. Set original's `status` = `superseded`.
3. If original was pinned: show confirmation dialog warning that the pinned record will be superseded.
4. **Idempotency**: before creating, check if an active record already exists with same `observerCharacterId` + `kind` + `content` + `subjectIds`. If so, skip creation.

## 7. Delete Semantics

- Physical delete: `db.permanentMemoryBox.delete(memory.id)`.
- Confirmation dialog includes warning: 「删除不会自动恢复旧版本」.
- After delete, list refreshes immediately.
- `MemoryContextSelector` naturally stops injecting the content on next `select()` call (it only reads `active` + non-superseded records).
- Deleting an active corrected version does NOT resurrect its superseded parent.

## 8. Pin Semantics

- Directly set `memory.pinned = true/false` and save to box.
- Pinned records are excluded from `MemoryConflictResolver` supersede/invalidate actions (existing logic).
- Unpinning restores eligibility for automatic updates.

## 9. Migration Diagnostic Area

Collapsible section at the bottom, read-only:

- Observer's `AICharacter.memorySummary` (if non-empty)
- Observer's `CharacterMemory` records grouped by `groupId`
- Explanatory text: 「以下为旧版数据，仅供诊断，不会注入 Prompt」

These never mix with the `PermanentMemory` list and are never re-injected into prompts.

## 10. File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/features/memory/memory_management_page.dart` | Rewrite | Upgrade to `GlobalMemoryAuditPage` reading `PermanentMemory` |
| `lib/features/memory/memory_controls.dart` | Extend | Add permanent memory edit/create/supersede/delete/pin methods |
| `lib/features/memory/memory_audit_filter.dart` | Create | Filter model + filter widget |
| `lib/features/settings/settings_page.dart` | Modify | Add 「永久记忆审计」 entry under data management |
| `lib/features/chat_group/chat_room_page.dart` | Modify | Pass `originConversationId` through `_openMemoryManagement` |
| `test/memory_management_page_test.dart` | Rewrite | Cover filters, correction, deletion, pinning, source traceability, boundaries |
| `test/memory_controls_test.dart` | Extend | Add permanent memory operation tests |

## 11. Test Plan

### 11.1 Global Boundary
- Open audit page from Group A, clear origin filter, verify Group B/DM memories for same observer are visible.
- Verify A's memories and B's memories are separated by `observerCharacterId`.

### 11.2 Filters
- Observer, subject, origin type, status, kind, pinned status can be combined.
- Clear filters restores all.
- Deleted character/group names display correctly without crashing.

### 11.3 Correction
- New record: `manual`/`active`/`confidence` 1.0.
- New record's `supersedesIds` contains old ID.
- Old record becomes `superseded`.
- `MemoryContextSelector` outputs new content only once.
- Repeated save does not duplicate.

### 11.4 Deletion
- Physical delete removes from box.
- `MemoryContextSelector` stops injecting immediately.
- Does not resurrect superseded parent.
- Does not delete other records in the correction chain.

### 11.5 Pinning
- `pinned` field persists.
- Automatic conflict resolution skips pinned records.
- Unpinning restores auto-update eligibility.

### 11.6 Source Traceability
- Existing messages: 「查看原消息」 navigates and highlights.
- Missing messages: shows snapshot, disabled button.
- Legacy records: shows badge, never fabricates `sourceMessageIds`.

## 12. Verification

```
flutter test test/memory_management_page_test.dart
flutter test test/memory_controls_test.dart
flutter test test/memory_context_selector_test.dart
flutter analyze
flutter test
```
