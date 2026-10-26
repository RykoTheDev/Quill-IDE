@tool
extends RefCounted

## A second script pane next to the main editor.
##
## Godot can't make a second real script editor from a plugin, so the pane is a plain CodeEdit set
## up to look like the main one (same font, colours, GDScript highlighting). That means no
## autocomplete and no error checking in the pane.
##
## - Script also open in a main tab: the pane mirrors it live and is read-only, so the same file
##   can be looked at in two places without two copies of it going out of sync.
## - Script not open in a tab: the pane edits it directly, with its own Save (Ctrl+S in the pane).
##   If you later open it in a tab, unsaved pane edits are moved into that tab first.
##
## The pane is added by wrapping Godot's script TabContainer in an HSplitContainer; closing puts
## the TabContainer back exactly as it was.

const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

const SPLIT_NAME: StringName = &"QuillSplitView"
const CONFIRM_NAME: StringName = &"QuillSplitCloseConfirm"
const DISCARD_ACTION: StringName = &"discard"

enum PaneMode { NONE, MIRROR, EDIT }

# Theme items copied from the main editor so the pane looks the same.
const COPIED_COLORS: PackedStringArray = [
	"background_color", "font_color", "font_selected_color", "font_placeholder_color",
	"selection_color", "current_line_color", "caret_color", "word_highlighted_color",
	"search_result_color", "search_result_border_color", "line_number_color", "code_folding_color",
	"brace_mismatch_color", "bookmark_color", "line_length_guideline_color",
]
const COPIED_STYLEBOXES: PackedStringArray = ["normal", "focus"]
const COPIED_PROPERTIES: Array[StringName] = [
	&"gutters_draw_line_numbers", &"gutters_zero_pad_line_numbers", &"gutters_draw_fold_gutter",
	&"line_folding", &"indent_size", &"indent_use_spaces", &"indent_automatic",
	&"auto_brace_completion_enabled", &"auto_brace_completion_highlight_matching",
	&"highlight_current_line", &"highlight_all_occurrences", &"draw_tabs", &"draw_spaces",
	&"caret_blink", &"caret_blink_interval", &"scroll_smooth", &"wrap_mode", &"line_length_guidelines",
	&"delimiter_comments", &"delimiter_strings",
]

var tab_container: TabContainer
var split: HSplitContainer
var pane: VBoxContainer
var title_label: Label
var save_btn: Button
var code_edit: CodeEdit
var confirm_dialog: ConfirmationDialog

var path: String = ""
var mode: PaneMode = PaneMode.NONE
var mirror_source: CodeEdit
var modified: bool = false
var setting_text: bool = false
# File's modification time when the pane last loaded or saved it, to notice outside changes.
var disk_modified_time: int = 0
# What the tab container had before we wrapped it, so closing restores it exactly.
var original_size_flags_horizontal: int = Control.SIZE_EXPAND_FILL
# Kept between opens in this editor session, so the split comes back at the same ratio.
var remembered_split_offset: int = 0

func init(main_tab_container: TabContainer):
	tab_container = main_tab_container
	# A dead instance may have left the tabs wrapped in its split; unwrap them.
	var parent: Node = tab_container.get_parent()
	if parent and parent.name == SPLIT_NAME:
		_unwrap(parent as HSplitContainer)
	_free_named(EditorInterface.get_base_control(), CONFIRM_NAME)

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor.editor_script_changed.is_connected(_on_main_script_changed):
		script_editor.editor_script_changed.connect(_on_main_script_changed)
	var dock: FileSystemDock = EditorInterface.get_file_system_dock()
	if not dock.files_moved.is_connected(_on_file_moved):
		dock.files_moved.connect(_on_file_moved)
	if not dock.file_removed.is_connected(_on_file_removed):
		dock.file_removed.connect(_on_file_removed)

