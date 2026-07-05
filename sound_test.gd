extends Control
## SoundChain player UI.
##
## Transport controls + a progress slider that steers segment selection live, and
## a playlist Tree of tracks → segments.  Clicking a track starts it on one of its
## start segments; clicking a segment starts exactly there.  Segments/tracks that
## the current progress disallows are greyed out (and unclickable).  Tracks with
## validation issues show a ⚠️ with the details on hover.  All widgets are built
## in code so the .tscn stays trivial.

const METADATA_PATH := "res://sound_chain_metadata.json"

const COL_GREY       := Color(0.32, 0.32, 0.36)   # dim: "can't start here"
const COL_CURRENT_BG := Color(0.18, 0.38, 0.22)

var _tree              : Tree
var _status            : Label
var _slider            : HSlider
var _map               : TrackMap

var _issues_by_target  : Dictionary = {}   ## target name → Array[String] messages
var _track_items       : Dictionary = {}   ## track name → TreeItem
var _seg_items         : Dictionary = {}   ## segment name → TreeItem
var _current_item      : TreeItem = null

var _playing := false
var _paused  := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_window().content_scale_factor = SoundTestConstants.UI_SCALE

	SoundChain.load_metadata(METADATA_PATH)
	SoundChain.set_progress(0.0)
	_issues_by_target = _index_issues(SoundChainValidator.validate(SoundChain))

	_build_ui()
	_populate_tree()
	_refresh_eligibility()

	SoundChain.segment_changed.connect(_on_segment_changed)
	SoundChain.playback_changed.connect(_on_playback_changed)
	_refresh_status()

	SoundChain.start()   # autostart a normal metadata-driven playthrough


## Fold the flat issue list into { target_name: [message, …] } for quick lookup.
func _index_issues(issues: Array) -> Dictionary:
	var by_target: Dictionary = {}
	for issue in issues:
		var target: String = issue["target"]
		if not by_target.has(target):
			by_target[target] = []
		by_target[target].append(str(issue["message"]))
	return by_target

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# --- Transport row ---
	var transport := HBoxContainer.new()
	vbox.add_child(transport)
	_add_button(transport, "▶ Play", _on_play)
	_add_button(transport, "⏸ Pause", _on_pause)
	_add_button(transport, "⏹ Stop", _on_stop)
	_add_button(transport, "⏭ Next", _on_next)

	# Push the volume control to the right edge.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	transport.add_child(spacer)
	var vol_label := Label.new()
	vol_label.text = "Vol"
	transport.add_child(vol_label)
	var saved_volume := SoundTestConstants.load_volume()
	SoundChain.set_volume(saved_volume)
	var vol := HSlider.new()
	vol.min_value = 0.0
	vol.max_value = 1.0
	vol.step = 0.01
	vol.value = saved_volume
	vol.custom_minimum_size = Vector2(160, 24)
	vol.value_changed.connect(_on_volume_changed)
	transport.add_child(vol)

	# Now-playing status on its own line, with breathing room above/below so it
	# reads as separate from the transport buttons and the progress row.
	var status_margin := MarginContainer.new()
	status_margin.add_theme_constant_override("margin_top", 12)
	status_margin.add_theme_constant_override("margin_bottom", 12)
	vbox.add_child(status_margin)
	_status = Label.new()
	status_margin.add_child(_status)

	# --- Progress row (label width matches the map's name column, so the slider
	#     track lines up with the map axis below it) ---
	var prow := HBoxContainer.new()
	vbox.add_child(prow)
	var plabel := Label.new()
	plabel.text = "Progress"
	plabel.custom_minimum_size = Vector2(TrackMap.NAME_W, 0)
	prow.add_child(plabel)
	_slider = HSlider.new()
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.01
	_slider.value = 0.0
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.custom_minimum_size = Vector2(0, 24)
	_slider.value_changed.connect(_on_progress_changed)
	prow.add_child(_slider)

	# --- Track map (marker follows the slider; track names are click-to-start) ---
	_map = TrackMap.new()
	_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map.track_activated.connect(_on_map_track_activated)
	vbox.add_child(_map)

	# --- Playlist ---
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.add_theme_constant_override("h_separation", 14)   # gap: chevron ↔ text
	_tree.item_selected.connect(_on_item_selected)
	vbox.add_child(_tree)


