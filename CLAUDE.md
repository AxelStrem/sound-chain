# CLAUDE.md

Procedural soundtrack generator for Godot 4. Audio is chopped into short
segments that are strung together at runtime via a weighted-random **Markov
chain**, so the music is arranged differently every playthrough while staying
beat-aligned.

- **Engine:** `sound_chain.gd` (autoload-style `Node`). Public API documented in
  its header — `load_metadata()`, `start(seed)`, `set_progress()`, `pause()`,
  `stop()`, etc.
- **Data:** `sound_chain_metadata.json` — defines every segment and the
  transition graph. **This is the file you edit to change the arrangement.**
- **Audio:** `segments/*.wav` (+ Godot `.wav.import` sidecars). Global tempo is
  **114 BPM** (~0.526 s/beat), so a 32-beat segment ≈ 16.8 s and 64 beats ≈ 33.7 s.

Everything is one connected graph: a playthrough starts at a `start_segments`
entry and walks transitions forever (it never dead-ends — every terminal path
loops back into the piano track).

---

## Metadata file structure

Top-level object:

| Field             | Meaning |
|-------------------|---------|
| `bpm`             | Global tempo. Drives the beat clock (`60 / bpm` seconds per beat). |
| `lookahead_beats` | How many beats **before** a segment ends the engine pre-selects the next one (default 2). Gives the audio time to be loaded/queued so playback is seamless. |
| `start_segments`  | `{ name: weight }` — where a playthrough can begin. Weighted random, progress-filtered. |
| `segments`        | Array of segment objects (below). |

Each entry in `segments`:

| Field          | Meaning |
|----------------|---------|
| `name`         | Unique id. Referenced by `start_segments` and every `next` table. |
| `audio`        | Audio file, **without extension**, resolved as `res://segments/<audio>.wav` (falls back to `.ogg`). May also be a bare filename with extension or a full `res://`/absolute path. |
| `progress`     | List of `[lo, hi]` intervals in `[0, 1]`. The segment is only eligible when the current `progress` value (set via `set_progress()`) falls inside one of them. `[[0.0, 1.0]]` = always eligible. |
| `length_beats` | Length in beats. Determines when the next segment fires. |
| `next`         | `{ name: weight }` transition table. Weights are **relative** (the engine normalizes by their sum), so `1.0 / 0.5 / 0.2` just express ratios, not probabilities. |

### Selection rules (how the engine walks the graph)

- **Weighted random:** among a `next`/`start` table, candidates are filtered to
  those eligible for the current `progress`, then chosen proportional to weight.
- **Progress filtering:** ineligible segments are skipped; if *none* are
  eligible, the engine falls back to the candidate whose `progress` interval is
  nearest the current value.
- **Memoryless:** selection depends only on the *current* segment, not history.
  A graph therefore cannot enforce "visit each of N once" — it can only
  approximate it with probabilities (see the piano/beat-pre notes below).
- **Dead-ends** (empty `next`) simply stop playback. None currently exist.

> Note: `sound_chain_metadata.json` is machine-formatted with 2-space indent.
> Prefer editing it with a script (load JSON → mutate → dump) rather than by
> hand — the transition tables are large and easy to desync.

---

## Song: Piano loops (`114-piano-loop-*`)

Fifteen piano loops, files `segments/114-piano-loop-1.wav` … `-15.wav`
(114 BPM, each 32 beats). This is the "home" track and the default start.

Each loop `N` is represented by **two segments** sharing the same audio:

- `114-piano-loop-Na` — first pass. Always transitions to `…-Nb`.
- `114-piano-loop-Nb` — second pass. Transitions to **any other loop**.

**Behaviour (verified against the data):**

```
loop-Na  ──(1.0)──▶  loop-Nb                       # every loop plays exactly TWICE
loop-Nb  ──(1.0 each)──▶  loop-Ma   for every M ≠ N   # then jump to any OTHER loop
loop-Nb  ──(0.5)──▶  114-noisestep-intro           # ~3.3% chance to enter the noisestep track
```

So a loop always plays through twice (`a` then `b`), then jumps to a *different*
loop chosen uniformly (never repeating itself back-to-back). Each `b` pass also
has a small (weight 0.5 ≈ 3.3%) chance to hand off to the noisestep intro.

