@tool
class_name TabManager

const BUILT_IN_SCRIPT: StringName = &"::GDScript"

var scripts_tab_container: TabContainer
var scripts_tab_bar: TabBar
var script_filter_txt: LineEdit
var scripts_item_list: ItemList
var panel_container: Node

var selected_tab: int = -1
var last_tab_hovered: int = -1
var sync_script_list: bool = false
var file_to_navigate: String = &""
var tab_state: TabStateCache
var old_script_editor_base: ScriptEditorBase

var settings_manager: QuillSettingsManager
var icon_manager: IconManager
var left_side_panel: Control

var _closing_tabs: bool = false

const TAB_THEME: Theme = preload("uid://dr3t6l2rux68p")

signal script_tab_changed(script: Script)
## After every tab refresh, with the tab index -> script map (pins and groups re-apply on this).
signal tabs_updated(tab_scripts: Dictionary)

## Set by the tab extras: returns true for a script path that's pinned. Pinned tabs are skipped by
## auto-close, "close others", middle click and the tab's close button.
var is_pinned: Callable = func(_path: String) -> bool: return false

## Returns false (and changes nothing) if the editor nodes we need aren't there.
func init(settings_mgr: QuillSettingsManager, icon_mgr: IconManager) -> bool:
	settings_manager = settings_mgr
	icon_manager = icon_mgr

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var split_container: Node = find_or_null(script_editor.find_children("*", "HSplitContainer", true, false))
	# First ItemList in the script editor is the open-scripts list. We mostly hide it,
	# but it's still what Godot uses to switch/close scripts, so we drive it from the tabs.
	var found_list: ItemList = find_or_null(script_editor.find_children("*", "ItemList", true, false))
	var found_filter: LineEdit = find_or_null(found_list.get_parent().find_children("*", "LineEdit", true, false)) if found_list else null
	var found_tabs: TabContainer = find_or_null(script_editor.find_children("*", "TabContainer", true, false))
	if not split_container or split_container.get_child_count() == 0 or not found_list or not found_filter or not found_tabs:
		return false

	left_side_panel = split_container.get_child(0)
	scripts_item_list = found_list
	scripts_item_list.allow_reselect = true

	script_filter_txt = found_filter
	script_filter_txt.gui_input.connect(_on_script_filter_input)

	scripts_tab_container = found_tabs
	scripts_tab_bar = scripts_tab_container.get_tab_bar()

	tab_state = TabStateCache.new()
	tab_state.save(scripts_tab_container, scripts_tab_bar)

	scripts_tab_bar.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	scripts_tab_container.tabs_visible = settings_manager.is_script_tabs_visible
	scripts_tab_container.drag_to_rearrange_enabled = true
	update_tabs_position()

	scripts_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
	scripts_tab_bar.drag_to_rearrange_enabled = true
	scripts_tab_bar.select_with_rmb = true

	scripts_tab_bar.tab_close_pressed.connect(_on_tab_close)
	scripts_tab_bar.tab_rmb_clicked.connect(_on_tab_rmb)
	scripts_tab_bar.tab_hovered.connect(_on_tab_hovered)
	scripts_tab_bar.mouse_exited.connect(_on_tab_bar_mouse_exited)
	scripts_tab_bar.active_tab_rearranged.connect(_on_active_tab_rearranged)
	scripts_tab_bar.gui_input.connect(_on_tab_bar_gui_input)
	scripts_tab_bar.tab_changed.connect(_on_tab_changed)

	panel_container = scripts_item_list.get_parent().get_parent()

	update_script_list_visibility()
	_update_minimalism()
	_on_tab_changed(scripts_tab_bar.current_tab)

	if not script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.connect(_on_active_script_changed)
	return true

