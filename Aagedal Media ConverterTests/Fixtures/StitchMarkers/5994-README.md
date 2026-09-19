# Resolve 59.94 DF current-source acceptance — 2026-09-19

Resolve Studio **21.1.0.14**, macOS **27.0 (26A428)**, project **Aagedal 5994
Marker Acceptance 20260919**, timeline **5994 DF current sources**. The timeline
was created at 59.94 DF and `00:00:58;00` before importing any markers.

The September 19 Debug player build opened the generated source pair and loaded
the unchanged eight-finding review. **Notes → Open Notes Copy…** selected the
separate seven-finding `resolve-unique.aagedal-compare.json`; **Export → DaVinci
Resolve Markers (.edl)…** saved the unmodified EDL retained here. Only Fixture 5,
the duplicate anchor, is excluded by that prepared copy. No source or original
review was edited. `native-export-provenance.json` retains app source revision,
binary identity and post-import input hashes. This is native workflow evidence,
not a new optimized Release candidate verification.

The user performed **Timelines → Import → Timeline Markers from EDL** through
Resolve's media-pool timeline menu. The read-only
`scripts/capture-resolve-marker-snapshot.lua` then captured the actual timeline
records in `native-snapshot.json`. All seven markers match the original EDL:

| Relative frame | Source timecode | Duration in frames |
| --- | --- | --- |
| 0 | 00:00:58;00 | 1 |
| 1 | 00:00:58;01 | 1 |
| 119 | 00:00:59;59 | 3 |
| 120 | 00:01:00;04 | 1 |
| 32483 | 00:09:59;59 | 3 |
| 32484 | 00:10:00;00 | 1 |
| 36562 | 00:11:08;02 | 1 |

Exact Unicode/tab text, classifications, colors and current A/B URLs survive
in the API's `name` field; `note` remains empty. The API also identifies the
actual V1 clip as `/private/tmp/aagedal-resolve-5994-20260919/source-a.mov`,
59.94 fps, starting at `00:00:58;00`, with 36,563 source frames. Its untrimmed
placement spans timeline frames 3,480–40,043 (exclusive end), matching the
timeline bounds. Source B is retained in marker provenance, not loaded as a
second Resolve clip.

The user's native **Timeline Markers to EDL** re-export passes the strict
comparison: **7/7 exact records**, no missing or unexpected events. Resolve
saved the file as `resolve-roundtrip.edl.edl`; the retained copy is named
`resolve-roundtrip.edl` with identical bytes. Its SHA-256 is
`28b67ea9e3ddd30fa39400d42db437ae9c12ea19e7a72d89a66ef04203a0f896`.
`native-roundtrip-comparison.json` combines the passing EDL comparison,
native snapshot validation and fresh post-export hashes of both media files
and both reviews. This closes the focused 59.94 DF current-source round trip.

Recheck the retained EDL bytes independently of the disposable media:

```sh
python3 scripts/validate-resolve-marker-roundtrip.py \
  docs/evidence/resolve-markers-5994-20260919/source-a_vs_source-b_review.edl \
  docs/evidence/resolve-markers-5994-20260919/resolve-roundtrip.edl \
  --rate 60000/1001 --editor-version 21.1.0.14 \
  --output /tmp/aagedal-resolve-5994-recheck.json
```

To also recheck native identity and fixture hashes while the original fixture
remains available, add `--native-snapshot
docs/evidence/resolve-markers-5994-20260919/native-snapshot.json` and
`--fixture-manifest
/private/tmp/aagedal-resolve-5994-20260919/fixture-manifest.json`.
Use a new output path for each run.

The manifest and both sidecars are retained here. The generated movies remain
at `/private/tmp/aagedal-resolve-5994-20260919`; the manifest's file-provenance
check must use that original location. Moving these evidence copies does not
move or relink the fixture. Same-frame findings remain explicitly unsupported
in Resolve EDL export; 23.976 and other-editor acceptance remain separate gates.
