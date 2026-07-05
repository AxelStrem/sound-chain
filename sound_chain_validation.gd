class_name SoundChainValidator
## Static validation + interval helpers for SoundChain arrangements.
##
## [method validate] scans a loaded [code]SoundChain[/code] (via its public
## accessors) and returns a flat list of "issue" dictionaries that a UI can index
## by target to show warnings.  It is deliberately rule-based: adding a new check
## later is just writing one more [code]_rule_*[/code] function and appending it
## to the list in [method _rules].
##
## Progress ranges use the same [code][[lo, hi], …][/code] format as segments and
## tracks; an empty list means "always" (the whole [0, 1] span).  The interval
## helpers here (overlap / merge / intersect / format) are also used by the UI to
## compute each track's "effective" startable range.

enum Severity { WARNING, ERROR }


## Run every rule over [param chain] and return the collected issues.  Each issue:
## [code]{ severity, target_type: "track"|"segment", target, code, message }[/code].
static func validate(chain) -> Array:
	var issues: Array = []
	for rule in _rules():
		issues.append_array(rule.call(chain))
	return issues


## The ordered list of rule callables.  Append new rules here.
static func _rules() -> Array:
	return [
		Callable(SoundChainValidator, "_rule_start_seg_progress_overlap"),
	]


static func _issue(severity: Severity, target_type: String, target: String,
		code: StringName, message: String) -> Dictionary:
	return {
		"severity": severity,
		"target_type": target_type,
		"target": target,
		"code": code,
		"message": message,
	}

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

## A start segment whose own progress range never overlaps its track's main-file
## progress range can never actually start that track — warn on the track.
static func _rule_start_seg_progress_overlap(chain) -> Array:
	var out: Array = []
	for track in chain.get_track_names():
		var cfg: Dictionary = chain.get_track_config(track)
		var track_range: Array = cfg.get("progress", [])
		var starts: Dictionary = cfg.get("start_segments", {})
		for seg_name in starts:
			var seg: Dictionary = chain.get_segment(seg_name)
			if seg.is_empty():
				continue  # missing-segment references are a separate concern
			var seg_range: Array = seg.get("progress", [])
			if not ranges_overlap(track_range, seg_range):
				out.append(_issue(Severity.WARNING, "track", track, &"start_seg_progress",
					"start segment '%s' range %s never overlaps track range %s" %
					[seg_name, format_ranges(seg_range), format_ranges(track_range)]))
	return out

# ---------------------------------------------------------------------------
# Interval helpers (format: [[lo, hi], …]; empty == whole [0, 1] span)
# ---------------------------------------------------------------------------

## Coerce an interval list into a normalized, sorted, merged form.  An empty list
## becomes the full [0, 1] span.
static func normalize_ranges(r: Array) -> Array:
	var ivs: Array = []
	if r.is_empty():
		return [[0.0, 1.0]]
	for iv in r:
		if iv is Array and iv.size() >= 2:
			ivs.append([minf(float(iv[0]), float(iv[1])), maxf(float(iv[0]), float(iv[1]))])
	if ivs.is_empty():
		return [[0.0, 1.0]]
	ivs.sort_custom(func(a, b): return a[0] < b[0])
	var merged: Array = [ivs[0]]
	for i in range(1, ivs.size()):
		var last: Array = merged[-1]
		var cur: Array = ivs[i]
		if cur[0] <= last[1]:
			last[1] = maxf(last[1], cur[1])
		else:
			merged.append(cur)
	return merged


## Union of two interval lists.
static func merge_ranges(a: Array, b: Array) -> Array:
	return normalize_ranges(a + b)


## Intersection of two interval lists.  May be empty (no overlap).
static func intersect_ranges(a: Array, b: Array) -> Array:
	var na := normalize_ranges(a)
	var nb := normalize_ranges(b)
	var out: Array = []
	for ia in na:
		for ib in nb:
			var lo := maxf(ia[0], ib[0])
			var hi := minf(ia[1], ib[1])
			if lo <= hi:
				out.append([lo, hi])
	return out  # already disjoint & sorted (na, nb are)


## True when the two interval lists share any point.
static func ranges_overlap(a: Array, b: Array) -> bool:
	return not intersect_ranges(a, b).is_empty()


## Human-readable form, e.g. "0.0-0.3" or "0.0-0.3, 0.6-1.0"; "∅" when empty.
static func format_ranges(r: Array) -> String:
	if r.is_empty():
		return "∅"
	var parts: PackedStringArray = []
	for iv in r:
		if iv is Array and iv.size() >= 2:
			parts.append("%s-%s" % [_fmt(float(iv[0])), _fmt(float(iv[1]))])
	return ", ".join(parts)


## Trim a progress value to at most 2 decimals, keeping at least one (0 → "0.0").
static func _fmt(v: float) -> String:
	var s := "%.2f" % v
	if s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	return s