# Safe to call more than once, or after a failed init.
func cleanup():
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)

	if is_instance_valid(proxy_menu):
		if proxy_menu.get_parent():
			proxy_menu.get_parent().remove_child(proxy_menu)
		proxy_menu.queue_free()
	proxy_menu = null
	godot_menu = null

	if is_instance_valid(old_script_editor_base):
		if old_script_editor_base.edited_script_changed.is_connected(_on_script_changed):
			old_script_editor_base.edited_script_changed.disconnect(_on_script_changed)
		var old_code_edit: Control = old_script_editor_base.get_base_editor()
		if old_code_edit is CodeEdit and old_code_edit.text_changed.is_connected(_on_script_text_changed):
			old_code_edit.text_changed.disconnect(_on_script_text_changed)
	old_script_editor_base = null

	if is_instance_valid(scripts_tab_container):
		tab_state.restore(scripts_tab_container, scripts_tab_bar)

		for connection: Array in [
			[scripts_tab_bar.mouse_exited, _on_tab_bar_mouse_exited],
			[scripts_tab_bar.gui_input, _on_tab_bar_gui_input],
			[scripts_tab_bar.tab_close_pressed, _on_tab_close],
			[scripts_tab_bar.tab_rmb_clicked, _on_tab_rmb],
			[scripts_tab_bar.tab_hovered, _on_tab_hovered],
			[scripts_tab_bar.active_tab_rearranged, _on_active_tab_rearranged],
			[scripts_tab_bar.tab_changed, _on_tab_changed],
		]:
			var tab_signal: Signal = connection[0]
			if tab_signal.is_connected(connection[1]):
				tab_signal.disconnect(connection[1])

		# Undo _customize_tabbar.
		for stylebox: StringName in [&"tab_unselected", &"tab_hovered", &"tab_selected", &"tab_focus"]:
			scripts_tab_bar.remove_theme_stylebox_override(stylebox)
	scripts_tab_container = null
	scripts_tab_bar = null

	if is_instance_valid(scripts_item_list):
		scripts_item_list.allow_reselect = false
		scripts_item_list.get_parent().visible = true
	scripts_item_list = null

	if is_instance_valid(script_filter_txt) and script_filter_txt.gui_input.is_connected(_on_script_filter_input):
		script_filter_txt.gui_input.disconnect(_on_script_filter_input)
	script_filter_txt = null

	if is_instance_valid(left_side_panel):
		left_side_panel.visible = true
	left_side_panel = null

func update_editor():
	if not scripts_tab_container:
		return
	update_script_text_filter()

	if sync_script_list:
		if file_to_navigate != &"":
			EditorInterface.get_file_system_dock().navigate_to_path(file_to_navigate)
			EditorInterface.get_script_editor().get_current_editor().get_base_editor().grab_focus()
			file_to_navigate = &""

		sync_tab_with_script_list()
		sync_script_list = false

	update_tabs()

	if scripts_tab_bar: _customize_tabbar(scripts_tab_bar)

func _on_active_script_changed(script: Script):
	if settings_manager and settings_manager.is_auto_close_scripts and not _closing_tabs:
		_closing_tabs = true
		call_deferred("_close_other_tabs_deferred")

	update_tabs()

func _close_other_tabs_deferred():
	_close_all_except(scripts_tab_bar.current_tab)
	_closing_tabs = false

## Called by the plugin when a script is saved to disk (EditorPlugin.resource_saved).
func on_script_saved(_script: Script):
	# Any tab could be the one saved (Save All), and update_tabs() is cheap.
	update_tabs()