- **Start:** `114-piano-loop-1a` (weight 1.0 in `start_segments`).
- All 30 segments use `progress [[0.0, 1.0]]` (always eligible).

---

## Song: Noisestep (`114-noisestep-*`)

A structured drop-based track (114 BPM) arranged as intro → build → drop →
aftermath, with probabilistic "weirdness" detours. Segments are 32 beats except
`intro`, `inbeat`, and `weird-atmo`, which are 64 beats (16 bars).

### Flow

```
intro ─▶ inbeat ─▶ beat-pre{1..4} ⇄ (other pre | drop | weird-1/2/3 | no-drums)
drop  ─▶ afterdrop{1,2}
afterdrop ⇄ (other afterdrop | ending | weird-4/5/6 | no-drums | atmo)
ending ─▶ 114-piano-loop-1a            # hands back to the piano track
```

### Segments & transitions

| Segment                     | Beats | `next` (weights) |
|-----------------------------|-------|------------------|
| `intro`                     | 64    | `inbeat` 1.0 |
| `inbeat`                    | 64    | `beat-pre-1..4` 1.0 each |
| `beat-pre-1..4`             | 32    | other 3 pres 1.0 · `drop` 1.0 · `weird-1/2/3` 0.2 · `no-drums` 0.15 |
| `drop`                      | 32    | `afterdrop-1` 1.0 · `afterdrop-2` 1.0 |
| `afterdrop-1/2`             | 32    | other afterdrop 1.0 · `ending` 0.5 · `weird-4/5/6` 0.35 · `no-drums` 0.25 · `atmo` 0.2 |
| `ending`                    | 32    | `114-piano-loop-1a` 1.0 |
| `weird-1/2/3` (build-zone)  | 32    | `beat-pre-1..4` 1.0 · `drop` 0.5 · other build-weirds 0.15 |
| `weird-4/5/6` (drop-zone)   | 32    | `afterdrop-1/2` 1.0 · `ending` 0.5 · other drop-weirds 0.15 |
| `weird-no-drums01`          | 32    | `beat-pre-1..4` 1.0 · `afterdrop-1/2` 1.0 · all weirds 0.1 |
| `weird-atmo`                | 64    | `ending` 1.0 · `114-piano-loop-1a` 1.0 |

### Design rules baked into the weights

- **Must start `intro → inbeat`**, then build through the `beat-pre` pool before
  the drop.
- **~4 beat-pre segments before dropping:** from any `beat-pre`, the 3 other
  pres and `drop` are equally weighted (~21% each), so on average ~4 pre
  segments play before the drop. (Memoryless — it *approximates* a random
  permutation of the four; it can't guarantee no repeats.)
- **`drop` always → an afterdrop**, which then ping-pongs / heads to `ending`.
- **Weirdness is split by zone:** `weird-1/2/3` live in the build (return to
  beat-pre / drop); `weird-4/5/6` live in the aftermath (return to afterdrop /
  ending). `weird-no-drums01` is shared (returns to either zone). `weird-atmo`
  is a 64-beat breakdown reachable **only from afterdrop**, exiting to `ending`
  or the piano track.
- **Weirdness by zone:** in the *build* zone weirdness stays subordinate — the
  aggregate probability of entering a weird segment is below that node's
  smallest "proper" transition (beat-pre 15.8% < 21.1%). In the *drop* zone it
  is deliberately dominant (afterdrop P(weird) ≈ 50%) and `ending` is weighted
  low (16.7%) so the aftermath lingers instead of bailing out early — the
  section now averages ~6 segments before the ending (was ~2.3). Scale the
  afterdrop `0.35 / 0.25 / 0.2` weird weights up (or `ending` 0.5 down) to
  stretch it further.

### Entering / leaving the track

- **Enter:** as a `start_segments` entry (`114-noisestep-intro`, weight 1.0,
  50/50 with the piano start) **or** organically — every `114-piano-loop-Nb`
  has a weight-0.5 (~3.3%) edge into `114-noisestep-intro`.
- **Leave:** `ending` (and `weird-atmo`) hand back to `114-piano-loop-1a`, so
  the arrangement flows back into the piano track and never truly stops.