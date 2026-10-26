@tool
extends Control

## VS Code style smooth caret for one CodeEdit. Sits on top of the editor, makes the native caret
## transparent, and draws its own caret that animates toward wherever the real one is.
##
## Positions are kept in document space (view position + scroll), so a caret that's mid-glide isn't
## thrown off when the view scrolls under it, including by our own smooth scrolling.
##
## Block carets and overtype mode are left to Godot: there the caret also recolours the character
## under it, which an overlay can't reproduce, so we step aside and show the native one.

const NAME: StringName = &"QuillSmoothCaret"
const GODOT_CARET_COLOR: StringName = &"text_editor/theme/highlighting/caret_color"
const SCROLL_DURATION: float = 0.15

enum Mode { OFF, ALWAYS, EXPLICIT }
enum Motion { EASE_OUT, GLIDE, TRAIL }
enum BlinkStyle { SOLID, FADE }

var code_edit: CodeEdit
var mode: Mode = Mode.ALWAYS
var motion: Motion = Motion.GLIDE
## Glide length in seconds (the trail's head uses a bit less).
var duration: float = 0.09
## Catch-up rate for Ease out and for the trail's tail. Higher is snappier.
var speed: float = 20.0
## Seconds for caret moves caused by editing (typing, deleting, joining lines). 0 keeps the caret
## stuck to the text; anything long falls behind fast typing.
var typing_duration: float = 0.0
var blink_style: BlinkStyle = BlinkStyle.FADE
var smooth_scroll: bool = true

var native_caret_color: Color
var carets: Array[CaretState] = []
var last_text_version: int = -1
var last_line_height: float = -1.0
var last_size: Vector2 = Vector2.ZERO
# Document-space offset of the view, captured each frame for _draw.
var scroll_offset: Vector2 = Vector2.ZERO
var blink_elapsed: float = 0.0
var blink_alpha: float = 1.0
var stepped_aside: bool = false
var was_focused: bool = false

var last_scroll_v: float = 0.0
var scroll_animating: bool = false
var scroll_from: float = 0.0
var scroll_to: float = 0.0
var scroll_written: float = 0.0
var scroll_elapsed: float = 0.0

class CaretState:
	var cell: Vector2i = Vector2i(-1, -1)
	# All in document space; x < 0 means "not on screen".
	var head: Vector2 = Vector2(-1, -1)
	var tail: Vector2 = Vector2(-1, -1)
	var start: Vector2 = Vector2.ZERO
	var end: Vector2 = Vector2(-1, -1)
	var elapsed: float = 0.0
	var moving: bool = false
	# This move came from an edit, so it uses typing_duration.
	var typing: bool = false
	# Frames we've kept drawing the old spot while Godot's draw cache catches up, and whether an
	# edit happened during them.
	var hold_frames: int = 0
	var edit_pending: bool = false

