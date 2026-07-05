class_name TrackMap
extends Control
## A compact "which tracks can start where" map: one lane per track, drawn on a
## shared 0→1 progress axis, with each track's effective startable range as
## bar(s).  A vertical marker shows the current progress; lanes whose range
## contains the marker are highlighted (they have a chance to start there).
##
## The marker is driven by [method set_progress] (the UI feeds it from the
## progress slider).  Track names are clickable — clicking one emits
## [signal track_activated] (the UI starts that track, same as the playlist);
## only lanes startable at the current marker are clickable.
##
## The range bars are editable: drag a bar's body to move it, or an edge to
## resize it (snapped to [constant SNAP]).  On release the lane's (possibly
## multiple) intervals are merged/clamped and [signal range_committed] fires so
## the UI can persist the new track range.

## Emitted when the user clicks a startable track's name.
signal track_activated(track_name: String)

## Emitted after a drag edit, with the lane's finalized intervals.
signal range_committed(track_name: String, ranges: Array)

enum { DRAG_NONE, DRAG_LEFT, DRAG_RIGHT, DRAG_MOVE }

const ROW_H      := 22.0    ## Height of one track lane.
const NAME_W     := 110.0   ## Left name column width (matched by the slider label).
const AXIS_INSET := 8.0     ## Inset so the axis lines up with the slider grabber.
const PAD_TOP    := 18.0    ## Headroom for the marker value text.
const PAD_BOT    := 6.0
const EDGE_PX    := 6.0     ## Grab tolerance around a bar edge, in pixels.
const SNAP       := 0.01    ## Drag snap resolution.
const MIN_W      := 0.01    ## Smallest interval width a resize can leave.

const COL_BAR_ON   := Color(0.30, 0.70, 0.42)   # range contains the marker
const COL_BAR_OFF  := Color(0.34, 0.34, 0.40)   # range elsewhere
const COL_NAME_ON  := Color(0.85, 1.0, 0.88)
const COL_NAME_OFF := Color(0.58, 0.58, 0.64)
const COL_MARKER   := Color(0.96, 0.85, 0.30)
const COL_AXIS     := Color(0.24, 0.24, 0.28)
const COL_DRAG     := Color(0.55, 0.90, 1.00)   # dotted target line while dragging

var _lanes: Array = []          ## [{ name: String, ranges: [[lo, hi], …] }]
var _progress: float = 0.0
var _font: Font
var _font_size := 15

var _drag: Dictionary = {}      ## active edit: { lane, iv, mode, grab }


func _ready() -> void:
	_font = ThemeDB.fallback_font
	custom_minimum_size = Vector2(0, PAD_TOP + PAD_BOT)


## Set the track lanes to draw.  Each entry: { name, ranges }.
func set_lanes(lanes: Array) -> void:
	_lanes = lanes
	custom_minimum_size = Vector2(0, PAD_TOP + PAD_BOT + _lanes.size() * ROW_H)
	queue_redraw()


## Move the marker to [param p] (0..1).
func set_progress(p: float) -> void:
	_progress = clampf(p, 0.0, 1.0)
	queue_redraw()


func _axis_x(v: float) -> float:
	var lo := NAME_W + AXIS_INSET
	var hi := size.x - AXIS_INSET
	return lo + clampf(v, 0.0, 1.0) * (hi - lo)


