extends Node
## SoundChain — Procedural Markov-chain soundtrack generator.
##
## Plays audio segments sequentially, selected via weighted random from a
## Markov transition table.  Segment eligibility is filtered by a [0, 1]
## "progress" value so the soundtrack evolves with game state.
##
## The arrangement is split across several files: a main metadata file that
## lists the available "tracks" (each with a probability weight and an allowed
## progress range), plus one "sound_arrangement_<name>.json" per track holding
## that track's own start_segments + segments.  They are merged on load.  A
## segment may use the reserved next-target [constant END_TRACK] to end its
## track and let the engine pick a different eligible track to continue in.
##
## Usage (from any script):
##   SoundChain.set_audio_base_dir("res://audio/level1")
##   SoundChain.set_bus(&"Music")
##   SoundChain.load_metadata("res://my_soundtrack.json")
##   SoundChain.set_progress(0.3)
##   SoundChain.set_playback_speed(0.7)  # temporary slowdown effect
##   SoundChain.start(12345)
##   SoundChain.pause()
##   SoundChain.stop()
##
## --- Timing model ---
## Transitions are scheduled by Godot's native [AudioStreamInteractive]: one
## clip per segment, a single CLIP_ANY→CLIP_ANY transition firing at the
## outgoing clip's musical end (beat_count × 60 / bpm), executed on the audio
## thread sample-accurately.  This script only decides *which* clip comes next
## (the Markov walk) and queues it with switch_to_clip(); the engine owns all
## timing.  Because segment audio does not loop, the engine lets the outgoing
## clip ring out to its natural file end — the baked tail overlaps the next
## segment exactly like before.
##
## Two engine constraints shape the implementation:
##   * The AudioStreamInteractive resource must NOT be modified while playing
##     (set_clip_stream & co. bump an internal version and the playback kills
##     itself).  So each clip's stream is a [BeatSyncStream] wrapper whose
##     *contents* we swap to pick a variation — a separate resource, safe to
##     touch at runtime.  The wrapper also reports bpm/beat_count so END
##     transitions stay beat-aligned (all clips share the internal 171 grid;
##     beat_count = the segment's length_beats).
##   * get_current_clip_index() doesn't change on a self-transition, so
##     segments that can follow themselves (repeat > 1 or self in `next`) get
##     TWIN clips that alternate.  Every hop is then an observable clip-index
##     change: the walk advances purely on that event.  It also means the
##     pending clip is never the one currently sounding, making the variation
##     pool swap race-free.
## A frame-delta clock remains only to emit [signal beat_advanced] — it plays
## no part in scheduling.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const DEFAULT_LENGTH_BEATS  := 16

## AudioStreamInteractive's hard clip limit (MAX_CLIPS in the engine).
const MAX_INTERACTIVE_CLIPS := 63

## Special "next" target.  When selected it ends the current track and lets the
## engine jump to a different song (progress-filtered, weighted).  See
## [method _select_new_track].
const END_TRACK := "END_TRACK"


## Clip stream wrapper: holds the currently-chosen audio variation (pool of
## exactly one stream, swapped by [method _arm_clip]) and reports the beat
## metadata AudioStreamInteractive needs to schedule the END transition.
class BeatSyncStream extends AudioStreamRandomizer:
	var sync_bpm  := 0.0
	var sync_beats := 0
	func _get_bpm() -> float: return sync_bpm
	func _get_beat_count() -> int: return sync_beats

# ---------------------------------------------------------------------------
# Signals (for UI / debug — the walk itself does not depend on them)
# ---------------------------------------------------------------------------

## Emitted whenever a segment starts playing (including each `repeat` pass).
## [param segment_name]/[param track_name] are "" when playback stops.
signal segment_changed(segment_name: String, track_name: String)

## Emitted when playback starts, pauses/resumes, or stops.
signal playback_changed(playing: bool, paused: bool)

## Emitted once per beat while playing (carries the current absolute beat).
signal beat_advanced(beat: int)

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

var _metadata   := {}   ## Raw parsed JSON (main file)
var _segments   := {}   ## name → segment Dictionary (fast lookup, all tracks merged)
var _tracks     := {}   ## track name → { probability, progress, start_segments }
var _seg_track  := {}   ## segment name → owning track name
var _bpm        := 120.0
var _beat_secs  := 0.5

var _rng        := RandomNumberGenerator.new()
var _progress   := 0.0
var _playing    := false
var _paused     := false