# Safe to call more than once.
func cleanup():
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_main_script_changed):
		script_editor.editor_script_changed.disconnect(_on_main_script_changed)
	var dock: FileSystemDock = EditorInterface.get_file_system_dock()
	if dock.files_moved.is_connected(_on_file_moved):
		dock.files_moved.disconnect(_on_file_moved)
	if dock.file_removed.is_connected(_on_file_removed):
		dock.file_removed.disconnect(_on_file_removed)
	# No one to ask at shutdown: keep the edits by saving them.
	close(true)
	if is_instance_valid(confirm_dialog):
		_free_node(confirm_dialog)
	confirm_dialog = null

func is_open() -> bool:
	return is_instance_valid(split)

## Shortcut: opens the current script in the pane (a second view of the same file), or closes it.
func toggle():
	if is_open():
		close()
		return
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script:
		return
	open(script.resource_path)

func open(script_path: String):
	if script_path.contains("::"):
		ProjectFiles.toast("Split view works with script files; built-in scripts can't be opened on their own.")
		return
	if script_path.is_empty() or not ResourceLoader.exists(script_path) or not is_instance_valid(tab_container):
		return
	if is_open() and script_path == path:
		code_edit.grab_focus()
		return
	# Moving to another script: keep the pane where it is if its unsaved edits can't be saved.
	if modified and not save():
		return

	_build_layout()
	path = script_path
	modified = false
	mode = PaneMode.NONE
	_refresh_mode()
	code_edit.grab_focus()

## Takes the pane away and puts the tabs back. With unsaved edits it asks first (Save / Don't Save
## / Cancel); force saves them without asking, for when the plugin is shutting down.
func close(force: bool = false):
	if not is_open():
		return
	if modified:
		if force:
			save()
		else:
			_ask_before_closing()
			return
	_close_now()

## Writes the pane's text to disk (edit mode only). Returns false if there was something to save
## and it couldn't be.
func save() -> bool:
	if not modified or mode != PaneMode.EDIT or path.is_empty() or not is_instance_valid(code_edit):
		return true
	var script: Script = load(path) as Script
	if not script:
		ProjectFiles.toast("Couldn't save %s: it no longer loads as a script." % path.get_file())
		return false
	script.source_code = code_edit.text
	var error: Error = ResourceSaver.save(script, path)
	if error != OK:
		ProjectFiles.toast("Couldn't save %s (error %d). Your changes are still in the split pane." % [path.get_file(), error])
		return false
	script.reload(true)
	EditorInterface.get_resource_filesystem().update_file(path)
	modified = false
	_remember_disk_state()
	_update_header()
	return true

## Editor settings changed: the main editor may have a new font, colours or indentation.
func handle_settings_change():
	if is_open():
		_match_main_editor.call_deferred()

## Project files changed: if the pane's file was changed by something else, reload it (or warn,
## when the pane has unsaved edits of its own).
func on_filesystem_changed():
	if not is_open() or mode != PaneMode.EDIT or path.is_empty() or not FileAccess.file_exists(path):
		return
	var modified_time: int = FileAccess.get_modified_time(path)
	if modified_time == disk_modified_time:
		return
	disk_modified_time = modified_time
	if modified:
		ProjectFiles.toast("%s changed on disk, but the split pane has unsaved edits. Saving the pane will overwrite the other changes." % path.get_file())
		return
	_load_from_disk()

