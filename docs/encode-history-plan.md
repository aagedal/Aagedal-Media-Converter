# Encode History & Last-Session Restore — Implementation Plan

Status: phases 1–4 implemented (store, tracking, last-session snapshot, overlays, History settings tab, per-item preset override, monthly rollups + Statistics settings tab, tolerant/versioned decoding). Cloud sync deferred.

## Goals

- The queue stays disposable: nothing is restored automatically on launch.
- **Last session**: unfinished queue items from the previous run are offered once
  for restore (separate icon + overlay). Covers accidental quit and crashes.
- **Encode history (archive)**: every started encode leaves a record (no media),
  browsable by session, re-queueable with its per-item settings.
- **Statistics**: a Settings tab computed from history + long-lived monthly rollups.
- User control: history on/off, retention (default 90 days), clear.

## Key decisions

| Topic | Decision |
|---|---|
| Storage | Plain JSON in `~/Library/Application Support/AagedalMediaConverter/History/`, atomic writes. No SwiftData. |
| Cloud sync | Deferred. Later: per-device files in the CloudDocs folder, merged on read (no conflicts). Record carries `deviceName` from day one. |
| What triggers a record | A row entering `.converting` (start) and leaving it for `.done/.failed/.cancelled` or being removed (finish). |
| Where it is observed | A status diff in `ContentView` on `droppedFiles` / `encodingGroups` changes. Catches **both** engines (`ConversionManager` and `ApplicationJobService` projected rows) without touching either. |
| Crash/interrupt detection | Records written as `running` at start. On launch, leftover `running` → `interrupted`. Sessions carry `endedCleanly`; an open session at launch = unexpected exit. |
| Restoring a different preset | v1: restored items whose preset ≠ current preset go into an encoding group named after the preset. Phase 3 adds a per-item preset override and drops the group workaround. |
| Missing source files | Path → stored bookmark → "missing" with **Locate…**. Relinking one file auto-relinks siblings found in the same new folder. |
| Scope v1 | Single-file encodes, including grouped items. Merge/concat items are recorded per input (marked `merged`), DCP/IMF/image-sequence recorded but their extra metadata is not restored yet. Downloads not recorded until encoded. |

## Data model (`Logic/History/EncodeHistoryModels.swift`)

```
EncodeHistoryFile { version, sessions: [HistorySession], records: [EncodeRecord], rollups: [MonthlyRollup] }
HistorySession  { id, startedAt, endedAt?, endedCleanly, deviceName, appVersion }
EncodeRecord    { id, sessionID, startedAt, finishedAt?, outcome, errorMessage?,
                  source: SourceSnapshot, recipe: EncodeRecipe,
                  presetRawValue, presetDisplayName, groupName?, merged,
                  outputPath?, outputSizeBytes?, kind }
outcome         running | completed | failed | cancelled | interrupted
SourceSnapshot  { path, bookmark?, sizeBytes, durationSeconds, container, videoCodec,
                  width, height, frameRate, audioCodec, audioChannels }
EncodeRecipe    { trimStart/End, crop, audioRouting, timecode, isMuted, comment,
                  metadataEditorSettings, includeDateTag, outputFileNameOverride,
                  recursiveEncodingGenerations, uploadEnabled, uploadSourceFile,
                  subtitleEnabled, analyticsEnabled, selectedAudioStreamIndex,
                  waveformBackgroundImagePath }
```

`EncodeRecipe` is shared by the last-session snapshot, which adds group structure:

```
LastSessionSnapshot { savedAt, presetRawValue, items: [SnapshotItem], groups: [SnapshotGroup] }
SnapshotItem  { sourcePath, bookmark?, recipe, status }
SnapshotGroup { name, presetRawValue?, concat/upload/transcription/analytics/sequentialNaming flags, items }
```

## Phases

### Phase 1 — Store, tracking, last-session snapshot
1. `EncodeHistoryModels.swift` — Codable models above, `EncodeRecipe(item:)` and `apply(to:)`.
2. `EncodeHistoryStore.swift` — `@MainActor @Observable` store: load/prune on launch,
   mark interrupted/unexpected exits, open a session, append/update records,
   coalesced background writes, synchronous `flush()` at quit. Settings keys:
   `encodeHistoryEnabled` (true), `encodeHistoryRetentionDays` (90, 0 = forever).