func _customize_tabbar(tab_bar: TabBar) -> void:
	var editor_settings = EditorInterface.get_editor_settings()
	var base_color: Color = editor_settings.get_setting("interface/theme/base_color")
	var contrast_factor: float = 0.25
	var bg_color: Color = base_color.darkened(contrast_factor)
	tab_bar.theme = TAB_THEME
	var sb_normal = TAB_THEME.get_stylebox("tab_unselected", "TabBar").duplicate()
	sb_normal.bg_color = base_color
	
	var sb_hover = TAB_THEME.get_stylebox("tab_hovered", "TabBar").duplicate()
	sb_hover.bg_color = Color(0.146, 0.167, 0.2)
	
	var sb_focus = TAB_THEME.get_stylebox("tab_selected", "TabBar").duplicate()
	sb_focus.bg_color = bg_color
	sb_focus.expand_margin_bottom = 0
	
	tab_bar.add_theme_stylebox_override("tab_unselected", sb_normal)
	tab_bar.add_theme_stylebox_override("tab_hovered", sb_hover)
	tab_bar.add_theme_stylebox_override("tab_selected", sb_focus)
	tab_bar.add_theme_stylebox_override("tab_focus", sb_focus)


func handle_settings_change(changed_settings: PackedStringArray, settings_mgr: QuillSettingsManager):
	settings_manager = settings_mgr

	for setting: String in changed_settings:
		if setting == settings_manager.SCRIPT_LIST_VISIBLE:
			update_script_list_visibility()
		elif setting == settings_manager.SCRIPT_TABS_VISIBLE:
			scripts_tab_container.tabs_visible = settings_manager.is_script_tabs_visible
		elif setting == settings_manager.MINIMALISM:
			_update_minimalism()

func _update_minimalism():
	if not settings_manager or not left_side_panel:
		return
	var minimalism: bool = settings_manager.is_minimalism

	if minimalism:
		left_side_panel.visible = false
		scripts_tab_container.tabs_visible = false
	else:
		left_side_panel.visible = true
		update_script_list_visibility()
		scripts_tab_container.tabs_visible = settings_manager.is_script_tabs_visible

func cycle_tab_forward():
	var new_tab: int = scripts_tab_container.current_tab + 1
	if new_tab == scripts_tab_container.get_tab_count():
		new_tab = 0
	scripts_tab_container.current_tab = new_tab

func cycle_tab_backward():
	var new_tab: int = scripts_tab_container.current_tab - 1
	if new_tab == -1:
		new_tab = scripts_tab_container.get_tab_count() - 1
	scripts_tab_container.current_tab = new_tab

# Clears the script list filter. A filtered list hides items, which breaks
# anything that clicks the list by tab index.
func update_script_text_filter():
	if script_filter_txt.text != &"":
		script_filter_txt.text = &""
		script_filter_txt.text_changed.emit(&"")

func update_script_list_visibility():
	if not scripts_item_list or not settings_manager:
		return
	scripts_item_list.get_parent().visible = settings_manager.is_script_list_visible

func update_tabs():
	if not scripts_tab_container:
		return
	var tab_scripts: Dictionary[int, Script] = get_tab_scripts()
	for index: int in scripts_tab_container.get_tab_count():
		update_tab(index, tab_scripts.get(index))
	tabs_updated.emit(tab_scripts)

## Whether the tab at this index holds a pinned script.
func is_tab_pinned(index: int, tab_scripts: Dictionary = {}) -> bool:
	if tab_scripts.is_empty():
		tab_scripts = get_tab_scripts()
	var script: Script = tab_scripts.get(index)
	return script != null and is_pinned.call(script.resource_path)

# tab index -> script. Both lists come back in tab order, but get_open_scripts() leaves out
# text files, so skip their editors too or everything after them ends up off by one.
func get_tab_scripts() -> Dictionary[int, Script]:
	var result: Dictionary[int, Script] = {}
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var scripts: Array[Script] = script_editor.get_open_scripts()

	var script_editors: Array[ScriptEditorBase] = []
	for editor: ScriptEditorBase in script_editor.get_open_script_editors():
		if editor.get_class() != &"TextEditor":
			script_editors.append(editor)
	if script_editors.size() != scripts.size():
		return result

	for i: int in scripts.size():
		var tab: int = scripts_tab_container.get_tab_idx_from_control(script_editors[i])
		if tab != -1:
			result[tab] = scripts[i]
	return result