var _beat       := 0    ## Current beat number (monotonically increasing)
var _cur_name   := ""   ## Currently-playing segment name
var _cur_seg    := {}   ## Currently-playing segment data
var _cur_track  := ""   ## Track owning the currently-playing segment
var _cur_variation := "" ## The `audio` variation chosen for the current pass
var _cur_clip   := -1   ## Clip index currently sounding
var _reps_left  := 0    ## Remaining extra `repeat` passes of the current segment
var _run_len    := 0    ## Consecutive fresh self-loops of _cur_name (for `max_repeats`)

var _next_name  := ""   ## Scratch: last result of _select_next()

## The hop we've asked the engine to make at the current clip's musical end.
## An empty _pending_seg means nothing is queued (dead end → playback winds
## down via the player's `finished` signal).
var _pending_seg  := ""
var _pending_clip := -1
var _pending_fresh := false  ## true = a real `next` pick; false = a `repeat` pass
var _pending_variation := ""

# Native interactive-audio playback
var _interactive : AudioStreamInteractive
var _player      : AudioStreamPlayer
var _playback    : AudioStreamPlaybackInteractive
var _clips_of   := {}   ## segment name → Array of clip indices ([primary] or [primary, twin])
var _clip_seg   : Array[String] = []  ## clip index → segment name
var _wrappers   := {}   ## clip index → BeatSyncStream
var _variations := {}   ## segment name → { streams: Array, names: Array }

# Beat clock for the beat_advanced signal only (no scheduling role).
var _play_elapsed_usec := 0
var _beat_usec         := 500_000

var _bus_name        := &"Master"       ## Audio bus for the player
var _audio_base      := "res://segments"  ## Base directory for segment audio files
var _playback_speed  := 1.0                ## Playback speed / pitch scale (1.0 = normal)
var _history         : Array[String] = []  ## Segment names in order since last start()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Load a metadata JSON file and prepare the playback engine.
## Call this once before [method start].
func load_metadata(path: String) -> void:
	stop()

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SoundChain: cannot open metadata file: " + path)
		return

	var text := f.get_as_text()
	f.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("SoundChain: JSON parse error in " + path + " → " + json.get_error_message())
		return

	_metadata = json.get_data()
	_bpm      = float(_metadata.get("bpm", 120.0))
	_beat_secs = 60.0 / _bpm

	_segments.clear()
	_tracks.clear()
	_seg_track.clear()

	var base_dir := path.get_base_dir()
	var tracks_cfg: Dictionary = _metadata.get("tracks", {})

	if tracks_cfg.is_empty():
		# Legacy layout: the main file carries its own segments/start_segments.
		_add_track("", _metadata.get("start_segments", {}), [[0.0, 1.0]],
			_metadata.get("segments", []), 1.0)
	else:
		for track_name in tracks_cfg:
			var cfg: Dictionary = tracks_cfg[track_name]
			var arr := _load_arrangement(track_name, cfg, base_dir)
			_add_track(track_name, arr.get("start_segments", {}),
				cfg.get("progress", []), arr.get("segments", []),
				float(cfg.get("probability", 1.0)))

	_recalc_beat_usec()
	_build_interactive()

	print("SoundChain: loaded %d tracks, %d segments (%d clips), %d BPM (%.3f s/beat)" %
		[_tracks.size(), _segments.size(), _clip_seg.size(), int(_bpm), _beat_secs])


## Load one track's arrangement file, returning its parsed dict (with
## "start_segments" + "segments"), or {} on failure.
## Path defaults to "<base_dir>/sound_arrangement_<track_name>.json" but a
## track's config may override it with an explicit "file" (absolute or
## base-relative).
func _load_arrangement(track_name: String, cfg: Dictionary, base_dir: String) -> Dictionary:
	var file_name: String = cfg.get("file", "sound_arrangement_%s.json" % track_name)
	var arr_path := file_name
	if not (arr_path.begins_with("res://") or arr_path.begins_with("user://") or arr_path.begins_with("/")):
		arr_path = base_dir + "/" + file_name

	var f := FileAccess.open(arr_path, FileAccess.READ)
	if f == null:
		push_error("SoundChain: cannot open arrangement '%s' for track '%s'" % [arr_path, track_name])
		return {}
	var text := f.get_as_text()
	f.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("SoundChain: JSON parse error in %s → %s" % [arr_path, json.get_error_message()])
		return {}
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		push_error("SoundChain: arrangement '%s' is not a JSON object" % arr_path)
		return {}
	return data


