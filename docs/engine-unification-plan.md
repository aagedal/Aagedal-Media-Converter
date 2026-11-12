# Conversion Engine Unification — Plan

Status: proposal, 2026-11-12. Nothing in this plan has been implemented yet.

The app has two conversion engines. `ConversionManager` is the original queue engine.
`ApplicationJobService` (with `ApplicationFFmpegJobExecutor`) is the durable job service built
for 4.5 for Shortcuts and local agent (MCP) access, and since then also used for manual work it
can represent. Both call the same `FFMPEGConverter`. This plan moves all work onto the job service
in phases, so that each feature is implemented once.

## How work is routed today

| Entry point | Route |
|---|---|
| Manual Start / row encode / group encode (`ContentView.startConversion`, `encodeOnlyItem`, `submitApplicationGroupIfSupported`) | `ManualApplicationJobBridge.makeRequest` → `ApplicationJobService.planAndSubmit` when the rows are representable; otherwise `ConversionManager.startConversion` / `convertGroup`. |
| Shortcuts "Convert immediately" (`ContentViewNotificationHandlers`) | `AppIntentApplicationJobBridge.makeRequest` (6 presets: `usesExistingManualSharedBridge`) → service; other presets import rows and run `startConversion`, i.e. either engine as above. |
| Local agent / MCP (`ApplicationAgentTools`) | Service only. |
| Watch folder, history re-queue, last-session restore | Import rows, then the manual path. |

Shared between both engines already:

- `FFMPEGConverter` (one instance per engine) and everything under it.
- `ApplicationConversionExecutionGate.shared`, a FIFO gate. `ConversionManager.shared` holds it for
  a whole batch or group; the service holds it per job. The engines never encode at the same time.
- The queue UI. `ConversionManager` writes `VideoItem` rows directly through a `Binding`. Service
  records are projected into rows by `ContentView.synchronizeApplicationJobs` / `applyApplicationJob`,
  which set `applicationJobID`, `applicationJobSourceIndex`, `applicationJobOrigin` and status.
- Observers of rows: `EncodeHistoryTracker` / `LastSessionStore` (see `encode-history-plan.md`) and
  `ApplicationVisibleQueueRegistry` (lists legacy rows to agents as non-durable `manual_*` jobs).

## What is duplicated

| Concern | `ConversionManager` | Job service |
|---|---|---|
| Settings capture | `ConversionPreparationSettings` read from `UserDefaults` at item start (`preparationSettingsProvider`). | `ApplicationPresetSettings` snapshot at request time, replayed through a private `UserDefaults` suite (`ApplicationExecutionDefaults`). |
| Building the `ConversionRequest` | `convertNextFile` (~25 fields, plus `exportsMatteSidecar`, ETA and output-resolution callbacks). | `ApplicationFFmpegJobExecutor.makeConversion` (~13 fields). |
| Output naming and destination | `outputBaseName` + `OutputDestinationSettings.resolveFolder`; `FFMPEGConverter` reserves a unique sibling if the name is taken. | `ApplicationJobService.plannedOutputs` computes exact names at plan time, reserves them, and rejects existing outputs. |
| Ordering | `conversionQueue`, batch IDs, recursive `convertNextFile`. | `pendingExecutions` + `drainExecutionQueue`. |
| Cancellation | `cancelConversion`, `cancelItem`, `cancelAllConversions`, plus merge-preparation and subtitle cancellation. | `requestCancellation` → `ApplicationJobExecutor.cancel`. `ContentView` calls both paths. |
| Progress | Row mutation throttled to ~4 Hz, ETA callbacks, `AsyncStream<Double>` for the dock. | `ApplicationJobProgressReporter` → registry → `recordUpdates()` → projection into rows. |
| File access | `ensureInputFileAccessible` / `ensureDirectoryAccessible` with bookmark fallback. | `ApplicationFileAccessAuthorizer` leases from stored bookmarks; the bridge persists grants first. |
| Status model | `ConversionManager.ConversionStatus` on `VideoItem`. | `ApplicationJobState`; mapped to row status in `ContentView` and back again in `ApplicationVisibleQueueRegistry.summary`. |
| Persistence and recovery | None; rows are in memory, `LastSessionStore` snapshots them. | `ApplicationJobStore` (versioned JSON); restart marks in-flight jobs `interrupted`. |

There are about 45 references to `applicationJobID` (`ContentView` 18, the queue table and cells 14,
`ConversionQueueState` 7, others). Most of them pick one engine or the other, and each is a place
where the two can diverge.

## What only `ConversionManager` can do

