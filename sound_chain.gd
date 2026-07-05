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

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const DEFAULT_LENGTH_BEATS  := 16
const DEFAULT_LOOKAHEAD     := 2
const MAX_PLAYERS           := 4

## Special "next" target.  When selected it ends the current track and lets the
## engine jump to a different song (progress-filtered, weighted).  See
## [method _select_new_track].
const END_TRACK := "END_TRACK"

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
var _cur_start  := 0    ## Beat on which current segment (this pass) started
var _reps_left  := 0    ## Remaining extra `repeat` passes of the current segment

var _next_name  := ""   ## Pre-selected next segment
var _next_done  := false ## Whether next selection has happened this cycle

var _timer      : Timer
var _pool       : Array[AudioStreamPlayer] = []
var _active     := {}   ## AudioStreamPlayer → segment_name

var _bus_name        := &"Master"       ## Audio bus for all players
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

	# (Re)create timer and player pool
	_setup_timer()
	_setup_pool()

	print("SoundChain: loaded %d tracks, %d segments, %d BPM (%.3f s/beat)" %
		[_tracks.size(), _segments.size(), int(_bpm), _beat_secs])


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
	if _segments.is_empty():
		push_error("SoundChain: no metadata loaded — call load_metadata() first")
		return

	_rng.set_seed(seed_value if seed_value >= 0 else randi())
	_beat      = 0
	_playing   = true
	_paused    = false

	if first == "":
		push_error("SoundChain: no start segment could be selected")
		_playing = false
		return

	_start_segment(first, 0)
	_timer.start()
	playback_changed.emit(_playing, _paused)


## Toggle pause.  Audio players and the beat clock are paused together.
func pause() -> void:
	if not _playing:
		return
	_paused = not _paused
	_timer.paused = _paused
	for player in _active:
		player.stream_paused = _paused
	playback_changed.emit(_playing, _paused)


## Stop playback immediately and release all players.
func stop() -> void:
	_stop_all()


## Skip to the next segment right now, bypassing any remaining `repeat` passes.
## Resolves the current segment's `next` table (including END_TRACK) exactly as the
## automatic hand-off would.  No-op unless actively playing.
func skip() -> void:
	if not is_playing() or _cur_name == "":
		return
	_reps_left = 0
	if not _next_done:
		_select_next()
	if _next_name == "":
		return
	# Unlike an automatic boundary transition (where the outgoing segment's tail
	# is meant to ring out under the next), a manual skip happens mid-segment, so
	# cut the current audio before starting the next.
	_silence_active()
	_start_segment(_next_name, _beat)


## Stop and release every currently-sounding player without tearing down the
## playthrough (state, timer and beat clock keep running).
func _silence_active() -> void:
	for player in _active.keys():
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_active.clear()


## Update the progress value [0.0, 1.0].  If a next segment has already been
## pre-selected, its validity is re-checked and may trigger a re-selection.
func set_progress(value: float) -> void:
	_progress = clampf(value, 0.0, 1.0)

	if _next_done and _next_name != "":
		if not _valid_for_progress(_segments.get(_next_name, {})):
			_select_next()


## Returns true when playback is active and not paused.
func is_playing() -> bool:
	return _playing and not _paused


## Set the audio bus used by all players.  Call before [method start];
## existing players are updated immediately.
func set_bus(bus: StringName) -> void:
	_bus_name = bus
	for p in _pool:
		if is_instance_valid(p):
			p.bus = _bus_name


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
## Changes pitch as well — intended for temporary sound effects.
## Updates all currently-playing and idle players immediately.
func set_playback_speed(speed: float) -> void:
	_playback_speed = maxf(0.05, speed)
	_apply_playback_speed()


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

# ---------------------------------------------------------------------------
# Engine callbacks
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Create timer early so it's always present; wait_time updated on load.
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = _beat_secs
	_timer.timeout.connect(_on_beat)
	add_child(_timer)

	# Prime the pool (no-op until metadata is loaded and _setup_pool runs).
	_pool.clear()
	for _i in MAX_PLAYERS:
		var p := AudioStreamPlayer.new()
		p.bus = _bus_name
		p.pitch_scale = _playback_speed
		p.finished.connect(_on_player_done.bind(p))
		add_child(p)
		_pool.append(p)


func _exit_tree() -> void:
	_stop_all()

# ---------------------------------------------------------------------------
# Internal setup
# ---------------------------------------------------------------------------

func _setup_timer() -> void:
	if _timer:
		_timer.wait_time = _beat_secs / _playback_speed


func _setup_pool() -> void:
	# Recycle existing players: stop them and clear active set.
	for player in _active.keys():
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_active.clear()


## Push _playback_speed to all players (active + idle) and rescale beat clock.
func _apply_playback_speed() -> void:
	if _timer:
		_timer.wait_time = _beat_secs / _playback_speed
	for p in _pool:
		if is_instance_valid(p):
			p.pitch_scale = _playback_speed

# ---------------------------------------------------------------------------
# Beat clock
# ---------------------------------------------------------------------------

