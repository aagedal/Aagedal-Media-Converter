# 4.4 release plan — Stabilization and release readiness

Status: stabilization in progress; no release readiness claimed.
Created: 2026-09-11.

4.3 is stable; 4.4 is in development. Ship the improvements already implemented
once the finite gates below are satisfied. Do not wait for every item in
IMPROVEMENT_PLAN.md, and do not start MCP or broad architectural refactoring as
part of release closure. Agent access is proposed for 4.5.

## Evidence already recorded

The improvement plan's latest validation records 829 passing unit tests, three
passing conversion UI smoke tests, 43 passing release-script tests, passing
localization/inventory checks, and an unsigned Release bundle audit covering
44 Mach-O images and six packaged notices. These are historical results, not
tests rerun for this planning change or proof of a signed release's readiness.

Priority 0, the initial generated-media integration suite, UI smoke coverage, and
the shared subprocess runner are recorded as complete. Preserve those gains.

## Required release gates

### 1. Close dependency attribution and packaging gaps

- [ ] Resolve the 99 outstanding source-inventory attributions recorded by the
  plan: avmenc, avmdec, rclone, and 96 dylibs. Establish actual build provenance,
  add the appropriate notices/material, and verify packaged notice coverage.
- [ ] Pass the existing complete-license gate and inventory freshness check.
  Do not bypass the gate or infer licenses from filenames. If removing a dependency
  is necessary, prove it is unused, update packaging/inventory, and validate it.
- [ ] Verify framework and transitive dependency coverage identified in
  [the dependency inventory](bundled-dependency-licenses.md).

This is a concrete publishing blocker: scripts/release.sh currently invokes the
strict attribution gate before building or uploading. Binary-size optimization
and general reachability cleanup are not required to close it.

### 2. Triage the remaining correctness risks

- [ ] Give each risk below a recorded disposition: fixed with regression evidence,
  verified unaffected in the supported scope, or affected functionality disabled
  with a clear user-facing explanation. Include issue/evidence references.

| Risk named by the latest improvement-plan entry | Required 4.4 disposition |
| --- | --- |
| Ambiguous numeric filter targets and stream inventory | Prove supported mapping/cropping is correct or reject ambiguous cases before encoding |
| Package/framework and superseded-helper draining; late filesystem writes | Targeted cancellation/retry checks; fix confirmed work continuing or publishing under retired ownership |
| Multi-process subtitle and remote coordination | Check output collision/ownership behavior; fix or constrain reproducibly unsafe concurrent use |
| IMF descriptor/conformance gaps | Validate supported export claims; fix or explicitly restrict affected output, rather than assume playable means conformant |
| Matroska layout labels inferred from channel counts | Verify media tracks remain correct; fix misleading labels or explicitly present unknown/inferred information |
| Generated waveform/synthesized AV2 video | Keep unsupported combinations rejected clearly; adding support belongs to follow-up work |

These are unresolved review topics, not claims that every one is a reproduced
defect. Completing the entire typed-plan or concurrency audit is not a gate.

### 3. Validate changed workflows in the real app

- [ ] Import → preset → convert → inspect output, including trim/crop, timecode,
  multichannel audio, existing-output collisions, and cancel/retry. Use a small
  representative matrix of the branches changed since stable 4.3.
- [ ] Native and MPV preview, seeking, audio playback, and screenshots.
- [ ] Shortcuts with the app closed and open; no missing or duplicated submissions.
- [ ] Output/watch-folder grant renewal, denied access, unavailable volumes, and
  restart; verify cleanup preserves files when access is insufficient.
- [ ] Real-model transcription and representative download/upload retry and
  cancellation, including output ownership and failure recovery.
- [ ] Live static/animated recording at supported fixed rates plus Auto, stop/finalize,
  permission denial/renewal, and representative long A/V sync. Verify fractional
  rate/timecode behavior in an editor. Record duration, rates, and editor versions.
- [ ] Core import, preset, convert/cancel, error details, and Settings flows using
  keyboard and VoiceOver; inspect changed UI in English and Norwegian.
- [ ] Upgrade from 4.3 preserves presets, destinations, credentials/references,
  schedules, and applicable saved access; malformed saved state is not erased.

Record pass/fail, candidate commit, macOS version, fixtures, and any limitations.
Test secondary features proportionately to changes; exhaustive UI and every
codec/device combination are follow-up work. Core flow failures must be resolved.

### 4. Validate the release candidate and distribution

- [ ] Freeze a candidate commit and rerun Debug/unit tests, conversion UI smoke,
  release-script tests, localization, and manifest checks. Do not use 829 as a
  fixed expected count; the candidate's full applicable suite must pass.
