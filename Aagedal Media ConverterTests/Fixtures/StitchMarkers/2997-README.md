# Fresh Resolve marker round trip — 2026-09-19

Resolve Studio 21.1.0.14, project **Aagedal Adjacent Marker Acceptance
20260919**, timeline **Unique markers semicolon**, 29.97 DF with start
`00:00:58;00` set before the first marker import. The user performed the native
**Timelines → Import → Timeline Markers from EDL** action.

The seven-finding import passes: relative frames `0, 1, 59, 60, 16241, 16242,
18280`, durations `1, 1, 3, 1, 3, 1, 1`. Exact marker text, including Unicode,
tabs, classification labels and historical source URLs, is preserved in the
API's `name` field; the API's `note` field is empty. No extra markers exist.
First/adjacent frames and minute/ten-minute DF boundaries are correct.

- `unique-markers.edl`: September 15 native app export with only event 005
  (Fixture 5, duplicate relative frame 60) omitted. No positions were changed.
- `resolve-marker-api.tsv`: actual read-only `GetMarkers()` results captured
  through Resolve's Lua console after import. Tabs/newlines inside text fields
  are escaped as `\t`/`\n`; metadata precedes the tabular header.
- `native-import-validation.json`: exact frame/duration/color/text comparison
  against that EDL, input/API hashes and unchanged-media/sidecar verification.
- `fixture-manifest.json`: fresh generated media/sidecar identities. The movies
  and original eight-finding sidecar remain outside the repository at
  `/private/tmp/aagedal-resolve-adjacent-20260919`.
- `resolve-roundtrip.edl`: the user's native **Timeline Markers to EDL**
  re-export from this timeline, retained byte-for-byte (3,956 bytes).
- `native-roundtrip-comparison.json`: passing strict comparison of all seven
  anchors, durations, colors and exact texts; no missing or unexpected events.
- `post-export-source-validation.json`: fresh post-export hashes confirming
  that both generated movies and the original eight-finding sidecar are unchanged.

The prior adjacent-frame displacement does not reproduce in this fresh import.
Its earlier cause is not established; no coordinate fix is justified by this
result. Same-frame findings remain deliberately rejected by the app exporter.

Native re-export passes at `30000/1001`: all seven findings survive, including
first/adjacent frames, minute/ten-minute DF boundaries and three-frame ranges.
The returned EDL SHA-256 is
`7939e17ae765f1efb723adc2aaf3c2093eff11f41e1f783cbaecfd92e184d256`.
Reproduce the comparison from the repository root:

```sh
python3 scripts/validate-resolve-marker-roundtrip.py \
  docs/evidence/resolve-markers-20260919/unique-markers.edl \
  docs/evidence/resolve-markers-20260919/resolve-roundtrip.edl \
  --rate 30000/1001 --editor-version 21.1.0.14 \
  --output /tmp/aagedal-resolve-roundtrip-recheck.json
```

The output path must not already exist. This reduced diagnostic does not establish
complete editor acceptance: it retains historical source URLs from September
15 rather than the fresh generated media paths, omits one finding, and covers
only 29.97 DF. Other rates, current-source identity and other editors remain
separate gates. See [the interchange run sheet](../../COMPARE_MODE_INTERCHANGE.md).