func _draw() -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	if _lanes.is_empty():
		return

	var axis_lo := NAME_W + AXIS_INSET
	var axis_hi := size.x - AXIS_INSET
	var bar_h := ROW_H * 0.5

	for i in _lanes.size():
		var lane: Dictionary = _lanes[i]
		var y := PAD_TOP + i * ROW_H
		var mid := y + ROW_H * 0.5
		var contains := _ranges_contain(lane["ranges"], _progress)

		draw_string(_font, Vector2(4.0, mid + _font_size * 0.35), lane["name"],
			HORIZONTAL_ALIGNMENT_LEFT, NAME_W - 8.0, _font_size,
			COL_NAME_ON if contains else COL_NAME_OFF)

		draw_line(Vector2(axis_lo, mid), Vector2(axis_hi, mid), COL_AXIS, 1.0)

		var col := COL_BAR_ON if contains else COL_BAR_OFF
		var edge_col := col.lightened(0.35)
		for r in lane["ranges"]:
			if r is Array and r.size() >= 2:
				var x0 := _axis_x(float(r[0]))
				var x1 := _axis_x(float(r[1]))
				var half := bar_h * 0.5
				draw_rect(Rect2(x0, mid - half, maxf(2.0, x1 - x0), bar_h), col)
				# Grab handles at each edge.
				draw_line(Vector2(x0, mid - half - 2.0), Vector2(x0, mid + half + 2.0), edge_col, 2.0)
				draw_line(Vector2(x1, mid - half - 2.0), Vector2(x1, mid + half + 2.0), edge_col, 2.0)

	var mx := _axis_x(_progress)
	var top := PAD_TOP - 2.0
	var bot := PAD_TOP + _lanes.size() * ROW_H + 2.0
	draw_line(Vector2(mx, top), Vector2(mx, bot), COL_MARKER, 2.0)
	draw_string(_font, Vector2(mx + 4.0, PAD_TOP - 4.0), "%.2f" % _progress,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, COL_MARKER)

	# While dragging, a dotted target line at the point(s) being edited: the
	# grabbed edge when resizing, both ends when moving.
	if not _drag.is_empty():
		var dr: Array = _lanes[_drag["lane"]]["ranges"][_drag["iv"]]
		var mode := int(_drag["mode"])
		if mode == DRAG_LEFT or mode == DRAG_MOVE:
			_draw_target(float(dr[0]), top, bot)
		if mode == DRAG_RIGHT or mode == DRAG_MOVE:
			_draw_target(float(dr[1]), top, bot)


## A dotted vertical target line + value label at progress [param v].
func _draw_target(v: float, top: float, bot: float) -> void:
	var x := _axis_x(v)
	var y := top
	while y < bot:
		var y2 := minf(y + 4.0, bot)
		draw_line(Vector2(x, y), Vector2(x, y2), COL_DRAG, 1.0)
		y = y2 + 3.0
	draw_string(_font, Vector2(x + 4.0, PAD_TOP - 4.0), "%.2f" % v,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, COL_DRAG)


static func _ranges_contain(ranges: Array, v: float) -> bool:
	for r in ranges:
		if r is Array and r.size() >= 2 and v >= float(r[0]) and v <= float(r[1]):
			return true
	return false

# ---------------------------------------------------------------------------
# Interaction — clickable track names (only where a track can start)
# ---------------------------------------------------------------------------

## The lane index whose name a position falls on and that is startable at the
## current marker, or -1.  Shared by click handling and the cursor shape.
func _clickable_lane_at(pos: Vector2) -> int:
	if pos.x >= NAME_W:
		return -1
	var i := int((pos.y - PAD_TOP) / ROW_H)
	if pos.y < PAD_TOP or i < 0 or i >= _lanes.size():
		return -1
	return i if _ranges_contain(_lanes[i]["ranges"], _progress) else -1


## Progress value (0..1) at a pixel x — inverse of [method _axis_x].
func _x_to_progress(px: float) -> float:
	var lo := NAME_W + AXIS_INSET
	var hi := size.x - AXIS_INSET
	if hi <= lo:
		return 0.0
	return clampf((px - lo) / (hi - lo), 0.0, 1.0)