## Register a track: merge its segments into the global lookup and remember its
## start table, allowed progress range and selection weight.
func _add_track(track_name: String, start_segments: Dictionary, progress: Array,
		segments: Array, probability: float) -> void:
	for seg in segments:
		var nm: String = seg.get("name", "")
		if nm == "":
			push_warning("SoundChain: segment entry missing 'name' in track '%s', skipped" % track_name)
			continue
		_segments[nm] = seg
		_seg_track[nm] = track_name

	_tracks[track_name] = {
		"probability": probability,
		"progress": progress,
		"start_segments": start_segments,
	}


## True when a segment can be followed by itself (a `repeat` pass or a
## self-loop in `next`) — such segments need a twin clip (see header).
func _self_following(seg: Dictionary, name: String) -> bool:
	if int(seg.get("repeat", 1)) > 1:
		return true
	return (seg.get("next", {}) as Dictionary).has(name)


## Build the AudioStreamInteractive: one clip per segment (two for segments
## that can follow themselves), each holding a BeatSyncStream wrapper with the
## shared 171-grid beat metadata.  All variation audio is preloaded here (no
## runtime load hitches).  One wildcard END transition covers every clip pair.
## The resource is never modified after playback starts.
func _build_interactive() -> void:
	_interactive = AudioStreamInteractive.new()
	_clips_of.clear()
	_clip_seg.clear()
	_wrappers.clear()
	_variations.clear()

	# Preload every segment's variation streams.
	for name in _segments:
		var seg: Dictionary = _segments[name]
		var streams: Array = []
		var names: Array = []
		for entry in seg.get("audio", []):
			var path := _resolve_entry_path(str(entry), name)
			if path == "":
				continue
			var s := _load_stream(path)
			if s == null:
				push_warning("SoundChain: failed to load '%s' for segment '%s'" % [path, name])
				continue
			streams.append(s)
			names.append(str(entry))
		if streams.is_empty():
			# Fallback: try <segment name>.ogg/.wav
			var path := _resolve_entry_path(name, name)
			if path != "":
				var s := _load_stream(path)
				if s != null:
					streams.append(s)
					names.append(name)
		if streams.is_empty():
			push_error("SoundChain: no audio for segment '%s'" % name)
		_variations[name] = { "streams": streams, "names": names }

	# Plan the clip layout.
	var total := 0
	for name in _segments:
		total += 2 if _self_following(_segments[name], name) else 1
	if total > MAX_INTERACTIVE_CLIPS:
		push_error("SoundChain: %d clips exceed AudioStreamInteractive's limit of %d" %
			[total, MAX_INTERACTIVE_CLIPS])
	_interactive.clip_count = total

	var idx := 0
	for name in _segments:
		var seg: Dictionary = _segments[name]
		var copies := 2 if _self_following(seg, name) else 1
		var arr := []
		for c in copies:
			var w := BeatSyncStream.new()
			w.sync_bpm = _bpm
			w.sync_beats = int(seg.get("length_beats", DEFAULT_LENGTH_BEATS))
			w.random_pitch = 1.0
			w.random_volume_offset_db = 0.0
			var streams: Array = _variations[name]["streams"]
			if not streams.is_empty():
				w.add_stream(0, streams[0])
			_interactive.set_clip_name(idx, name if c == 0 else name + "#2")
			_interactive.set_clip_stream(idx, w)
			_wrappers[idx] = w
			_clip_seg.append(name)
			arr.append(idx)
			idx += 1
		_clips_of[name] = arr

	# One wildcard transition: fire at the outgoing clip's musical end, start
	# the incoming at its beginning, no fades — non-looping sources ring out to
	# their natural file end (the baked tail overlaps the next clip).
	_interactive.add_transition(
		AudioStreamInteractive.CLIP_ANY, AudioStreamInteractive.CLIP_ANY,
		AudioStreamInteractive.TRANSITION_FROM_TIME_END,
		AudioStreamInteractive.TRANSITION_TO_TIME_START,
		AudioStreamInteractive.FADE_DISABLED, 1.0, false, -1, false)

	if _player:
		_player.stream = _interactive


## Start a new playthrough with a normal metadata-driven pick (weighted,
## progress-filtered track + start segment).  [param seed_value] seeds the RNG so
## the same seed + progress trajectory yields the same sequence; pass a negative
## value (the default) to seed randomly.
func start(seed_value: int = -1) -> void:
	_begin(_select_start(), seed_value)


## Start a playthrough at a weighted, progress-filtered start segment of the
## given track.  Used by the UI to jump straight into a specific track.
func start_track(track_name: String, seed_value: int = -1) -> void:
	if not _tracks.has(track_name):
		push_error("SoundChain: unknown track '%s'" % track_name)
		return
	_begin(_select_start_in_track(track_name), seed_value)