`ManualApplicationJobBridge` (`AppIntents/AppIntentHandoff.swift`) sends rows to the legacy engine
when any of these apply:

- Merge, stitch markers or conformance merge (`mergeClipsEnabled`, group `concatEnabled` /
  `conformanceMergeEnabled`).
- Recursive generations, image-sequence input, generated waveform or synthesized video.
- Presets DCP, IMF (both) and image sequence (`supportsManualSharedExecution == false`), whose
  package metadata (`resolveDCPMetadata` / `resolveIMFMetadata`) is not captured.
- Post-conversion subtitles, upload or quality analytics (per row or per group).
- An existing output file (the legacy engine writes a unique sibling; the service rejects it).
- Custom name templates whose counters don't match a fresh sequence, and duplicate sources.

## Drift found during this investigation

The bridge decides what the service can represent, and nothing checks that list against
`convertNextFile`. Features added since 4.5 went into `ConversionManager` only, so some rows
that the bridge accepts lose settings. Found by reading the code; not yet reproduced in the app:

1. **Per-item adjustments** (rotation, flips, speed, fades, audio offset, extra audio, burned-in
   subtitles; commit 534292a5). `isRepresentable` doesn't check `item.adjustments`,
   `ApplicationSourceExecutionSettings` has no field for them, and `makeConversion` never sets
   `ConversionRequest.adjustments`. An ungrouped H.264 row with a rotation is encoded unrotated.
2. **Global loudness normalization** (`ConversionPreparationSettings.loudness`). It isn't captured
   in `ApplicationPresetSettings`, so the shared path never runs the measurement pass.
3. **Matte sidecar** (`ExportPreset.exportsMatteSidecar()`). It's set only in `convertNextFile`, so the
   preference is ignored for shared jobs.
4. To verify: `sourceMetadata` / `sourceCameraMetadata` are not passed by the service, so
   `FFMPEGConverter` probes again or goes without camera metadata.

These are the strongest argument for unifying: any feature added to one engine is silently
missing from the other.

## Target

One job service owns the whole lifecycle for every origin: accept → plan (names, destinations,
reservations) → execute (single file, multi-input, package) → follow-ups (subtitles, upload,
analytics) → persist. The queue UI is a projection of job records. `ConversionManager`'s
pipeline code (merge preparation, subtitle generation and so on, now in its
`ConversionManager+*.swift` extension files) moves behind the executor, and the legacy batch queue
is deleted.

## Phases

Each phase is shippable on its own and leaves both engines working.

### Phase 0 — Close the drift (behaviour fix, prerequisite)

Make `ManualApplicationJobBridge.isRepresentable` return false for rows with explicit
adjustments (`MediaAdjustments.hasVideoAdjustments` / `hasAudioAdjustments`, or loudness set on
the item), when global loudness normalization is enabled, and when the matte sidecar is enabled
for the preset. Those rows go back to `ConversionManager`,
which already supports them.

- Tests: extend `AppIntentHandoffTests.testManualBridgeFallsBackWhenBehaviorCannotBeRepresented`
  with one case per setting. Add one live test (an encoded output with a rotation applied) to the
  existing live shared-job tests in `ApplicationJobContractTests`.
- Risk: low. More work runs on the legacy engine until phase 2.

### Phase 1 — One request builder and a parity test

Extract a pure `ConversionRequestFactory` that turns (row recipe, resolved settings, output URL)
into a `ConversionRequest` plus the settings that `FFMPEGConverter.convert` takes. Both
`convertNextFile` and `ApplicationFFmpegJobExecutor.makeConversion` call it, so they can no longer
diverge on fields.

- Tests: a parity test that builds the request both ways from the same row and `UserDefaults`
  for every preset with `supportsManualSharedExecution` and checks that the results are equal
  (compare a projection that leaves out the closures). This test would have caught every item in
  the drift list. Keep `testFFmpegAdapterBuildsExecutableSettingsForAllSupportedPresets` and
  `testFFmpegAdapterExecutesCapturedSettingsAfterDefaultsChange` green.
- Risk: medium. `convertNextFile` is hot code with many callbacks. Move the field mapping only,
  not the callbacks.

### Phase 2 — Widen the request contract

Add optional fields to `ApplicationSourceExecutionSettings` / `ApplicationPresetSettings` for
adjustments, loudness, matte sidecar, source metadata, DCP/IMF package metadata, image-sequence
input, recursive generations and generated video. Remove the matching `isRepresentable` conditions
one at a time.

- For each field: decode old snapshots without it (the existing optional-field pattern,
  `testRequestDecodesSnapshotsCreatedBeforeCounterCapture`), validate it in
  `ApplicationJobRegistry.validate`, show it in `acceptedSettingsSummary` with localization (the
  `nb` catalog check in `ci-local.sh`), and add a live encode test.