func _add_button(parent: Control, text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	parent.add_child(b)

# ---------------------------------------------------------------------------
# Playlist population
# ---------------------------------------------------------------------------

func _populate_tree() -> void:
	var root := _tree.create_item()
	var lanes: Array = []   # for the track map: { name, effective ranges }

	for track in SoundChain.get_track_names():
		var cfg := SoundChain.get_track_config(track)
		var main_range: Array = cfg.get("progress", [])
		var starts: Dictionary = cfg.get("start_segments", {})

		# Effective startable range = main ∩ (union of start-segment ranges).
		# Only surfaced when it actually narrows the main range (i.e. the start
		# segments don't cover all of it) — otherwise it's just noise.
		var starts_union: Array = []
		for sname in starts:
			starts_union = SoundChainValidator.merge_ranges(
				starts_union, SoundChain.get_segment(sname).get("progress", []))
		var eff := SoundChainValidator.intersect_ranges(main_range, starts_union)
		lanes.append({"name": track, "ranges": eff})
		var main_str := SoundChainValidator.format_ranges(
			SoundChainValidator.normalize_ranges(main_range))
		var eff_str := SoundChainValidator.format_ranges(eff)

		var titem := _tree.create_item(root)
		var label := "%s   [%s]" % [track, main_str]
		if eff_str != main_str:
			label += " (eff %s)" % eff_str
		_apply_issue_marker(titem, track, label)
		titem.set_metadata(0, {"kind": "track", "name": track})
		_track_items[track] = titem

		for seg_name in SoundChain.get_track_segments(track):
			var seg := SoundChain.get_segment(seg_name)
			var sitem := _tree.create_item(titem)
			var slabel := "%s   [%s]" % [seg_name,
				SoundChainValidator.format_ranges(seg.get("progress", []))]
			_apply_issue_marker(sitem, seg_name, slabel)
			sitem.set_metadata(0, {"kind": "segment", "name": seg_name})
			_seg_items[seg_name] = sitem

	_map.set_lanes(lanes)
	_map.set_progress(SoundChain.get_progress())


## Set an item's text, prefixing ⚠️ and attaching a hover tooltip when the target
## has validation issues.
func _apply_issue_marker(item: TreeItem, target: String, label: String) -> void:
	if _issues_by_target.has(target):
		item.set_text(0, "⚠️ " + label)
		item.set_tooltip_text(0, "\n".join(_issues_by_target[target]))
	else:
		item.set_text(0, label)

# ---------------------------------------------------------------------------
# Eligibility (grey-out) — recomputed whenever progress changes
# ---------------------------------------------------------------------------

func _refresh_eligibility() -> void:
	for track in _track_items:
		_apply_eligibility(_track_items[track], SoundChain.is_track_eligible(track))
	for seg_name in _seg_items:
		_apply_eligibility(_seg_items[seg_name], SoundChain.is_segment_eligible(seg_name))


func _apply_eligibility(item: TreeItem, eligible: bool) -> void:
	item.set_selectable(0, eligible)
	if eligible:
		item.clear_custom_color(0)
	else:
		item.set_custom_color(0, COL_GREY)

# ---------------------------------------------------------------------------
# Signal handlers — transport & tree
# ---------------------------------------------------------------------------

func _on_play() -> void:   SoundChain.start()       # fresh random seed each press
func _on_pause() -> void:  SoundChain.pause()
func _on_stop() -> void:   SoundChain.stop()
func _on_next() -> void:   SoundChain.skip()


func _on_volume_changed(v: float) -> void:
	SoundChain.set_volume(v)
	SoundTestConstants.save_volume(v)


func _on_progress_changed(v: float) -> void:
	SoundChain.set_progress(v)
	_map.set_progress(v)
	_refresh_eligibility()


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if typeof(meta) == TYPE_DICTIONARY:
		_start_target(meta["kind"], meta["name"])


func _on_map_track_activated(track_name: String) -> void:
	_start_target("track", track_name)


## Single entry point shared by the playlist tree and the track map: start a
## track (weighted start segment) or an exact segment.
func _start_target(kind: String, target_name: String) -> void:
	if kind == "track":
		SoundChain.start_track(target_name)
	else:
		SoundChain.start_segment_at(target_name)

# ---------------------------------------------------------------------------
# Signal handlers — engine state → UI
# ---------------------------------------------------------------------------

func _on_segment_changed(seg_name: String, _track: String) -> void:
	# Move the "now playing" highlight to the current segment.
	if _current_item != null and is_instance_valid(_current_item):
		_current_item.clear_custom_bg_color(0)
	_current_item = null
	if seg_name != "" and _seg_items.has(seg_name):
		_current_item = _seg_items[seg_name]
		_current_item.set_custom_bg_color(0, COL_CURRENT_BG)
	_refresh_status()


func _on_playback_changed(playing: bool, paused: bool) -> void:
	_playing = playing
	_paused = paused
	_refresh_status()


func _refresh_status() -> void:
	var seg := SoundChain.get_current_segment()
	var track := SoundChain.get_current_track()
	if not _playing or seg == "":
		_status.text = "⏹ stopped"
	elif _paused:
		_status.text = "⏸ paused — %s / %s" % [track, seg]
	else:
		_status.text = "▶ %s / %s" % [track, seg]
