# Proposed 4.5 release — Local agent access

Status: signed local transport, visible shared-job queue projection, initial
Shortcut submission, and ordinary manual shared-queue submission implemented on
`codex/release-4.5`; feasibility decision pending final-client, specialized-path,
and Release-package validation.
Created: 2026-09-11.

## Release context

- 4.4.0 is the current stable release.
- 4.5 is the development target for an initial local MCP interface.
- No release date is committed. Confirm scope after the feasibility milestone.

The checked-in development metadata is **4.5.0 (577)**. This is not a frozen or
signed release candidate.

## Implementation progress — through 2026-09-13

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

The shared service now also creates versioned, expiring conversion plans with
captured file identities and deterministic output locations. Planning reports
existing outputs and rejects duplicate names within a batch. Submission rechecks
source identity and disk collisions, reserves output names across concurrent
jobs, and retains idempotency across both same-plan retries and equivalent newly
created plans. Terminal transitions release in-memory reservations. This remains
a transport-neutral boundary; execution adapters are not yet connected. See the
[planning validation record](4.5-planning-validation-2026-09-13.md).

Plans, job records, submitted-plan links, and requester-scoped idempotency
identities are now atomically persisted in Application Support. Startup restores
terminal results and marks queued, running, or cancelling work interrupted rather
than restarting it. Plans expire after 15 minutes and terminal records (including
their idempotency keys) are retained for 30 days. Corrupt or unsupported snapshots
are reported and preserved instead of being silently replaced. See the
[persistence validation record](4.5-persistence-validation-2026-09-13.md).

Planning and submission now require persisted user-approved security-scoped
access for every source and writable access for the destination. The service
uses the narrowest matching file or ancestor-folder bookmark, retains balanced
access for the whole filesystem validation operation, and rechecks grants at
submission so revoked access cannot enqueue work. Stable permission errors
separate missing source and destination grants. See the
[folder-authorization validation record](4.5-folder-authorization-validation-2026-09-13.md).

Submitted jobs can now hand off to an injected app-owned executor without giving
the transport or a SwiftUI view ownership of conversion tasks. The service
serializes manual, App Intent, and local-agent work, publishes progress and
terminal results through the shared record, retains every security-scoped lease
until execution finishes, rechecks queued sources and output collisions before
launch, and signals only the active job's executor during cancellation. Executor
outputs must match the accepted plan. The concrete FFmpeg adapter is still open;
this increment establishes and tests the lifecycle it will plug into. See the
[execution-handoff validation record](4.5-execution-handoff-validation-2026-09-13.md).

The live shared service is now connected to the bundled `FFMPEGConverter` through
an app-owned adapter. It reconstructs the exact captured H.264, HEVC, ProRes,
Proxy, Audio Only, and Stream Copy settings without consulting current user
preferences, converts every planned source/output pair in order, aggregates batch
progress, stops on the first failure, and fences cancellation to the active job.
Unrepresentable snapshots fail before FFmpeg launches instead of silently falling
back. Focused adapter coverage and the full unit result are recorded in the
[FFmpeg adapter validation record](4.5-ffmpeg-adapter-validation-2026-09-13.md).

Shared-service records now stream into the existing visible queue as one row per
source. Rows preserve the accepted output location, follow live and terminal
state, identify Agent or Shortcut origin plus a stable job ID, and route
cancellation back to the service. Legacy manual selection, bulk cancellation,
and dock progress explicitly exclude service-owned rows, preventing the old
manager from claiming or mutating them. At this validation point, the manual and
App Intent entry points still started work through `ConversionManager`. See the
[visible queue validation record](4.5-visible-queue-validation-2026-09-13.md).

File-bearing App Intent conversions for the initial H.264, HEVC, ProRes, Proxy,
Audio Only, and Stream Copy subset now use the same persisted planner and
serialized executor as MCP jobs. The handoff captures date-tag, timecode, comment,
preset, and filename settings before suspension, preserves request identity for
idempotency, and persists the selected files and destination grants before
planning. Presets outside the bounded contract and the per-source “save next to
original” mode continue through the established path rather than silently losing
semantics. Shared-submission failures become visible failed Shortcut rows. See the
[App Intent handoff validation record](4.5-app-intent-handoff-validation-2026-09-13.md).

Ordinary ungrouped manual H.264, HEVC, ProRes, Proxy, Audio Only, and Stream Copy
conversions now plan and execute through the same persisted service. Existing
manual rows are claimed by exact request/item identity rather than duplicated,
and batches preserve row order plus captured date-tag, timecode, preset, and
filename settings. The bridge declines customized rows, merge/group work,
post-actions, per-source destinations, and other semantics absent from the v1
contract before changing ownership. Every shared row also exposes a selectable
inspector rendered from its immutable accepted request rather than current
preferences. See the
[manual handoff validation record](4.5-manual-handoff-validation-2026-09-13.md).

The six proposed agent operations now have a transport-neutral, typed workflow:
media inspection, preset discovery, conversion planning and submission, job
lookup, and cancellation. Inspection requires an existing user-approved read
grant and returns structured video, audio, subtitle, timecode, and exact rational
rate metadata. Preset discovery captures the current resolved settings for the
six supported stable preset IDs, while planning records local-agent ownership and
uses the same persisted service as execution. Codable success and stable,
path-safe failure payloads are covered by the
[agent tools validation record](4.5-agent-tools-validation-2026-09-13.md).

The six operations are now reachable through a runtime-free stdio MCP helper
that Xcode builds as a separate Hardened Runtime command-line target and embeds
with Code Sign On Copy. A versioned `CFMessagePort` boundary carries typed JSON
requests to the app, while the helper negotiates the current MCP protocol,
publishes the six bounded schemas, launches the enclosing app when needed, and
returns structured tool results. The app endpoint remains off by default.

Settings now include an Agent Access pane with opt-in control, connection test,
copyable client configuration, helper discovery, approved-folder guidance, and
an explicit disabling policy. A packaged Debug helper successfully negotiated
MCP and returned all six resolved presets through a running app. See the
[MCP transport validation record](4.5-mcp-transport-validation-2026-09-13.md).

This is still a prototype rather than a completed feasibility decision. The
current direct-distribution target has App Sandbox disabled, two named MCP
clients have not been exercised, and a Developer ID Release archive has not
completed signing/notarization validation. Specialized manual jobs and
unsupported or per-source-destination App Intent cases still use the legacy
executor, so full cross-boundary serialization remains open. Localization and
the packaged end-to-end acceptance matrix also remain open.

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
