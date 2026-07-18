extends SceneTree
## Temporary check: segment boundaries must stretch with set_playback_speed().

var chain: Node
var t0 := 0
var last := 0

func _initialize() -> void:
	chain = load("res://sound_chain.gd").new()
	root.add_child(chain)
	chain.segment_changed.connect(_on_seg)
	await process_frame  # let the chain's _ready create its player
	chain.load_metadata("res://sound_chain_metadata.json")
	chain.start_track("pianoloops", 42)
	t0 = Time.get_ticks_msec()
	last = t0
	create_timer(20.0).timeout.connect(func ():
		print(">>> SPEED 0.5 at t=%d ms" % (Time.get_ticks_msec() - t0))
		chain.set_playback_speed(0.5))
	create_timer(75.0).timeout.connect(func ():
		print(">>> SPEED 1.0 at t=%d ms" % (Time.get_ticks_msec() - t0))
		chain.set_playback_speed(1.0))
	create_timer(115.0).timeout.connect(func (): quit())

func _on_seg(seg: String, _track: String) -> void:
	if seg == "":
		return
	var now := Time.get_ticks_msec()
	print("SEG %-32s dt=%6d ms   t=%7d ms" % [seg, now - last, now - t0])
	last = now