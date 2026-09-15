# Proposed 4.5 release — Local agent access

Status: signed local transport, visible shared-job queue projection, initial
Shortcut submission including per-source destinations, and ordinary manual
shared-queue submission with common per-file settings and destinations
implemented on `codex/release-4.5`;
live manual success/cancellation and bilingual Agent Access diagnostics now pass.
Beta readiness still depends on named-client, access-loss, output-matrix, sandbox
scope, and Release-package validation.
Created: 2026-09-11.

## Release context

- 4.4.0 is the current stable release.
- 4.5 is the development target for an initial local MCP interface.
- No release date is committed. Confirm scope after the feasibility milestone.

The checked-in development metadata is **4.5.0 (577)**. This is not a frozen or
signed release candidate.

## Implementation progress — through 2026-09-15

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
planning. Presets outside the bounded contract continue through the established
path rather than silently losing semantics. Shared-submission failures become
visible failed Shortcut rows. See the
[App Intent handoff validation record](4.5-app-intent-handoff-validation-2026-09-13.md).

Ordinary ungrouped manual H.264, HEVC, ProRes, Proxy, Audio Only, and Stream Copy
conversions now plan and execute through the same persisted service. Existing
manual rows are claimed by exact request/item identity rather than duplicated,
and batches preserve row order plus captured date-tag, timecode, preset, and
filename settings. The bridge declines customized rows, merge/group work,
post-actions, and other semantics absent from the v1 contract before changing
ownership. Every shared row also exposes a selectable
inspector rendered from its immutable accepted request rather than current
preferences. See the
[manual handoff validation record](4.5-manual-handoff-validation-2026-09-13.md).

The manual handoff now also captures per-source comments, trim ranges, crop,
mute, date-tag, and timecode choices in a backward-compatible optional request
snapshot. Acceptance validates source alignment and bounded trim/crop values,
the FFmpeg adapter applies each source's immutable choices, and the queue
inspector shows the settings for its exact row. Audio routing, custom names,
groups/merge, generated waveform behavior, post-actions, and per-source
destinations were still on the legacy path at this increment. See the
[per-source handoff validation record](4.5-per-source-handoff-validation-2026-09-13.md).

Per-source snapshots now also carry manual audio routing and custom output base
names. Routing validation rejects unknown or duplicate stream identities,
out-of-range channel operations, unsupported presets, and MCA options outside
the six-preset contract. Custom names are bounded and path-safe, participate in
duplicate-output and collision checks, and remain attached to the exact source
through execution and queue inspection. Groups/merge, generated waveform
behavior, post-actions, and per-source destinations were still on the legacy path
at this increment.
See the [routing and naming validation record](4.5-routing-naming-validation-2026-09-13.md).

First-party manual requests now also capture an immutable destination for each
source. This moves “save next to original,” including preset and custom
subfolders, into the shared planner without authorizing or persisting an unused
batch fallback folder. Planning, submission, queued execution, collision checks,
and accepted-settings inspection all use the effective destination for each row.
Older schema-v1 snapshots decode without the new optional field. The Agent Access
pane, queue origin labels, connection states, and accepted-settings control now
have initial Norwegian translations. See the
[destination and localization validation record](4.5-destination-localization-validation-2026-09-13.md).

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

The immutable accepted-settings summary now uses the string catalog for every
label and state, with locale-aware numbers and capture dates. Norwegian coverage
includes preset, codec, metadata, subtitle, filename, destination, timecode,
trim, crop, mute, routing, and custom-name details, and the packaged Norwegian
catalog is exercised directly by the focused handoff suite. See the
[accepted-settings localization validation record](4.5-accepted-settings-localization-validation-2026-09-13.md).

Live manual shared-queue UI coverage now verifies both successful H.264 output
and cancellation of a running FFmpeg subprocess. This closed three integration
gaps: dormant waveform preferences no longer divert ordinary video to the legacy
path, global UI activity/cancellation follows service-owned jobs after handoff,
and the FFmpeg adapter awaits the converter's asynchronous completion callback.
Agent Access also starts and stops its endpoint off the main thread and passes an
English/Norwegian opt-in plus loopback diagnostic test. The full unit target now
passes 929 tests, all 74 release-script tests pass, and the 1,616-entry catalog
audit remains green. A Release build passes static validation for 45 arm64 Mach-O
images and 12 packaged notices; strict helper signature verification remains
blocked by the recorded local Apple Development trust-chain failure and does not
replace Developer ID archive/notarization. See the
[shared UI ownership validation record](4.5-shared-ui-ownership-validation-2026-09-14.md).

