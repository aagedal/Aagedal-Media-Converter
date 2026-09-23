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

The development metadata is **4.5.0 (582)**. This is not a frozen or
signed release candidate.

## Implementation progress — through 2026-09-22

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
than restarting it. Unsubmitted plans expire after 15 minutes; accepted plans
remain with their job records. Terminal records (including their plans and
idempotency keys) are retained for 30 days. Corrupt or unsupported snapshots
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

Inspection now also distinguishes a source lost *during* probing from malformed
media that remains present. It rechecks fresh filesystem attributes after a
probe failure, returns `source_unavailable` for loss, and rejects directories
before probing. Focused coverage is in the
[inspection access-loss validation record](4.5-inspection-access-loss-validation-2026-09-15.md).

The packaged helper now validates the app's IPC response schema and requires
exactly one success result or failure before presenting a tool result. An
incompatible schema or ambiguous response returns `transport_unavailable` rather
than being mistaken for a valid MCP result. A separate helper-process regression
exercises both cases; see the
[helper response validation record](4.5-helper-response-validation-2026-09-15.md).

An independently launched packaged Debug helper now reached the opt-in app
endpoint in the normal login session and returned all six presets. Cold launch
exposed a same-bundle-ID substitution: with the installed stable app running,
Launch Services reused that installation instead of opening the helper's
enclosing Debug app. The helper now disables running-app substitution, and a
repeat call started the exact Debug bundle while preserving the saved disabled
Agent Access preference. Non-object MCP tool arguments now fail with JSON-RPC
invalid parameters. See the
[cold-launch and input validation record](4.5-helper-cold-launch-validation-2026-09-15.md).

A packaged-helper test now drives media inspection, planning, submission,
completion, and reconnect lookup against the live FFmpeg adapter using a real
Stream Copy fixture. It exposed that the adapter passed the plan's final filename
to a converter that appends its own extension, leaving a succeeded job pointing
to a nonexistent planned file. The adapter now supplies the filename base; the
test confirms the exact planned output exists and decodes. See the
[live output validation record](4.5-live-mcp-output-validation-2026-09-15.md).
The same live adapter is now exercised for the other five supported presets:
each creates its exact planned file, decodes all streams, and reports the
expected output video/audio codecs through the bundled FFmpeg binary. This
narrows the output-matrix gate; representative in-app playback, channel/timecode
cases, and signed-package validation still require separate checks.

The shared-service handoff now rechecks cancellation after persisting the
running state, before invoking FFmpeg. The adapter also keeps a targeted
pre-start cancellation until execution begins, so an app request delivered at
that boundary does not turn into an unnecessary encode. The focused regression
and full application-job contract suite pass; see the
[handoff cancellation validation record](4.5-handoff-cancellation-validation-2026-09-15.md).

The live Stream Copy MCP workflow now checks a source with 5.1 audio and an MOV
timecode track. Inspection reports six channels and the source timecode; output
keeps the channel layout. Agent v1 has no timecode override and deliberately
disables output timecode, so the accepted-settings inspector now says so instead
of omitting the policy. A separate live first-party shared-job run with
preserve-source timecode retains the track and 5.1 layout. See the
[channel/timecode validation record](4.5-channel-timecode-validation-2026-09-15.md).

Shared-service FFmpeg jobs and legacy manual/group conversion batches now take
turns through one application execution gate. The gate is FIFO and spans each
batch's conversion completion; a cancelled service job is skipped when its turn
arrives, and a legacy request cancelled while waiting cannot start preparation.
The legacy manager still rejects retries immediately while its previous batch
is active or cancellation is draining. This covers engine admission across the
two owners; post-conversion follow-ups and overlapping specialized-job output
checks remain in the beta acceptance matrix. See the
[execution serialization validation record](4.5-execution-serialization-validation-2026-09-15.md).

Shared jobs now require the converter to reserve each exact accepted output path.
If another operation creates that output after the service validates the batch,
the converter returns `output_collision` before encoding or registering the file
for cleanup. It no longer chooses a suffixed output and incorrectly reports the
pre-existing planned file as success. Legacy conversions keep their existing
unique-name behavior. A live two-file Stream Copy regression exercises the late
collision and preserves both the first completed output and the colliding file.
See the [exact-output validation record](4.5-exact-output-validation-2026-09-19.md).

Failed and cancelled sequential batches now retain the outputs completed before
execution stopped. The service validates that these outputs match the beginning
of the accepted plan, persists them for reconnect lookup, and projects completed
source rows as done even when the overall job failed or was cancelled. A live
late-collision regression verifies the earlier output survives both on disk and
in restored job history; cancellation and invalid partial-output reports have
focused coverage. See the
[partial-batch validation record](4.5-partial-batch-validation-2026-09-19.md).

Cancellation at the FFmpeg completion boundary now retains a successfully
published output before stopping the batch, including when that output is the
last source. Cancellation received while the adapter publishes preparation
progress also prevents the runner from starting. A real Stream Copy regression
covers single-source and multi-source publication, persisted reconnect results,
and decoding of the retained output. See the
[publication cancellation validation record](4.5-publication-cancellation-validation-2026-09-19.md).

Shared FFmpeg batches now persist each successfully completed output before
starting the next source. Reconnect lookup and visible rows expose that completed
prefix while the batch is active; restart recovery retains it while marking the
unfinished job interrupted. Cancellation preserves checkpoints, invalid or
regressing reports cannot erase them, and a checkpoint write failure stops the
adapter before another source starts. See the
[per-file checkpoint validation record](4.5-per-file-checkpoint-validation-2026-09-19.md).

Concurrent submissions now serialize the acceptance boundary across registry
suspension points. Competing requests cannot both pass the same output reservation
check, and simultaneous same-plan or equivalent-plan retries return one accepted
job. Submission admission is separate from conversion execution, so new work can
still queue while an existing job runs. See the
[submission concurrency validation record](4.5-submission-concurrency-validation-2026-09-19.md).

Submission retries now recover an execution handoff after a temporary job-store
write failure. Original-plan and equivalent-plan retries retain the accepted job
identity, save it before enqueueing, and start execution only once. Cancelling
the pending job discards the handoff so later retries cannot revive it. See the
[submission recovery validation record](4.5-submission-recovery-validation-2026-09-19.md).

A failure saving the running transition now stops the job before launching its
executor, makes the terminal result visible even while the store is unavailable,
and releases its output reservation. Once storage recovers, an idempotent retry
saves and returns that same failed job; a new request can reuse the output and
execute normally. See the
[running-state persistence validation record](4.5-running-persistence-validation-2026-09-19.md).

Completed and cancelled jobs now remain visible to queue observers when saving
those state changes fails. Transitions, cancellation, interruption, and completed
output checkpoints publish their in-memory results while still reporting the
storage error. Once storage recovers, an idempotent submission retry saves the
same terminal result without starting another conversion. See the
[terminal-state persistence validation record](4.5-terminal-persistence-validation-2026-09-19.md).

