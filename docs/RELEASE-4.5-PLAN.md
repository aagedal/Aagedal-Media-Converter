# Proposed 4.5 release — Local agent access

Status: implementation started on `codex/release-4.5`; feasibility decision pending.
Created: 2026-09-11.

## Release context

- 4.4.0 is the current stable release.
- 4.5 is the development target for an initial local MCP interface.
- No release date is committed. Confirm scope after the feasibility milestone.

The checked-in development metadata is **4.5.0 (577)**. This is not a frozen or
signed release candidate.

## Implementation progress — 2026-09-12

The first shared-boundary increment is implemented without selecting an IPC
transport prematurely:

- stable wire identifiers for the initial H.264, HEVC, ProRes, Proxy, Audio Only,
  and Stream Copy subset;
- a Codable, versioned conversion request and job record with explicit manual,
  App Intent, and local-agent origins;
- actor-owned acceptance with requester-scoped idempotency and conflict detection;
- stable machine-readable error codes for boundary validation and lifecycle errors;
- explicit queued, running, cancelling, succeeded, failed, cancelled, and
  interrupted transitions; and
- restart handling that marks incomplete records interrupted instead of silently
  restarting them.

Ten focused unit tests cover serialization, validation, stable error codes,
concurrent retry deduplication, requester isolation, cancellation, lifecycle
ownership, and restart semantics. This is foundation for milestone 2, not
completion of milestone 1 or a claim that the existing UI/App Intent conversion
paths use the service yet. See the
[foundation validation record](4.5-foundation-validation-2026-09-12.md).

The next shared-boundary increment captures the resolved settings for all six
initial presets in each request. Stable semantic identifiers cover the output
container, encoder, video profile, audio codec, quality/rate controls, resolution,
metadata/subtitle policy, and filename rules. These snapshots round-trip through
the versioned contract and participate in idempotency comparison, so a settings
change cannot mutate accepted work or turn a retry into a different conversion.
Focused coverage is recorded in the
[settings-capture validation record](4.5-settings-capture-validation-2026-09-12.md).

## Intended outcome

An agent on the user's Mac can inspect media, discover the user's presets, plan
a conversion, and submit it to the app. The user sees agent-created jobs in the
same queue as manual work and can inspect their settings, preview media, and
cancel them. The app uses its existing conversion logic and bundled tools.

The value is reliable access to established media workflows: consistent proxy
settings, audio and timecode handling, output naming, and observable batch work.
The app does not need an embedded AI model or an AI-service subscription.

## Proposed first-release scope

- Opt-in local agent access, with connection instructions and a connection test.
- App-owned execution; the app may launch for a connection and stays responsible
  for jobs after the agent disconnects. Fully headless operation is deferred.
- Structured media inspection and discovery of supported presets/settings.
- Conversion planning with resolved settings, intended destinations, warnings,
  and validation errors before execution.
- Submission of one or more files, job status and results, and per-job cancellation.
- Ordinary file conversions using a tested subset of built-in presets. Select
  the exact subset during feasibility, starting with H.264, HEVC, ProRes/proxy,
  audio export, and stream copy where the existing pipeline supports them.
- User-approved source and destination folders using existing sandbox access
  mechanisms. Explain how to grant or renew access in the app.
- Agent origin and job identity visible in the queue; manual work remains usable
  while an agent is connected.

Initially defer remote/network access, a public REST API, a separate CLI, arbitrary
FFmpeg arguments, preset/settings mutation, downloads, uploads, recording,
transcription, and complex exports such as DCP, IMF, and image sequences. These
remain candidates for later expansion after the shared job contract is proven.

## Architecture direction

### Improvements carried forward from the existing roadmap

Prioritize these as part of the shared agent boundary:

- Section 3.1: move job ownership and request handling out of views.
- Section 3.2: explicit typed requests/plans with captured settings and validation.
- Section 3.3: centralize settings needed by those requests; preserve migration
  behavior and avoid dependence on mutable global selections.
- Sections 2.2–2.3: cancellation, ownership, and structured error behavior required
  by the new service and reconnect contract.

These are bounded MCP prerequisites, not a requirement to rewrite all conversion
code. Existing correctness bugs identified during 4.4 triage stay with 4.4 unless
the affected feature is explicitly restricted there.

Other carried-forward work is a prioritized follow-up backlog: wider actor and
filesystem audits; remaining settings migrations; broader accessibility and
scrolled bilingual review; additional format coverage and generated AV2 video;
runtime memory measurement, dynamic dependency reachability, and measured binary
cleanup. Pick individual items after the feasibility milestone. They do not all
block 4.5, and may move to later releases. Keep dependency attribution and signed
distribution checks complete for every release; these are not deferred from 4.4.