## Start a playthrough at an exact segment, bypassing start-segment selection.
## Used by the UI to jump straight into a specific segment.
func start_segment_at(seg_name: String, seed_value: int = -1) -> void:
	if not _segments.has(seg_name):
		push_error("SoundChain: unknown segment '%s'" % seg_name)
		return
	_begin(seg_name, seed_value)


## Shared playthrough kick-off: seed the RNG, arm state and play [param first].
func _begin(first: String, seed_value: int) -> void:
	stop()
	if _segments.is_empty() or _interactive == null:
		push_error("SoundChain: no metadata loaded — call load_metadata() first")
		return

	if first == "":
		push_error("SoundChain: no start segment could be selected")
		return

	_rng.set_seed(seed_value if seed_value >= 0 else randi())
	_beat = 0
	_play_elapsed_usec = 0
	_playing = true
	_paused  = false

	var clip: int = _clips_of[first][0]
	_interactive.initial_clip = clip   # resource not playing yet — safe
	var v := _arm_clip(clip, first)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamPlaybackInteractive

	_promote(first, clip, true, v)
	playback_changed.emit(_playing, _paused)


## Toggle pause.  Player audio (and thereby the engine's transition timing) and
## the beat clock are frozen together.
func pause() -> void:
	if not _playing:
		return
	_paused = not _paused
	if _player:
		_player.stream_paused = _paused
	playback_changed.emit(_playing, _paused)


## Stop playback immediately and release the player.
func stop() -> void:
	_stop_all()


## Skip to the next segment right now, bypassing any remaining `repeat` passes.
## Resolves the current segment's `next` table (including END_TRACK) exactly as
## the automatic hand-off would.  No-op unless actively playing.
##
## Unlike an automatic boundary transition (where the outgoing tail rings out
## under the next), a manual skip cuts the current audio and restarts playback
## at the target — matching the old skip's hard cut.
func skip() -> void:
	if not is_playing() or _cur_name == "":
		return
	_reps_left = 0
	_select_next()
	if _next_name == "":
		return
	var target := _next_name
	_player.stop()
	var clip: int = _clips_of[target][0]
	_interactive.initial_clip = clip   # not playing during the swap — safe
	var v := _arm_clip(clip, target)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamPlaybackInteractive
	_promote(target, clip, true, v)


## Update the progress value [0.0, 1.0].  If a next segment has already been
## queued, its validity is re-checked and may trigger a re-selection (the new
## switch request simply replaces the previous one in the engine).
func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)

	# Only a real (non-repeat) queued pick can become progress-invalid.
	if _playing and _pending_seg != "" and _pending_fresh:
		if not _valid_for_progress(_segments.get(_pending_seg, {})):
			_select_next()
			if _next_name != "":
				_pending_seg = _next_name
				_pending_clip = _pick_clip(_pending_seg)
				_pending_variation = _arm_clip(_pending_clip, _pending_seg)
				if _playback:
					_playback.switch_to_clip(_pending_clip)


## Returns true when playback is active and not paused.
func is_playing() -> bool:
	return _playing and not _paused


## Set the audio bus used by the player.  Call before [method start];
## the existing player is updated immediately.
func set_bus(bus: StringName) -> void:
	_bus_name = bus
	if _player and is_instance_valid(_player):
		_player.bus = _bus_name


## Set the base directory for resolving segment audio files whose path is not
## explicitly given in metadata.  Default is "res://segments".
func set_audio_base_dir(path: String) -> void:
	_audio_base = path


## Set output volume on the active bus.  [param linear] is 0..1 (0 = silent,
## 1 = 0 dB / unchanged).
func set_volume(linear: float) -> void:
	var idx := AudioServer.get_bus_index(_bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(linear, 0.0, 1.0)))


## Current output volume of the active bus as a 0..1 linear value.
func get_volume() -> float:
	var idx := AudioServer.get_bus_index(_bus_name)
	if idx < 0:
		return 1.0
	return db_to_linear(AudioServer.get_bus_volume_db(idx))


## Set playback speed (1.0 = normal, 0.5 = half, 2.0 = double).
## Changes pitch as well — intended for temporary sound effects.  The engine's
## transition timing scales with the audio automatically.
func set_playback_speed(speed: float) -> void:
	_playback_speed = maxf(0.05, speed)
	_recalc_beat_usec()
	if _player and is_instance_valid(_player):
		_player.pitch_scale = _playback_speed