- [ ] Build and audit Release, then validate the signed/notarized candidate and
  final archive, including architectures, dependencies, packaged notices,
  Gatekeeper, Sparkle signature, and appcast version/build agreement.
- [ ] Test clean direct-download installation and Homebrew packaging, plus update
  from stable 4.3 using a controlled candidate feed/artifact. Include the minimum
  supported macOS and the current supported release where available. Do not
  publish publicly just to run these checks; distinguish staging checks from any
  final live-channel verification.
- [ ] Prepare accurate 4.4 release notes and version/build metadata. Draft notes and development metadata now identify 4.4.0 (576); finalize them
  against the frozen candidate and signed artifact before release.

## Stabilization evidence — 2026-09-11 continuation

- Development metadata is now **4.4.0 (576)**. This is not a frozen or signed
  release candidate. `CHANGELOG.md` separates draft 4.4 notes from the exact
  published history recovered from stable release commit `ce2f016`; incremental
  engineering notes are retained in [the development history](4.4-development-history.md).
- [Numeric-filter review](4.4-numeric-filter-review.md): ambiguous crop targets
  and numeric filters combined with app-managed output mapping changes now fail
  before encoding with typed-filter guidance. Known explicit output ordering
  remains supported; ambiguous deinterlace aliases are left untouched.
- [Matroska review](4.4-matroska-layout-review.md): suppresses count-derived
  speaker labels and extracts AVC-Intra mono channels by position, avoiding
  layout guesses that could remix or silence samples.
- [Generated AV2 review](4.4-generated-av2-review.md): synthesized video and
  both waveform engines retain explicit unsupported-request rejection with no
  output file or app-created ownership left behind.
- [Dependency provenance review](4.4-dependency-provenance-review.md): records
  exact rclone revision evidence, an AVM revision lead, pinned package revisions,
  and historical dylib-copy scripts. The 99 missing attributions remain open.
  It additionally confirms that FFmpeg reports GPL v3-or-later while its manifest
  entry and notice still specify v2. Correct attribution requires more than
  eliminating `NOASSERTION` entries.

The [validation record](4.4-validation-2026-09-11.md) records the new regression
evidence and the combined checks.

These findings do not close the live-workflow, signed-distribution, IMF descriptor,
package/helper draining, or multi-process coordination gates. No public release
or appcast change has been made.

## Additional stabilization — cancellation, coordination and IMF

Continuation based on `4bb9cb7` records these dispositions:

- [IMF review](4.4-imf-review.md): both IMF export presets are disabled before
  tool lookup or output creation because descriptor, identity and schema gaps
  prevent a conformance claim. Settings and conversion errors explain the
  restriction; existing preferences are preserved.
- [Helper draining](4.4-helper-draining-review.md): Deno extraction and whole
  updates retain cancelled owners until drained; yt-dlp cancellation now spans
  release lookup, checksums and publication. Regression helpers deliberately
  perform late writes to verify replacements wait.
- [Coordination review](4.4-coordination-review.md): subtitle publication locks
  the destination directory across app processes. Remote uploads acquire a
  same-destination lock for cooperating instances under the same user/container.
  Endpoint aliases, other clients and live network behavior remain explicit limits.
- The dependency gate now records FFmpeg's own reported license and rejects the
  known manifest/notice mismatches alongside the 99 missing attributions. This
  strengthens detection; it does not supply the missing source/build evidence.

These close concrete implementation findings in the remaining risk reviews, but
manual workflow validation, complete attribution and signed distribution gates
remain open. Final checks passed: 843 unit tests, three conversion UI smoke tests,
53 release-script tests, localization, inventory freshness and the unsigned Release
bundle audit. See [continuation validation](4.4-validation-continuation-2026-09-11.md).

## What can wait for 4.5

- Full orchestration extraction and typed filter/codec/output plans.
- Remaining settings centralization and migrations unrelated to a concrete bug.
- Broad actor, filesystem, and multi-process audits beyond the dispositions above.
- Exhaustive accessibility/localization coverage and additional first-run polish.
- New AV2 generated-video support and additional format combinations.
- Runtime-memory profiling, dynamic dependency reachability, and size optimization.
- MCP and its shared application/job service.

See the [4.5 plan](RELEASE-4.5-PLAN.md) for ordering. These are follow-up targets,
not a promise to complete all of them in a single release.

## Release decision

4.4 is reasonable to release when all four gates have evidence, no known unresolved
data-loss or silent-output-correctness issue affects enabled supported flows, and
remaining limitations have explicit dispositions. A green test suite alone is
insufficient, but finishing the whole improvement roadmap is unnecessary.

Recommended next work: resolve attribution and triage the six risk topics first;
then execute the bounded live matrix, fix its findings, and validate the candidate.
Estimate a release date after those first two activities establish the actual
remaining defects. This plan does not authorize implementation or publication.