func update_tab(index: int, script_override: Script = null):
	if not scripts_tab_container or not icon_manager:
		return
	var tab_control: Control = scripts_tab_container.get_tab_control(index)
	if tab_control == null:
		return

	# Don't use tab_control.get("script") - that's the editor node's own script, always null.
	var script: Script = script_override if script_override else get_tab_scripts().get(index)
	if script:
		var name: String = script.resource_path.get_file()
		if name == "":
			name = script.resource_name
		if name == "":
			name = "[Built-in]"

		var icon: Texture2D = icon_manager.get_icon_for_script(script)

		scripts_tab_container.set_tab_title(index, name)
		scripts_tab_container.set_tab_icon(index, icon)
		scripts_tab_container.set_tab_tooltip(index, script.resource_path)
	else:
		# Fallback: find the matching ItemList entry by resource path metadata
		# instead of by index, because the ItemList and TabContainer order can differ
		# (e.g. when tabs are rearranged or scripts opened/closed).
		var res_path: String = get_res_path(index)
		if res_path != "" and scripts_item_list:
			for i in range(scripts_item_list.item_count):
				var item_path: String = str(scripts_item_list.get_item_metadata(i))
				if item_path == res_path:
					scripts_tab_container.set_tab_title(index, scripts_item_list.get_item_text(i))
					scripts_tab_container.set_tab_icon(index, scripts_item_list.get_item_icon(i))
					scripts_tab_container.set_tab_tooltip(index, res_path)
					return

		# Ultimate fallback: use ItemList at the same index (may be wrong if order differs)
		if scripts_item_list and index < scripts_item_list.item_count:
			scripts_tab_container.set_tab_title(index, scripts_item_list.get_item_text(index))
			scripts_tab_container.set_tab_icon(index, scripts_item_list.get_item_icon(index))
			scripts_tab_container.set_tab_tooltip(index, scripts_item_list.get_item_tooltip(index))

func update_tabs_position():
	if not scripts_tab_container:
		return
	scripts_tab_container.tabs_position = TabContainer.POSITION_TOP

# Keeps the script list selection on the active tab, since Godot acts on whatever's selected there.
func sync_tab_with_script_list():
	if not scripts_item_list or not scripts_tab_bar:
		return
	if selected_tab >= scripts_item_list.item_count:
		selected_tab = scripts_tab_bar.current_tab

	if selected_tab != -1 && scripts_item_list.item_count > 0 && !scripts_item_list.is_selected(selected_tab):
		scripts_item_list.select(selected_tab)
		scripts_item_list.item_selected.emit(selected_tab)
		scripts_item_list.ensure_current_is_visible()

func get_res_path(idx: int) -> String:
	var tab_control: Control = scripts_tab_container.get_tab_control(idx)
	if tab_control == null:
		return ''

	var path_var: Variant = tab_control.get(&"metadata/_edit_res_path")
	if path_var == null:
		return ''

	return path_var

# Godot already handles closing (middle click) and the context menu (right click) on the
# script list, so rather than redo all that we fake the click there.
func simulate_item_clicked(tab_idx: int, mouse_idx: int):
	scripts_item_list.item_clicked.emit(_list_index_for_tab(tab_idx), scripts_item_list.get_local_mouse_position(), mouse_idx)

# The script list can be in a different order from the tabs (it sorts by name by default, and tabs
# can be dragged around), but Godot stores each row's tab index as its metadata. If a Godot version
# doesn't, fall back to assuming the same order.
func _list_index_for_tab(tab_idx: int) -> int:
	for i: int in scripts_item_list.item_count:
		var metadata: Variant = scripts_item_list.get_item_metadata(i)
		if typeof(metadata) == TYPE_INT and metadata == tab_idx:
			return i
	return tab_idx

# Godot marks unsaved scripts with "(*)" in the script list.
func _is_tab_unsaved(tab_idx: int) -> bool:
	var row: int = _list_index_for_tab(tab_idx)
	return row < scripts_item_list.item_count and scripts_item_list.get_item_text(row).ends_with("(*)")