## Read-only accessors (useful for debug / UI).
func get_progress() -> float:  return _progress
func get_bpm() -> float:       return _bpm
func get_playback_speed() -> float: return _playback_speed
func get_current_segment() -> String: return _cur_name
func get_current_track() -> String: return _cur_track
func get_current_variation() -> String: return _cur_variation
func get_current_beat() -> int: return _beat
func get_current_length_beats() -> int: return int(_cur_seg.get("length_beats", DEFAULT_LENGTH_BEATS))
func get_current_total_passes() -> int: return maxi(1, int(_cur_seg.get("repeat", 1)))
func get_current_pass() -> int: return get_current_total_passes() - _reps_left
func get_history() -> Array[String]: return _history.duplicate()


## Track/segment introspection for UIs.  All return copies so callers cannot
## mutate engine state.

## Track names in metadata (load) order.
func get_track_names() -> Array[String]:
	var names: Array[String] = []
	for n in _tracks:
		names.append(n)
	return names


## A track's config: { probability, progress, start_segments }.  {} if unknown.
func get_track_config(track_name: String) -> Dictionary:
	return _tracks.get(track_name, {}).duplicate(true)


## Names of the segments owned by [param track_name], in arrangement-file order
## (segments are merged into the global lookup contiguously and in order, so the
## insertion order of _seg_track is preserved per track).
func get_track_segments(track_name: String) -> Array[String]:
	var names: Array[String] = []
	for n in _seg_track:
		if _seg_track[n] == track_name:
			names.append(n)
	return names


## A segment's full config (name, audio, progress, length_beats, repeat, next).
func get_segment(seg_name: String) -> Dictionary:
	return _segments.get(seg_name, {}).duplicate(true)


## The track that owns [param seg_name] ("" if unknown).
func get_segment_track(seg_name: String) -> String:
	return _seg_track.get(seg_name, "")


## True when [param track_name] is eligible at the current progress.
func is_track_eligible(track_name: String) -> bool:
	return _valid_for_progress(_tracks.get(track_name, {}))


## True when [param seg_name] is eligible at the current progress.
func is_segment_eligible(seg_name: String) -> bool:
	return _valid_for_progress(_segments.get(seg_name, {}))


## Replace a track's allowed progress range at runtime (used by the map editor).
## Updates the live selection table without reloading/interrupting playback.
func set_track_progress(track_name: String, progress: Array) -> void:
	if _tracks.has(track_name):
		_tracks[track_name]["progress"] = progress.duplicate(true)
	if _metadata.has("tracks") and _metadata["tracks"].has(track_name):
		_metadata["tracks"][track_name]["progress"] = progress.duplicate(true)

# ---------------------------------------------------------------------------
# Engine callbacks
# ---------------------------------------------------------------------------

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = _bus_name
	_player.pitch_scale = _playback_speed
	_player.finished.connect(_on_player_finished)
	add_child(_player)


func _exit_tree() -> void:
	_stop_all()


## Advance the beat signal clock and watch for the engine executing the queued
## hop (the clip index changes at the outgoing clip's musical end — the seam
## itself was placed sample-accurately on the audio thread; this poll only
## promotes bookkeeping, so its frame quantization is cosmetic).
func _process(delta: float) -> void:
	if not _playing or _paused:
		return

	_play_elapsed_usec += int(delta * 1_000_000.0)
	if _beat_usec > 0:
		var b := _play_elapsed_usec / _beat_usec
		while _beat < b:
			_beat += 1
			beat_advanced.emit(_beat)

	if _playback == null:
		return
	var idx := _playback.get_current_clip_index()
	if idx == _cur_clip:
		return
	if idx == _pending_clip and idx >= 0:
		_promote(_pending_seg, idx, _pending_fresh, _pending_variation)
	elif idx >= 0 and idx < _clip_seg.size():
		# Shouldn't happen; adopt whatever the engine is actually playing.
		push_warning("SoundChain: resync — engine on unexpected clip %d ('%s')" % [idx, _clip_seg[idx]])
		_promote(_clip_seg[idx], idx, true, "")


## The interactive playback ended (dead-end segment played out its tail with
## nothing queued).  Wind the playthrough down.
func _on_player_finished() -> void:
	if _playing:
		_stop_all()

# ---------------------------------------------------------------------------
# Walk bookkeeping
# ---------------------------------------------------------------------------