Startup recovery now serializes concurrent restore calls and makes service
requests wait for recovery to finish. A second caller cannot reload the old
snapshot over new plans or accepted jobs while the first caller is suspended on
the registry. Concurrent restart/submission coverage checks one-time interruption,
retained new jobs, idempotent retries, and persistence across another reload. See
the [startup recovery validation record](4.5-startup-recovery-validation-2026-09-19.md).

Startup recovery now publishes interrupted job records even when the recovery
snapshot cannot be saved. Subsequent service requests retry that save before
proceeding, without reloading the old snapshot or changing the original recovery
diagnostic and timestamp. Reconnect and idempotency retain the same interrupted
job after storage becomes writable again. See the
[startup save recovery validation record](4.5-startup-save-recovery-validation-2026-09-19.md).

Newly accepted jobs now reach queue observers even when saving their submission
fails. The pending job remains visible and cancellable while storage is
unavailable, and execution still waits for a successful save. Original-plan and
equivalent-plan retries retain the same job without reviving cancelled work or
starting duplicate conversions. See the
[submission visibility validation record](4.5-submission-visibility-validation-2026-09-19.md).

Startup recovery now validates every persisted plan and submitted-plan link
before replacing live job records. Invalid snapshots stay untouched and cannot
leak partially restored jobs into the visible queue. After the snapshot is
repaired, the same service can retry recovery and preserve interruption and
idempotency behavior. See the
[atomic recovery validation record](4.5-atomic-recovery-validation-2026-09-19.md).

Startup recovery also verifies that each submitted plan belongs to its linked
job's original request or a valid requester-scoped idempotent retry. Mismatched
requesters, keys, or conversion inputs now reject the snapshot before any jobs
become visible. Original requests without keys and equivalent retries with new
request IDs and capture timestamps remain supported. See the
[recovery link validation record](4.5-recovery-links-validation-2026-09-19.md).

Startup recovery now also checks persisted source identities and output mappings
against their captured requests before publishing any jobs. Missing, reordered,
or unrelated sources, missing outputs, duplicate output paths, and destinations
outside the captured per-source folder reject the snapshot without overwriting it.
Accepted filenames remain frozen across restarts. Recovery after repair and valid
per-source destinations pass the 83-test contract suite. See the
[plan integrity validation record](4.5-plan-integrity-validation-2026-09-19.md).

Accepted plans now survive the planning expiry window for the lifetime of their
job records. Queue inspection retains the frozen output mapping, and retries of
an accepted plan still return the same job after expiry and restart. Unsubmitted
plans still expire normally; terminal-record retention removes associated plans
and retry links together. See the
[accepted-plan retention validation record](4.5-plan-retention-validation-2026-09-19.md).

Queue output lookup now selects a retained plan matching the job's original
request instead of an arbitrary linked idempotent retry. Equivalent requests can
capture different dates and propose different template-based filenames; those
retry names no longer replace the accepted names in queue inspection, including
after restart. The 85-test contract suite passes. See the
[original output plan validation record](4.5-original-output-plan-validation-2026-09-19.md).

Planning-time retention cleanup now publishes removed terminal jobs to existing
queue observers. Storage failures still report an error while the visible queue
follows the authoritative in-memory state; a later successful save retains the
cleanup across restart. See the
[retention queue publication validation record](4.5-retention-publication-validation-2026-09-19.md).

Startup recovery now checks saved job outputs against the original accepted
plan before publishing any jobs. Completed jobs require the full output list;
partial and interrupted jobs retain only an ordered prefix, and queued jobs
cannot claim outputs. Invalid snapshots remain untouched and can be retried after
repair. Equivalent retry plans cannot substitute their filenames. Older snapshots
without retained original plans keep their existing recovery behavior. See the
[recovered output validation record](4.5-recovered-output-validation-2026-09-19.md).

Live shared-job output checks now cover captured first-party trim, crop, mute,
and audio routing. A three-second source produces a one-second, 24-frame,
64×48 muted output after trimming and cropping; a separate six-channel source
retains six channels or downmixes to stereo according to its captured routing.
All outputs decode with the bundled FFmpeg, and all 90 shared-job contract tests
pass. This expands automated output validation without closing named-client,
real bookmark, or in-app playback gates. See the
[live per-source override validation record](4.5-live-overrides-validation-2026-09-19.md).

Shared-job access validation now also runs with native macOS security-scoped
bookmarks in an isolated grant store. Missing source approval and read-only
output approval reject planning; removing either persisted grant rejects a
restored plan's submission without creating a job or output. Renewing both grants
lets the same plan complete through bundled FFmpeg, and retry returns the same
job. Native folder-grant coverage also rejects sibling-prefix paths and symlink
escapes while a valid borrower holds the scope. This narrows the bookmark gate;
interactive folder selection, OS-level revocation, lost drives, and the chosen
App Sandbox scope still require release validation. See the
[native bookmark validation record](4.5-native-bookmark-validation-2026-09-19.md).

Queued shared jobs now have native-bookmark access-loss coverage after acceptance.
With execution held behind the gate used by legacy manual work, removing a source
or writable destination grant causes the affected job to fail before FFmpeg runs;
the next authorized job still completes. Failed records survive service reload,
renewal does not restart them through an idempotent retry, and new requests can
reuse their released output names. All 107 contract/bookmark tests pass. See the
[queued grant validation record](4.5-queued-grants-validation-2026-09-19.md).

Legacy group and agent cancellation now have integration coverage through the
real `ConversionManager.convertGroup` entry point and shared job service using
the same execution gate. Cancelling group preparation releases waiting agent
work without reviving cancelled rows; cancelling a waiting agent preserves the
group and allows subsequent agent work after the group ends. All 111 contract
and queue-state tests pass. Controlled preparation and executor fixtures isolate
ownership; live merged exports and specialized post-actions remain open. See the
[group coexistence validation record](4.5-group-coexistence-validation-2026-09-19.md).

Live merge coexistence now also runs the real two-clip concatenation path with
bundled FFmpeg. Each all-intra fixture is trimmed to one second; an agent job
waits behind merge preparation and starts only after both group rows report the
shared merged output complete. The merged file and separate planned agent output
each contain 48 frames, span two seconds, and decode successfully. This narrows
the live export overlap gate; audio continuity, long-GOP trimming, encoding-time
cancellation, post-actions, and playback remain open. See the
[live merge coexistence validation record](4.5-live-merge-coexistence-validation-2026-09-19.md).

Live merge coexistence now also covers trimmed all-intra clips with distinct
mono PCM tones. The regression checks audio format, bounded packet overhang,
clip order, audible energy around the join, full decoding, and agent execution
only after merged output publication. The fixture exposes an existing Stream
Copy limitation: two seconds of trimmed video retain 2.048 seconds of audio.
Sample-accurate cuts, perceptually seamless joins, compressed audio, and long-GOP
behavior remain unproven. See the
[trimmed merge audio validation record](4.5-merge-audio-validation-2026-09-19.md).

