@tool
extends HBoxContainer

## Breadcrumb bar showing the class/function chain under the caret.
## Each crumb opens a popup of its sibling symbols to jump to.
## Also reports the top-level member under the caret so the outline can follow it.

signal top_level_symbol_changed(symbol_name: String)

const REPARSE_DELAY: float = 0.3
const SEPARATOR: String = "›"

const KIND_FUNC: StringName = &"func"
const KIND_CLASS: StringName = &"class"
const KIND_VAR: StringName = &"var"
const KIND_CONST: StringName = &"const"
const KIND_SIGNAL: StringName = &"signal"
const KIND_ENUM: StringName = &"enum"

var settings_manager: QuillSettingsManager
var icon_manager: IconManager

var tab_container: TabContainer
var code_edit: CodeEdit
var crumbs: HBoxContainer
var reparse_timer: Timer
var symbol_popup: PopupMenu

# Symbols in line order: { name, kind, line, end_line, indent, exported, parent }.
var symbols: Array[Dictionary] = []
var current_chain: Array[int] = []
var top_level_name: String = ""
var popup_symbols: Array[int] = []
var refresh_queued: bool = false

var symbol_regex: RegEx = RegEx.create_from_string(
	"^((?:@[\\w.]+(?:\\(.*?\\))?\\s+)*)(?:static\\s+)?(func|class|var|const|signal|enum)\\s+([A-Za-z_]\\w*)")

func init(settings_mgr: QuillSettingsManager, icon_mgr: IconManager) -> bool:
	settings_manager = settings_mgr
	icon_manager = icon_mgr
	name = &"QuillBreadcrumbs"

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var containers: Array[Node] = script_editor.find_children("*", "TabContainer", true, false)
	if containers.is_empty() or not containers[0].get_parent() is VBoxContainer:
		push_error("Required node not found for Quill breadcrumbs")
		return false
	tab_container = containers[0]

	clip_contents = true
	add_theme_constant_override(&"separation", 0)

	crumbs = HBoxContainer.new()
	crumbs.add_theme_constant_override(&"separation", 0)
	add_child(crumbs)

	reparse_timer = Timer.new()
	reparse_timer.one_shot = true
	reparse_timer.wait_time = REPARSE_DELAY
	reparse_timer.timeout.connect(_reparse)
	add_child(reparse_timer)

	symbol_popup = PopupMenu.new()
	symbol_popup.id_pressed.connect(_on_symbol_popup_id_pressed)
	add_child(symbol_popup)

	var host: Node = tab_container.get_parent()
	host.add_child(self)
	host.move_child(self, tab_container.get_index() + 1)

	script_editor.editor_script_changed.connect(_on_active_script_changed)
	_on_active_script_changed(null)
	return true

func cleanup():
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)
	_detach_code_edit()
	if get_parent():
		get_parent().remove_child(self)
	queue_free()

func handle_settings_change():
	_rebuild_crumbs()

func _on_active_script_changed(_script: Script):
	var new_code_edit: CodeEdit = null
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor_base and editor_base.get_base_editor() is CodeEdit:
		new_code_edit = editor_base.get_base_editor()

	if new_code_edit != code_edit:
		_detach_code_edit()
		code_edit = new_code_edit
		if code_edit:
			code_edit.caret_changed.connect(_queue_refresh)
			code_edit.text_changed.connect(reparse_timer.start)
	_reparse()

func _detach_code_edit():
	if is_instance_valid(code_edit):
		if code_edit.caret_changed.is_connected(_queue_refresh):
			code_edit.caret_changed.disconnect(_queue_refresh)
		if code_edit.text_changed.is_connected(reparse_timer.start):
			code_edit.text_changed.disconnect(reparse_timer.start)
	code_edit = null

func _is_gdscript_open() -> bool:
	return is_instance_valid(code_edit) and EditorInterface.get_script_editor().get_current_script() is GDScript

func _reparse():
	symbols.clear()
	if _is_gdscript_open():
		_parse_symbols()
	_refresh(true)

func _queue_refresh():
	if refresh_queued:
		return
	refresh_queued = true
	_refresh.call_deferred()

func _refresh(force: bool = false):
	refresh_queued = false
	var chain: Array[int] = []
	if _is_gdscript_open():
		chain = _chain_at_line(code_edit.get_caret_line())
	if not force and chain == current_chain:
		return
	current_chain = chain
	_rebuild_crumbs()

	var top: String = symbols[chain[0]][&"name"] if not chain.is_empty() else ""
	if top != top_level_name:
		top_level_name = top
		top_level_symbol_changed.emit(top)

