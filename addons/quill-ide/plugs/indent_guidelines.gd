@tool
class_name IndentGuidelinesManager


const SETTINGS_ROOT: StringName = &"Quill/IndentGuidelines/"
const SETTINGS_VERSION: StringName = &"Quill/_indent_version"

# General
const GUIDELINES_DRAW: StringName = SETTINGS_ROOT + &"general/draw"

# Appearance
const GUIDELINES_COLOR: StringName = SETTINGS_ROOT + &"appearance/color"
const GUIDELINES_ACTIVE_COLOR: StringName = SETTINGS_ROOT + &"appearance/active_color"
const GUIDELINES_STYLE: StringName = SETTINGS_ROOT + &"appearance/style"
const GUIDELINES_DRAW_SIDE: StringName = SETTINGS_ROOT + &"appearance/draw_side"
const GUIDELINES_WIDTH: StringName = SETTINGS_ROOT + &"appearance/width"
const GUIDELINES_Y_OFFSET: StringName = SETTINGS_ROOT + &"appearance/y_offset"
const GUIDELINES_DRAW_ROOT_GUIDES: StringName = SETTINGS_ROOT + &"appearance/draw_root_guides"

# Behavior
const GUIDELINES_KEEP_CARET: StringName = SETTINGS_ROOT + &"behavior/keep_caret"

# Rainbow
const RAINBOW_ENABLED: StringName = SETTINGS_ROOT + &"rainbow/enabled"

# Foldmarks
const FOLDMARKS_DRAW: StringName = SETTINGS_ROOT + &"foldmarks/draw"
const FOLDMARKS_COLOR: StringName = SETTINGS_ROOT + &"foldmarks/color"
const FOLDMARKS_WIDTH: StringName = SETTINGS_ROOT + &"foldmarks/width"
const FOLDMARKS_X_OFFSET: StringName = SETTINGS_ROOT + &"foldmarks/x_offset"
const FOLDMARKS_Y_OFFSET: StringName = SETTINGS_ROOT + &"foldmarks/y_offset"

# Tweaks
const TWEAKS_COMPLETION_LINES: StringName = SETTINGS_ROOT + &"tweaks/completion_lines"
const TWEAKS_COMPLETION_MAX_WIDTH: StringName = SETTINGS_ROOT + &"tweaks/completion_max_width"

enum GuidelinesStyle { LINE, LINE_CLOSE }
enum GuidelinesOffset { LEFT = 0, MIDDLE, RIGHT }


var draw_guidelines: bool = true
var guideline_color: Color = Color(0.8, 0.8, 0.8, 0.3)
var guideline_active_color: Color = Color(0.8, 0.8, 0.8, 0.55)
var guidelines_style: GuidelinesStyle = GuidelinesStyle.LINE_CLOSE
var guideline_drawside: GuidelinesOffset = GuidelinesOffset.MIDDLE
var guideline_width: float = 1.0
var guideline_keep_caret: bool = true
var guideline_y_offset: float
var guideline_draw_root_guides: bool = false

var draw_foldmarks: bool = true
var foldmark_color: Color = Color(0.9, 0.9, 0.9, 0.9)
var foldmark_width: float = 3.0
var foldmark_x_offset: float = -3.0
var foldmark_y_offset: float

var tweak_completion_lines: int = 7
var tweak_completion_max_width: int = 50
var rainbow_enabled: bool = false


var ids_code_edits: Array[int]
var rids_code_edits: Array[RID]
var bound_draw_callables: Dictionary = {}

func _init() -> void:
	guideline_y_offset = -2.0 if Engine.get_version_info().hex >= 0x040400 else -1.0
	foldmark_y_offset = 0.0 if Engine.get_version_info().hex >= 0x040400 else 2.0

func init() -> void:
	if not Engine.is_editor_hint():
		return

	_register_settings()

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var on_script_changed: Signal = script_editor.editor_script_changed
	if not on_script_changed.is_connected(_editor_script_changed):
		on_script_changed.connect(_editor_script_changed)
		on_script_changed.emit(script_editor.get_current_script())