This is still a beta candidate under construction rather than a completed
feasibility decision. The
current direct-distribution target has App Sandbox disabled, the Claude Code,
Codex, and OpenCode tool workflows have not all been exercised, and a Developer ID
Release archive has not completed signing/notarization validation. Groups/merge, generated waveform
behavior, post-actions, and unsupported App Intent cases still use the legacy
executor. Their end-to-end coexistence with agent jobs remains open. The Agent Access surface and
accepted-settings inspector now have Norwegian catalog coverage, but bilingual
visual review and the packaged end-to-end acceptance matrix remain open.

## Continuation — 2026-09-20

The MCP helper now validates request envelopes and treats ID-less messages as
silent notifications without invoking app tools. Seven process regressions cover
invalid JSON, malformed requests, ID/parameter validation, initialization,
discovery, and recovery after errors. All 81 script tests pass. See the
[helper envelope validation record](4.5-helper-envelope-validation-2026-09-20.md).

Three live cancellation regressions now cover merged and sequential legacy H.264
groups while agent work waits. They observe real encoded frames and subprocess
termination, verify execution ownership through cancellation drainage, preserve
cancelled rows, and complete subsequent agent output. All 22 queue tests passed.
See the [encoding cancellation validation record](4.5-encoding-cancellation-validation-2026-09-20.md).

The Norwegian catalog now includes 50 previously missing stitching, accepted
settings, and analysis strings. LUFS remains an untranslated measurement unit.
The 1,671-entry audit passes with no unclassified missing keys or placeholder
mismatches. Full visual review of the newer panels remains open. See the
[localization validation record](4.5-localization-validation-2026-09-20.md).

Silent video now exports through ProRes and Proxy: their default audio maps no
longer require a nonexistent audio stream. Live regressions verify preserve,
replace, and disabled timecode for both presets, plus the content and order of
two explicitly reordered audio tracks. All 1,017 Debug unit tests pass with no
failures or skips. See the
[silent video and timecode validation record](4.5-silent-video-and-reencoded-timecode-validation-2026-09-20.md).

The English/Norwegian Agent Access opt-in and packaged-helper diagnostic UI test
passes. Targeted native and MPV preview tests both completed initial seeking and
frame capture, but failed later playback/reopen interactions. Event-delivery
stalls suggest a possible focus problem without establishing the cause. These
checks remain failed release gates; see the
[preview validation record](4.5-preview-validation-2026-09-20.md).

The unsigned Release build (`CODE_SIGNING_ALLOWED=NO`) and static bundle audit
pass: 45 arm64 Mach-O images and 12 packaged license notices. Evidence is retained
in `/private/tmp/amc-4.5-sept20-release.log`,
`/private/tmp/amc-4.5-sept20-bundle-audit.log`, and
`/private/tmp/amc-4.5-sept20-bundle-report.json`. This does not establish signing
or notarization readiness. Dependencies and bundled media binaries are unchanged.

A subsequent repeat passed both unchanged preview tests. The preview keyboard
handler now defers to native text editors, and Command-A uses the backend's
window-scoped handler instead of an app-wide audio-meter monitor. Strengthened
UI coverage checks timecode replacement without toggling the meter, in addition
to seeking, frame capture, playback/pause, and reopening. This fixes a concrete
editing conflict without claiming to explain every earlier event-delivery stall.
See the [preview keyboard validation record](4.5-preview-keyboard-validation-2026-09-20.md).

The broader output matrix now includes a non-keyframe trim within a four-second
H.264 GOP with B-frames, exported to ProRes and WAV. It checks all 36 decoded
video frames and the exact 72,000-sample audio range against independent decoded
references. This exposed missing WAV inspection duration; the inspector now uses
the existing bounded duration fallback when the audio parser omits it. See the
[long-GOP and audio-range record](4.5-long-gop-audio-range-validation-2026-09-20.md).

Two new integration cases cover legacy quality analytics while an agent export
succeeds or is cancelled. They run real FFmpeg export and PSNR processes, hold
metric completion to force overlap, and verify that the delayed result preserves
row ownership and terminal agent state. See the
[analytics coexistence record](4.5-analytics-agent-coexistence-validation-2026-09-20.md).

A [named-client validation runbook](../Documentation/NAMED_CLIENT_VALIDATION.md)
now defines tool arguments, actual transcript evidence, reconnect, cancellation,
restart, and cold-launch checks. Installed Claude Code and Codex pass executable
preflight. OpenCode still terminates by SIGKILL and its installed executable
fails signature verification; the causal relationship is not established.
Actual named-client workflows remain open. See the
[client preflight record](4.5-named-client-preflight-validation-2026-09-20.md).

All 1,020 Debug unit tests pass with no failures or skips, including the new
long-GOP and analytics cases. All 81 script tests and the 1,671-entry Norwegian
catalog audit pass. The combined unit/UI run found a test-only checkbox value
cast in the strengthened preview assertions; both corrected UI tests pass
in their separate final run. Evidence is retained in the linked validation records.
The updated unsigned Release build and static bundle audit also pass (45 arm64
Mach-O images and 12 packaged license notices). Final evidence:
`/private/tmp/amc-4.5-continuation-release.log`,
`/private/tmp/amc-4.5-continuation-bundle-audit.log`, and
`/private/tmp/amc-4.5-continuation-bundle-report.json`. Signing/notarization remains
unvalidated; dependencies and bundled binaries are unchanged.

The stitching continuation fixes empty-source starts, trim-out advancement,
replay ordering, and unnecessary seeks on ordinary resume. Native and MPV UI
cases now pass with two trimmed generated clips, transitions, sequence-end replay
progress, pause, and closing/reopening the editor. Three added unit cases cover
boundary behavior. Screenshots were visually reviewed; real-card/MXF/long-media
and delayed-loading stress coverage remain open. See the
[stitching playback record](4.5-stitching-playback-validation-2026-09-20.md).

The output matrix now verifies decoded keyframe-aligned Stream Copy content and
AAC sample alignment through WAV and H.264/AAC exports. Copied audio may retain
part of its final packet; the test measures that bounded tail without claiming
sample-exact stream-copy trimming. Two additional real subtitle-mux cases verify
late publication and cancellation alongside independent agent execution. See the
[Stream Copy/AAC record](4.5-stream-copy-aac-boundary-validation-2026-09-20.md) and
[subtitle coexistence record](4.5-subtitle-agent-coexistence-validation-2026-09-20.md).

The complete Debug unit target passes **1,027 tests**, with no failures or skips.
Both new stitching UI cases, all 81 script tests, and the 1,671-entry Norwegian
catalog audit pass. The updated unsigned Release build and static bundle audit
also pass: 45 arm64 Mach-O images and 12 packaged license notices. Evidence:
`/private/tmp/amc-4.5-sequence-release.log`,
`/private/tmp/amc-4.5-sequence-bundle-audit.log`, and
`/private/tmp/amc-4.5-sequence-bundle-report.json`. This does not validate
Developer ID signing or notarization. No dependencies or bundled media binaries
changed.