- Decide per field whether agents may set it. MCP tool schemas and `supportedOverrides` stay
  unchanged unless that is a deliberate product decision.
- Risk: medium. Persisted records are restored at launch. A file that doesn't decode blocks
  mutation by design (`testDamagedPersistenceBlocksMutationAndIsNotOverwritten`), and a request
  that no longer validates is dropped (`testEntryThatNoLongerValidatesIsDroppedInsteadOfBlockingNewWork`).
  Every new field must be optional, decode-tolerant, and must not invalidate older requests.

### Phase 3 — Collision-safe naming in the planner

For `origin == .manual`, plan a unique sibling name instead of rejecting an existing output.
Agents and Shortcuts keep exact-output semantics.

- Tests: `testManualRepeatExportKeepsCollisionSafeLegacyNaming` moves to the service path; keep
  the reservation tests (`testConcurrentSubmissionsReserveAnOutputForOnlyOneJob`,
  case-variant and alias tests) green.

### Phase 4 — Follow-ups as job stages

Run subtitle generation and embedding, upload and analytics as stages of a job, and record their
state on the job record so rows can show it. Keep the current ordering, where an upload waits for
subtitles (`startUploadAfterSubtitles`).

- Tests: move `SubtitleAgentCoexistenceTests`, `UploadLifecycleTests` and the analytics
  coexistence tests in `ConversionQueueStateTests` onto service jobs; add a restart-recovery test
  for a job interrupted during a follow-up.
- Risk: high. Follow-ups have their own cancellation and ownership rules
  (`ConversionCallbackOwnership`, `subtitleEmbeddingAttempts`).

### Phase 5 — Multi-input jobs

Add a job kind with ordered sources for merge, stitch and conformance merge. Its executor reuses
the code now in `ConversionManager+MergePreparation`, `+MergeExecution` and `+ConformanceMerge`.

- Tests: `StitchingTimelineTests`, `NativeMXFMergeTests`, merge compatibility tests in
  `Aagedal_Media_Converter_Tests`, and the live merged-group tests in `ApplicationJobContractTests`
  (which today check legacy merges against waiting agent jobs) rewritten for service merges.
- Risk: high. Temporary segments, stream-copy end cuts and MXF index fixes must keep their cleanup
  and cancellation behaviour.

### Phase 6 — Groups become jobs

An `EncodingGroup` submits one job with its own preset and flags. Remove
`ConversionManager.convertGroup` and the sequential-naming copy in `ContentView`.

### Phase 7 — Remove the legacy queue

Delete `ConversionManager`'s batch state and `startConversion`, the legacy halves of
`ConversionQueueState`, the second cancellation path in `ContentView`, the `applicationJobID == nil`
branches, and the legacy summaries in `ApplicationVisibleQueueRegistry`. `EncodeHistoryTracker`
needs no change because it observes rows.

- Tests: the legacy-only tests in `ConversionQueueStateTests` are deleted or rewritten; UI tests
  for cancel and progress run against service jobs.

## Cross-cutting risks

- **Restart behaviour changes for manual work.** Today a quit loses legacy work, and the
  last-session overlay offers to restore it. Service jobs come back as `interrupted` records.
  Decide which one wins before phase 2 makes most manual work durable.
- **Progress volume.** Every progress tick publishes all records and `ContentView` re-projects
  them. That is fine for a few agent jobs but not proven for hundreds of queued rows. Measure it
  before phase 6, and throttle in the reporter if needed.
- **Security-scoped access.** The service authorizes only through stored bookmarks, so every
  manual entry point must persist grants first (as `ManualApplicationJobBridge.persistFileAccess`
  does today). The watch folder and history re-queue are the paths most likely to miss this.
- **Partial batches.** Cancelling a service job ends the whole job and keeps the outputs completed
  so far. The legacy engine can cancel a single row (`cancelItem`) and carry on with the batch.
  Rows must show the same thing either way.
- **Agent contract.** New fields must not leak paths into summaries or tool results
  (`ApplicationAgentToolFailure` already strips them).

## First concrete step

Phase 0: three extra conditions in `ManualApplicationJobBridge.isRepresentable` (explicit
adjustments, global loudness normalization enabled, matte sidecar enabled for the preset), with
unit tests for each case. It is small and routes rows back to the engine that already handles them, but it changes
which engine runs some manual work. It was therefore left out of the behaviour-preserving
refactor that produced this plan, and should land as its own reviewed change. Phase 1's parity
test is the next step, so the same drift can't come back.