3. `EncodeHistoryTracker.swift` — pure diff `(previous statuses, rows) → [start/finish events]`; unit tested.
4. `LastSessionStore.swift` — snapshot unfinished rows (debounced on queue changes, fingerprinted so
   progress ticks don't write; flushed at quit). On launch the previous snapshot becomes the pending restore.
5. Hooks: `ContentView` `onChange(droppedFiles/encodingGroups)` → tracker + snapshot;
   `AppDelegate.applicationShouldTerminate` → flush both stores (+ end session cleanly).
6. Quit confirmation while encoding (setting, default on).

### Phase 2 — UI
1. Bottom-leading corner buttons on the queue: history (always), last session (only when pending, tinted).
2. `LastSessionOverlay` — checklist, missing-file state + Locate…, Restore selected / Discard.
3. `EncodeHistoryOverlay` — sessions grouped ("Today 14:02 · 6 encodes"), search, expandable
   details (source facts, preset, recipe summary, output, error), actions: Re-queue, Re-queue
   session, Reveal output, Remove.
4. Restore path: `ContentView.restoreQueueItems(_:)` — placeholder → apply recipe → load details,
   dedupe against URLs already in the queue, preset-group workaround.
5. Settings → **History** tab: enable, retention picker, last-session restore toggle, quit confirmation, clear.

### Phase 3 — Per-item preset override
Small button + popover on the cell; `VideoItem.presetOverride`; ContentView batches ungrouped
items by effective preset; shared-job bridge respects it. Restore uses it instead of groups.

Implemented rules:
- Only ungrouped rows have an override; grouped rows follow the group preset picker (button hidden).
- Merge ignores overrides (one shared preset); the button is disabled while merging.
- Picking the queue preset clears the override. Reset with "clear settings" clears it too.
- `startConversion` splits each ungrouped batch into consecutive same-preset runs, each going
  through the shared job service or the legacy path with its own preset.
- `EncodeRecipe.presetOverrideRawValue` keeps overrides in the last-session snapshot; history
  re-queue sets the recorded preset as the override (empty queue adopts the most common preset).

### Phase 4 — Statistics
Monthly rollups folded in before pruning (counts by outcome/preset/codec/container/resolution,
seconds encoded, bytes in/out). Settings → **Statistics** tab with Swift Charts:
counts for 7d / 30d / 90d / 1y / all, encodes over time, top codecs/containers/resolutions/presets,
failed / cancelled / interrupted / unexpected exits, speed vs realtime, bytes saved.

Implemented rules:
- `MonthlyRollup` (in `EncodeHistoryFile.rollups`, file version 2) is keyed by `yyyy-MM` + device and holds
  counts by outcome / preset display name / video codec / container (file extension, else first ffprobe
  format name) / resolution bucket (short edge), media seconds encoded (trimmed length), wall-clock encode
  seconds, paired media/wall seconds for speed, paired bytes in/out, sessions and unexpected exits.
- `prune` folds expiring records and sessions into rollups in the same step (and the same write) that
  deletes them, so statistics = rollups + live records with nothing counted twice. Retention 0 never prunes.
  Removing single records from the history does not fold them.
- Clear History also clears rollups and past sessions (statistics reset).
- Aggregation is pure (`EncodeStatistics`, unit-tested). A rollup month counts toward a period only when the
  whole month is inside it, so 7d/30d (and usually 90d) come from live records only. "1 Year" = current
  month + 11 before it. Bars are daily for 7d/30d/90d, monthly for 1y/All.
- The "N encodes didn't finish" notice in the history overlay surfaces `interruptedAtLaunchCount` until dismissed.

### Robust decoding
- Arrays (sessions, records, rollups, snapshot items/groups) decode element by element; a bad element is
  dropped and the original file is copied to `encode-history.corrupt-<ts>.json` before it is rewritten.
- Records, recipes, source facts, sessions, snapshot items/groups decode non-essential fields with
  defaults; embedded `CropConfig` / `MetadataEditorSettings` / `AudioRoutingConfig` fall back to nil.
- A file with a newer `version` is loaded as far as possible and copied to `…v<N>-<ts>.json` first.
- Last-session items persist a raw `status` (localized at display) plus a source bookmark; snapshots
  from before that keep showing their stored `statusLabel`.

### Later
Cloud sync (per-device files), merge/stitch as one record with multiple inputs, DCP/IMF/image-sequence
metadata restore, yt-dlp source URLs.