The delayed-loading continuation adds native and MPV checks for pausing during
preparation, preserving the trimmed in-point, resuming, and closing/reopening the
editor before preparation completes. It fixes a paused MPV startup callback that
could replace the pending seek position with zero. Seventeen Norwegian marker and
waveform translations also close the current catalog audit gaps. See the
[delayed-loading validation record](4.5-stitching-delayed-loading-validation-2026-09-20.md).
All 26 focused unit tests, four native/MPV UI tests, the 1,688-entry localization
audit, and an unsigned Release build pass for this continuation.

The reordered/trimmed stitching export now has a live regression through
`ConversionManager.convertGroup` and bundled FFmpeg. Two distinct generated
all-intra sources are reversed and asymmetrically trimmed; all 48 decoded output
frames match the retained source frames in that order. Embedded chapter ranges
and Resolve EDL notes match the new sequence positions, and notes outside the
retained ranges are excluded. All 12 focused export/marker tests pass. See the
[reordered export validation record](4.5-stitching-reordered-export-validation-2026-09-20.md).
This covers the conversion boundary with generated video; editor-driven export,
real-card/MXF/long-recording media, and compressed-audio joins remain open.

Generated AAC stitching joins now pass with marker export both enabled and
disabled. The live group-conversion regressions check decoded tone order,
audio energy across the join, bounded packet rounding, video frame count,
chapter/sidecar output, and serialization with a waiting agent conversion.
All 16 focused stitching/export tests pass. See the
[AAC join validation record](4.5-stitching-aac-join-validation-2026-09-20.md).
This narrows compressed-audio coverage to matching mono 48 kHz AAC sources;
multichannel, differing encoder delay, long-GOP joins, and real media remain open.

Generated stereo and 5.1 AAC stitching joins now also pass with marker export
both enabled and disabled. Distinct tones verify every decoded channel's identity
and clip order, including LFE; per-channel seam checks detect packet-sized gaps.
The four new cases retain the existing duration, chapter, decode, and waiting-agent
serialization checks. All 20 focused stitching/export tests pass. See the
[multichannel AAC validation record](4.5-stitching-multichannel-aac-validation-2026-09-20.md).
This covers matching-format generated sources; differing encoder delays,
long-GOP joins, other layouts, and real media remain open.

Generated closed-GOP H.264 with two B-frames and stereo AAC now has bounded
Stream Copy stitching regressions with marker export enabled and disabled.
Independent source-frame comparisons verify clip order and the exact retained
reference-frame tails; audio checks cover both channels across the extended join.
This exposed a timing limitation: even keyframe-aligned 0.5–1.5 second cuts retain
26 rather than 24 frames per clip, and the two-clip output lasts about 2.22–2.29
seconds. These tests characterize current packet-copy behavior; they do not
establish exact long-GOP trimming. See the
[long-GOP stitching validation record](4.5-stitching-long-gop-validation-2026-09-20.md).
The editor now provides explicit boundary guidance as described below; exact cut
handling, open-GOP validation, and real-media coverage remain open.

The stitching editor now displays a persistent Stream Copy notice below the
timeline explaining that exports can include extra video frames and audio even
at keyframes. It distinguishes the requested preview/timeline selection from
actual export boundaries and duration. English and Norwegian text replace the
previous tooltip-only guidance. This addresses disclosure of the observed timing
limitation; it does not change trimming or establish exact cuts. See the
[boundary guidance validation record](4.5-stitching-boundary-guidance-validation-2026-09-20.md).

Generated open-GOP H.264/AAC stitching now has regressions with markers enabled
and disabled. These expose a new unresolved correctness issue: two decoded frames
at the join do not match either original source, even though FFmpeg reports a
successful decode. The container reports 56 frames while only 54 decode. Source
frames on either side remain intact, and audio/marker/agent serialization checks
pass. The whole-output frame-identity requirement remains an explicit strict
expected failure in each new test; this is not open-GOP acceptance. See the
[open-GOP validation record](4.5-stitching-open-gop-validation-2026-09-20.md).
Fix or explicitly restrict this case before claiming reliable open-GOP trimmed
stitching; the existing approximate-boundary notice does not resolve the mismatch.

Trimmed merge preparation now drops leading video pictures presented before the
first copied keyframe, preventing the demonstrated open-GOP join corruption.
The two expected failures above are replaced by strict source-frame identity
checks, with additional cuts between keyframes and markers enabled/disabled.
The generated outputs contain 52 reported and decoded frames, all matching the
originals. All 152 focused application-job, marker, merge, queue, and cancellation
tests pass. Approximate trim boundaries and retained audio preroll remain; broader
codec/container and real-media acceptance is still open. See the
[open-GOP fix validation record](4.5-stitching-open-gop-fix-validation-2026-09-20.md).

Active subtitle mux cancellation now has a process-level coexistence regression.
A generated attached-SRT mux reports live FFmpeg progress and remains active while
a real agent Stream Copy export completes. Cancelling the mux then drains its
subprocess, preserves the original legacy output and completed agent result, and
removes staged subtitle files. All three focused subtitle coexistence tests pass.
This extends the earlier publication-boundary cancellation coverage; cancellation
while both media subprocesses are active, transcription/OCR inference, and live
uploads remain open. See the
[active subtitle cancellation validation record](4.5-active-subtitle-cancellation-validation-2026-09-20.md).

Subtitle cancellation now also passes while both the subtitle mux and agent
FFmpeg export are actively running. The new regression waits for real progress
from both subprocesses, cancels and drains only the subtitle mux, checks that the
agent remains running, and verifies its eventual successful output. All four
focused subtitle coexistence tests pass. Cancelling the agent while subtitle
muxing continues, inference/OCR, and upload remain open. See the
[simultaneous subtitle cancellation validation record](4.5-simultaneous-subtitle-cancellation-validation-2026-09-20.md).

The reverse cancellation direction now also passes with both real FFmpeg
processes active: cancelling the shared agent job drains only its subprocess,
while the subtitle mux remains running and publishes its subtitle-bearing output.
The regression checks the cancelled job stays cancelled with no published outputs,
source/SRT bytes remain unchanged, and no partial or subtitle staging files remain.
All five focused subtitle coexistence tests pass. Inference/OCR and upload remain
open. See the
[agent cancellation during subtitle mux validation record](4.5-agent-cancellation-subtitle-validation-2026-09-20.md).

Upload-manager coexistence now has regressions for both cancellation directions
while a real bundled FFmpeg agent export is active. Cancelling the upload rejects
late progress/success and leaves the export running to completion; cancelling the
agent drains its subprocess without cancelling the upload, which can still publish
its successful result. Both checks preserve the source and upload-file bytes and
verify no partial files remain. All 17 upload lifecycle tests pass. The upload
service is controlled in these tests; live rclone/remote transfers, inference/OCR,
and upload UI integration remain open. See the
[upload-agent coexistence validation record](4.5-upload-agent-coexistence-validation-2026-09-20.md).

Whisper-service coexistence now passes both cancellation directions alongside a
real agent FFmpeg export. Cancelling transcription rejects a deliberately late
successful SRT result while the agent completes; cancelling the agent leaves
transcription active and permits collision-safe subtitle publication. Source and
existing subtitle bytes remain unchanged, and no staging files remain. All seven
focused Whisper/subtitle coexistence tests pass. The inference subprocess and
model availability are controlled in these regressions; real model inference,
OCR, and UI integration remain open. See the
[Whisper-agent coexistence validation record](4.5-whisper-agent-coexistence-validation-2026-09-20.md).