## Adopt [param seg_name]/[param clip] as the currently-sounding segment and
## immediately queue its successor with the engine.  [param fresh] true re-arms
## the `repeat` counter; false is a repeat pass of the same segment.
func _promote(seg_name: String, clip: int, fresh: bool, variation: String) -> void:
	var prev := _cur_name
	_cur_name = seg_name
	_cur_seg  = _segments.get(seg_name, {})
	_cur_track = _seg_track.get(seg_name, _cur_track)
	_cur_variation = variation
	_cur_clip = clip

	if fresh:
		_reps_left = maxi(1, int(_cur_seg.get("repeat", 1))) - 1
		# Count consecutive next-driven self-loops (a `repeat` pass isn't fresh,
		# so it never touches this) — see `max_repeats` in _select_next.
		_run_len = _run_len + 1 if seg_name == prev else 1

	_history.append(seg_name)
	print("SoundChain: beat %3d → '%s'  (len=%d, pass %d/%d, var=%s)" %
		[_beat, seg_name, get_current_length_beats(),
		get_current_pass(), get_current_total_passes(), variation])
	segment_changed.emit(_cur_name, _cur_track)

	_queue_successor()


## Decide the next hop (repeat pass / weighted `next` / END_TRACK → new track)
## and ask the engine to switch at the current clip's musical end.
func _queue_successor() -> void:
	_pending_seg = ""
	_pending_clip = -1
	_pending_fresh = false
	_pending_variation = ""

	var target := ""
	if _reps_left > 0:
		_reps_left -= 1
		target = _cur_name
		_pending_fresh = false
	else:
		_select_next()
		target = _next_name
		_pending_fresh = true

	if target == "":
		return  # dead end → clip plays out its tail, `finished` winds down

	_pending_seg = target
	_pending_clip = _pick_clip(target)
	_pending_variation = _arm_clip(_pending_clip, target)
	if _playback and _pending_clip >= 0:
		_playback.switch_to_clip(_pending_clip)


## The clip index a hop into [param seg_name] should use: the twin of the
## current clip when hopping to the same segment, else the primary.
func _pick_clip(seg_name: String) -> int:
	var arr: Array = _clips_of.get(seg_name, [])
	if arr.size() == 2 and arr[0] == _cur_clip:
		return arr[1]
	return arr[0] if not arr.is_empty() else -1


## Choose a random `audio` variation for [param seg_name] (deterministic for a
## given RNG seed) and install it as clip [param clip]'s stream content.  The
## clip is never the one currently sounding, so this is race-free — and it does
## not touch the AudioStreamInteractive resource itself.
func _arm_clip(clip: int, seg_name: String) -> String:
	var d: Dictionary = _variations.get(seg_name, {})
	var streams: Array = d.get("streams", [])
	if streams.is_empty() or clip < 0:
		return ""
	var i := _rng.randi() % streams.size()
	(_wrappers[clip] as BeatSyncStream).set_stream(0, streams[i])
	return d["names"][i]


func _recalc_beat_usec() -> void:
	_beat_usec = maxi(1, int(_beat_secs / _playback_speed * 1_000_000.0))

# ---------------------------------------------------------------------------
# Selection logic
# ---------------------------------------------------------------------------

## Pick the first segment of a playthrough: choose an eligible track (weighted,
## progress-filtered), then a start segment within it.
func _select_start() -> String:
	if _tracks.is_empty():
		return _pick_any_valid()

	var track := _pick_track(false)
	if track != "":
		var s := _select_start_in_track(track)
		if s != "":
			return s

	# Fallbacks: any eligible segment, else closest across ALL segments.
	var pick := _pick_any_valid()
	if pick != "":
		return pick
	return _closest_by_distance(_segments.keys())


## Pick the next segment from the current segment's "next" table.
## A selected [constant END_TRACK] is resolved into the start of a new track.
func _select_next() -> void:
	_next_name = ""

	if _cur_name == "":
		return

	var seg       = _segments.get(_cur_name, {})
	var next_map  : Dictionary = seg.get("next", {})

	if next_map.is_empty():
		return  # dead end → playback will naturally stop

	# `max_repeats`: cap on how many times a segment may play back-to-back via a
	# self-loop in `next`.  Once it has run that many times, drop it from its own
	# next table so the pick is forced elsewhere.  Skipped when self is the only
	# candidate (excluding it would dead-end the track).
	var max_reps := int(seg.get("max_repeats", 0))
	if max_reps > 0 and _run_len >= max_reps and next_map.has(_cur_name) and next_map.size() > 1:
		next_map = next_map.duplicate()
		next_map.erase(_cur_name)

	var pick := _weighted_pick(next_map)
	if pick == "":
		# No candidate matched progress — use distance fallback
		pick = _closest_by_distance(next_map.keys())

	if pick == END_TRACK:
		pick = _select_new_track()

	_next_name = pick


## Choose the start segment of a *different* eligible track to continue in when
## the current track ends (via END_TRACK).  Falls back to the current track only
## if it is the sole eligible one.
func _select_new_track() -> String:
	var track := _pick_track(true)
	if track == "":
		return ""
	return _select_start_in_track(track)