func _on_script_filter_input(event: InputEvent):
	navigate_on_list(event, scripts_item_list, _select_script)

func _on_tab_changed(index: int):
	selected_tab = index

	if is_instance_valid(old_script_editor_base):
		if old_script_editor_base.edited_script_changed.is_connected(_on_script_changed):
			old_script_editor_base.edited_script_changed.disconnect(_on_script_changed)
		var old_code_edit: CodeEdit = old_script_editor_base.get_base_editor()
		if old_code_edit:
			if old_code_edit.text_changed.is_connected(_on_script_text_changed):
				old_code_edit.text_changed.disconnect(_on_script_text_changed)
		old_script_editor_base = null

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var script_editor_base: ScriptEditorBase = script_editor.get_current_editor()

	if script_editor_base != null:
		if not script_editor_base.edited_script_changed.is_connected(_on_script_changed):
			script_editor_base.edited_script_changed.connect(_on_script_changed)
		old_script_editor_base = script_editor_base

		var code_edit: CodeEdit = script_editor_base.get_base_editor()
		if code_edit and not code_edit.text_changed.is_connected(_on_script_text_changed):
			code_edit.text_changed.connect(_on_script_text_changed)

	sync_script_list = true

	if settings_manager and settings_manager.is_auto_navigate_in_fs && script_editor.get_current_script() != null:
		var file: String = script_editor.get_current_script().get_path()

		if file.contains(BUILT_IN_SCRIPT):
			file = file.get_slice(BUILT_IN_SCRIPT, 0)

		file_to_navigate = file
	else:
		file_to_navigate = &""

	var script: Script = script_editor.get_current_script()
	if script:
		emit_signal("script_tab_changed", script)

	update_tab(index, script)

func _on_script_text_changed():
	if selected_tab == -1:
		return
	update_tab(selected_tab)


func _on_script_changed():
	if selected_tab == -1 || scripts_item_list.item_count == 0:
		return
	update_tab(selected_tab)

func _on_tab_close(tab_idx: int):
	# Pinned: unpin first (the pin button on the tab, or the Tabs menu).
	if is_tab_pinned(tab_idx):
		return
	update_script_text_filter()

	# Disconnect tab_changed temporarily to prevent a double _on_tab_changed call.
	# simulate_item_clicked triggers Godot's script close, which may fire tab_changed
	# and call _on_tab_changed. We let the manual call below handle it once.
	var was_connected: bool = scripts_tab_bar.tab_changed.is_connected(_on_tab_changed)
	if was_connected:
		scripts_tab_bar.tab_changed.disconnect(_on_tab_changed)

	simulate_item_clicked(tab_idx, MOUSE_BUTTON_MIDDLE)

	if was_connected and not scripts_tab_bar.tab_changed.is_connected(_on_tab_changed):
		scripts_tab_bar.tab_changed.connect(_on_tab_changed)

	selected_tab = scripts_tab_bar.current_tab
	_on_tab_changed(selected_tab)
	call_deferred("update_tabs")

## Closes every tab whose script path isn't in keep_paths. Pinned and unsaved tabs always stay.
## Used by session loading.
##
## Unsaved ones are skipped rather than closed: closing one makes Godot ask "save changes?" and
## wait, and that answer is applied to whichever tab is current when you click, which by then
## wouldn't be the one it asked about.
func close_tabs_except_paths(keep_paths: PackedStringArray):
	if not scripts_tab_container:
		return
	update_script_text_filter()
	var tab_scripts: Dictionary[int, Script] = get_tab_scripts()
	_closing_tabs = true
	for i in range(scripts_tab_container.get_tab_count() - 1, -1, -1):
		var script: Script = tab_scripts.get(i)
		if script and not keep_paths.has(script.resource_path) and not is_tab_pinned(i, tab_scripts) and not _is_tab_unsaved(i):
			simulate_item_clicked(i, MOUSE_BUTTON_MIDDLE)
	_closing_tabs = false