OCR stream selection now has a bundled-FFmpeg regression using a generated MKV
with video, audio, and two distinct subtitle tracks. The test passes the live
inspector's subtitle-relative indices into the production extractor, verifies
each selected track's text, and confirms unchanged source bytes. The existing
mapping is correct; a misleading queue-model comment is corrected. All six focused
extraction tests pass. Bitmap recognition and OCR/agent cancellation coexistence
remain open. See the
[OCR stream-selection validation record](4.5-ocr-stream-selection-validation-2026-09-20.md).

OCR-service coexistence now passes both cancellation directions alongside a
real agent FFmpeg export. A minimal generated PGS display set exercises the real
parser and PNG rendering, while a controlled recognition engine returns late
success after cancellation. Cancelling OCR discards that result without stopping
the agent; cancelling the agent leaves OCR able to publish a collision-safe SRT.
Both checks preserve existing files and verify scratch/staging cleanup. All nine
focused OCR, Whisper, and subtitle-mux coexistence tests pass. Extraction and
recognition are controlled boundaries; real bitmap extraction, recognition quality,
and UI integration remain open. See the
[OCR-agent coexistence validation record](4.5-ocr-agent-coexistence-validation-2026-09-21.md).

The OCR coexistence checks now mux a generated PGS display set into an H.264 MKV
and extract its real subtitle track through bundled FFmpeg before parsing and
recognition. Both cancellation directions pass with unchanged source/existing
subtitle bytes, exact successful SRT timing, and scratch cleanup. Recognition
remains controlled to exercise late completion deterministically; VOBSUB extraction,
real recognition, and UI integration remain open. See the
[live PGS extraction validation record](4.5-live-pgs-extraction-validation-2026-09-21.md).

Active PGS extraction now has both cancellation directions covered alongside a
real agent FFmpeg export. Tests observe FFmpeg progress and require both
subprocesses to be active before cancellation. Cancelling OCR drains extraction
without reaching recognition or affecting the agent; cancelling the agent lets
extraction finish and OCR publish its collision-safe SRT. Source/existing output
preservation and scratch cleanup are checked. All 11 focused OCR, Whisper, and
subtitle-mux coexistence tests pass. Recognition remains controlled;
real engines, VOBSUB, and UI integration remain open. See the
[active PGS cancellation validation record](4.5-active-pgs-cancellation-validation-2026-09-21.md).

Real bundled Tesseract recognition now passes after cancelling an overlapping
agent export. A generated readable PGS bitmap is muxed into MKV, extracted through
bundled FFmpeg, parsed, recognized with the bundled English model, and published
with exact text/timing while preserving existing files. This work also fixes short
tracks reporting success with an empty SRT when every recognition attempt failed:
they now return an OCR error before publication. All 13 focused OCR, Whisper, and
subtitle-mux coexistence tests pass. A real Apple Vision attempt exceeded its
10-second frame deadline on this host and remains an open validation issue;
recognizer-internal cancellation, VOBSUB, and UI integration also remain open.
See the [real OCR and failure validation record](4.5-real-ocr-validation-2026-09-21.md).

Tesseract recognition now rechecks cancellation after subprocess completion before
accepting text or interpreting an exit failure. Two controlled completion-race
regressions fail before the fix and pass afterward; a real subprocess stand-in
also verifies prompt cancellation through the production engine and runner.
All 24 focused engine/coexistence tests pass, including real Tesseract publication.
Cancellation inside the actual recognition binary, the Apple Vision timeout,
VOBSUB, and UI integration remain open. See the
[OCR engine cancellation validation record](4.5-ocr-engine-cancellation-validation-2026-09-21.md).

DVD VOBSUB parser validation exposed incorrect MPEG-PS pack handling, control-chain
parsing, display-date scaling, palette mapping, and run-length decoding. These
are corrected with generated pixel/timing and malformed-input regressions; the
original parser returned no frames for the fixture, while bundled FFmpeg decoded
it independently. All 17 focused parser/OCR/Whisper/subtitle coexistence tests
pass. The service's extraction path still expects a `.sub/.idx` pair
that bundled FFmpeg cannot mux, so end-to-end VOBSUB OCR and cancellation
coexistence remain open. See the
[VOBSUB parser validation record](4.5-vobsub-parser-validation-2026-09-21.md).

DVD bitmap extraction now uses the supported VOB program-stream muxer and dumps
selected-stream codec metadata separately to retain its palette. The parser reads
PES presentation timestamps and reassembles the subtitle packets. A generated
two-track MKV regression checks selected-track color, exact timing, and SRT
publication with a controlled recognizer while preserving source/existing output.
The DVD muxer was rejected after validation exposed its first-timestamp rebasing.
DVD-specific agent cancellation overlap, real recognition/disc media, and UI
integration remain open. See the
[VOBSUB extraction validation record](4.5-vobsub-extraction-validation-2026-09-21.md).

DVD extraction now also has bidirectional cancellation/coexistence coverage with
an agent export. The generated fragmented-packet fixture exercises real bundled
FFmpeg VOB extraction, controlled OCR publication with three exact display
intervals, cancellation ownership, source/existing-output preservation, and
scratch-directory cleanup. A test-only discarded video output and nonzero initial
burst keep the extraction subprocess active for the overlap assertion. All 20
focused OCR, VOBSUB, Whisper, and subtitle-mux tests pass. Real disc media,
recognition accuracy, missing palettes, long tracks, and UI validation remain open.
See the [active DVD cancellation validation record](4.5-active-dvd-cancellation-validation-2026-09-21.md).

DVD program-stream subtitle timing now unwraps the 33-bit PES clock instead of
jumping backward at its boundary. Three fragmented-packet regressions cover
forward wrap, repeated/small backward timestamps, and reordering across the
boundary. All 23 focused parser, OCR, subtitle-mux, and Whisper coexistence tests
pass. Real-disc and long-track validation remain open; nearest-timestamp
unwrapping cannot resolve gaps exceeding half the clock period or an epoch before
the first observed timestamp. See the
[DVD timestamp-wrap validation record](4.5-dvd-timestamp-wrap-validation-2026-09-21.md).

DVD subtitle decoding now retains contrast independently of palette selection,
preserving transparency when alpha commands precede colors or a later control
block selects new colors. Two pixel-level regressions cover both cases; all 25
focused parser, OCR, subtitle-mux, and Whisper coexistence tests pass. The parser
still emits one bitmap per SPU, without time-varying palette animation. Missing
palettes, real-disc recognition, and UI validation remain open. See the
[DVD contrast-state validation record](4.5-dvd-alpha-validation-2026-09-21.md).

