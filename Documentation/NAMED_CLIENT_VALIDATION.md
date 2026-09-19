# Named MCP client validation for 4.5

Use this procedure separately in Claude Code, Codex, and OpenCode. It closes a
different release gate from helper protocol tests or configuration registration.
The [setup guide](LOCAL_AGENT_ACCESS.md) describes enabling access and registering
the embedded helper. Record the exact app build, installed path, macOS version,
client executable/version, date, and transcript location for every run.

## Evidence levels

| Observation | What it establishes |
| --- | --- |
| Version/help commands run | Client executable is available |
| Client accepts a server entry | Registration syntax is accepted |
| Client reports connected / discovers six tools | Client-to-helper initialization works |
| Actual client invokes the tools and receives app results | The recorded workflow works in that client |

A custom JSON-RPC driver using a client's name in `clientInfo` does not establish
that client's compatibility. A CLI registration command or a model's summary
without tool results does not establish the conversion workflow. Preserve the
actual tool arguments and responses from the named client. Do not include tokens,
unrelated client configuration, or private source media in committed evidence.

## Tool arguments and response fields

These are the helper's wire names, independent of localized labels:

| Tool | Required arguments | Successful `structuredContent` |
| --- | --- | --- |
| `list_presets` | `{}` | `presets` array |
| `inspect_media` | `source_path` | Media inspection object |
| `plan_conversion` | `source_paths` array, `destination_path`, `preset_id` | Plan with `id`, `request`, `outputs`, and `warnings` |
| `submit_conversion` | `plan_id` | Acceptance with `record.id` and `wasAlreadyAccepted` |
| `get_job` | `job_id` | Job with `id`, `state`, and `outputURLs` |
| `cancel_job` | `job_id` | Job with `id`, `state`, and `outputURLs` |

Paths are absolute filesystem paths; identifiers are UUID strings. The preset
wire identifiers are `h264`, `hevc`, `prores`, `proxy`, `audio_only`, and
`stream_copy`. Pass the plan's `id` as `plan_id`, then the acceptance's
`record.id` as `job_id`. The helper also returns text containing the JSON result.
An MCP response with `isError: true` is a failed operation even when the transport
itself succeeds; preserve its error instead of treating it as workflow completion.

## Prepare one reproducible run

1. Install the build under test at a stable path. Enable Agent Access and test
   its connection in the app. Register the helper using the displayed setup.
2. Import an expendable, known-good video with audio in the app and choose an
   empty output folder. Use an absolute source path containing a space to cover
   path handling. Record fixture duration, stream types, and a file hash.
3. Choose H.264 for the successful run. Record its resolved settings returned by
   `list_presets`; presets reflect app preferences. Use separate output folders
   for success, cancellation, and restart runs to avoid output collisions.
4. Prepare a longer video or sufficiently expensive preset for the cancellation
   run. A job that finishes before cancellation is an inconclusive cancellation
   check; retry with a longer fixture.
5. Start a real session in the client under test with its registered MCP server.
   Use only the six media converter MCP tools for media operations. Shell-based
   direct helper calls are separate transport evidence.

## Successful conversion and reconnect

Ask the client to carry out the following sequence, substituting approved paths:

```text
Use Aagedal Media Converter's MCP tools to list presets and inspect SOURCE.
Plan conversion of SOURCE into DESTINATION using h264. Show the returned plan
identifier, output paths, warnings, and captured settings. Submit that plan and
report the returned job identifier. Stop after acceptance so I can reconnect.
```

Confirm the accepted job appears in the app. Close the client session while the
job is queued or running, leaving the app open. Record the disconnect time and
last observed state. Start another session in the same named client and ask it
to call `get_job` using the saved job identifier until terminal state. Expected
result: `succeeded`, output URLs, and no duplicate conversion on reconnect.
Inspect the output with the app preview and a media probe; record video/audio
streams, approximate duration, and playback result. A disconnect after completion
proves result retrieval, but does not prove execution survives a disconnect.

## Cancellation

In the named client, plan and submit the longer fixture into a fresh destination.
Save its job identifier, call `get_job`, then `cancel_job`, and follow with
`get_job` until terminal state. Expected result: `cancelled` (possibly preceded
by `cancelling`) and the same terminal state in the visible app queue. Record
whether cancellation was requested while queued or running. An accepted cancel
request alone is insufficient; the terminal state must be observed.

## App restart and cold launch

For restart recovery, submit another long-running job and confirm it is running.
Quit and reopen the app, reconnect the same client, and retrieve the saved job.
Expected result: `interrupted`, with no automatic duplicate/restart. Preserve
the app's visible result and client response. The current normal-quit handler
waits up to two seconds for preview-process cleanup; it does not drain or cancel
the application conversion queue. Startup changes persisted nonterminal jobs to
`interrupted`. Use a fixture that remains active throughout that quit window.
If the job completes before app exit, a restored `succeeded` result is valid but
does not exercise interruption recovery; repeat with a longer fixture. Record
whether the exit was normal quit or an abrupt termination, and do not present
one as evidence of the other.

For cold launch, first enable Agent Access, then quit the app with no active
jobs. Start the named client and call `list_presets`; the embedded helper should
open the app and return presets. Record launch/response evidence separately
from an app already running. Do not count a hand-written initialization request
as a named-client cold-launch test.

## Results checklist

For each client, record **pass**, **fail**, **blocked**, or **not run** for:

- Registration and real tool discovery.
- `list_presets`, `inspect_media`, and `plan_conversion` with actual responses.
- `submit_conversion`, visible queue admission, and saved plan/job identifiers.
- Disconnect during active work, reconnect, terminal `get_job`, and playable output.
- `cancel_job` while queued/running and terminal `cancelled`.
- App restart and terminal `interrupted` without automatic retry.
- Helper-triggered app cold launch from that client.

Attach transcript excerpts and output observations to each claim. Record errors
verbatim and identify the last step reached. Keep this client compatibility gate
separate from the six-preset output matrix, sandbox scope decision, access-loss
tests, signing/notarization, and clean-install review.