#region Layout
func _build_layout():
	if is_instance_valid(split):
		return
	var host: Node = tab_container.get_parent()
	var index: int = tab_container.get_index()
	original_size_flags_horizontal = tab_container.size_flags_horizontal

	split = HSplitContainer.new()
	split.name = SPLIT_NAME
	split.size_flags_horizontal = tab_container.size_flags_horizontal
	split.size_flags_vertical = tab_container.size_flags_vertical
	split.split_offset = remembered_split_offset
	host.add_child(split)
	host.move_child(split, index)
	tab_container.reparent(split, false)
	tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	pane = VBoxContainer.new()
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(pane)

	var header: HBoxContainer = HBoxContainer.new()
	pane.add_child(header)

	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(title_label)

	if EditorInterface.has_method(&"popup_quick_open"):
		_add_header_button(header, "Open...", "Show another script here", _pick_script)
	_add_header_button(header, "Swap", "Swap with the script in the main editor", _swap)
	save_btn = _add_header_button(header, "Save", "Save this script (Ctrl+S in the pane)", save)
	var close_btn: Button = _add_header_button(header, "", "Close split view", close)
	close_btn.icon = EditorInterface.get_editor_theme().get_icon(&"Close", &"EditorIcons")

	code_edit = CodeEdit.new()
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code_edit.text_changed.connect(_on_pane_text_changed)
	code_edit.gui_input.connect(_on_pane_gui_input)
	pane.add_child(code_edit)
	_match_main_editor()
	_refresh_tab_bar_layout()

func _add_header_button(header: HBoxContainer, text: String, tooltip: String, action: Callable) -> Button:
	var button: Button = Button.new()
	button.text = text
	button.flat = true
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	header.add_child(button)
	return button

func _close_now():
	_disconnect_mirror()
	if is_instance_valid(split):
		remembered_split_offset = split.split_offset
		_unwrap(split)
	split = null
	pane = null
	code_edit = null
	title_label = null
	save_btn = null
	path = ""
	mode = PaneMode.NONE
	modified = false
	# Hand the keyboard back to the main editor.
	var main: CodeEdit = _current_main_code_edit()
	if main:
		main.grab_focus.call_deferred()

func _unwrap(old_split: HSplitContainer):
	var host: Node = old_split.get_parent()
	if host and is_instance_valid(tab_container) and tab_container.get_parent() == old_split:
		var index: int = old_split.get_index()
		tab_container.reparent(host, false)
		host.move_child(tab_container, index)
		tab_container.size_flags_horizontal = original_size_flags_horizontal
		_refresh_tab_bar_layout()
	_free_node(old_split)

# After the tab container moves, its TabBar keeps the tab positions it worked out for the old
# width; it only recomputes them when a tab's title or icon changes. (That's why saving, which
# changes a title, used to put the tabs right.) Nudge every title once the new layout has settled.
func _refresh_tab_bar_layout():
	var refresh: Callable = func():
		if not is_instance_valid(tab_container):
			return
		var tab_bar: TabBar = tab_container.get_tab_bar()
		for i: int in tab_bar.tab_count:
			var title: String = tab_bar.get_tab_title(i)
			tab_bar.set_tab_title(i, title + " ")
			tab_bar.set_tab_title(i, title)
		if tab_bar.current_tab >= 0:
			tab_bar.ensure_tab_visible(tab_bar.current_tab)
		tab_container.update_minimum_size()
		tab_container.queue_sort()
	# Once at the end of this frame and once on the next, after containers have re-sorted.
	refresh.call_deferred()
	(Engine.get_main_loop() as SceneTree).process_frame.connect(refresh, CONNECT_ONE_SHOT)

# Copies look and editing behaviour from the main script editor.
func _match_main_editor():
	var main: CodeEdit = _current_main_code_edit()
	if not main or not is_instance_valid(code_edit):
		return
	for property: StringName in COPIED_PROPERTIES:
		if property in main:
			code_edit.set(property, main.get(property))

	code_edit.add_theme_font_override(&"font", main.get_theme_font(&"font"))
	code_edit.add_theme_font_size_override(&"font_size", main.get_theme_font_size(&"font_size"))
	code_edit.add_theme_constant_override(&"line_spacing", main.get_theme_constant(&"line_spacing"))
	for color_name: String in COPIED_COLORS:
		code_edit.add_theme_color_override(color_name, main.get_theme_color(color_name))
	for stylebox_name: String in COPIED_STYLEBOXES:
		code_edit.add_theme_stylebox_override(stylebox_name, main.get_theme_stylebox(stylebox_name))
	# Mirror mode is read-only; keep it looking like normal code rather than greyed out.
	code_edit.add_theme_color_override(&"font_readonly_color", main.get_theme_color(&"font_color"))
	code_edit.add_theme_stylebox_override(&"read_only", main.get_theme_stylebox(&"normal"))

	# A copy of the main editor's highlighter (a highlighter can only serve one editor).
	if main.syntax_highlighter:
		code_edit.syntax_highlighter = main.syntax_highlighter.duplicate()
