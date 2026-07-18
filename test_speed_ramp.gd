extends SceneTree
## Stress check: ramp playback speed EVERY PHYSICS FRAME (like the game's
## slow-motion tween in player.gd) across several segment boundaries.  A
## boundary that fires mid-ramp used to make the next set_playback_speed()
## re-issue switch_to_clip() for the clip that had just become current — the
## engine then restarts the live playback inside the mix callback and the walk
## stalls.  The walk must keep advancing for the whole run.

var chain: Node
var t0 := 0
var last_seg_ms := 0
var segs := 0

func _initialize() -> void:
	chain = load("res://sound_chain.gd").new()
	root.add_child(chain)
	chain.segment_changed.connect(_on_seg)
	await process_frame  # let the chain's _ready create its player
	chain.load_metadata("res://sound_chain_metadata.json")
	chain.start_track("aphex", 7)
	t0 = Time.get_ticks_msec()
	last_seg_ms = t0
	physics_frame.connect(_ramp)
	create_timer(120.0).timeout.connect(_finish)

func _ramp() -> void:
	var t := (Time.get_ticks_msec() - t0) / 1000.0
	chain.set_playback_speed(0.8 + 0.2 * sin(t * 2.0))  # 0.6..1.0, new value every frame
	# Longest segment is 96 internal beats ≈ 34 s content → ≈ 56 s wall at the
	# slowest ramp speed; anything past 90 s without a transition is a stall.
	if Time.get_ticks_msec() - last_seg_ms > 90_000:
		print("FAIL: walk stalled — no segment change for 90 s")
		quit(1)

func _on_seg(seg: String, _track: String) -> void:
	if seg == "":
		return
	var now := Time.get_ticks_msec()
	print("SEG %-28s dt=%6d ms  t=%7d ms" % [seg, now - last_seg_ms, now - t0])
	last_seg_ms = now
	segs += 1

func _finish() -> void:
	if segs >= 4:
		print("PASS: %d transitions under continuous ramping" % segs)
		quit(0)
	else:
		print("FAIL: only %d transitions in 120 s" % segs)
		quit(1)