## Weighted, progress-filtered pick among a track's start_segments.
func _select_start_in_track(track: String) -> String:
	var starts: Dictionary = _tracks.get(track, {}).get("start_segments", {})
	if starts.is_empty():
		return ""
	var pick := _weighted_pick(starts)
	if pick == "":
		pick = _closest_by_distance(starts.keys())
	return pick


## Weighted random pick among tracks eligible for the current progress.
## When [param exclude_current] and more than one track is eligible, the
## currently-playing track is dropped so END_TRACK moves to a different one.
## Falls back to the progress-closest track when none are strictly eligible.
func _pick_track(exclude_current: bool) -> String:
	var eligible := {}
	for xname in _tracks:
		if not _valid_for_progress(_tracks[xname]):
			continue
		var w := maxf(0.0, float(_tracks[xname].get("probability", 1.0)))
		if w > 0.0:
			eligible[xname] = w

	if exclude_current and _cur_track != "" and eligible.size() > 1 and eligible.has(_cur_track):
		eligible.erase(_cur_track)

	if eligible.is_empty():
		return _closest_track_by_distance()

	var total := 0.0
	for k in eligible:
		total += eligible[k]

	var r := _rng.randf() * total
	var cum := 0.0
	for k in eligible:
		cum += eligible[k]
		if r <= cum:
			return k
	return eligible.keys()[-1]


## Fallback: the track whose progress range is closest to _progress.
func _closest_track_by_distance() -> String:
	var best := ""
	var best_dist := INF
	for xname in _tracks:
		var d := _progress_distance(_tracks[xname])
		if d < best_dist:
			best_dist = d
			best = xname
	return best


## Weighted random selection from {name: weight} map, filtering by progress.
## [constant END_TRACK] is always an eligible candidate (its progress handling
## happens later, when the new track is chosen).
## Returns "" when no candidate is valid for the current progress.
func _weighted_pick(weights: Dictionary) -> String:
	var candidates: Array[Dictionary] = []
	var total := 0.0

	for n in weights:
		if n != END_TRACK:
			if not _segments.has(n):
				continue
			if not _valid_for_progress(_segments[n]):
				continue
		var w := maxf(0.0, float(weights[n]))
		if w > 0.0:
			candidates.append({"name": n, "weight": w})
			total += w

	if candidates.is_empty() or total <= 0.0:
		return ""

	var r := _rng.randf() * total
	var cum := 0.0
	for entry in candidates:
		cum += entry["weight"]
		if r <= cum:
			return entry["name"]

	# Floating-point guard
	return candidates[-1]["name"]


## Fallback: among `candidates`, pick the one whose progress intervals are
## closest to `_progress`.  Used when no segment is strictly valid.
func _closest_by_distance(candidates: Array) -> String:
	var best := ""
	var best_dist := INF
	for n in candidates:
		if not _segments.has(n):
			continue
		var d := _progress_distance(_segments[n])
		if d < best_dist:
			best_dist = d
			best = n
	return best


## Pick any single segment valid for current progress (equal probability).
func _pick_any_valid() -> String:
	var valid: Array[String] = []
	for n in _segments:
		if _valid_for_progress(_segments[n]):
			valid.append(n)
	if valid.is_empty():
		return ""
	return valid[_rng.randi() % valid.size()]

# ---------------------------------------------------------------------------
# Playback helpers
# ---------------------------------------------------------------------------

## Resolve a single `audio` entry (or a bare segment name) to a concrete file
## path, or "" if none exists.
##   - full path:  "res://some/fx.ogg"  (used as-is)
##   - bare name with extension: "a0.wav"  (prefixed with _audio_base)
##   - bare name without extension: "a0"   (tries .ogg then .wav)
func _resolve_entry_path(p: String, seg_name: String) -> String:
	if p.begins_with("res://") or p.begins_with("user://") or p.begins_with("/") or (p.length() >= 2 and p[1] == ":"):
		return p
	if p.ends_with(".wav") or p.ends_with(".ogg"):
		var candidate := _audio_base + "/" + p
		if FileAccess.file_exists(candidate):
			return candidate
	else:
		for ext in [".ogg", ".wav"]:
			var candidate: String = _audio_base + "/" + p + ext
			if FileAccess.file_exists(candidate):
				return candidate

	# Fallback to <segment name>.ogg/.wav
	if seg_name != p:
		for ext in [".ogg", ".wav"]:
			var candidate: String = _audio_base + "/" + seg_name + ext
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