### Shared service

Introduce a small application service shared by the UI, App Intents, and MCP.
It accepts explicit requests and exposes job records independently of views.
Reuse existing conversion services; avoid a wholesale engine rewrite.

The current App Intent handoff is useful precedent for launch buffering, but it
routes through ContentView notification handlers. ConversionManager also accepts
SwiftUI bindings. Move only the ownership and request boundaries needed for this
release behind the shared service.

Prefer a bundled local MCP helper using stdio, subject to a signed-app prototype.
Decide helper-to-app IPC, launch behavior, and sandbox access in that prototype.
Do not commit to a transport that requires users to install a separate runtime.

## Proposed tool contract

| Tool | Result |
| --- | --- |
| `inspect_media` | Structured streams, duration, dimensions, frame rate, audio, and available timecode metadata |
| `list_presets` | Stable preset identifiers, resolved settings, and supported overrides |
| `plan_conversion` | Validated plan ID, captured settings, proposed outputs, warnings, and errors |
| `submit_conversion` | Job IDs for an accepted plan; returns before encoding completes |
| `get_job` | State, stage/progress where available, diagnostics, and output locations |
| `cancel_job` | Cancellation acknowledgement followed by observable terminal state |

Keep the schema versioned and bounded. Return stable error codes with readable
messages. Advertise only capabilities supported by this interface, even where
the UI offers additional features.

Plans capture preset settings, naming rules, destination, and supported per-file
overrides. Submission rechecks file access, source identity, and output collisions;
it rejects stale plans rather than silently changing them. Reserve actual output
names at submission and report them. Default to preserving existing files.

Submission accepts an idempotency key so a retry cannot duplicate accepted work.
Define per-file outcomes for batch submission. Cancellation applies to the
specified job and drains its helpers before reaching a terminal state.

Job records distinguish queued, running, cancelling, succeeded, failed, cancelled,
and interrupted work. Persist enough identity and terminal results to answer
reconnects; app restart must not silently restart incomplete conversions. Define
record retention and idempotency-key lifetime before implementation.

## Milestones and exit criteria

### 1. Feasibility and scope decision

Prove a signed, sandboxed app and bundled helper can connect, launch the app if
needed, inspect an approved file, and return structured data. Test denied and
revoked folder access. Verify compatibility with two selected local MCP clients.

Exit: documented IPC/transport decision, supported-client list, setup flow,
initial preset/override matrix, and an effort estimate. If file access or packaging
is impractical, revise the scope before refactoring the queue.

### 2. Shared job boundary

Introduce explicit requests, captured settings, stable IDs, and job state ownership.
Route the necessary UI/App Intent paths through this boundary without changing
their existing behavior. Establish coexistence rules for manual and agent work.

Exit: automated coverage for settings capture, duplicate submissions, concurrent
manual/agent submissions, cancellation ownership, and launch handoff.

### 3. MCP workflow

Implement the six tools over the shared service, including validation, structured
errors, approved-folder checks, reconnect behavior, and persisted job outcomes.

Exit: a local client can inspect, plan, submit, follow, and cancel a conversion;
disconnecting the client does not stop an accepted job or lose its result.

### 4. User experience and release validation

Add opt-in settings, setup instructions, connection diagnostics, queue origin
labels, and readable permission/error guidance. Define disabling behavior so
new requests stop and already accepted work has an explicit, visible policy.

Exit: Debug build and relevant unit/UI tests pass; a signed Release package passes
the end-to-end matrix below. Update release notes and include setup documentation
and UI screenshots. Verify any added dependency's packaging and license.

## Release acceptance matrix

- Fresh setup, app closed/open, client disconnect/reconnect, and app restart.
- File access granted, denied, revoked, or lost on an unavailable external drive.
- Invalid inputs, unsupported options, stale plans, and output-name collisions.
- Duplicate requests and concurrent agent/manual queue operations.
- Cancellation during preparation, encoding, and final output publication.
- Actual output metadata and representative playback for each supported preset,
  including audio-channel and timecode preservation where promised.
- Existing manual import, preview, conversion, App Intents, and sandboxed access.
- No separate FFmpeg or helper-runtime installation required for supported tools.

## Deferred decisions

Resolve during milestone 1: exact MCP client targets, IPC mechanism, minimum
supported macOS implications, supported trim/audio/timecode overrides, folder-grant
UX, and batch acceptance semantics. Resolve before milestone 3: job retention,
plan expiry, reconnect guarantees, and protocol compatibility policy.

4.5 ships when the supported workflow is dependable. Additional formats and agent
tools should not delay that core scope.