func attach(target: CodeEdit, config: Dictionary):
	code_edit = target
	configure(config)
	name = NAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE

	# Prefer the colour the editor is actually using; the setting is the fallback in case a dead
	# instance left the caret transparent.
	native_caret_color = EditorInterface.get_editor_settings().get_setting(GODOT_CARET_COLOR)
	var current: Color = code_edit.get_theme_color(&"caret_color")
	if current.a > 0.0:
		native_caret_color = current

	code_edit.add_child(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	code_edit.caret_changed.connect(_restart_blink)
	last_text_version = code_edit.get_version()
	last_scroll_v = code_edit.scroll_vertical

func configure(config: Dictionary):
	mode = config.get(&"mode", mode)
	motion = config.get(&"motion", motion)
	duration = config.get(&"duration", duration)
	speed = config.get(&"speed", speed)
	typing_duration = config.get(&"typing_duration", typing_duration)
	blink_style = config.get(&"blink_style", blink_style)
	smooth_scroll = config.get(&"smooth_scroll", smooth_scroll)
	blink_alpha = 1.0
	queue_redraw()

## Puts the native caret back and removes the overlay.
func detach():
	if is_instance_valid(code_edit):
		if code_edit.caret_changed.is_connected(_restart_blink):
			code_edit.caret_changed.disconnect(_restart_blink)
		_show_native_caret()
	if get_parent():
		get_parent().remove_child(self)
	if not is_queued_for_deletion():
		queue_free()

func _process(delta: float):
	if not is_instance_valid(code_edit) or not is_visible_in_tree():
		return

	if code_edit.caret_type == TextEdit.CARET_TYPE_BLOCK or code_edit.is_overtype_mode_enabled():
		if not stepped_aside:
			stepped_aside = true
			_show_native_caret()
			queue_redraw()
		return
	stepped_aside = false
	# Godot re-applies its theme colours now and then (settings changes, theme reloads).
	_hide_native_caret()

	var count: int = code_edit.get_caret_count()
	if carets.size() != count:
		carets.clear()
		for i: int in count:
			carets.append(CaretState.new())

	var changed: bool = false
	if smooth_scroll and _update_scroll(delta):
		changed = true

	var line_height: float = code_edit.get_line_height()
	# Zoom or resize moves everything at once; don't animate that.
	var snap_all: bool = line_height != last_line_height or code_edit.size != last_size
	last_line_height = line_height
	last_size = code_edit.size
	scroll_offset = Vector2(code_edit.scroll_horizontal, code_edit.scroll_vertical * line_height)

	var text_version: int = code_edit.get_version()
	var edited: bool = text_version != last_text_version
	last_text_version = text_version

	var any_moving: bool = false
	for i: int in count:
		var state: CaretState = carets[i]
		var cell: Vector2i = Vector2i(code_edit.get_caret_line(i), code_edit.get_caret_column(i))
		var view_position: Vector2 = _get_caret_position(cell)

		if view_position.x < 0.0:
			# get_rect_at_line_column reads Godot's draw cache, so right after typing past the end of
			# a line it says "not visible" until Godot redraws. Hold the caret for a couple of frames
			# instead of letting it blink out. state.cell stays as it was, and we remember the edit,
			# so the move is still seen as typing once the position comes back.
			if state.head.x >= 0.0 and state.hold_frames < 2:
				state.hold_frames += 1
				state.edit_pending = state.edit_pending or edited
				continue
			if state.head.x >= 0.0:
				changed = true
			state.cell = cell
			state.head = Vector2(-1, -1)
			state.tail = state.head
			state.moving = false
			continue

		var cell_changed: bool = cell != state.cell
		state.cell = cell
		var caret_edited: bool = edited or state.edit_pending
		state.edit_pending = false
		state.hold_frames = 0
		var target: Vector2 = view_position + scroll_offset
		var previous_head: Vector2 = state.head
		var previous_tail: Vector2 = state.tail

		# The text changed and the caret's spot with it: typing, deleting, Enter, joining lines.
		var typing: bool = caret_edited and (cell_changed or target != state.end)
		if snap_all or state.head.x < 0.0 or (typing and (mode == Mode.EXPLICIT or typing_duration <= 0.0)):
			# Appearing, zooming, or an edit with typing animation off: stick to the text.
			state.head = target
			state.tail = target
			state.end = target
			state.moving = false
		else:
			if cell_changed or (not state.moving and target != state.head):
				state.start = state.head
				state.end = target
				state.elapsed = 0.0
				state.moving = true
				state.typing = typing
			elif target != state.end:
				# Same move, corrected target (Godot's caret x lands a frame late, folds shift lines).
				# Retarget without restarting, so the motion doesn't stutter.
				state.end = target
			_advance(state, delta)

		if state.head != previous_head or state.tail != previous_tail:
			changed = true
		any_moving = any_moving or state.moving

	# The caret only shows while the editor has focus, so gaining or losing it needs a redraw too.
	var focused: bool = code_edit.has_focus()
	if focused != was_focused:
		was_focused = focused
		changed = true

	# No point animating a blink nobody can see (the fade would otherwise redraw for nothing).
	if focused and _update_blink(delta, any_moving):
		changed = true

	# Only redraw when something changed; redrawing every frame would keep the editor from idling.
	if changed:
		queue_redraw()

func _advance(state: CaretState, delta: float):
	# Edits get a short, plain ease-out whatever the motion style, so typing never trails behind.
	if state.typing:
		state.elapsed += delta
		var t: float = clampf(state.elapsed / maxf(typing_duration, 0.001), 0.0, 1.0)
		state.head = state.start.lerp(state.end, _ease_out(t))
		state.tail = state.head
		state.moving = t < 1.0
		return

	match motion:
		Motion.EASE_OUT:
			# Covers the same fraction of the remaining distance per second, at any frame rate.
			state.head = state.head.lerp(state.end, 1.0 - exp(-speed * delta))
			if state.head.distance_squared_to(state.end) < 0.25:
				state.head = state.end
			state.tail = state.head
			state.moving = state.head != state.end
		Motion.GLIDE:
			state.elapsed += delta
			var t: float = clampf(state.elapsed / maxf(duration, 0.001), 0.0, 1.0)
			state.head = state.start.lerp(state.end, _ease_in_out(t))
			state.tail = state.head
			state.moving = t < 1.0
		Motion.TRAIL:
			# The head darts there quickly; the tail lags behind and the shape between them is drawn
			# as one stretched caret.
			state.elapsed += delta
			var t: float = clampf(state.elapsed / maxf(duration * 0.6, 0.001), 0.0, 1.0)
			state.head = state.start.lerp(state.end, _ease_out(t))
			state.tail = state.tail.lerp(state.head, 1.0 - exp(-speed * delta))
			if state.tail.distance_squared_to(state.head) < 0.25:
				state.tail = state.head
			state.moving = t < 1.0 or state.tail != state.head

# Returns true if the blink needs a redraw.
func _update_blink(delta: float, moving: bool) -> bool:
	var previous: float = blink_alpha
	if moving or not code_edit.caret_blink:
		# Solid while moving, like every editor does.
		blink_elapsed = 0.0
		blink_alpha = 1.0
	else:
		blink_elapsed += delta
		var interval: float = maxf(code_edit.caret_blink_interval, 0.05)
		var phase: float = fmod(blink_elapsed, interval * 2.0) / (interval * 2.0)
		if blink_style == BlinkStyle.SOLID:
			blink_alpha = 1.0 if phase < 0.5 else 0.0
		else:
			# A cosine pushed past 0..1 and clamped: holds fully on, fades out, holds off, fades in.
			blink_alpha = clampf(0.5 + 0.75 * cos(phase * TAU), 0.0, 1.0)
	# Skip redraws for changes too small to see, but always land exactly on fully on/off.
	return blink_alpha != previous and (absf(blink_alpha - previous) > 0.01 or blink_alpha == 0.0 or blink_alpha == 1.0)

# When a caret move makes the view jump (Page Down, Ctrl+End, go to line), rewind the scroll and
# ease it to where Godot put it. Scrolling by hand mid-way cancels it. Returns true while animating.
func _update_scroll(delta: float) -> bool:
	var current: float = code_edit.scroll_vertical
	if scroll_animating:
		if absf(current - scroll_written) > 0.01:
			# Someone else scrolled (wheel, scrollbar, typing re-centred the view). They win.
			scroll_animating = false
			last_scroll_v = current
			return false
		scroll_elapsed += delta
		var t: float = clampf(scroll_elapsed / SCROLL_DURATION, 0.0, 1.0)
		code_edit.scroll_vertical = lerpf(scroll_from, scroll_to, _ease_out(t))
		scroll_written = code_edit.scroll_vertical
		last_scroll_v = scroll_written
		scroll_animating = t < 1.0
		return true

	var main_cell: Vector2i = Vector2i(code_edit.get_caret_line(0), code_edit.get_caret_column(0))
	var caret_moved: bool = not carets.is_empty() and carets[0].cell.x >= 0 and main_cell != carets[0].cell
	if caret_moved and absf(current - last_scroll_v) >= 1.0:
		scroll_from = last_scroll_v
		scroll_to = current
		scroll_elapsed = 0.0
		scroll_animating = true
		code_edit.scroll_vertical = scroll_from
		scroll_written = code_edit.scroll_vertical
		last_scroll_v = scroll_written
		return true

	last_scroll_v = current
	return false

func _draw():
	if stepped_aside or not is_instance_valid(code_edit) or not code_edit.has_focus() or blink_alpha <= 0.0:
		return
	var color: Color = Color(native_caret_color, native_caret_color.a * blink_alpha)
	var caret_size: Vector2 = Vector2(maxf(1.0, code_edit.get_theme_constant(&"caret_width")), code_edit.get_line_height())
	var gutter_end: float = code_edit.get_total_gutter_width()

	for state: CaretState in carets:
		if state.head.x < 0.0:
			continue
		var head: Vector2 = state.head - scroll_offset
		var tail: Vector2 = state.tail - scroll_offset
		# Scrolled in under the gutter.
		if head.x < gutter_end:
			continue
		if head.distance_squared_to(tail) < 0.25:
			draw_rect(Rect2(head, caret_size), color)
			continue
		# Trail: one shape covering the caret at both ends.
		var corners: PackedVector2Array = [
			head, head + Vector2(caret_size.x, 0), head + caret_size, head + Vector2(0, caret_size.y),
			tail, tail + Vector2(caret_size.x, 0), tail + caret_size, tail + Vector2(0, caret_size.y),
		]
		var hull: PackedVector2Array = Geometry2D.convex_hull(corners)
		# convex_hull repeats the first point at the end; the polygon draw doesn't want that.
		if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
			hull.remove_at(hull.size() - 1)
		if hull.size() >= 3:
			draw_colored_polygon(hull, color)
		else:
			draw_rect(Rect2(head, caret_size), color)

# View-space top-left of the caret, or (-1, -1) if it's off screen.
# Measured from the text layout, which is current the moment text changes. (Godot's own caret draw
# position only updates when it next draws, a frame late, which made typing look laggy.)
# The caret sits on the left edge of the character after it; at the end of a line there's no such
# character, so use the right edge of the one before it.
func _get_caret_position(cell: Vector2i) -> Vector2:
	# An entirely empty editor returns a zero rect (no gutter offset); Godot's own position is right there.
	if code_edit.get_line_count() == 1 and code_edit.get_line(0).is_empty():
		var draw_pos: Vector2 = code_edit.get_caret_draw_pos()
		return _on_screen(Vector2(draw_pos.x, 0.0))

	var rect: Rect2i = code_edit.get_rect_at_line_column(cell.x, cell.y)
	if rect.position.y < 0:
		return Vector2(-1, -1)
	# Careful: for column c > 0 this rect is the character *before* c (TextServer's grapheme lookup
	# matches a glyph whose end equals c), so the caret is on its right edge. Column 0 gets the first
	# character, and the caret is on its left edge.
	if cell.y == 0:
		return _on_screen(Vector2(rect.position))
	return _on_screen(Vector2(rect.position.x + rect.size.x, rect.position.y))

func _on_screen(view_position: Vector2) -> Vector2:
	if view_position.x < 0.0 or view_position.x > code_edit.size.x:
		return Vector2(-1, -1)
	return view_position

static func _ease_in_out(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

static func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3.0)

func _restart_blink():
	blink_elapsed = 0.0
	if blink_alpha < 1.0:
		blink_alpha = 1.0
		queue_redraw()

func _hide_native_caret():
	var current: Color = code_edit.get_theme_color(&"caret_color")
	if current.a > 0.0:
		native_caret_color = current
		code_edit.add_theme_color_override(&"caret_color", Color(current, 0.0))

func _show_native_caret():
	code_edit.add_theme_color_override(&"caret_color", native_caret_color)