DVD OCR now rejects missing and malformed palettes with actionable bilingual
errors before recognition, preserving existing outputs and cleaning extraction
scratch files. Both waveform decoders now retain delayed audio on the source
timeline instead of displaying it too early. Camera-card import shows a
non-blocking performance advisory only when a discovered clip's volume reports
removable media, with the volume check performed off the main actor while the
selected folder's access remains active. Recent timeline and source-meter strings
now have Norwegian translations. See the
[continuation validation record](4.5-palette-waveform-card-validation-2026-09-21.md).

The continuation UI smoke run exposed a **release-blocking MPV crash** during
sequence replay, with `EXC_BAD_ACCESS` in the bundled CoreAudio hotplug callback.
Native replay passed; the subsequent range-drag test was obstructed by the crash
notice and needs a clean rerun. Investigate the dependency callback lifetime and
rerun MPV transition/replay checks before treating playback validation as closed.
The continuation record retains the crash evidence and diagnostic limits.

Follow-up investigation found a matching upstream CoreAudio initialization-failure
cleanup fix and retained its complete two-commit patch. Independent app-side fixes
remove MPVPlayer's callback retention cycle and correct 32-bit flag reads. The
bundled library remains unchanged; its rebuild and crash validation remain a
release blocker. See the [MPV investigation and rebuild steps](4.5-mpv-lifetime-and-coreaudio-2026-09-21.md).

The next continuation adds zoom-aware keyframe candidates to Stream Copy
filmstrips, including while snapping is disabled. Dense candidate clusters remain
hidden, and only the selected clip is scanned until snapping is enabled. Camera
recording-day grouping now has a tested, transport-independent foundation with
fixed-timezone day boundaries, explicit missing-date handling, indivisible logical
recordings, and strictly greater-than-two-hour end-to-start gaps. Automatic card
splitting remains disabled pending reliable span metadata and import preview UI.
The full unit suite and focused keyframe UI check pass; MPV replay and
pause/dismiss pass for this run, while the existing range-deletion drag UI check
still fails and needs investigation. See the
[continuation validation record](4.5-keyframes-grouping-mpv-validation-2026-09-21.md).

Keyframe discovery now scans bounded regions around trim endpoints and the
selected playhead, with cancellable readers, identity-aware caching, and explicit
completed coverage. Same-path replacements invalidate cached results, and unknown
neighboring regions cannot cause distant keyframe snapping. Free Stream Copy
trimming shows the requested start and a preceding seek estimate with a time
difference and export caveat. Discovery remains native because ffprobe is absent
from the current bundle. The range/ruler UI tests now use macOS mouse-drag APIs;
the product's SwiftUI range gesture is retained. All 1,123 unit tests, 81 release
script tests, localization checks, and three isolated serial UI checks pass,
including the previously failing range deletion/undo check. See the
[bounded discovery validation record](4.5-bounded-keyframes-validation-2026-09-21.md).

The free Stream Copy trim panel now displays the requested end and, when continuous
scan coverage permits it, a following-keyframe reference and time difference.
The reference explicitly does not predict the exported end. Camera-card grouping
now has a conservative compatibility-proposal layer that keeps logical spans
intact, preserves contiguous order, and isolates unknown/conflicting recordings
for review. Import activation still requires span resolution and a reviewed UI.
A live shared-service regression also verifies every selected 24-bit sample in
all six surround channels for trimmed WAV, FLAC, and ProRes output. See the
[continuation validation record](4.5-end-guidance-surround-grouping-validation-2026-09-21.md).

MPV decoder failures now stop stitching and show a bilingual error with accessible
Retry instead of treating the failed source as a completed clip. Natural EOF is
separated from stop/replacement/error events, and observer retirement rejects
queued callbacks after failure, replacement, or dismissal. A real missing-source
regression failed before the fix and passes afterward alongside focused lifecycle
and timeline coverage. All 1,136 unit tests, 81 release-script tests, localization
checks, and four serial UI checks pass, including bilingual failure/retry and
native/MPV replay. The error panels were visually reviewed. See the
[preview failure recovery record](4.5-preview-failure-recovery-validation-2026-09-22.md).
This does not resolve the bundled CoreAudio dependency blocker or establish
physical-drive removal and OS-level permission recovery.

MPV source loading now has a 30-second deadline. A decoder that reports neither
readiness nor failure enters the existing bilingual Retry flow, preserves audio
selection, and retires callbacks before teardown. Readiness, replacement, and
dismissal cancel the deadline. All 12 focused MPV observation tests pass,
including three new deadline regressions and the real missing-source check. See
the [load deadline validation record](4.5-preview-load-deadline-validation-2026-09-22.md).
This bounds asynchronous MPV loading only; native-player loading, synchronous
decoder hangs, and broader real-media stress remain unverified.

Native AVPlayer loading now also has a 30-second deadline. A source that stays
in the unknown state retires its native callbacks and falls back to the existing
bounded MPV path while preserving audio selection. The camera-card grouping
foundation now has a conservative probe-metadata adapter for explicitly resolved
logical recordings, including complete span duration and every video/audio track.
Automatic splitting stays disabled pending reliable span identification and a
reviewed import preview. Shared-job output reservations now recognize symlinked
ancestor-folder aliases, including duplicate per-source destinations checked
again at submission. All 1,162 unit tests, three serial preview UI checks,
81 release-script tests, and the localization audit pass. See the
[continuation validation record](4.5-native-card-alias-validation-2026-09-22.md).

The retained CoreAudio patch has now completed an isolated libmpv-only rebuild
for arm64 and x86_64 with the installed macOS 27 SDK, including universal framework,
XCFramework, and ZIP assembly. A reusable driver preserves the original checkout
and dependency outputs. Candidate hashes and the remaining publication,
provenance, and runtime gates are retained in the
[isolated rebuild record](dependency-patches/README.md).
The app still uses its previous dependency; the CoreAudio release blocker remains
open until the patched package is integrated and validated.

Camera-card scanning now deterministically orders duplicate clip basenames by
folder path, including a stable tie-breaker for naturally equivalent spellings.
Preview lifecycle coverage now stresses repeated source replacement, queued stale
callbacks, cancellation, and real missing-source decoder teardown. A read-only
MPV candidate verifier checks retained hashes, actual universal architectures,
XCFramework declarations, and archive/build binary correspondence. The retained
patched candidate passes; integration and CoreAudio runtime validation remain
open. See the [continuation record](4.5-preview-stress-candidate-validation-2026-09-22.md).

Shared-job output reservations now honor destination-volume case sensitivity,
preventing case-variant batch names and competing jobs from claiming the same
output on case-insensitive volumes. Dangling output symlinks now produce an
existing-output warning and block submission/execution. Accepted public paths
remain unchanged. See the [output entry safety record](4.5-output-entry-safety-validation-2026-09-22.md).
Whisper and OCR extraction adapters also reject late successful subprocess results
after task cancellation, before flushing buffered progress; see the
[adapter cancellation record](4.5-subtitle-adapter-completion-cancellation-validation-2026-09-22.md).
The retained MPV candidate additionally passes actual thin-archive architecture
checks and stricter archive-path validation; see the
[candidate archive record](4.5-mpv-candidate-archive-validation-2026-09-22.md).
All 1,172 unit tests, 96 release-script tests, and the 1,737-entry localization
audit pass. The full unit result is retained at
`/private/tmp/amc-45-output-cancellation-full.xcresult`; four existing test-target
QoS warnings remain. No new UI/manual playback or signed Release run is claimed.
These checks do not close package integration or CoreAudio runtime gates.

