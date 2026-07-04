# Roadmap

## Audio file naming convention

Sliced audio (from `../ableton-slicer/sliced`) is named:

```
<bpm>-<trackname><section>-<optional variation number>-<total-length>
```

e.g. `114-Noisestep-beats-pre-1-40`, `114-pianoloop-piano intro-11-40`,
`114-Noisestep intro-72`.

- `<total-length>` is the **factual** length of the slice in beats **at its
  native BPM** (tail included).
- The trailing beats are a **tail** that rings out under the following segment:
  **8 beats for 114 BPM**, **16 beats for 171 BPM** (doubled so reverb isn't
  chopped — see below). Musical length = `total-length − tail` (native beats).
- The segment's `length_beats` is that musical length converted to the internal
  171-BPM clock: `length_beats = (total-length − tail) × 171 / native_bpm`
  (see CLAUDE.md "×3/2 trick"). E.g. native-114 `-40` (tail 8) → `48`;
  native-171 `-48` (tail 16) → `32`.
- `<optional variation number>` maps to entries in a segment's `audio` list
  (interchangeable variations).

## Tempo: resolved via internal 171 clock

Mixed 114/171 BPM tracks are handled by running the beat clock at **171** (=
114 × 3/2) and scaling every `length_beats` accordingly. All current musical
lengths land on whole 171-beats, so no per-track `bpm` field was needed. If a
future track's tempo is not a clean ratio of 171, per-track tempo support (or a
finer sub-beat clock) becomes necessary.

## Unfinished / to revisit

- **guitar gods, aphex, dnb** — arranged but rough (simple linear builds).
  `aphex` is build-only (no drop/ending). Flesh out transitions later.
- **guitar gods intro is 7/8** — fires on the uniform beat grid like everything
  else; revisit if the meter change needs special handling.