func _on_beat() -> void:
	if not _playing or _paused:
		return

	_beat += 1

	# Safety: nothing to schedule against
	if _cur_name == "":
		return

	beat_advanced.emit(_beat)

	var end_beat  : int = _cur_start + _cur_seg.get("length_beats", DEFAULT_LENGTH_BEATS)
	var lookahead : int = _metadata.get("lookahead_beats", DEFAULT_LOOKAHEAD)

	if _reps_left > 0:
		# --- More `repeat` passes to go: replay the same segment on the boundary ---
		if _beat >= end_beat:
			_reps_left -= 1
			_start_segment(_cur_name, _beat, false)
	else:
		# --- Final pass: pre-select then hand off to the next segment ---
		if not _next_done and _beat >= end_beat - lookahead:
			_select_next()

		if _next_done and _next_name != "" and _beat >= end_beat:
			_start_segment(_next_name, _beat)

	# --- If nothing is playing and nothing is queued, wind down ---
	if _active.is_empty() and _next_name == "":
		_stop_all()

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
	_next_done = true
	_next_name = ""

	if _cur_name == "":
		return

	var seg       = _segments.get(_cur_name, {})
	var next_map  : Dictionary = seg.get("next", {})

	if next_map.is_empty():
		return  # dead end → playback will naturally stop

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
	for name in _tracks:
		if not _valid_for_progress(_tracks[name]):
			continue
		var w := maxf(0.0, float(_tracks[name].get("probability", 1.0)))
		if w > 0.0:
			eligible[name] = w

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
	for name in _tracks:
		var d := _progress_distance(_tracks[name])
		if d < best_dist:
			best_dist = d
			best = name
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

## Resolve the audio file path for a segment.
## Priority: explicit "audio" field → {_audio_base}/{name}.wav → .ogg.
##
## The "audio" field is always a list of interchangeable "variations".  One
## entry is chosen at random every time the segment starts — the variations are
## musically equivalent, so which one plays does not matter.  A list with a
## single entry simply always plays that entry.
##
## Each variation accepts:
##   - full path:  "res://some/fx.ogg"  (used as-is)
##   - bare name:  "a0.wav"            (prefixed with _audio_base)
##   - bare name without extension: "a0"  (tries .wav then .ogg)
func _resolve_audio(seg: Dictionary, seg_name: String) -> String:
	_cur_variation = ""
	var variations: Array = seg.get("audio", [])
	if not variations.is_empty():
		var p := str(variations[_rng.randi() % variations.size()])
		_cur_variation = p
		if p.begins_with("res://") or p.begins_with("user://") or p.begins_with("/") or (p.length() >= 2 and p[1] == ":"):
			# Absolute path — use as-is
			return p
		if p.ends_with(".wav") or p.ends_with(".ogg"):
			# Bare filename with extension — prefix with _audio_base
			var candidate := _audio_base + "/" + p
			if FileAccess.file_exists(candidate):
				return candidate
		else:
			# Bare name without extension — try both
			for ext in [".wav", ".ogg"]:
				var candidate: String = _audio_base + "/" + p + ext
				if FileAccess.file_exists(candidate):
					return candidate

	for ext in [".wav", ".ogg"]:
		var p : String = _audio_base + "/" + seg_name + ext
		if FileAccess.file_exists(p):
			return p

	return ""


## Start playing `seg_name` at the given beat position.
## [param fresh] true means this is a newly-selected segment, so its `repeat`
## counter is (re)armed; false means this is a replay of the current segment for
## another of its `repeat` passes (counter left as-is).
func _start_segment(seg_name: String, at_beat: int, fresh: bool = true) -> void:
	var seg = _segments.get(seg_name, {})
	if seg.is_empty():
		push_error("SoundChain: unknown segment '%s'" % seg_name)
		return

	if fresh:
		# Arm the repeat counter: total passes minus this first one.
		_reps_left = maxi(1, int(seg.get("repeat", 1))) - 1

	var path := _resolve_audio(seg, seg_name)
	if path == "":
		push_error("SoundChain: audio not found for segment '%s'" % seg_name)
		return

	var stream := load(path)
	if stream == null:
		stream = _load_wav_fallback(path)
	if stream == null:
		push_error("SoundChain: failed to load audio: " + path)
		return

	var player := _get_free_player()
	if player == null:
		push_warning("SoundChain: all %d players busy — skipping '%s'" % [MAX_PLAYERS, seg_name])
		return

	player.pitch_scale = _playback_speed
	player.stream = stream
	player.play()
	_active[player] = seg_name

	_cur_name  = seg_name
	_cur_seg   = seg
	_cur_track = _seg_track.get(seg_name, _cur_track)
	_cur_start = at_beat
	_next_name = ""
	_next_done = false

	_history.append(seg_name)

	var total_reps := maxi(1, int(seg.get("repeat", 1)))
	print("SoundChain: beat %3d → start '%s'  (len=%d beats, pass %d/%d, path=%s)" %
		[at_beat, seg_name, seg.get("length_beats", DEFAULT_LENGTH_BEATS),
		total_reps - _reps_left, total_reps, path])

	segment_changed.emit(_cur_name, _cur_track)


## Stop everything and reset state.
func _stop_all() -> void:
	_playing = false
	_paused  = false
	if _timer:
		_timer.stop()

	for player in _active.keys():
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_active.clear()

	_cur_name  = ""
	_cur_seg   = {}
	_cur_track = ""
	_cur_variation = ""
	_reps_left = 0
	_next_name = ""
	_next_done = false
	_beat      = 0
	_history.clear()

	segment_changed.emit("", "")
	playback_changed.emit(false, false)


## Return the first non-playing AudioStreamPlayer from the pool (or null).
func _get_free_player() -> AudioStreamPlayer:
	for p in _pool:
		if is_instance_valid(p) and not p.playing:
			return p
	return null

# ---------------------------------------------------------------------------
# Signal callbacks
# ---------------------------------------------------------------------------

func _on_player_done(player: AudioStreamPlayer) -> void:
	_active.erase(player)
	if is_instance_valid(player):
		player.stream = null

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


static func _decode_u16(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8)


static func _decode_u32(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)
