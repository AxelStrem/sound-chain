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
    `sound_arrangement_pianoloops.json` and `sound_arrangement_noisestep.json`.
    **These are the files you edit to change an arrangement.**
- **Audio:** `segments/*.wav` (+ Godot `.wav.import` sidecars). Global tempo is
  **114 BPM** (~0.526 s/beat), so a 32-beat segment ≈ 16.8 s and 64 beats ≈ 33.7 s.

Each track is its own connected graph and walks transitions forever. Tracks are
joined by the reserved `END_TRACK` next-target: reaching it ends the current
track and the engine jumps to a *different* eligible track (see below). It never
dead-ends — every terminal path hits `END_TRACK` and continues elsewhere.

---

## Metadata file structure

### Main file (`sound_chain_metadata.json`)

| Field             | Meaning |
|-------------------|---------|
| `bpm`             | Global tempo. Drives the beat clock (`60 / bpm` seconds per beat). |
| `lookahead_beats` | How many beats **before** a segment ends the engine pre-selects the next one (default 2). Gives the audio time to be loaded/queued so playback is seamless. |
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
| `length_beats` | Length in beats. Determines when the next segment fires. |
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

Fifteen piano loops, files `segments/114-piano-loop-1.wav` … `-15.wav`
(114 BPM, each 32 beats). This is the "home" track and the default start.

Each loop `N` is represented by **two segments** sharing the same audio:

- `114-piano-loop-Na` — first pass. Always transitions to `…-Nb`.
- `114-piano-loop-Nb` — second pass. Transitions to **any other loop**.

**Behaviour (verified against the data):**

```
loop-Na  ──(1.0)──▶  loop-Nb                       # every loop plays exactly TWICE
loop-Nb  ──(1.0 each)──▶  loop-Ma   for every M ≠ N   # then jump to any OTHER loop
loop-Nb  ──(0.5)──▶  END_TRACK                     # ~3.3% chance to leave for another track
```

So a loop always plays through twice (`a` then `b`), then jumps to a *different*
loop chosen uniformly (never repeating itself back-to-back). Each `b` pass also
has a small (weight 0.5 ≈ 3.3%) chance to hit `END_TRACK` and hand off to another
track (with two tracks that means noisestep).

- **Start:** `114-piano-loop-1a` (weight 1.0 in this track's `start_segments`).
- All 30 segments use `progress [[0.0, 1.0]]` (always eligible).

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
  whenever another track hits `END_TRACK` (e.g. a piano `b` pass — ~3.3%).
- **Leave:** `ending` (100%) and `weird-atmo` route to `END_TRACK`, so the
  engine hands back to track selection (a *different* eligible track — with two
  tracks, the piano) and never truly stops.