func _close_all_except(exclude_index: int):
	var tab_count: int = scripts_tab_container.get_tab_count()
	if tab_count <= 1:
		return

	_closing_tabs = true
	update_script_text_filter()
	var tab_scripts: Dictionary[int, Script] = get_tab_scripts()

	# Back to front, so closing one doesn't shift the indices we haven't got to yet.
	# Unsaved tabs stay open for the same reason as in close_tabs_except_paths.
	for i in range(tab_count - 1, -1, -1):
		if i != exclude_index and not is_tab_pinned(i, tab_scripts) and not _is_tab_unsaved(i):
			simulate_item_clicked(i, MOUSE_BUTTON_MIDDLE)
			if i < exclude_index:
				exclude_index -= 1

	_closing_tabs = false

func _on_tab_rmb(tab_idx: int):
	update_script_text_filter()
	simulate_item_clicked(tab_idx, MOUSE_BUTTON_RIGHT)
	_adapt_context_menu(tab_idx)

#region Tab context menu
# Godot's menu is written for its vertical script list ("Close Tabs Below", "Move Document Up").
# For a horizontal tab bar we show our own copy of it instead, reworded for where the clicked tab
# sits: close-left and/or close-right, and move left/right without the one that can't happen.
#
# Why a copy rather than editing Godot's menu in place: Godot's handler sees every id clicked in
# its menu, and ids it doesn't know get read as one of its own commands (it opened a file dialog).
# In the copy, Godot's items are passed back to Godot's menu as if clicked there, and ours never
# reach it.
#
# Only English labels are recognised; with the editor in another language the copy is unchanged.

# Positive on purpose: PopupMenu reports an item with a negative id by its position instead, and
# position 2 handed to Godot is its "Open File" command. Large enough not to clash with Godot's ids.
const CLOSE_TABS_LEFT_ID: int = 900001
const CLOSE_TABS_RIGHT_ID: int = 900002
const PROXY_MENU_NAME: StringName = &"QuillTabContextMenu"
const CLOSE_BELOW_TEXTS: PackedStringArray = ["Close Tabs Below"]
const MOVE_UP_TEXTS: PackedStringArray = ["Move Document Up", "Move Up"]
const MOVE_DOWN_TEXTS: PackedStringArray = ["Move Document Down", "Move Down"]

var godot_menu: PopupMenu
var proxy_menu: PopupMenu
var context_tab_idx: int = -1

func _adapt_context_menu(tab_idx: int):
	var popup: PopupMenu = _find_open_context_menu()
	if not popup:
		return
	godot_menu = popup
	context_tab_idx = tab_idx
	_ensure_proxy_menu()
	proxy_menu.clear()

	var has_left: bool = false
	var has_right: bool = false
	for i: int in scripts_tab_container.get_tab_count():
		if i == tab_idx or scripts_tab_container.is_tab_hidden(i):
			continue
		if i < tab_idx:
			has_left = true
		else:
			has_right = true
	var last_tab: int = scripts_tab_container.get_tab_count() - 1

	for i: int in popup.item_count:
		var text: String = popup.get_item_text(i)
		if CLOSE_BELOW_TEXTS.has(text):
			if has_left:
				proxy_menu.add_item("Close Tabs to the Left", CLOSE_TABS_LEFT_ID)
			if has_right:
				proxy_menu.add_item("Close Tabs to the Right", CLOSE_TABS_RIGHT_ID)
			continue
		if MOVE_UP_TEXTS.has(text):
			if tab_idx == 0:
				continue
			text = "Move Tab Left"
		elif MOVE_DOWN_TEXTS.has(text):
			if tab_idx == last_tab:
				continue
			text = "Move Tab Right"
		_copy_menu_item(popup, i, text)

	# Show ours where Godot's was, and put Godot's away without it acting on anything.
	var at: Vector2i = popup.position
	popup.hide()
	proxy_menu.reset_size()
	proxy_menu.popup(Rect2i(at, Vector2i.ZERO))