Camera-card import now offers an opt-in recording-date review. Users mark
continuation segments explicitly before grouping; the preview shows a fixed
timezone, optional gaps over two hours, compatibility partitions, and a
single-group choice. Incomplete or conflicting multi-file recordings block the
proposed import. Physical-card fixtures and live import/export checks remain open.

The anonymous usage indicator now has a first-open choice, a General Settings
control, a device-only Keychain secret, weekly tokens, and a daily HTTPS client.
There is no configured endpoint, so the client sends nothing. Server-side
aggregation, public policy, and the rolling-seven-day metric decision remain
open; unlinkable weekly tokens cannot deduplicate one installation across a
week boundary in that rolling window. See [privacy design and endpoint
requirements](ANONYMOUS-USAGE-PRIVACY.md).
The full Debug unit suite passes 1,176 tests; 96 release-script tests and the
1,761-entry Norwegian catalog audit pass. The unsigned Release build and static
45-image/12-notice bundle audit pass. See the [continuation validation
record](4.5-card-grouping-usage-indicator-validation-2026-09-22.md).

The camera-card review now keeps each source directory contiguous, so repeated
clip names from separate cameras do not interleave and prevent users from marking
adjacent continuation segments. The reviewed import guard evaluates each marked
multi-file recording's format compatibility on its own; a conflicting whole
group no longer makes a compatible recording look unmergeable. All 20 focused
grouping tests pass, including a two-camera temporary card tree. Physical-card,
real-span, export/playback, and bilingual visual checks remain open. See the
[card review validation record](4.5-card-review-order-validation-2026-09-22.md).

The retained patched libmpv candidate has been verified as GPL-enabled in both
architectures and prepared under the `Libmpv-GPL` asset name expected by the
app's package target. Its bytes and SwiftPM checksum are recorded in the
[asset preparation record](4.5-mpv-gpl-asset-preparation-2026-09-22.md). The asset
remains in temporary storage and unpublished; package integration, provenance,
CoreAudio runtime recovery, and signed distribution checks remain open.

The integrated Debug unit suite now passes **1,178 tests**, all 98 release-script
tests pass, and the unsigned Release build passes the 45-image/12-notice static
bundle audit. The Xcode 27 workspace did not retain its generated Swift package
lockfile, so the project now requires exact revisions for all three packages.
The strict manifest check binds them to reviewed attribution, and local package
resolution, an unsigned Debug build, and an unsigned Release archive with the
45-image/12-notice static audit pass. A signed release archive is still required.
See the [combined validation record](4.5-card-mpv-release-validation-2026-09-22.md)
and [package pin validation](4.5-package-pin-validation-2026-09-23.md).
The [September 23 continuation](4.5-continuation-2026-09-23.md) records the
99-test release-script run, five focused keyframe tests, and camera-card review
validation change.
The next bounded keyframe increment extends a sparse-GOP search into adjacent
regions while retaining per-reader limits and source-identity checks; six focused
tests pass. The retained MPV candidate verifier now checks the patched CoreAudio
source against build evidence before inspecting its archives, with 20 focused
script tests passing. The [named-client continuation](4.5-named-client-validation-2026-09-23.md)
records direct helper discovery and successful Claude Code and Codex registration,
but no live named-client tool call: Claude Code needs authentication, the Codex
headless run was blocked by local state permissions, and OpenCode exited with
signal 9. MPV integration still needs a published versioned asset, an MPVKit
package revision and exact app pin, provenance, and affected-macOS runtime checks.
The integrated Debug unit suite passes 1,178 tests, all 102 release-script
tests pass, and the updated unsigned Release archive passes the static
45-image/12-notice bundle audit. These checks are recorded in the
[September 23 continuation](4.5-continuation-2026-09-23.md).

Remaining priorities: validate stitching with broader real media and decoder-loading
stress; exercise full Claude Code, Codex, and OpenCode workflows after resolving
the OpenCode installation issue; validate actual OS-level grant revocation/lost
drives and settle App Sandbox scope; cover upload, transcription, OCR/subtitle
post-actions and broader stream-copy/audio/merge output cases; visually review the
new bilingual panels; and complete Developer ID signing/notarization, clean
installation/update checks, release notes, and retained package reports.

### Privacy-preserving usage indicator

Implemented an explicit first-launch choice for a small aggregate usage indicator. The
dialog offers **Allow anonymous usage count** and **Don't send data**, explains why
the count helps development, describes the reporting frequency, and shows an
illustrative payload. No option is preselected; declining produces no network
request for this feature, and the choice can be changed later in Settings.

When the user allows reporting, the app creates a random installation secret in
the device-only Keychain and derives a different pseudonymous token for each
calendar week. It sends that token at most once per day when the app opens over
HTTPS. The request contains no filenames, paths, media or conversion details,
account information, hardware identifiers, or OS metadata. The server assigns
the date/week, stores only the minimum data needed for aggregation, avoids
retaining client IP addresses, and reports distinct active installations during
the last seven days. The product copy must say “active installations,” not
“active users,” because one person may use several Macs and a Mac may be shared.

The client is implemented with a clear off switch and remains separate from the
existing quality-analysis feature. An endpoint, server controls, and a public
privacy policy are required before any reports can be sent. The client does not
collect conversion analytics.

## Beta readiness snapshot — 2026-09-15

The six-tool MCP workflow, shared execution for the six selected presets,
ordinary manual and Shortcut handoff, queue ownership, reconnect persistence,
and English/Norwegian setup diagnostics are implemented and covered in Debug.
The focused application-job suite, release-script suite, localization audit,
and unsigned Release build pass.

An external beta still needs named Claude Code, Codex, and OpenCode tool calls
through the packaged app in a normal login session; real first-party grants and
revocation/lost-drive recovery; overlapping agent/manual specialized-job checks;
in-app playback plus the broader cancellation/output matrix; bilingual visual
review; and a Developer ID archive with strict nested signing and notarization.
This host currently reports zero valid code-signing identities, so the signed
package gate requires signing access before it can be completed here.

Final-release closure additionally needs candidate stabilization, clean
installation and update verification, final release notes/screenshots, and the
signed artifact's dependency/license report retained with the release.

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


## Stitching editor — 2026-09-19

Stitched exports now default to Resolve EDL clip markers and embedded chapters
in MOV/MP4/M4V/MKV. Existing chapters trigger a Keep/Replace prompt, defaulting
to Keep. See [marker export behavior and reused Resolve evidence](stitch-marker-export.md).