## Hit-test a bar: returns { lane, iv, mode } for the interval/edge under `pos`,
## or {} when the position is not over a bar.
func _bar_hit(pos: Vector2) -> Dictionary:
	if pos.x < NAME_W:
		return {}
	var i := int((pos.y - PAD_TOP) / ROW_H)
	if pos.y < PAD_TOP or i < 0 or i >= _lanes.size():
		return {}
	var ranges: Array = _lanes[i]["ranges"]
	for iv in ranges.size():
		var r: Array = ranges[iv]
		if r.size() < 2:
			continue
		var x0 := _axis_x(float(r[0]))
		var x1 := _axis_x(float(r[1]))
		if absf(pos.x - x0) <= EDGE_PX:
			return {"lane": i, "iv": iv, "mode": DRAG_LEFT}
		if absf(pos.x - x1) <= EDGE_PX:
			return {"lane": i, "iv": iv, "mode": DRAG_RIGHT}
		if pos.x > x0 and pos.x < x1:
			return {"lane": i, "iv": iv, "mode": DRAG_MOVE}
	return {}


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# A click on a startable name starts the track…
			var lane := _clickable_lane_at(event.position)
			if lane >= 0:
				track_activated.emit(_lanes[lane]["name"])
				return
			# …otherwise begin a bar edit if one is under the cursor.
			var hit := _bar_hit(event.position)
			if not hit.is_empty():
				_drag = hit
				if hit["mode"] == DRAG_MOVE:
					var r: Array = _lanes[hit["lane"]]["ranges"][hit["iv"]]
					_drag["grab"] = _x_to_progress(event.position.x) - float(r[0])
		elif not _drag.is_empty():
			_commit_drag()
	elif event is InputEventMouseMotion and not _drag.is_empty():
		_apply_drag(event.position)


## Update the dragged interval as the mouse moves (snapped, clamped).
func _apply_drag(pos: Vector2) -> void:
	var p := snappedf(_x_to_progress(pos.x), SNAP)
	var r: Array = _lanes[_drag["lane"]]["ranges"][_drag["iv"]]
	match int(_drag["mode"]):
		DRAG_LEFT:
			r[0] = clampf(p, 0.0, float(r[1]) - MIN_W)
		DRAG_RIGHT:
			r[1] = clampf(p, float(r[0]) + MIN_W, 1.0)
		DRAG_MOVE:
			var w := float(r[1]) - float(r[0])
			var lo := snappedf(clampf(p - float(_drag["grab"]), 0.0, 1.0 - w), SNAP)
			r[0] = lo
			r[1] = snappedf(lo + w, SNAP)
	queue_redraw()


## Finish a drag: merge/clamp the lane's intervals and notify the UI to persist.
func _commit_drag() -> void:
	var lane: int = _drag["lane"]
	_drag = {}
	_lanes[lane]["ranges"] = _merge_ranges(_lanes[lane]["ranges"])
	queue_redraw()
	range_committed.emit(_lanes[lane]["name"], _lanes[lane]["ranges"])


## Sort intervals and merge overlapping/adjacent ones (keeps the bars sane after
## dragging one interval across another).
static func _merge_ranges(ranges: Array) -> Array:
	var ivs: Array = []
	for r in ranges:
		if r is Array and r.size() >= 2:
			# Snap endpoints to the grid so saved values stay clean (0.25, not 0.2487).
			ivs.append([snappedf(minf(float(r[0]), float(r[1])), SNAP),
				snappedf(maxf(float(r[0]), float(r[1])), SNAP)])
	ivs.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for iv in ivs:
		if out.is_empty() or iv[0] > out[-1][1]:
			out.append(iv)
		else:
			out[-1][1] = maxf(out[-1][1], iv[1])
	return out


func _get_cursor_shape(at_position: Vector2 = Vector2()) -> int:
	if not _drag.is_empty():
		return CURSOR_HSIZE if int(_drag["mode"]) != DRAG_MOVE else CURSOR_MOVE
	if _clickable_lane_at(at_position) >= 0:
		return Control.CURSOR_POINTING_HAND
	var hit := _bar_hit(at_position)
	if not hit.is_empty():
		return CURSOR_HSIZE if int(hit["mode"]) != DRAG_MOVE else CURSOR_MOVE
	return Control.CURSOR_ARROW
