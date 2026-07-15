# CLAUDE.md

Procedural soundtrack generator for Godot 4. Audio is chopped into short
segments that are strung together at runtime via a weighted-random **Markov
chain**, so the music is arranged differently every playthrough while staying
beat-aligned.

- **Engine:** `sound_chain.gd` (autoload-style `Node`). Public API documented in
  its header — `load_metadata()`, `start(seed)`, `set_progress()`, `pause()`,
  `stop()`, etc.
- **Data:** split across files (merged on load):
  - `sound_chain_metadata.json` — the **main** file: global settings + the
	`tracks` table (which tracks exist, their weight and progress range).
  - `sound_arrangement_<track>.json` — one per **track**, holding that track's
    own `start_segments` + `segments` (the transition graph). Currently
    `pianoloops`, `noisestep`, `guitargods` (all natively 114 BPM), `aphex` and
    `dnb` (natively 171 BPM). **These are the files you edit to change an
    arrangement.**
- **Audio:** `segments/*.wav` (+ Godot `.wav.import` sidecars). Files are named
  `<native-bpm>-<track><section>-<variation?>-<total-length>`; the slice's
  factual length is `total-length` beats **at its native BPM**, and its musical
  length is `total-length − tail`, where the tail that rings out under the next
  segment is **8 beats at 114 BPM** and **16 beats at 171 BPM**.

### Internal clock is 171 BPM (the "×3/2 trick")

The engine has one global beat clock, but tracks are authored at two tempos
(114 and 171, and `171 = 114 × 3/2`). To keep every `length_beats` a whole
number, the **internal `bpm` is 171** and each segment's `length_beats` is its
musical length expressed in 171-beat units:

```
length_beats = (total_length − tail) × 171 / native_bpm      (tail: 8 @114, 16 @171)
```

- native **171** segments: `×1` → musical beats used directly (e.g. `48−16=32`).
- native **114** segments: `×3/2` (all their musical lengths are even, so this
  stays integer, e.g. `32→48`, `64→96`, `16→24`, `56→84`).

The audio always plays at its own recorded speed (pitch unchanged); the internal
BPM only sets *when* the next segment fires. So a 114 loop still sounds like 114
— its `length_beats` is just counted on the faster 171 clock. See `roadmap.md`
for the naming convention.

Each track is its own connected graph and walks transitions forever. Tracks are
joined by the reserved `END_TRACK` next-target: reaching it ends the current
track and the engine jumps to a *different* eligible track (see below). It never
dead-ends — every terminal path hits `END_TRACK` and continues elsewhere.

---

## Metadata file structure

### Main file (`sound_chain_metadata.json`)