The encoding group editor offers a Timeline toggle for stitching groups, including
memory-card imports. A single horizontal track displays all clips end to end,
with duration-proportional filmstrips, a shared time ruler and playhead, zoom, and
Fit. Clip-edge handles ripple-trim the sequence; clicking or dragging within a
clip or the ruler scrubs the assembled sequence. Each clip has a black footer with
start removed / kept duration / end removed readouts. Removed amounts use frame
counts; kept duration and sequence/ruler positions use non-drop-frame timecode.
Per-clip frame rates drive trim snapping and one-frame accessibility adjustments.
The shared ruler/counter uses frames only when all source rates agree; mixed or
unknown rates use whole-second clock values. Internal/export trim storage stays
in seconds and Stream Copy retains its keyframe constraints. Narrow clips show the kept
duration, with all three values in their tooltip and accessibility description.
Handles use a thin white grip with an opaque black surround and a larger hit area.
Shift–Z fits the current sequence and returns the timeline to its start, including
after heavy trimming. Numeric trim-entry fields have been removed; Reset trim
remains available for the selected clip.

Playback advances automatically from each clip's out-point to the next clip's
in-point, and stops at the sequence end. Source loading uses the existing native
and MPV preview paths and security-scoped access. Loading a new source can cause
a brief transition pause; this is not a pre-rendered, sample-accurate preview.
Per-file loop settings are suppressed for sequence preview without changing the
stored clip settings. Pausing, scrubbing, trimming, and reordering stop sequence
playback. Preview controllers tear down when their clip or editor disappears.

The timeline and clip list share the group's actual items and source trim fields.
Earlier/Later buttons update the list order, clear its sort mode, and refresh
sequential filenames where enabled. The list marks trimmed clips explicitly.
There are no additional tracks, volume editing, effects, or transitions. Stream
Copy retains its existing keyframe-dependent cut behavior. Closed-GOP B-frame
validation also found retained reference-frame tails at keyframe-aligned cuts;
keyframe alignment alone does not guarantee an exact exported out-point.

Initial validation: Debug build and five focused XCTest cases passed. Coverage includes
sequence-to-source mapping at boundaries, reordered clips, empty/zero-duration
sources, scrub bounds, invalid input, and trim limits. UI automation imported
both generated sample files but was interrupted by app-state changes before
validating the group editor. No successful live playback/export check was claimed
at that initial point.
Generated native/MPV transition, replay, pause, and reopening checks now pass; see
the [continuation record](4.5-stitching-playback-validation-2026-09-20.md).
Generated reordered/trimmed Stream Copy export validation now passes through
the real group conversion path, including decoded frame identity, chapters, and
note sidecars; see the [export record](4.5-stitching-reordered-export-validation-2026-09-20.md).
An editor-driven export and the broader real-media matrix remain open.

Before release, manually validate native and MPV sequence playback, transition
from a trimmed out-point to the next trimmed in-point, pause while loading, replay
after sequence end, ripple trim and reordering in exported output, list/timeline
sync, and sandbox access after switching clips and closing/reopening the editor.
Test a real memory-card group, MXF sources, and long recordings. Capture screenshots.

### Memory-card import improvements

Implemented: the import sheet shows a non-blocking local-copy advisory when at
least one discovered source reports `volumeIsRemovable`. Local copies and unknown
volume status do not trigger it. Import remains available, and the existing
folder grant covers both scanning and the off-main-actor volume lookup. Physical
card and bilingual visual validation remain open.

The grouping foundation is implemented and connected to an opt-in import review.
Users explicitly mark continuation files to resolve logical recordings before
splitting. Camera dates take precedence over container dates; filesystem dates
are never substituted. The preview fixes one timezone for the import, preserves
input order, keeps consecutive undated recordings together, and offers both a
single group and optional splitting after gaps longer than two hours. Compatibility
is evaluated across every segment. Unknown or incompatible multi-file recordings
cannot be submitted through this flow. The scanner still lacks trusted
format-specific span identity, so automatic continuation detection remains off.
The reviewed import now applies the same card-name validation as ordinary import
and retains the chosen upload server for its resulting groups.

Remaining live validation and automation:

- Validate review and actual imported groups with physical cards, MXF and spanned
  recordings, including output and playback. Capture bilingual screenshots.
- Add trusted format-specific span identifiers before offering automatic
  continuation detection. Keep manual review available.


### Keyframe-aware trimming — partially implemented

Optional Stream Copy keyframe snapping now applies to trim edges and selected
ranges. Discovery reads compressed samples from the first video track with a
cancellable, bounded AVAssetReader scans, retaining scoped source access. Completed
regions are cached by fresh source identity and track; unavailable or insufficient
coverage falls back to frame snapping.
The existing approximate-cut guidance remains applicable.

Completed keyframe scans now also serve contained bounded requests for the same
source identity and video track. Moving nearby trim handles can reuse inspected
coverage without rereading compressed samples. A preserved local FFmpeg 9.0.1
build contains `ffprobe`, but its executable is absent from the current checkout
and local temporary outputs. The [packaging review](4.5-ffprobe-packaging-review-2026-09-23.md)
keeps bounded native discovery for 4.5 until the candidate's bytes, source/license
attribution, bundle size, signing, and Release package can be verified. The app
does not use a user's Homebrew `ffprobe` for keyframe candidates.

The editor also includes split and range deletion, multiple-clip selection,
drag reordering, undo/redo, scalable waveform envelopes, and source audio meters.
Mono streams share a meter bank; stereo and surround tracks remain separate.
Waveform decoding now preserves delayed-track alignment with the source meters.

Stream Copy filmstrips now show candidate keyframe ticks when adjacent points
are at least eight screen points apart. Dense/all-intra clusters remain hidden
until zoom makes individual points readable; rendering is limited to the visible
trimmed interval. The selected clip loads candidates independently of snapping,
so displaying ticks leaves free trimming available. These remain candidate seek
points, not a guarantee of independently decodable or exact exported boundaries.

Remaining refinements:

- Requested-start and preceding-seek-candidate feedback is implemented, including
  a difference and uncertainty caveat. Requested-end and coverage-gated
  following-keyframe references are also implemented, explicitly without predicting
  exported end. Actual out-point estimates and temporary export-boundary previews
  remain open. Do not claim decoded preview is exact
  Stream Copy output. Merge preparation uses input-side `-ss`, `-t`, and `-c copy`.
- Recover and validate an attributed bundled ffprobe, then probe packet keyframe
  flags/timestamps using the selected bundled tool, scoped to
  the selected video stream; cache by source identity and normalize source start
  timestamps. Prefer bounded, cancellable scans around edited regions on long
  recordings/cards, expanding when the next/previous keyframe is not yet known.
- Treat keyframe markers as candidate seek points, not proof of an independently
  decodable cut for every codec/GOP. Validate open-GOP/B-frame dependencies and
  audio packet alignment against the actual trim/export path. If exact preview
  is needed, offer a short temporary Stream Copy boundary preview using the same
  preparation commands. All-intra material should avoid an unreadable tick at
  every frame at normal zoom.
- References: [FFmpeg seek behavior](https://ffmpeg.org/ffmpeg.html#Main-options)
  and [ffprobe packet/interval inspection](https://ffmpeg.org/ffprobe.html#Main-options).
