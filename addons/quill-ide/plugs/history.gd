@tool
extends RefCounted

## Back/forward history, plus the per-project list of recently opened files.
## Switching scripts or jumping more than a screen adds an entry. Smaller moves just update
## the current one, so going back lands you where you actually were.

signal changed

const MAX_ENTRIES: int = 50
const MAX_RECENT_FILES: int = 30
const MIN_JUMP_LINES: int = 10
const PROJECT_METADATA_SECTION: String = "quill_ide"
const RECENT_FILES_KEY: String = "recent_files"

# Entries: { path, line, column }. index points at the current location.
var entries: Array[Dictionary] = []
var index: int = -1
var recent_files: PackedStringArray = []

var code_edit: CodeEdit
var last_text_version: int = -1
var navigating: bool = false

func init():
	recent_files = EditorInterface.get_editor_settings().get_project_metadata(PROJECT_METADATA_SECTION, RECENT_FILES_KEY, PackedStringArray())

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	script_editor.editor_script_changed.connect(_on_active_script_changed)
	_on_active_script_changed(script_editor.get_current_script())

func cleanup():
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)
	_detach_code_edit()

func can_go_back() -> bool:
	return index > 0

func can_go_forward() -> bool:
	return index < entries.size() - 1

func go_back():
	if not can_go_back():
		return
	_update_current(_current_location())
	index -= 1
	_open(entries[index])

func go_forward():
	if not can_go_forward():
		return
	_update_current(_current_location())
	index += 1
	_open(entries[index])

#region Recent files
func record_recent_file(path: String):
	if path.is_empty():
		return
	var existing: int = recent_files.find(path)
	if existing == 0:
		return
	if existing != -1:
		recent_files.remove_at(existing)
	recent_files.insert(0, path)
	if recent_files.size() > MAX_RECENT_FILES:
		recent_files.resize(MAX_RECENT_FILES)
	EditorInterface.get_editor_settings().set_project_metadata(PROJECT_METADATA_SECTION, RECENT_FILES_KEY, recent_files)
#endregion

func _on_active_script_changed(script: Script):
	_attach_current_code_edit()
	if script:
		record_recent_file(_get_file_path(script))
	if navigating:
		return
	var location: Dictionary = _current_location()
	if not location.is_empty():
		_push(location)

func _attach_current_code_edit():
	var new_code_edit: CodeEdit = null
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor_base and editor_base.get_base_editor() is CodeEdit:
		new_code_edit = editor_base.get_base_editor()
	if new_code_edit == code_edit:
		return

	_detach_code_edit()
	code_edit = new_code_edit
	if code_edit:
		last_text_version = code_edit.get_version()
		code_edit.caret_changed.connect(_on_caret_changed)

func _detach_code_edit():
	if is_instance_valid(code_edit) and code_edit.caret_changed.is_connected(_on_caret_changed):
		code_edit.caret_changed.disconnect(_on_caret_changed)
	code_edit = null

func _on_caret_changed():
	if navigating or not is_instance_valid(code_edit):
		return
	var location: Dictionary = _current_location()
	if location.is_empty():
		return

	# Typing, pasting and undo move the caret too, but that's not navigation.
	var text_version: int = code_edit.get_version()
	var edited: bool = text_version != last_text_version
	last_text_version = text_version

	var jump_lines: int = maxi(MIN_JUMP_LINES, code_edit.get_visible_line_count())
	var current: Dictionary = entries[index] if index >= 0 else {}
	if not edited and (current.is_empty() or current[&"path"] != location[&"path"] or absi(current[&"line"] - location[&"line"]) > jump_lines):
		_push(location)
	else:
		_update_current(location)

func _current_location() -> Dictionary:
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script or not is_instance_valid(code_edit):
		return {}
	return {
		&"path": script.resource_path,
		&"line": code_edit.get_caret_line(),
		&"column": code_edit.get_caret_column(),
	}

func _push(location: Dictionary):
	if index >= 0 and entries[index][&"path"] == location[&"path"] and entries[index][&"line"] == location[&"line"]:
		return
	entries.resize(index + 1)
	entries.append(location)
	if entries.size() > MAX_ENTRIES:
		entries.pop_front()
	index = entries.size() - 1
	changed.emit()

func _update_current(location: Dictionary):
	if location.is_empty() or index < 0 or entries[index][&"path"] != location[&"path"]:
		return
	entries[index] = location

func _open(entry: Dictionary):
	var path: String = entry[&"path"]
	var script: Script = null
	if ResourceLoader.has_cached(path) or ResourceLoader.exists(path):
		script = load(path) as Script
	if not script:
		# File's gone, just drop it.
		entries.remove_at(index)
		index = clampi(index, 0, entries.size() - 1)
		changed.emit()
		return

	# Opening the script fires the usual change signals; navigating stops us from recording them.
	navigating = true
	EditorInterface.edit_script(script)
	EditorInterface.set_main_screen_editor(&"Script")
	_finish_navigation.call_deferred(entry)

func _finish_navigation(entry: Dictionary):
	_attach_current_code_edit()
	if is_instance_valid(code_edit):
		var line: int = clampi(entry[&"line"], 0, code_edit.get_line_count() - 1)
		code_edit.set_caret_line(line)
		code_edit.set_caret_column(entry[&"column"])
		code_edit.center_viewport_to_caret()
		code_edit.grab_focus()
		last_text_version = code_edit.get_version()
	navigating = false
	changed.emit()

# Built-in scripts live inside a scene, so record the scene file instead.
func _get_file_path(resource: Resource) -> String:
	var path: String = resource.resource_path
	if path.contains("::"):
		path = path.get_slice("::", 0)
	return path