func _ensure_proxy_menu():
	if is_instance_valid(proxy_menu):
		return
	var base_control: Control = EditorInterface.get_base_control()
	var stale: Node = base_control.get_node_or_null(NodePath(PROXY_MENU_NAME))
	if stale:
		base_control.remove_child(stale)
		stale.queue_free()
	proxy_menu = PopupMenu.new()
	proxy_menu.name = PROXY_MENU_NAME
	proxy_menu.id_pressed.connect(_on_proxy_id_pressed)
	base_control.add_child(proxy_menu)

# Copies one of Godot's items (same id, so it can be handed back). Its shortcut is shown as an
# accelerator rather than copied: a copied shortcut could fire the command a second time.
func _copy_menu_item(from: PopupMenu, index: int, text: String):
	var id: int = from.get_item_id(index)
	if from.is_item_separator(index):
		proxy_menu.add_separator(text, id)
		return
	var accelerator: Key = from.get_item_accelerator(index)
	var shortcut: Shortcut = from.get_item_shortcut(index)
	if accelerator == KEY_NONE and shortcut:
		for event: InputEvent in shortcut.events:
			if event is InputEventKey:
				accelerator = (event as InputEventKey).get_keycode_with_modifiers()
				break
	proxy_menu.add_item(text, id, accelerator)
	var added: int = proxy_menu.item_count - 1
	var icon: Texture2D = from.get_item_icon(index)
	if icon:
		proxy_menu.set_item_icon(added, icon)
	proxy_menu.set_item_disabled(added, from.is_item_disabled(index))
	proxy_menu.set_item_tooltip(added, from.get_item_tooltip(index))

func _on_proxy_id_pressed(id: int):
	if id == CLOSE_TABS_LEFT_ID:
		close_tabs_beside(context_tab_idx, true)
		return
	if id == CLOSE_TABS_RIGHT_ID:
		close_tabs_beside(context_tab_idx, false)
		return
	if not is_instance_valid(godot_menu):
		return
	# Hand Godot its own item, the same way its menu would have. Whichever signal it listens to.
	if not godot_menu.id_pressed.get_connections().is_empty():
		godot_menu.id_pressed.emit(id)
	elif not godot_menu.index_pressed.get_connections().is_empty():
		godot_menu.index_pressed.emit(godot_menu.get_item_index(id))

## Closes the tabs left (or right) of this one. Pinned, unsaved and group-hidden tabs stay.
func close_tabs_beside(tab_idx: int, left: bool):
	if not scripts_tab_container or tab_idx < 0:
		return
	update_script_text_filter()
	var tab_scripts: Dictionary[int, Script] = get_tab_scripts()
	# Back to front either way, so a close never shifts a tab we haven't reached yet.
	var indices: Array = range(tab_idx - 1, -1, -1) if left else range(scripts_tab_container.get_tab_count() - 1, tab_idx, -1)
	_closing_tabs = true
	for i: int in indices:
		if scripts_tab_container.is_tab_hidden(i) or is_tab_pinned(i, tab_scripts) or _is_tab_unsaved(i):
			continue
		simulate_item_clicked(i, MOUSE_BUTTON_MIDDLE)
	_closing_tabs = false
	update_tabs.call_deferred()

# Godot builds the menu right before showing it, so the visible one is the one just opened.
func _find_open_context_menu() -> PopupMenu:
	for node: Node in EditorInterface.get_script_editor().find_children("*", "PopupMenu", true, false):
		if node is PopupMenu and node.visible and node != proxy_menu:
			return node
	return null
#endregion

func _on_tab_hovered(idx: int):
	last_tab_hovered = idx

func _on_tab_bar_mouse_exited():
	last_tab_hovered = -1

func _on_active_tab_rearranged(idx_to: int):
	# Looks like a no-op, but re-setting it makes the container refresh after a drag.
	scripts_tab_container.current_tab = scripts_tab_container.current_tab
	selected_tab = scripts_tab_container.current_tab

