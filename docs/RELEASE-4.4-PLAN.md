# 4.4 release plan — Stabilization and release readiness

Status: proposed release scope; no release readiness claimed.
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
- [ ] Prepare accurate 4.4 release notes and version/build metadata. The checked-in
  changelog and marketing version still say 4.3.0 at planning time; reconcile the
  actual changes since the stable release rather than relabel historical entries.

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