| Field             | Meaning |
|-------------------|---------|
| `bpm`             | Internal beat-clock tempo (`60 / bpm` s/beat). **171** — see the "×3/2 trick" above; it is not each track's native tempo. |
| `lookahead_beats` | How many beats **before** a segment ends the engine pre-selects the next one (currently 3). Gives the audio time to be loaded/queued so playback is seamless. |
| `tracks`          | `{ name: { probability, progress } }` — the tracks the soundtrack can play. `probability` is the relative selection weight; `progress` is a list of `[lo, hi]` intervals (same format/semantics as a segment's, see below) gating when the track is eligible. Each track's graph is loaded from `sound_arrangement_<name>.json` next to this file (override with an optional `"file"` field). |

### Arrangement files (`sound_arrangement_<track>.json`)

| Field            | Meaning |
|------------------|---------|
| `start_segments` | `{ name: weight }` — where a playthrough *into this track* can begin. Weighted random, progress-filtered. |
| `segments`       | Array of segment objects (below). |

Each entry in `segments`:

| Field          | Meaning |
|----------------|---------|
| `name`         | Unique id (unique across **all** tracks — they share one merged lookup). Referenced by `start_segments` and every `next` table. |
| `audio`        | **List** of interchangeable *variations* — one is picked at random every time the segment starts (they're musically equivalent, so it doesn't matter which). A single-entry list always plays that entry. Each entry is an audio file **without extension**, resolved as `res://segments/<entry>.wav` (falls back to `.ogg`); it may also be a bare filename with extension or a full `res://`/absolute path. |
| `progress`     | List of `[lo, hi]` intervals in `[0, 1]`. The segment is only eligible when the current `progress` value (set via `set_progress()`) falls inside one of them. `[[0.0, 1.0]]` = always eligible. |
| `length_beats` | Length in **internal (171 BPM) beats** — determines when the next segment fires. Derived as `(total_length − tail) × 171 / native_bpm` (tail 8 @114, 16 @171; see the ×3/2 trick above). |
| `repeat`       | How many times the segment plays back-to-back before consulting `next`. Default `1`. Each pass re-triggers the audio (a fresh `audio` variation may be picked) but does **not** re-select from `next` until the last pass. |
| `max_repeats`  | Cap on how many times the segment may play back-to-back via a **self-loop in `next`**. Default `0` (unlimited). Once it has run this many consecutive times, the segment is dropped from its own `next` table for the following pick, forcing the walk elsewhere. Ignored when the self-loop is the segment's *only* `next` entry (excluding it would dead-end). Counts only next-driven self-loops — `repeat` passes don't count. |
| `next`         | `{ name: weight }` transition table. Weights are **relative** (the engine normalizes by their sum), so `1.0 / 0.5 / 0.2` just express ratios, not probabilities. The reserved target **`END_TRACK`** may appear here like any other key — selecting it ends the current track (see below). |

### Selection rules (how the engine walks the graph)

- **Weighted random:** among a `next`/`start` table, candidates are filtered to
  those eligible for the current `progress`, then chosen proportional to weight.
- **Progress filtering:** ineligible segments are skipped; if *none* are
  eligible, the engine falls back to the candidate whose `progress` interval is
  nearest the current value.
- **Memoryless:** selection depends only on the *current* segment, not history.
  A graph therefore cannot enforce "visit each of N once" — it can only
  approximate it with probabilities (see the piano/beat-pre notes below).
- **Starting / `END_TRACK`:** a playthrough begins by picking an eligible track
  (weighted by `probability`, progress-filtered) then a `start_segments` entry
  within it. Selecting `END_TRACK` in a `next` table does the same pick but
  **excludes the current track** (unless it is the only eligible one), so it
  always moves to a *different* track — then continues from that track's
  `start_segments`.
- **Dead-ends** (empty `next`) simply stop playback. None currently exist —
  every terminal path routes through `END_TRACK`.

> Note: these JSON files are machine-formatted with 2-space indent, except
> `progress` interval lists are collapsed onto one line (e.g. `[ [0.0, 1.0] ]`).
> Prefer editing them with a script (load JSON → mutate → dump) rather than by
> hand — the transition tables are large and easy to desync.

---

## Track: Piano loops (`sound_arrangement_pianoloops.json`)

Three distinct piano sections (114 BPM, each 32 beats musical / 40-beat slices),
each **one segment** with `repeat: 2` (plays twice before transitioning):

| Segment                     | `audio` variations |
|-----------------------------|--------------------|
| `114-pianoloop-columbo`     | `columbo-01/02` (2) |
| `114-pianoloop-jingle`      | `jingle-01/02` (2) |
| `114-pianoloop-piano-intro` | `piano intro-01…11` (11) |

**Behaviour:**

```
loop  ──(repeat 2)──▶ (plays twice; each pass may pick a different variation)
loop  ──(1.0 each)──▶  the OTHER two loops       # equally likely, never repeats itself
loop  ──(0.5)──▶  END_TRACK                      # leaves for another track
```

The three sections are kept **equally likely**: symmetric transitions (each →
the other two at weight 1.0) and equal `start_segments` weights, so no section
dominates despite `piano-intro` having more variations. This is the "home" track.

> Note: per loop, `P(END_TRACK) = 0.5 / (1 + 1 + 0.5) = 20%` — much higher than
> the old ~3.3%, because there are now only 3 loops to bounce between instead of
> 15. So the piano hands off to another track roughly every ~5 loops. Lower the
> `END_TRACK` weight if it should linger longer before leaving.

- **Start:** any of the three (weight 1.0 each in `start_segments`).
- All 3 segments use `progress [[0.0, 1.0]]` (always eligible).

---

## Track: Noisestep (`sound_arrangement_noisestep.json`)

A structured drop-based track (114 BPM) arranged as intro → build → drop →
aftermath, with probabilistic "weirdness" detours. Segments are 32 beats except
`intro`, `inbeat`, and `weird-atmo`, which are 64 beats (16 bars).

The old numbered siblings that were just interchangeable takes of the same role
are now collapsed into a single segment with an `audio` **variation list** (one
take chosen at random each time the segment plays):

- `beat-pre-1..4` → **`beat-pre`** (4 variations)
- `weird-1/2/3` (build-zone) → **`weird-build`** (3 variations)
- `weird-4/5/6` (drop-zone) → **`weird-drop`** (3 variations)
- `afterdrop-1/2` → **`afterdrop`** (2 variations)

Because the graph is memoryless anyway, cycling through the pool is now a
**self-loop**: e.g. `beat-pre` transitions back to `beat-pre` (picking a fresh
variation) instead of hopping between four separate nodes. The self-loop weight
is set so the old ratios (and thus the average section lengths) are preserved
exactly — the only behavioural change is that a variation may now repeat
back-to-back (harmless, since the takes are equivalent).

### Flow

```
intro ─▶ inbeat ─▶ beat-pre ⇄ (self | drop | weird-build | no-drums)
drop  ─▶ afterdrop
afterdrop ⇄ (self | ending | weird-drop | no-drums | atmo)
ending ─▶ END_TRACK                    # 100% — hands back to track selection
```

### Segments & transitions

| Segment                    | Beats | Variations | `next` (weights) |
|----------------------------|-------|-----------|------------------|
| `intro`                    | 64    | 1 | `inbeat` 1.0 |
| `inbeat`                   | 64    | 1 | `beat-pre` 1.0 |
| `beat-pre`                 | 32    | 4 | self 3.0 · `drop` 1.0 · `weird-build` 0.6 · `no-drums` 0.15 |
| `drop`                     | 32    | 1 | `afterdrop` 1.0 |
| `afterdrop`                | 32    | 2 | self 1.0 · `ending` 0.4 · `weird-drop` 1.05 · `no-drums` 0.25 · `atmo` 0.2 |
| `ending`                   | 32    | 1 | `END_TRACK` 1.0 |
| `weird-build`              | 32    | 3 | `beat-pre` 4.0 · `drop` 0.5 · self 0.3 |
| `weird-drop`               | 32    | 3 | `afterdrop` 2.0 · `ending` 0.5 · self 0.3 |
| `weird-no-drums01`         | 32    | 1 | `beat-pre` 4.0 · `afterdrop` 2.0 · `weird-build` 0.3 · `weird-drop` 0.3 |
| `weird-atmo`               | 64    | 1 | `ending` 1.0 · `END_TRACK` 1.0 |

(Segment names above are prefixed `114-noisestep-`. The self-loop / collapsed
weights are the sums of the old per-sibling weights, so the probabilities are
identical to the pre-refactor graph.)

### Design rules baked into the weights

- **Must start `intro → inbeat`**, then build through the `beat-pre` pool before
  the drop.
- **~4 beat-pre segments before dropping:** `beat-pre` self-loops with weight
  3.0 vs `drop` 1.0 — i.e. staying in the pool is ~3× as likely as dropping, so
  on average ~4 pre segments play before the drop (each picking a random of the
  4 variations).
- **`drop` always → `afterdrop`**, which then self-loops / heads to `ending`.
- **Weirdness is split by zone:** `weird-build` lives in the build (returns to
  `beat-pre` / `drop`); `weird-drop` lives in the aftermath (returns to
  `afterdrop` / `ending`). `weird-no-drums01` is shared (returns to either
  zone). `weird-atmo` is a 64-beat breakdown reachable **only from afterdrop**,
  exiting to `ending` or `END_TRACK`.
- **Weirdness by zone:** in the *build* zone weirdness stays subordinate — the
  aggregate probability of entering a weird segment is below that node's
  smallest "proper" transition (beat-pre 15.8% < 21.1%). In the *drop* zone it
  is deliberately dominant (afterdrop P(weird) ≈ 50%) and `ending` is weighted
  low so the aftermath lingers instead of bailing out early. Scale the afterdrop
  `weird-drop 1.05 / no-drums 0.25 / atmo 0.2` weights up (or `ending` 0.4 down)
  to stretch it further.

### Entering / leaving the track

- **Enter:** the engine picks this track via the main `tracks` table (weighted
  by `probability`, progress-filtered) then its `start_segments`
  (`114-noisestep-intro`, weight 1.0). This happens on the initial `start()` or
  whenever another track hits `END_TRACK` and this one is chosen.
- **Leave:** `ending` (100%) and `weird-atmo` route to `END_TRACK`, so the
  engine hands back to track selection (a *different* eligible track, chosen
  among the other four) and never truly stops.

---

## Track: Guitar gods (`sound_arrangement_guitargods.json`)

Native 114 BPM (7/8-feel intro). Unfinished — a simple linear build:

```
intro (start) ─▶ loop-base ⇄ (self | breakdown)
breakdown ─▶ drop ─▶ full-harmony ──(repeat 2)──▶ END_TRACK
```

| Segment        | Vars | len(171) | `next` |
|----------------|------|----------|--------|
| `intro`        | 2    | 84 | `loop-base` 1.0 |
| `loop-base`    | 2    | 48 | self 2.0 · `breakdown` 1.0 |
| `breakdown`    | 1    | 48 | `drop` 1.0 |
| `drop`         | 1    | 24 | `full-harmony` 1.0 |
| `full-harmony` | 1    | 24 | `END_TRACK` 1.0 (`repeat: 2`) |

- Track-specific rule: **`breakdown` sits right before `drop`** (not a general
  convention). **Only `full-harmony` ends the track** — it plays twice then
  `END_TRACK`; nothing else leaves.

## Track: Aphex (`sound_arrangement_aphex.json`)

Native 171 BPM. Build-only (no drop/ending yet) — loops the `pre` then hands off:

```
intro (start) ─▶ pre ⇄ (self | END_TRACK 0.5)
```

| Segment | Vars | len(171) | `next` |
|---------|------|----------|--------|
| `intro` | 3    | 32 | `pre` 1.0 |
| `pre`   | 3    | 32 | self 1.0 · `END_TRACK` 0.5 |

## Track: DnB (`sound_arrangement_dnb.json`)

Native 171 BPM. Full arrangement: intro → build → beat → drop → tail-out.

```
intro (start) ─▶ pre ⇄ (self | beat)
beat ⇄ (self | breakdown)
breakdown ─▶ fullon ⇄ (self | breakdown | winddown)
winddown ─▶ outro ─▶ END_TRACK
```

| Segment     | Vars | len(171) | `next` |
|-------------|------|----------|--------|
| `intro`     | 1    | 64 | `pre` 1.0 |
| `pre`       | 1    | 32 | self 1.0 · `beat` 1.0 |
| `beat`      | 4    | 32 | self 2.0 · `breakdown` 1.0 |
| `breakdown` | 1    | 64 | `fullon` 1.0 |
| `fullon`    | 2    | 32 | self 1.0 · `breakdown` 0.5 · `winddown` 0.5 |
| `winddown`  | 1    | 32 | `outro` 1.0 |
| `outro`     | 1    | 32 | `END_TRACK` 1.0 |

- Track-specific rules: **`breakdown` sits right before `fullon`**; the drop can
  re-trigger (`fullon → breakdown`) for another go before it exits. The track
  **only ends through the tail-out** — `fullon → winddown → outro → END_TRACK`;
  `END_TRACK` is reachable only from `outro`.
- `beat` cycles four interchangeable takes as a self-loop (`beat 1`, `beat 2`,
  `beat 2 jingle`, `beat 3 jingle`); the ~2:1 self-vs-`breakdown` weight keeps it
  grooving ~3 bars before the drop. `fullon` variations: `dnb fullon` and
  `dnb fullon choir` — both 48-beat slices (musical 32), fully interchangeable.