func _on_tab_bar_gui_input(event: InputEvent):
	if last_tab_hovered == -1:
		return

	# Middle click closes a tab, like in a browser.
	if event is InputEventMouseButton:
		if event.is_pressed() and event.button_index == MOUSE_BUTTON_MIDDLE:
			if is_tab_pinned(last_tab_hovered):
				return
			update_script_text_filter()
			simulate_item_clicked(last_tab_hovered, MOUSE_BUTTON_MIDDLE)

			if last_tab_hovered >= scripts_tab_bar.tab_count - 1:
				last_tab_hovered = -1

func _select_script(selected_idx: int):
	scripts_item_list.item_selected.emit(selected_idx)

func navigate_on_list(event: InputEvent, list: ItemList, submit: Callable):
	if event.is_action_pressed(&"ui_text_submit"):
		var index: int = get_list_index(list)
		if index == -1:
			return
		submit.call(index)
		list.accept_event()
	elif event.is_action_pressed(&"ui_down", true):
		var index: int = get_list_index(list)
		if index == list.item_count - 1:
			return
		navigate_list(list, index, 1)
	elif event.is_action_pressed(&"ui_up", true):
		var index: int = get_list_index(list)
		if index <= 0:
			return
		navigate_list(list, index, -1)
	elif event.is_action_pressed(&"ui_page_down", true):
		var index: int = get_list_index(list)
		if index == list.item_count - 1:
			return
		navigate_list(list, index, 5)
	elif event.is_action_pressed(&"ui_page_up", true):
		var index: int = get_list_index(list)
		if index <= 0:
			return
		navigate_list(list, index, -5)
	elif event is InputEventKey && list.item_count > 0 && !list.is_anything_selected():
		list.select(0)

func get_list_index(list: ItemList) -> int:
	var items: PackedInt32Array = list.get_selected_items()
	if items.is_empty():
		return -1
	return items[0]

func navigate_list(list: ItemList, index: int, amount: int):
	index = clamp(index + amount, 0, list.item_count - 1)
	list.select(index)
	list.ensure_current_is_visible()
	list.accept_event()

# Missing nodes are reported once by the plugin as a toast, so no error here.
static func find_or_null(arr: Array[Node], index: int = 0) -> Node:
	if index >= arr.size():
		return null
	return arr[index]

class TabStateCache:
	var tabs_visible: bool
	var drag_to_rearrange_enabled: bool
	var auto_translate_mode_state: Node.AutoTranslateMode
	var tab_bar_drag_to_rearrange_enabled: bool
	var tab_close_display_policy: TabBar.CloseButtonDisplayPolicy
	var select_with_rmb: bool
	var tab_bar_theme: Theme

	func save(tab_container: TabContainer, tab_bar: TabBar):
		if tab_container != null:
			tabs_visible = tab_container.tabs_visible
			drag_to_rearrange_enabled = tab_container.drag_to_rearrange_enabled
		if tab_bar != null:
			tab_bar_drag_to_rearrange_enabled = tab_bar.drag_to_rearrange_enabled
			tab_close_display_policy = tab_bar.tab_close_display_policy
			select_with_rmb = tab_bar.select_with_rmb
			auto_translate_mode_state = tab_bar.auto_translate_mode
			tab_bar_theme = tab_bar.theme

	func restore(tab_container: TabContainer, tab_bar: TabBar):
		if tab_container != null:
			tab_container.tabs_visible = tabs_visible
			tab_container.drag_to_rearrange_enabled = drag_to_rearrange_enabled
		if tab_bar != null:
			tab_bar.drag_to_rearrange_enabled = tab_bar_drag_to_rearrange_enabled
			tab_bar.tab_close_display_policy = tab_close_display_policy
			tab_bar.select_with_rmb = select_with_rmb
			tab_bar.auto_translate_mode = auto_translate_mode_state
			tab_bar.theme = tab_bar_theme
