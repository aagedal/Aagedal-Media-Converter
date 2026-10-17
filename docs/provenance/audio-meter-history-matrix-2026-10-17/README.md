# Timestamp-history matrix evidence

The linked [method and limits](../../audio-playback-history-matrix-2026-10-17.md)
describe these isolated experimental captures. They do not qualify presentation
or device synchronization and did not change the application's dependencies.

Reports retain the probe commands, source/tool/fixture hashes, per-case acceptance
checks, reference-sample comparisons and diagnostic clock offsets. Each capture
is an xz-compressed original JSONL stream; recompression preserves its bytes but
changes the compressed-file hash, which the retained report records. Fixture MOVs
and executable products stay outside the repository; regenerate them with the
runner and matching inputs for replay. The first-sample reference model assumes
these generated continuous stereo streams.

The build record reuses the prior instrumented candidate's object/archive and
records the new probe link command and hashes. It is not a clean dependency
rebuild or a distributable package. The lifecycle capture separately checks the
original pause/resume/seek/speed/filter-reinsertion path with video selected;
its reset attribution remains heuristic and its final/reset coverage unqualified.
