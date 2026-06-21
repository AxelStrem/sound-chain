extends Node
## SoundChain — Procedural Markov-chain soundtrack generator.
##
## Plays audio segments sequentially, selected via weighted random from a
## Markov transition table.  Segment eligibility is filtered by a [0, 1]
## "progress" value so the soundtrack evolves with game state.
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

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

var _metadata   := {}   ## Raw parsed JSON
var _segments   := {}   ## name → segment Dictionary (fast lookup)
var _bpm        := 120.0
var _beat_secs  := 0.5

var _rng        := RandomNumberGenerator.new()
var _progress   := 0.0
var _playing    := false
var _paused     := false

var _beat       := 0    ## Current beat number (monotonically increasing)
var _cur_name   := ""   ## Currently-playing segment name
var _cur_seg    := {}   ## Currently-playing segment data
var _cur_start  := 0    ## Beat on which current segment started

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

	# Index segments by name for O(1) lookup
	_segments.clear()
	for seg in _metadata.get("segments", []):
		var nm: String = seg.get("name", "")
		if nm == "":
			push_warning("SoundChain: segment entry missing 'name', skipped")
			continue
		_segments[nm] = seg

	# (Re)create timer and player pool
	_setup_timer()
	_setup_pool()

	print("SoundChain: loaded %d segments, %d BPM (%.3f s/beat)" % [_segments.size(), int(_bpm), _beat_secs])


## Start a new playthrough.  [param seed_value] seeds the RNG so the same
## seed + progress trajectory yields the same sequence.
func start(seed_value: int = 0) -> void:
	stop()
	if _segments.is_empty():
		push_error("SoundChain: no metadata loaded — call load_metadata() first")
		return

	_rng.set_seed(seed_value)
	_beat      = 0
	_playing   = true
	_paused    = false

	var first := _select_start()
	if first == "":
		push_error("SoundChain: no start segment could be selected")
		return

	_start_segment(first, 0)
	_timer.start()


## Toggle pause.  Audio players and the beat clock are paused together.
func pause() -> void:
	if not _playing:
		return
	_paused = not _paused
	_timer.paused = _paused
	for player in _active:
		player.stream_paused = _paused


## Stop playback immediately and release all players.
func stop() -> void:
	_stop_all()


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
func get_history() -> Array[String]: return _history.duplicate()

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

	var end_beat  : int = _cur_start + _cur_seg.get("length_beats", DEFAULT_LENGTH_BEATS)
	var lookahead : int = _metadata.get("lookahead_beats", DEFAULT_LOOKAHEAD)

	# --- Pre-select the next segment a few beats before current ends ---
	if not _next_done and _beat >= end_beat - lookahead:
		_select_next()

	# --- Launch the next segment exactly on the beat boundary ---
	if _next_done and _next_name != "" and _beat >= end_beat:
		_start_segment(_next_name, _beat)

	# --- If nothing is playing and nothing is queued, wind down ---
	if _active.is_empty() and _next_name == "":
		_stop_all()

# ---------------------------------------------------------------------------
# Selection logic
# ---------------------------------------------------------------------------

## Weighted pick from start_segments (progress-filtered, with distance fallback).
func _select_start() -> String:
	var starts: Dictionary = _metadata.get("start_segments", {})

	if starts.is_empty():
		return _pick_any_valid()

	var pick := _weighted_pick(starts)
	if pick != "":
		return pick

	# Fallback: closest by progress distance among start_segment keys
	pick = _closest_by_distance(starts.keys())
	if pick != "":
		return pick

	# Try any segment (progress-filtered)
	pick = _pick_any_valid()
	if pick != "":
		return pick

	# Absolute last resort: closest distance across ALL segments
	return _closest_by_distance(_segments.keys())


## Pick the next segment from the current segment's "next" table.
func _select_next() -> void:
	_next_done = true
	_next_name = ""

	if _cur_name == "":
		return

	var seg       = _segments.get(_cur_name, {})
	var next_map  : Dictionary = seg.get("next", {})

	if next_map.is_empty():
		return  # dead end → playback will naturally stop

	_next_name = _weighted_pick(next_map)

	if _next_name == "":
		# No candidate matched progress — use distance fallback
		_next_name = _closest_by_distance(next_map.keys())


## Weighted random selection from {name: weight} map, filtering by progress.
## Returns "" when no candidate is valid for the current progress.
func _weighted_pick(weights: Dictionary) -> String:
	var candidates: Array[Dictionary] = []
	var total := 0.0

	for n in weights:
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
## The "audio" field accepts:
##   - full path:  "res://some/fx.ogg"  (used as-is)
##   - bare name:  "a0.wav"            (prefixed with _audio_base)
##   - bare name without extension: "a0"  (tries .wav then .ogg)
func _resolve_audio(seg: Dictionary, seg_name: String) -> String:
	if seg.has("audio"):
		var p: String = seg["audio"]
		if p != "":
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
					var candidate := _audio_base + "/" + p + ext
					if FileAccess.file_exists(candidate):
						return candidate

	for ext in [".wav", ".ogg"]:
		var p : String = _audio_base + "/" + seg_name + ext
		if FileAccess.file_exists(p):
			return p

	return ""


## Start playing `seg_name` at the given beat position.
func _start_segment(seg_name: String, at_beat: int) -> void:
	var seg = _segments.get(seg_name, {})
	if seg.is_empty():
		push_error("SoundChain: unknown segment '%s'" % seg_name)
		return

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
	_cur_start = at_beat
	_next_name = ""
	_next_done = false

	_history.append(seg_name)

	print("SoundChain: beat %3d → start '%s'  (len=%d beats, path=%s)" %
		[at_beat, seg_name, seg.get("length_beats", DEFAULT_LENGTH_BEATS), path])


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
	_next_name = ""
	_next_done = false
	_beat      = 0
	_history.clear()


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