Supported file-bearing App Intent conversions now preserve “Save next to
original” through the shared service instead of returning to the legacy executor.
Each source captures its effective destination, including custom or preset-based
subfolders, and access persistence authorizes only destinations the plan will
use. Failed submission rows also retain the intended per-source folder. The full
unit target now passes 931 tests; the 74 release-script tests and 1,616-entry
catalog audit remain green. See the
[App Intent destination validation record](4.5-app-intent-destination-validation-2026-09-15.md).

SwiftMediaMetadata is now pinned to 3.0.1 at revision
`8662054299a3e13c49c65f74c564360559d1bf7f`, adopting its bounded-memory Sony
RTMD discovery fix. The exact tag source is retained and tied through the package,
GeoNames, source-component, and bundled-dependency manifests. Four focused
upstream RTMD tests, all 931 app unit tests, all 74 release-script tests, strict
source/license verification, a Release build, and the 45-image/12-notice static
bundle audit pass. See the
[SwiftMediaMetadata 3.0.1 validation record](4.5-swiftmediametadata-3.0.1-validation-2026-09-15.md).

Agent Access now shows copyable, client-specific setup for Claude Desktop,
Claude Code, Codex, and OpenCode, with a guide for file grants, reconnects,
retention, and the same-session access policy. The installed Claude Code and Codex CLIs
accepted the displayed command forms in isolated configurations; Claude Code
reported a healthy stdio connection and Codex reported the expected registered
helper path. OpenCode's local-MCP JSON is implemented and covered by a focused
configuration test, but its installed CLI has not connected in this environment.
This is setup-syntax validation, not the three-client end-to-end
workflow required for beta. See the
[client setup validation record](4.5-client-setup-validation-2026-09-15.md).

The MCP helper now retries only while waiting for the app endpoint to appear.
Once a port accepts a send attempt, transport failure is returned to the client
without replaying a potentially long-running or mutating tool call. Plans use
the helper's client-derived requester identity even if an undeclared caller
argument supplies another value, cold-launch waiting keeps the main run loop
available for `NSWorkspace` completion, and `list_presets` now has an object-shaped
MCP structured result. These changes are covered by the
[helper transport validation record](4.5-helper-transport-validation-2026-09-15.md).

The embedded Debug helper now has a process-level reconnect/access test: a plan
survives a revoked-source submission failure, can be submitted after access is
restored, and remains visible and cancellable from a new MCP client process.
Retrying the plan returns the same cancelled job. The freshly built Debug app
also cold-launched directly through Launch Services and displayed the Agent
Access pane. This narrows the packaged transport gate but does not yet prove a
named client's complete workflow or helper-triggered cold launch. An attempt
to connect the helper from the XCUITest runner failed because that runner could
see neither the app's UUID test port nor its default port despite an in-app
`Ready` diagnostic. The pane's connection test now launches the packaged helper
as an app child process and verifies its MCP preset result in both languages;
whether the runner failure reflects only test-runner isolation remains
unresolved. See the
[packaged MCP reconnect validation record](4.5-packaged-mcp-reconnect-validation-2026-09-15.md).

Agent Access startup and Settings opt-in changes now share a serialized
lifecycle reconciler. It reads the current preference at each transition and
again after endpoint startup, so a delayed app-launch task cannot reopen a
connection after the user disables access. A timing regression covers disabling
while startup is suspended. This narrows the disabling-policy gate; it does not
establish helper-triggered cold launch or an external named-client connection.
See the [lifecycle validation record](4.5-agent-access-lifecycle-validation-2026-09-15.md).

Approved sources that become unavailable now report the stable
`source_unavailable` failure during both media inspection and conversion
planning. Planning maps filesystem identity failures to that code, matching
submit-time revalidation; inspection checks availability after acquiring its
approved read lease and before launching the media probe. The typed IPC boundary
returns the same code for both operations. See the
[unavailable-source validation record](4.5-unavailable-source-validation-2026-09-15.md).

This is still a beta candidate under construction rather than a completed
feasibility decision. The
current direct-distribution target has App Sandbox disabled, the Claude Code,
Codex, and OpenCode tool workflows have not all been exercised, and a Developer ID
Release archive has not completed signing/notarization validation. Groups/merge, generated waveform
behavior, post-actions, and unsupported App Intent cases still use the legacy
executor, so full
cross-boundary serialization remains open. The Agent Access surface and
accepted-settings inspector now have Norwegian catalog coverage, but bilingual
visual review and the packaged end-to-end acceptance matrix remain open.

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

Prove a signed app and bundled helper can connect under the chosen App Sandbox
scope, launch the app if needed, inspect an approved file, and return structured data. Test denied and
revoked folder access. Verify compatibility with Claude Code, Codex, and OpenCode.

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