#region Parsing
# Indentation-based scan: a symbol's scope runs until the next code line at the same or lower indent.
# Comments, blank lines, multiline strings and lines starting with a closing bracket don't end a scope.
func _parse_symbols():
	var indent_size: int = code_edit.indent_size
	var stack: Array[int] = []
	var last_code_line: int = -1
	var in_multiline_string: bool = false
	var pending_annotations: String = ""

	for i: int in code_edit.get_line_count():
		var line: String = code_edit.get_line(i)
		var stripped: String = line.strip_edges()
		var quote_count: int = stripped.count("\"\"\"") + stripped.count("'''")

		if in_multiline_string:
			if quote_count % 2 == 1:
				in_multiline_string = false
				last_code_line = i
			continue
		if stripped.is_empty() or stripped.begins_with("#"):
			continue

		var indent: int = _indent_width(line, indent_size)
		if not stripped[0] in ")]}":
			while not stack.is_empty() and indent <= symbols[stack.back()][&"indent"]:
				symbols[stack.pop_back()][&"end_line"] = last_code_line

		var result: RegExMatch = symbol_regex.search(stripped)
		if result:
			var annotations: String = pending_annotations + " " + result.get_string(1)
			symbols.append({
				&"name": result.get_string(3),
				&"kind": StringName(result.get_string(2)),
				&"line": i,
				&"end_line": i,
				&"indent": indent,
				&"exported": annotations.contains("@export"),
				&"parent": stack.back() if not stack.is_empty() else -1,
			})
			stack.push_back(symbols.size() - 1)
			pending_annotations = ""
		elif stripped.begins_with("@"):
			pending_annotations += " " + stripped
		else:
			pending_annotations = ""

		last_code_line = i
		if quote_count % 2 == 1:
			in_multiline_string = true

	for index: int in stack:
		symbols[index][&"end_line"] = last_code_line

func _indent_width(line: String, indent_size: int) -> int:
	var width: int = 0
	for c: String in line:
		if c == "\t":
			width += indent_size
		elif c == " ":
			width += 1
		else:
			break
	return width

func _chain_at_line(line: int) -> Array[int]:
	# Nested symbols start after their parents, so the last symbol containing the line is the innermost.
	var innermost: int = -1
	for i: int in symbols.size():
		var symbol: Dictionary = symbols[i]
		if symbol[&"line"] > line:
			break
		if line <= symbol[&"end_line"]:
			innermost = i

	var chain: Array[int] = []
	while innermost != -1:
		chain.push_front(innermost)
		innermost = symbols[innermost][&"parent"]
	return chain
#endregion

#region UI
func _rebuild_crumbs():
	for child: Node in crumbs.get_children():
		crumbs.remove_child(child)
		child.queue_free()

	visible = settings_manager.show_breadcrumbs and _is_gdscript_open()
	if not visible:
		return

	var script: Script = EditorInterface.get_script_editor().get_current_script()
	var root_name: String = script.resource_path.get_file()
	if root_name.is_empty():
		root_name = script.resource_path
	_add_crumb(root_name, icon_manager.get_icon_for_script(script), -1, -1)

	for index: int in current_chain:
		var separator: Label = Label.new()
		separator.text = SEPARATOR
		separator.modulate.a = 0.5
		crumbs.add_child(separator)

		var symbol: Dictionary = symbols[index]
		_add_crumb(symbol[&"name"], _get_symbol_icon(symbol), symbol[&"parent"], index)

func _add_crumb(text: String, icon: Texture2D, sibling_parent: int, symbol_index: int):
	var button: Button = Button.new()
	button.flat = true
	button.text = text
	button.icon = icon
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = "Show members" if symbol_index == -1 else "Show siblings"
	button.pressed.connect(_show_symbol_popup.bind(sibling_parent, symbol_index, button))
	crumbs.add_child(button)

func _get_symbol_icon(symbol: Dictionary) -> Texture2D:
	match symbol[&"kind"]:
		KIND_FUNC: return icon_manager.get_func_icon(symbol[&"name"])
		KIND_CLASS: return icon_manager.class_icon
		KIND_SIGNAL: return icon_manager.signal_icon
		KIND_CONST, KIND_ENUM: return icon_manager.constant_icon
		KIND_VAR: return icon_manager.export_icon if symbol[&"exported"] else icon_manager.property_icon
	return null

func _show_symbol_popup(sibling_parent: int, current_index: int, anchor: Control):
	symbol_popup.clear()
	popup_symbols.clear()
	for i: int in symbols.size():
		if symbols[i][&"parent"] != sibling_parent:
			continue
		symbol_popup.add_icon_item(_get_symbol_icon(symbols[i]), symbols[i][&"name"], popup_symbols.size())
		popup_symbols.append(i)

	if popup_symbols.is_empty():
		return

	symbol_popup.reset_size()
	# The bar sits below the code, so open upwards.
	var popup_position: Vector2 = anchor.get_screen_position()
	popup_position.y -= symbol_popup.size.y
	symbol_popup.popup(Rect2i(Vector2i(popup_position), Vector2i.ZERO))

	var focused: int = popup_symbols.find(current_index)
	if focused != -1:
		symbol_popup.set_focused_item(focused)

func _on_symbol_popup_id_pressed(id: int):
	if id < 0 or id >= popup_symbols.size():
		return
	var line: int = symbols[popup_symbols[id]][&"line"]

	EditorInterface.get_script_editor().goto_line(line)
	if is_instance_valid(code_edit):
		code_edit.set_caret_line(line)
		code_edit.set_caret_column(code_edit.get_first_non_whitespace_column(line))
		code_edit.center_viewport_to_caret()
		code_edit.grab_focus()
#endregion