#endregion

#region Modes
func _refresh_mode():
	if not is_instance_valid(code_edit) or path.is_empty():
		return
	var main_edit: CodeEdit = _find_main_code_edit(path)

	if main_edit:
		# Already mirroring this exact editor: nothing to do (and nothing to reset).
		if mode == PaneMode.MIRROR and mirror_source == main_edit:
			return
		_disconnect_mirror()
		if modified:
			# Hand unsaved pane edits to the tab that just opened this script, as one undo step.
			main_edit.begin_complex_operation()
			main_edit.select_all()
			main_edit.insert_text_at_caret(code_edit.text)
			main_edit.end_complex_operation()
			modified = false
		mode = PaneMode.MIRROR
		mirror_source = main_edit
		mirror_source.text_changed.connect(_on_mirror_text_changed)
		# The tab can be closed without the script editor telling us; fall back to editing then.
		mirror_source.tree_exiting.connect(_on_mirror_gone)
		code_edit.editable = false
		_set_text_keep_view(main_edit.text)
		code_edit.clear_undo_history()
	elif mode != PaneMode.EDIT:
		# Switching into edit mode (or first load). Staying in edit mode on later tab switches
		# leaves the pane alone, so its undo history survives.
		_disconnect_mirror()
		mode = PaneMode.EDIT
		code_edit.editable = true
		if not modified:
			_load_from_disk()
	_update_header()

func _load_from_disk():
	_set_text_keep_view("\n".join(ProjectFiles.read_lines(path)))
	# Loaded text isn't the user's editing; don't let Ctrl+Z walk back through it.
	code_edit.clear_undo_history()
	_remember_disk_state()

func _remember_disk_state():
	disk_modified_time = FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0

func _disconnect_mirror():
	if is_instance_valid(mirror_source):
		if mirror_source.text_changed.is_connected(_on_mirror_text_changed):
			mirror_source.text_changed.disconnect(_on_mirror_text_changed)
		if mirror_source.tree_exiting.is_connected(_on_mirror_gone):
			mirror_source.tree_exiting.disconnect(_on_mirror_gone)
	mirror_source = null

func _on_mirror_gone():
	_disconnect_mirror()
	mode = PaneMode.NONE
	if is_open():
		_refresh_mode.call_deferred()

# Scripts were opened or closed in the main editor, which can flip the pane between modes.
func _on_main_script_changed(_script: Script):
	if is_open():
		_refresh_mode.call_deferred()

func _on_mirror_text_changed():
	if is_instance_valid(mirror_source) and is_instance_valid(code_edit):
		_set_text_keep_view(mirror_source.text)
		code_edit.clear_undo_history()

func _on_pane_text_changed():
	if setting_text or mode != PaneMode.EDIT:
		return
	if not modified:
		modified = true
		_update_header()

func _on_pane_gui_input(event: InputEvent):
	# Only in edit mode: when mirroring, Ctrl+S should reach Godot and save the main tab.
	if mode != PaneMode.EDIT:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S and event.is_command_or_control_pressed():
		save()
		code_edit.accept_event()

# Replaces the text without jumping the pane's scroll or caret around.
func _set_text_keep_view(text: String):
	if code_edit.text == text:
		return
	setting_text = true
	var scroll: float = code_edit.scroll_vertical
	var caret_line: int = code_edit.get_caret_line()
	var caret_column: int = code_edit.get_caret_column()
	code_edit.text = text
	code_edit.set_caret_line(mini(caret_line, code_edit.get_line_count() - 1), false)
	code_edit.set_caret_column(caret_column)
	code_edit.scroll_vertical = scroll
	setting_text = false

