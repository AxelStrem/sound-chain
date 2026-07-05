class_name SoundTestConstants
## App-level settings for the SoundChain player.
##
## [constant UI_SCALE] is a compile-time constant; the volume is persisted to a
## [code]user://[/code] config file so it survives restarts.  Access is static —
## there is no instance to create.

## Whole-UI magnification (Window.content_scale_factor).  Scales every Control
## uniformly, independent of window size.
const UI_SCALE := 2.0

## Linear 0..1 volume used until the user changes it (or if nothing is saved yet).
const DEFAULT_VOLUME := 1.0

const _CONFIG_PATH := "user://sound_test.cfg"
const _SECTION     := "audio"
const _KEY_VOLUME  := "volume"


## Load the persisted output volume (linear 0..1), or [constant DEFAULT_VOLUME].
static func load_volume() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(_CONFIG_PATH) != OK:
		return DEFAULT_VOLUME
	return clampf(float(cfg.get_value(_SECTION, _KEY_VOLUME, DEFAULT_VOLUME)), 0.0, 1.0)


## Persist the output volume so it is restored on next launch.
static func save_volume(v: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_CONFIG_PATH)   # preserve any other keys; fine if the file is absent
	cfg.set_value(_SECTION, _KEY_VOLUME, clampf(v, 0.0, 1.0))
	cfg.save(_CONFIG_PATH)
