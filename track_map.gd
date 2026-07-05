class_name TrackMap
extends Control
## A compact "which tracks can start where" map: one lane per track, drawn on a
## shared 0→1 progress axis, with each track's effective startable range as
## bar(s).  A vertical marker shows the current progress; lanes whose range
## contains the marker are highlighted (they have a chance to start there).
##
## The marker is driven by [method set_progress] (the UI feeds it from the
## progress slider).  Track names are clickable — clicking one emits
## [signal track_activated] (the UI starts that track, same as the playlist).
## Only lanes that can start at the current marker (highlighted) are clickable.

## Emitted when the user clicks a startable track's name.
signal track_activated(track_name: String)

const ROW_H      := 22.0    ## Height of one track lane.
const NAME_W     := 110.0   ## Left name column width (matched by the slider label).
const AXIS_INSET := 8.0     ## Inset so the axis lines up with the slider grabber.
const PAD_TOP    := 18.0    ## Headroom for the marker value text.
const PAD_BOT    := 6.0

const COL_BAR_ON   := Color(0.30, 0.70, 0.42)   # range contains the marker
const COL_BAR_OFF  := Color(0.34, 0.34, 0.40)   # range elsewhere
const COL_NAME_ON  := Color(0.85, 1.0, 0.88)
const COL_NAME_OFF := Color(0.58, 0.58, 0.64)
const COL_MARKER   := Color(0.96, 0.85, 0.30)
const COL_AXIS     := Color(0.24, 0.24, 0.28)

var _lanes: Array = []          ## [{ name: String, ranges: [[lo, hi], …] }]
var _progress: float = 0.0
var _font: Font
var _font_size := 15


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
		for r in lane["ranges"]:
			if r is Array and r.size() >= 2:
				var x0 := _axis_x(float(r[0]))
				var x1 := _axis_x(float(r[1]))
				draw_rect(Rect2(x0, mid - bar_h * 0.5, maxf(2.0, x1 - x0), bar_h), col)

	var mx := _axis_x(_progress)
	var top := PAD_TOP - 2.0
	var bot := PAD_TOP + _lanes.size() * ROW_H + 2.0
	draw_line(Vector2(mx, top), Vector2(mx, bot), COL_MARKER, 2.0)
	draw_string(_font, Vector2(mx + 4.0, PAD_TOP - 4.0), "%.2f" % _progress,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, COL_MARKER)


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


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var lane := _clickable_lane_at(event.position)
		if lane >= 0:
			track_activated.emit(_lanes[lane]["name"])


func _get_cursor_shape(at_position: Vector2 = Vector2()) -> int:
	return Control.CURSOR_POINTING_HAND if _clickable_lane_at(at_position) >= 0 \
		else Control.CURSOR_ARROW