## Load an audio file to an AudioStream, using the RIFF/Ogg fallbacks for
## absolute paths that ResourceLoader can't handle (e.g. exported builds).
func _load_stream(path: String) -> AudioStream:
	var s := load(path) as AudioStream
	if s == null:
		s = _load_ogg_fallback(path)
	if s == null:
		s = _load_wav_fallback(path)
	return s


## Stop everything and reset state.
func _stop_all() -> void:
	_playing = false
	_paused  = false

	if _player and is_instance_valid(_player):
		_player.stop()
	_playback = null

	_cur_name  = ""
	_cur_seg   = {}
	_cur_track = ""
	_cur_variation = ""
	_cur_clip  = -1
	_reps_left = 0
	_run_len   = 0
	_next_name = ""
	_pending_seg = ""
	_pending_clip = -1
	_pending_fresh = false
	_pending_variation = ""
	_beat      = 0
	_play_elapsed_usec = 0
	_history.clear()

	segment_changed.emit("", "")
	playback_changed.emit(false, false)

# ---------------------------------------------------------------------------
# Progress helpers
# ---------------------------------------------------------------------------

## True when `seg` has no progress restriction or _progress falls inside one
## of its allowed intervals.
func _valid_for_progress(seg: Dictionary) -> bool:
	var intervals: Array = seg.get("progress", [])
	if intervals.is_empty():
		return true
	for iv in intervals:
		if iv is Array and iv.size() >= 2:
			if _progress >= float(iv[0]) and _progress <= float(iv[1]):
				return true
	return false


## Minimum distance from _progress to the closest allowed interval of `seg`.
## 0.0 when already inside an interval.
func _progress_distance(seg: Dictionary) -> float:
	var intervals: Array = seg.get("progress", [])
	if intervals.is_empty():
		return 0.0
	var best := INF
	for iv in intervals:
		if iv is Array and iv.size() >= 2:
			var lo := float(iv[0])
			var hi := float(iv[1])
			if _progress >= lo and _progress <= hi:
				return 0.0
			var d := minf(absf(_progress - lo), absf(_progress - hi))
			if d < best:
				best = d
	return best

# ---------------------------------------------------------------------------
# WAV fallback loader (for exported builds)
# ---------------------------------------------------------------------------

## Fallback loader for .wav files when ResourceLoader can't handle
## absolute filesystem paths (e.g. exported builds).
## Properly scans RIFF chunks instead of assuming fixed header offsets.
func _load_wav_fallback(path: String) -> AudioStream:
	if not path.ends_with(".wav"):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var data := file.get_buffer(file.get_length())
	file.close()

	if data.size() < 12:
		return null
	if data.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	if data.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null

	# Scan RIFF chunks; extract fmt  and data chunks wherever they appear.
	var pos := 12
	var audio_format := -1
	var num_channels := -1
	var sample_rate := -1
	var bits_per_sample := -1
	var pcm_data: PackedByteArray = PackedByteArray()

	while pos + 8 <= data.size():
		var chunk_id := data.slice(pos, pos + 4).get_string_from_ascii()
		var chunk_size := _decode_u32(data, pos + 4)
		pos += 8

		if chunk_id == "fmt ":
			if chunk_size < 16 or pos + chunk_size > data.size():
				return null
			audio_format = _decode_u16(data, pos)
			num_channels = _decode_u16(data, pos + 2)
			sample_rate = _decode_u32(data, pos + 4)
			bits_per_sample = _decode_u16(data, pos + 14)

		elif chunk_id == "data":
			var usable := mini(chunk_size, data.size() - pos)
			pcm_data = data.slice(pos, pos + usable)

		pos += chunk_size

	# Validate what we parsed.
	if audio_format != 1:
		push_warning("SoundChain: WAV fallback only supports PCM (format 1), got %d" % audio_format)
		return null
	if pcm_data.is_empty():
		return null

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS if bits_per_sample == 16 else AudioStreamWAV.FORMAT_8_BITS
	stream.mix_rate = maxi(1, sample_rate)
	stream.stereo = num_channels == 2
	stream.data = pcm_data
	return stream


## Fallback loader for .ogg files when ResourceLoader can't handle
## absolute filesystem paths (e.g. exported builds without TOOLS_ENABLED).
## Uses AudioStreamOggVorbis.load_from_file() which is always available.
func _load_ogg_fallback(path: String) -> AudioStream:
	if not path.ends_with(".ogg"):
		return null
	if not FileAccess.file_exists(path):
		return null
	return AudioStreamOggVorbis.load_from_file(path)


static func _decode_u16(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8)


static func _decode_u32(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