func cleanup() -> void:
	for i: int in len(ids_code_edits):
		var code_edit: CodeEdit = instance_from_id(ids_code_edits[i])
		if code_edit != null:
			var id: int = ids_code_edits[i]
			if bound_draw_callables.has(id):
				var bound_fn: Callable = bound_draw_callables[id]
				if code_edit.draw.is_connected(bound_fn):
					code_edit.draw.disconnect(bound_fn)
				bound_draw_callables.erase(id)
		if rids_code_edits[i].is_valid():
			RenderingServer.free_rid(rids_code_edits[i])
	ids_code_edits.clear()
	rids_code_edits.clear()

func handle_settings_change(changed_settings: PackedStringArray) -> void:
	var needs_redraw: bool = false
	for setting: String in changed_settings:
		if not setting.begins_with(SETTINGS_ROOT):
			continue
		needs_redraw = true
		_sync_setting(setting)

	if needs_redraw:
		for i: int in len(ids_code_edits):
			var code_edit: CodeEdit = instance_from_id(ids_code_edits[i])
			if code_edit != null:
				code_edit.add_theme_constant_override("completion_lines", tweak_completion_lines)
				code_edit.add_theme_constant_override("completion_max_width", tweak_completion_max_width)
				code_edit.queue_redraw()

func _register_settings() -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()

	var current_version: int = 2
	var stored_version: int = editor_settings.get_setting(SETTINGS_VERSION) if editor_settings.has_setting(SETTINGS_VERSION) else 0

	if stored_version < current_version:
		_migrate_settings(editor_settings)
		editor_settings.set_setting(SETTINGS_VERSION, current_version)

	_register_setting(editor_settings, GUIDELINES_DRAW, draw_guidelines, TYPE_BOOL)

	_register_setting(editor_settings, GUIDELINES_COLOR, guideline_color, TYPE_COLOR)
	_register_setting(editor_settings, GUIDELINES_ACTIVE_COLOR, guideline_active_color, TYPE_COLOR)
	_register_setting(editor_settings, GUIDELINES_STYLE, guidelines_style, TYPE_INT, PROPERTY_HINT_ENUM, "Line, Closed line")
	_register_setting(editor_settings, GUIDELINES_DRAW_SIDE, guideline_drawside, TYPE_INT, PROPERTY_HINT_ENUM, "Left, Middle, Right")
	_register_setting(editor_settings, GUIDELINES_WIDTH, guideline_width, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.5,5.0,0.5")
	_register_setting(editor_settings, GUIDELINES_Y_OFFSET, guideline_y_offset, TYPE_FLOAT, PROPERTY_HINT_RANGE, "-10,10,0.5")
	_register_setting(editor_settings, GUIDELINES_DRAW_ROOT_GUIDES, guideline_draw_root_guides, TYPE_BOOL)

	_register_setting(editor_settings, GUIDELINES_KEEP_CARET, guideline_keep_caret, TYPE_BOOL)

	_register_setting(editor_settings, RAINBOW_ENABLED, rainbow_enabled, TYPE_BOOL)

	_register_setting(editor_settings, FOLDMARKS_DRAW, draw_foldmarks, TYPE_BOOL)
	_register_setting(editor_settings, FOLDMARKS_COLOR, foldmark_color, TYPE_COLOR)
	_register_setting(editor_settings, FOLDMARKS_WIDTH, foldmark_width, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1,10,0.5")
	_register_setting(editor_settings, FOLDMARKS_X_OFFSET, foldmark_x_offset, TYPE_FLOAT, PROPERTY_HINT_RANGE, "-20,20,1")
	_register_setting(editor_settings, FOLDMARKS_Y_OFFSET, foldmark_y_offset, TYPE_FLOAT, PROPERTY_HINT_RANGE, "-10,10,0.5")

	_register_setting(editor_settings, TWEAKS_COMPLETION_LINES, tweak_completion_lines, TYPE_INT, PROPERTY_HINT_RANGE, "0,20,1")
	_register_setting(editor_settings, TWEAKS_COMPLETION_MAX_WIDTH, tweak_completion_max_width, TYPE_INT, PROPERTY_HINT_RANGE, "10,100,1")

func _migrate_settings(editor_settings: EditorSettings) -> void:
	var old_to_new: Dictionary = {
		"Quill/IndentGuidelines/guidelines/draw": "Quill/IndentGuidelines/general/draw",
		"Quill/IndentGuidelines/guidelines/color": "Quill/IndentGuidelines/appearance/color",
		"Quill/IndentGuidelines/guidelines/active_color": "Quill/IndentGuidelines/appearance/active_color",
		"Quill/IndentGuidelines/guidelines/style": "Quill/IndentGuidelines/appearance/style",
		"Quill/IndentGuidelines/guidelines/draw_side": "Quill/IndentGuidelines/appearance/draw_side",
		"Quill/IndentGuidelines/guidelines/width": "Quill/IndentGuidelines/appearance/width",
		"Quill/IndentGuidelines/guidelines/keep_caret": "Quill/IndentGuidelines/behavior/keep_caret",
		"Quill/IndentGuidelines/guidelines/y_offset": "Quill/IndentGuidelines/appearance/y_offset",
		"Quill/IndentGuidelines/guidelines/draw_root_guides": "Quill/IndentGuidelines/appearance/draw_root_guides"
	}
	for old_path: String in old_to_new:
		if editor_settings.has_setting(old_path):
			var val: Variant = editor_settings.get_setting(old_path)
			var new_path: String = old_to_new[old_path]
			editor_settings.erase(old_path)
			editor_settings.set_setting(new_path, val)

func _register_setting(editor_settings: EditorSettings, setting_name: StringName, default_value: Variant, type: int, hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not editor_settings.has_setting(setting_name):
		editor_settings.set_setting(setting_name, default_value)
		editor_settings.set_initial_value(setting_name, default_value, false)

	if hint != PROPERTY_HINT_NONE:
		var property_info: Dictionary = {
			"name": setting_name,
			"type": type,
			"hint": hint,
			"hint_string": hint_string
		}
		editor_settings.add_property_info(property_info)


	_sync_setting(setting_name)

func _sync_setting(setting_name: StringName) -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if not editor_settings.has_setting(setting_name):
		return

	match setting_name:
		GUIDELINES_DRAW: draw_guidelines = editor_settings.get_setting(setting_name)
		GUIDELINES_COLOR: guideline_color = editor_settings.get_setting(setting_name)
		GUIDELINES_ACTIVE_COLOR: guideline_active_color = editor_settings.get_setting(setting_name)
		GUIDELINES_STYLE: guidelines_style = editor_settings.get_setting(setting_name)
		GUIDELINES_DRAW_SIDE: guideline_drawside = editor_settings.get_setting(setting_name)
		GUIDELINES_WIDTH: guideline_width = editor_settings.get_setting(setting_name)
		GUIDELINES_KEEP_CARET: guideline_keep_caret = editor_settings.get_setting(setting_name)
		GUIDELINES_Y_OFFSET: guideline_y_offset = editor_settings.get_setting(setting_name)
		GUIDELINES_DRAW_ROOT_GUIDES: guideline_draw_root_guides = editor_settings.get_setting(setting_name)
		FOLDMARKS_DRAW: draw_foldmarks = editor_settings.get_setting(setting_name)
		FOLDMARKS_COLOR: foldmark_color = editor_settings.get_setting(setting_name)
		FOLDMARKS_WIDTH: foldmark_width = editor_settings.get_setting(setting_name)
		FOLDMARKS_X_OFFSET: foldmark_x_offset = editor_settings.get_setting(setting_name)
		FOLDMARKS_Y_OFFSET: foldmark_y_offset = editor_settings.get_setting(setting_name)
		TWEAKS_COMPLETION_LINES: tweak_completion_lines = editor_settings.get_setting(setting_name)
		TWEAKS_COMPLETION_MAX_WIDTH: tweak_completion_max_width = editor_settings.get_setting(setting_name)
		RAINBOW_ENABLED: rainbow_enabled = editor_settings.get_setting(setting_name)


func scaled(p_val: float) -> float:
	const editor_scale: int = 100
	return p_val * (float(editor_scale) / 100.0)

func get_next_unfolded_line(code_edit: CodeEdit, line: int) -> int:
	var p_lines_to: int = code_edit.get_line_count()

	if code_edit.is_line_code_region_start(line):
		var region_level: int = 0
		for i: int in range(line + 1, p_lines_to):
			if code_edit.is_line_code_region_start(i): region_level += 1
			if code_edit.is_line_code_region_end(i):
				if region_level == 0:
					line = i
					break
				region_level -= 1
	else:
		var start_in_comment: int = code_edit.is_in_comment(line)
		var start_in_string: int = code_edit.is_in_string(line) if start_in_comment == 1 else -1
		if start_in_string != -1 or start_in_comment != -1:
			var end_line: int = code_edit.get_delimiter_end_position(line, code_edit.get_line(line).length() - 1).y
			if end_line == line:
				for i: int in range(line + 1, p_lines_to):
					if start_in_string != -1 and code_edit.is_in_string(i) == -1: break
					if start_in_comment != -1 and code_edit.is_in_comment(i) == -1: break
					line = i
		else:
			var start_indent = code_edit.get_indent_level(line)
			for i: int in range(line + 1, p_lines_to):
				if code_edit.get_line(i).strip_edges().is_empty(): continue
				if code_edit.get_indent_level(i) > start_indent:
					line = i
					continue
				elif code_edit.is_in_comment(i) == -1 and code_edit.is_in_string(i) == -1:
					break
	return line + 1

func build_lines(code_edit: CodeEdit, p_lines_from: int, p_lines_to: int, output: Array[LineInCodeEditor], foldedlines: PackedInt32Array) -> void:
	var indent_size: int = code_edit.indent_size
	var skiped_lines: int = 0
	var internal_line: int = -1
	var tmp_lines: Array[LineInCodeEditor]
	var skip_was_folded: bool = false
	var line: int = p_lines_from

	while line < p_lines_to:
		internal_line += 1
		var current_line_indent: int = code_edit.get_indent_level(line)
		var current_indent_level: int = current_line_indent / indent_size

		var current_line_folded: bool = code_edit.is_line_folded(line)
		if not current_line_folded:
			if code_edit.get_line(line).strip_edges().length() == 0 \
				or (current_indent_level <= len(tmp_lines) and code_edit.is_in_comment(line) != -1 and code_edit.is_in_comment(line) == code_edit.get_first_non_whitespace_column(line)):
					skiped_lines += 1
					line += 1
					continue

		for i: int in range(current_indent_level, len(tmp_lines)):
			var v: LineInCodeEditor = tmp_lines[i]
			v.lineno_to = line - skiped_lines - 1
			v.close_width = code_edit.get_indent_level(v.lineno_to) - v.indent
			if skip_was_folded: v.close_width -= indent_size
			output.append(v)

		if current_indent_level < len(tmp_lines): tmp_lines.resize(current_indent_level)

		for i: int in current_indent_level:
			if len(tmp_lines) <= i:
				var l: LineInCodeEditor = LineInCodeEditor.new()
				l.start_x = internal_line - skiped_lines
				l.height = 1 + skiped_lines
				l.indent = i * indent_size
				l.lineno_from = line - skiped_lines
				l.lineno_to = p_lines_to - 1
				l.source_lineno = line
				tmp_lines.append(l)
			else:
				tmp_lines[i].height += 1 + skiped_lines

		skiped_lines = 0
		skip_was_folded = current_line_folded
		if skip_was_folded:
			foldedlines.append(internal_line)
			line = get_next_unfolded_line(code_edit, line) - 1
		line += 1

	var lines_count = code_edit.get_line_count()
	for i: int in len(tmp_lines):
		var v: LineInCodeEditor = tmp_lines[i]
		if p_lines_to == lines_count:
			v.lineno_to -= skiped_lines
			v.close_width = code_edit.get_indent_level(v.lineno_to) - v.indent
			if skip_was_folded: v.close_width -= indent_size
		else:
			v.lineno_to = p_lines_to - 1
			v.height += 1
		output.append(v)

func _editor_script_changed(_s: Script) -> void:
	var code_edit: CodeEdit = _try_get_code_edit()
	if not code_edit:
		return

	if Engine.get_version_info().hex >= 0x040600:
		code_edit.clip_contents = true


	for i: int in range(len(ids_code_edits) - 1, -1, -1):
		var id: int = ids_code_edits[i]
		if instance_from_id(id) == null:
			ids_code_edits.remove_at(i)
			rids_code_edits.remove_at(i)
			bound_draw_callables.erase(id)

	var draw_rid: RID = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(draw_rid, code_edit.get_canvas_item())

	var instance_id: int = code_edit.get_instance_id()
	ids_code_edits.push_back(instance_id)
	rids_code_edits.push_back(draw_rid)


	code_edit.add_theme_constant_override("completion_lines", tweak_completion_lines)
	code_edit.add_theme_constant_override("completion_max_width", tweak_completion_max_width)

	var bound_fn: Callable = _draw_appendix.bind(code_edit, draw_rid)
	bound_draw_callables[instance_id] = bound_fn
	code_edit.draw.connect(bound_fn)
	code_edit.queue_redraw()

func _try_get_code_edit() -> CodeEdit:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor:
		return null
	var editor_base: ScriptEditorBase = script_editor.get_current_editor()
	if not editor_base:
		return null
	var code_edit: Control = editor_base.get_base_editor()
	if code_edit is CodeEdit:
		var id: int = code_edit.get_instance_id()
		var found: bool = bound_draw_callables.has(id) and code_edit.draw.is_connected(bound_draw_callables[id])
		if not found:
			return code_edit
	return null

func _draw_appendix(code_edit: CodeEdit, draw_rid: RID) -> void:
	var lines_count: int = code_edit.get_line_count()
	var style_box: StyleBox = code_edit.get_theme_stylebox("normal")
	var font: Font = code_edit.get_theme_font("font")
	var font_size: int = code_edit.get_theme_font_size("font_size")
	var xmargin_beg: int = style_box.get_margin(SIDE_LEFT) + code_edit.get_total_gutter_width()
	var row_height: int = code_edit.get_line_height()
	var space_width: float = font.get_char_size(" ".unicode_at(0), font_size).x
	var indent_size: int = code_edit.indent_size

	var guideline_offset: float = [0.0, 0.5, 1.0].get(guideline_drawside) * space_width

	var v_scroll: float = code_edit.scroll_vertical
	var h_scroll: float = code_edit.scroll_horizontal

	RenderingServer.canvas_item_clear(draw_rid)

	var caret_idx: int = code_edit.get_caret_line()
	var caret_indent: int = code_edit.get_indent_level(caret_idx)

	var visible_lines_from: int = maxi(code_edit.get_first_visible_line(), 0)
	var visible_lines_to: int = mini(code_edit.get_last_full_visible_line() + int(code_edit.scroll_smooth) + 10, lines_count)

	var vscroll_delta: float = v_scroll - floorf(v_scroll)

	if lines_count - visible_lines_to <= 10:
		visible_lines_to = lines_count

	var output: Array[LineInCodeEditor]
	var foldedlines: PackedInt32Array
	build_lines(code_edit, visible_lines_from, visible_lines_to, output, foldedlines)

	if draw_guidelines:
		_draw_guidelines(code_edit, draw_rid, output, foldedlines, xmargin_beg, caret_idx, caret_indent, indent_size, space_width, guideline_offset, h_scroll, row_height, vscroll_delta, font, font_size)

	if draw_foldmarks:
		_draw_foldmarks(code_edit, draw_rid, foldedlines, xmargin_beg, row_height, vscroll_delta)

func _draw_guidelines(code_edit: CodeEdit, draw_rid: RID, output: Array[LineInCodeEditor], _foldedlines: PackedInt32Array,
		xmargin_beg: int, caret_idx: int, caret_indent: int, indent_size: int, space_width: float,
		guideline_offset: float, h_scroll: float, row_height: int, vscroll_delta: float,
		font: Font, font_size: int) -> void:

	if guideline_keep_caret:
		var caret_lines: Array[LineInCodeEditor]
		var _caret_foldedlines: PackedInt32Array

		var caret_from: int = 0
		var caret_to: int = 0
		if caret_idx < code_edit.get_first_visible_line():
			caret_from = maxi(caret_idx - 1, 0)
			caret_to = code_edit.get_first_visible_line() + 1
		elif caret_idx > code_edit.get_last_full_visible_line():
			caret_from = maxi(code_edit.get_last_full_visible_line() - 1, 0)
			caret_to = caret_idx + 1

		if caret_from != caret_to:
			build_lines(code_edit, caret_from, caret_to, caret_lines, _caret_foldedlines)
			caret_lines = caret_lines.filter(func(l: LineInCodeEditor) -> bool:
				return l.lineno_from <= caret_idx and caret_idx <= l.lineno_to and l.indent == caret_indent - indent_size
			)
			if len(caret_lines) == 1:
				var nl: LineInCodeEditor = caret_lines[0]
				for l: LineInCodeEditor in output:
					if l.lineno_from <= nl.lineno_from and nl.lineno_from <= l.lineno_to and nl.indent == l.indent:
						l.lineno_from = mini(l.lineno_from, nl.lineno_from)
						l.lineno_to = maxi(l.lineno_to, nl.lineno_to)
						break
					if l.lineno_from <= nl.lineno_to and nl.lineno_to <= l.lineno_to and nl.indent == l.indent:
						l.lineno_from = mini(l.lineno_from, nl.lineno_from)
						l.lineno_to = maxi(l.lineno_to, nl.lineno_to)
						break

	var points: PackedVector2Array
	var colors: PackedColorArray
	var block_ends: PackedInt32Array

	for line_data: LineInCodeEditor in output:
		if not guideline_draw_root_guides and line_data.indent == 0:
			continue

		var _x: float = xmargin_beg - h_scroll + guideline_offset + line_data.indent * space_width
		if _x < xmargin_beg:
			continue

		var color: Color
		if rainbow_enabled:
			color = _get_rainbow_color(code_edit, line_data, caret_idx, caret_indent, indent_size)
		else:
			color = guideline_color
			if caret_idx >= line_data.lineno_from and caret_idx <= line_data.lineno_to and caret_indent == line_data.indent + indent_size:
				color = guideline_active_color

		var line_no: int = line_data.lineno_to
		var offset_y: float = scaled(minf(block_ends.count(line_no) * 2.0, font.get_height(font_size) / 2.0) + 2.0)
		var point_start: Vector2 = Vector2(_x, row_height * (line_data.start_x - vscroll_delta) + guideline_y_offset)
		var point_end: Vector2 = point_start + Vector2(0.0, row_height * line_data.height - offset_y + guideline_y_offset)
		points.append_array([point_start, point_end])
		colors.append(color)

		if guidelines_style == GuidelinesStyle.LINE_CLOSE and line_data.close_width > 0:
			var point_side: Vector2 = point_end + Vector2(line_data.close_width * space_width - guideline_offset, 0.0)
			points.append_array([point_end, point_side])
			colors.append(color)
			block_ends.append(line_no)

	if len(points) > 0:
		RenderingServer.canvas_item_add_multiline(draw_rid, points, colors, guideline_width)

func _get_rainbow_color(code_edit: CodeEdit, line_data: LineInCodeEditor, caret_idx: int, caret_indent: int, indent_size: int) -> Color:
	var in_range: bool = caret_idx >= line_data.lineno_from and caret_idx <= line_data.lineno_to and caret_indent == line_data.indent + indent_size
	var is_active: bool = in_range
	var source_line: int = line_data.source_lineno if line_data.source_lineno >= 0 else line_data.lineno_from
	var line_text: String = code_edit.get_line(source_line).strip_edges()

	var keyword: String
	if line_text.begins_with("static "):
		var rest: String = line_text.substr(7).strip_edges()
		keyword = rest.get_slice(" ", 0)
	else:
		keyword = line_text.get_slice(" ", 0)

	var base_color: Color
	match keyword:
		"func":
			base_color = Color(1.0, 0.33, 0.33)
		"if", "elif", "else":
			base_color = Color(0.33, 0.53, 1.0)
		"for", "while":
			base_color = Color(0.33, 1.0, 0.53)
		"match":
			base_color = Color(1.0, 0.67, 0.2)
		"class", "class_name":
			base_color = Color(1.0, 1.0, 0.4)
		"enum":
			base_color = Color(0.33, 1.0, 1.0)
		"signal":
			base_color = Color(1.0, 0.4, 0.8)
		"var":
			base_color = Color(0.2, 0.8, 0.8)
		"const":
			base_color = Color(0.67, 0.67, 0.67)
		"extends":
			base_color = Color(0.67, 0.4, 1.0)
		"@export", "@onready":
			base_color = Color(0.4, 0.87, 0.4)
		_:
			base_color = guideline_color

	if not is_active and caret_indent == line_data.indent:
		var caret_text: String = code_edit.get_line(caret_idx).strip_edges()
		var caret_keyword: String
		if caret_text.begins_with("static "):
			caret_keyword = caret_text.substr(7).strip_edges().get_slice(" ", 0)
		else:
			caret_keyword = caret_text.get_slice(" ", 0)
		if _is_scope_keyword(caret_keyword):
			is_active = true

	if is_active:
		return Color(
			mini(base_color.r * 1.6, 1.0),
			mini(base_color.g * 1.6, 1.0),
			mini(base_color.b * 1.6, 1.0),
			mini(base_color.a * 1.8, 0.85)
		)
	else:
		return Color(base_color.r, base_color.g, base_color.b, 0.35)

func _is_scope_keyword(keyword: String) -> bool:
	match keyword:
		"func", "if", "elif", "else", "for", "while", "match", "class", "class_name", "enum", "signal":
			return true
	return false

func _draw_foldmarks(code_edit: CodeEdit, draw_rid: RID, foldedlines: PackedInt32Array, xmargin_beg: int, row_height: int, vscroll_delta: float) -> void:
	var _x: float = xmargin_beg + foldmark_x_offset
	var fm_points: PackedVector2Array
	var fm_colors: PackedColorArray

	for internal_line: int in foldedlines:
		var point_start: Vector2 = Vector2(_x, row_height * (internal_line - vscroll_delta) + foldmark_y_offset)
		var point_end: Vector2 = point_start + Vector2(0.0, row_height + foldmark_y_offset)
		fm_points.append_array([point_start, point_end])
		fm_colors.append(foldmark_color)

	if len(fm_points) > 0:
		RenderingServer.canvas_item_add_multiline(draw_rid, fm_points, fm_colors, foldmark_width)


class LineInCodeEditor:
	var start_x: int = 0
	var height: int = 1
	var indent: int = -1
	var lineno_from: int = -1
	var lineno_to: int = -1
	var close_width: int = 0
	var source_lineno: int = -1
