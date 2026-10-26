@tool
extends RefCounted

## Small helpers for features that scan the whole project (symbol search, usages, TODOs).

const ADDONS: String = "res://addons/"

## All project files with one of the given extensions, from the editor's filesystem cache.
static func find_files(extensions: PackedStringArray, include_addons: bool) -> PackedStringArray:
	var files: PackedStringArray = []
	var root: EditorFileSystemDirectory = EditorInterface.get_resource_filesystem().get_filesystem()
	if root:
		_collect(root, extensions, include_addons, files)
	return files

static func _collect(dir: EditorFileSystemDirectory, extensions: PackedStringArray, include_addons: bool, out: PackedStringArray):
	if not include_addons and dir.get_path().begins_with(ADDONS):
		return
	for i: int in dir.get_subdir_count():
		_collect(dir.get_subdir(i), extensions, include_addons, out)
	for i: int in dir.get_file_count():
		var path: String = dir.get_file_path(i)
		if extensions.has(path.get_extension()):
			out.append(path)

## File contents split into lines. For scripts that are already loaded this uses the in-memory
## source, which the script editor keeps current, so unsaved edits are included.
static func read_lines(path: String) -> PackedStringArray:
	# Also covers built-in scripts, whose paths look like "res://scene.tscn::GDScript_abc".
	if ResourceLoader.has_cached(path):
		var script: Script = load(path) as Script
		if script and script.has_source_code():
			return script.source_code.split("\n")
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	return FileAccess.get_file_as_string(path).split("\n")

## Opens a script (or a scene's built-in script path) at a 0-based line in the script editor.
static func open_script_at(path: String, line: int, column: int = -1):
	var script: Script = load(path) as Script
	if not script:
		return
	EditorInterface.edit_script(script)
	EditorInterface.set_main_screen_editor(&"Script")
	# The editor needs a frame to switch before the caret can move.
	(func(): _set_caret_deferred(line, column)).call_deferred()

static func _set_caret_deferred(line: int, column: int):
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if not editor_base or not editor_base.get_base_editor() is CodeEdit:
		return
	var code_edit: CodeEdit = editor_base.get_base_editor()
	line = clampi(line, 0, code_edit.get_line_count() - 1)
	code_edit.set_caret_line(line)
	code_edit.set_caret_column(column if column >= 0 else code_edit.get_first_non_whitespace_column(line))
	code_edit.center_viewport_to_caret()
	code_edit.grab_focus()

## One warning toast in the editor's notification area (falls back to the output log).
static func toast(message: String):
	if EditorInterface.has_method(&"get_editor_toaster"):
		# 1 = EditorToaster.SEVERITY_WARNING; spelled out so older versions still parse this file.
		EditorInterface.call(&"get_editor_toaster").push_toast(message, 1)
	else:
		push_warning(message)