func _update_header():
	if not is_instance_valid(title_label):
		return
	var mirroring: bool = mode == PaneMode.MIRROR
	var suffix: String = "  (mirror, read-only)" if mirroring else ("  (*)" if modified else "")
	title_label.text = path.get_file() + suffix
	title_label.tooltip_text = path
	save_btn.visible = not mirroring
	save_btn.disabled = not modified
#endregion

#region Files moved or deleted
func _on_file_moved(old_file: String, new_file: String):
	if is_open() and old_file == path:
		path = new_file
		_remember_disk_state()
		_update_header()

func _on_file_removed(file: String):
	if not is_open() or file != path:
		return
	if modified:
		# Keep the text so it can still be copied out.
		ProjectFiles.toast("%s was deleted. The split pane still has your unsaved edits; copy them out before closing it." % file.get_file())
		code_edit.editable = true
		return
	_close_now()
#endregion

#region Actions
func _pick_script():
	var on_picked: Callable = func(picked: String):
		if not picked.is_empty():
			open(picked)
	EditorInterface.call(&"popup_quick_open", on_picked, [&"Script"] as Array[StringName])

# The pane shows the main editor's script and the main editor opens the pane's.
func _swap():
	var main_script: Script = EditorInterface.get_script_editor().get_current_script()
	if not main_script or main_script.resource_path.contains("::") or path.is_empty():
		return
	var pane_path: String = path
	if modified and not save():
		return
	EditorInterface.edit_script(load(pane_path))
	open(main_script.resource_path)

func _ask_before_closing():
	if not is_instance_valid(confirm_dialog):
		confirm_dialog = ConfirmationDialog.new()
		confirm_dialog.name = CONFIRM_NAME
		confirm_dialog.title = "Close Split View"
		confirm_dialog.ok_button_text = "Save"
		confirm_dialog.add_button("Don't Save", true, DISCARD_ACTION)
		confirm_dialog.confirmed.connect(_on_close_confirmed)
		confirm_dialog.custom_action.connect(_on_close_custom_action)
		EditorInterface.get_base_control().add_child(confirm_dialog)
	confirm_dialog.dialog_text = "Save changes to %s before closing the split view?" % path.get_file()
	confirm_dialog.popup_centered()

func _on_close_confirmed():
	if save():
		_close_now()

func _on_close_custom_action(action: StringName):
	if action == DISCARD_ACTION:
		confirm_dialog.hide()
		modified = false
		_close_now()
#endregion

func _current_main_code_edit() -> CodeEdit:
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor_base and editor_base.get_base_editor() is CodeEdit:
		return editor_base.get_base_editor()
	return null

# The main editor's CodeEdit for this script, if it's open in a tab. Pairs the open scripts with
# the open editors the same way the tabs do (text files have editors but aren't scripts).
func _find_main_code_edit(script_path: String) -> CodeEdit:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var scripts: Array[Script] = script_editor.get_open_scripts()
	var editors: Array[ScriptEditorBase] = []
	for editor: ScriptEditorBase in script_editor.get_open_script_editors():
		if editor.get_class() != &"TextEditor":
			editors.append(editor)
	if editors.size() != scripts.size():
		return null
	for i: int in scripts.size():
		if scripts[i].resource_path == script_path and editors[i].get_base_editor() is CodeEdit:
			return editors[i].get_base_editor()
	return null

static func _free_node(node: Node):
	if node.get_parent():
		node.get_parent().remove_child(node)
	if not node.is_queued_for_deletion():
		node.queue_free()

static func _free_named(parent: Node, node_name: StringName):
	var stale: Node = parent.get_node_or_null(NodePath(node_name))
	if stale:
		_free_node(stale)
