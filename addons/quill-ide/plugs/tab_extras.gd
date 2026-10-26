@tool
extends RefCounted

## Pinned tabs, tab groups and saved sessions, all reached from a "Tabs" menu that sits in the
## TabContainer's own popup slot (the arrow at the right end of the tab bar).
##
## We don't add to the tab's right-click menu on purpose: that menu belongs to Godot, and its
## handler treats unknown item ids above 100 as "switch to tab N".
##
## Everything is stored as project metadata in the editor settings, so it's per project and per
## machine, and never ends up in the repository.

const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

const META_SECTION: String = "quill_ide"
const PINNED_KEY: String = "pinned_tabs"
const GROUPS_KEY: String = "tab_groups"
const SESSIONS_KEY: String = "sessions"
const BRANCH_SESSION_PREFIX: String = "branch: "

const MENU_NAME: StringName = &"QuillTabsMenu"
const DIALOG_NAME: StringName = &"QuillTabsNameDialog"

enum Item { SHOW_ALL = 1, TOGGLE_PIN, ADD_TO_GROUP, REMOVE_FROM_GROUP, DELETE_GROUP, OPEN_SPLIT, SAVE_SESSION }
# Filter entries and session entries get ids from these ranges.
const FILTER_BASE: int = 1000
const LOAD_BASE: int = 2000
const DELETE_SESSION_BASE: int = 3000

## "Open Current Tab in Split View"; the plugin passes it on to the split view.
signal split_requested(path: String)

var tab_manager: TabManager
var settings_manager: QuillSettingsManager
var container: TabContainer
var menu: PopupMenu
var load_menu: PopupMenu
var delete_menu: PopupMenu
var previous_popup: Node
var name_dialog: AcceptDialog
var name_edit: LineEdit
var name_dialog_action: Callable
var pin_icon: Texture2D

var pinned: PackedStringArray = []
var groups: Dictionary = {}    # group name -> PackedStringArray of script paths
var sessions: Dictionary = {}  # session name -> { "scripts": PackedStringArray, "current": String }
# "" shows everything; otherwise "group:<name>" or "folder:<res:// dir>".
var filter: String = ""
var filter_entries: PackedStringArray = []
var session_names: PackedStringArray = []
var current_branch: String = ""

func init(tab_mgr: TabManager, settings_mgr: QuillSettingsManager):
	tab_manager = tab_mgr
	settings_manager = settings_mgr
	container = tab_manager.scripts_tab_container
	pinned = _load_meta(PINNED_KEY, PackedStringArray())
	groups = _load_meta(GROUPS_KEY, {})
	sessions = _load_meta(SESSIONS_KEY, {})
	pin_icon = EditorInterface.get_editor_theme().get_icon(&"Pin", &"EditorIcons")

	tab_manager.is_pinned = func(path: String) -> bool: return pinned.has(path)
	tab_manager.tabs_updated.connect(_on_tabs_updated)
	tab_manager.scripts_tab_bar.tab_button_pressed.connect(_on_tab_button_pressed)

	# A dead instance may have left its menu and dialog behind (older versions put the menu in the
	# tab container itself).
	var base_control: Control = EditorInterface.get_base_control()
	_free_named(container, MENU_NAME)
	_free_named(base_control, MENU_NAME)
	_free_named(base_control, DIALOG_NAME)

	menu = PopupMenu.new()
	menu.name = MENU_NAME
	menu.about_to_popup.connect(_rebuild_menu)
	menu.id_pressed.connect(_on_menu_id_pressed)
	load_menu = PopupMenu.new()
	load_menu.name = &"LoadSession"
	load_menu.id_pressed.connect(_on_session_id_pressed)
	menu.add_child(load_menu)
	delete_menu = PopupMenu.new()
	delete_menu.name = &"DeleteSession"
	delete_menu.id_pressed.connect(_on_session_id_pressed)
	menu.add_child(delete_menu)
	# Not a child of the tab container: Godot treats that container's children as its tabs when it
	# sorts them, and the split view reparents it.
	base_control.add_child(menu)
	previous_popup = container.get_popup()
	container.set_popup(menu)

	name_dialog = AcceptDialog.new()
	name_dialog.name = DIALOG_NAME
	name_edit = LineEdit.new()
	name_dialog.add_child(name_edit)
	name_dialog.register_text_enter(name_edit)
	name_dialog.confirmed.connect(_on_name_confirmed)
	base_control.add_child(name_dialog)

	current_branch = _read_branch()
	tab_manager.update_tabs()

# Safe to call more than once.
func cleanup():
	if tab_manager:
		tab_manager.is_pinned = func(_path: String) -> bool: return false
		if tab_manager.tabs_updated.is_connected(_on_tabs_updated):
			tab_manager.tabs_updated.disconnect(_on_tabs_updated)
		if is_instance_valid(tab_manager.scripts_tab_bar) and tab_manager.scripts_tab_bar.tab_button_pressed.is_connected(_on_tab_button_pressed):
			tab_manager.scripts_tab_bar.tab_button_pressed.disconnect(_on_tab_button_pressed)

	if is_instance_valid(container):
		# Show every tab again and take the pin buttons off.
		for i: int in container.get_tab_count():
			container.set_tab_hidden(i, false)
			container.get_tab_bar().set_tab_button_icon(i, null)
		if container.get_popup() == menu:
			container.set_popup(previous_popup if is_instance_valid(previous_popup) else null)
	for node: Variant in [menu, name_dialog]:
		if is_instance_valid(node):
			if node.get_parent():
				node.get_parent().remove_child(node)
			node.queue_free()
	menu = null
	name_dialog = null
	container = null
	tab_manager = null
	# The pending dialog action is a lambda holding on to us; drop it so we can be freed.
	name_dialog_action = Callable()

#region Pins
## Pins the current tab, or unpins it if it's pinned. (Shortcut and menu.)
func toggle_pin_current():
	var path: String = _current_path()
	if path.is_empty():
		return
	if pinned.has(path):
		pinned.remove_at(pinned.find(path))
	else:
		pinned.append(path)
	_save_meta(PINNED_KEY, pinned)
	tab_manager.update_tabs()

# The pin button on a pinned tab unpins it.
func _on_tab_button_pressed(index: int):
	var script: Script = tab_manager.get_tab_scripts().get(index)
	if script and pinned.has(script.resource_path):
		pinned.remove_at(pinned.find(script.resource_path))
		_save_meta(PINNED_KEY, pinned)
		tab_manager.update_tabs()
#endregion

# Re-applies pin buttons and the group filter whenever the tabs refresh.
func _on_tabs_updated(tab_scripts: Dictionary):
	if not is_instance_valid(container):
		return
	var tab_bar: TabBar = container.get_tab_bar()
	var current: int = container.current_tab
	for i: int in container.get_tab_count():
		var script: Script = tab_scripts.get(i)
		var path: String = script.resource_path if script else ""
		var is_pinned: bool = pinned.has(path)
		tab_bar.set_tab_button_icon(i, pin_icon if is_pinned else null)
		# The current tab can't be hidden, and pinned tabs stay visible in every group.
		var shown: bool = i == current or is_pinned or _matches_filter(path)
		container.set_tab_hidden(i, not shown)

func _matches_filter(path: String) -> bool:
	if filter.is_empty() or path.is_empty():
		return true
	if filter.begins_with("group:"):
		var members: PackedStringArray = groups.get(filter.trim_prefix("group:"), PackedStringArray())
		return members.has(path)
	if filter.begins_with("folder:"):
		return path.get_base_dir() == filter.trim_prefix("folder:")
	return true

#region Menu
func _rebuild_menu():
	menu.clear()
	filter_entries.clear()

	menu.add_radio_check_item("All tabs", Item.SHOW_ALL)
	menu.set_item_checked(menu.get_item_index(Item.SHOW_ALL), filter.is_empty())

	var group_names: Array = groups.keys()
	group_names.sort()
	if not group_names.is_empty():
		menu.add_separator("Groups")
		for group_name: String in group_names:
			_add_filter_item("group:" + group_name, group_name)

	# Folders are automatic: one entry per folder that has an open script.
	var folders: PackedStringArray = []
	for script: Script in EditorInterface.get_script_editor().get_open_scripts():
		var dir: String = script.resource_path.get_base_dir()
		if not script.resource_path.contains("::") and not folders.has(dir):
			folders.append(dir)
	folders.sort()
	if folders.size() > 1:
		menu.add_separator("Folders")
		for dir: String in folders:
			_add_filter_item("folder:" + dir, dir.trim_prefix("res://") if dir != "res://" else "res://")

	var current: String = _current_path()
	if not current.is_empty():
		menu.add_separator("Current tab")
		menu.add_item("Unpin" if pinned.has(current) else "Pin", Item.TOGGLE_PIN)
		menu.add_item("Add to Group...", Item.ADD_TO_GROUP)
		if not _groups_containing(current).is_empty():
			menu.add_item("Remove from Group", Item.REMOVE_FROM_GROUP)
		menu.add_item("Open in Split View", Item.OPEN_SPLIT)
	if filter.begins_with("group:"):
		menu.add_item("Delete Group \"%s\"" % filter.trim_prefix("group:"), Item.DELETE_GROUP)

	menu.add_separator("Sessions")
	menu.add_item("Save Session...", Item.SAVE_SESSION)
	load_menu.clear()
	delete_menu.clear()
	session_names = PackedStringArray(sessions.keys())
	session_names.sort()
	for i: int in session_names.size():
		load_menu.add_item(session_names[i], LOAD_BASE + i)
		delete_menu.add_item(session_names[i], DELETE_SESSION_BASE + i)
	if not session_names.is_empty():
		_add_submenu("Load Session", load_menu)
		_add_submenu("Delete Session", delete_menu)

func _add_filter_item(entry: String, label: String):
	var id: int = FILTER_BASE + filter_entries.size()
	filter_entries.append(entry)
	menu.add_radio_check_item(label, id)
	menu.set_item_checked(menu.get_item_index(id), filter == entry)

func _add_submenu(label: String, submenu: PopupMenu):
	# add_submenu_node_item is the 4.3+ way; the name-based one still works before that.
	if menu.has_method(&"add_submenu_node_item"):
		menu.call(&"add_submenu_node_item", label, submenu)
	else:
		menu.add_submenu_item(label, submenu.name)

func _on_menu_id_pressed(id: int):
	var current: String = _current_path()
	if id >= FILTER_BASE and id < FILTER_BASE + filter_entries.size():
		filter = filter_entries[id - FILTER_BASE]
	else:
		match id:
			Item.SHOW_ALL:
				filter = ""
			Item.TOGGLE_PIN:
				toggle_pin_current()
			Item.ADD_TO_GROUP:
				var suggestion: String = filter.trim_prefix("group:") if filter.begins_with("group:") else ""
				_ask_name("Add to Group", "Group name (new or existing)", suggestion, func(group_name: String):
					var members: PackedStringArray = groups.get(group_name, PackedStringArray())
					if not members.has(current):
						members.append(current)
					groups[group_name] = members
					_save_meta(GROUPS_KEY, groups)
					tab_manager.update_tabs())
			Item.REMOVE_FROM_GROUP:
				# From the group being shown, or from every group if showing all.
				var targets: Array = [filter.trim_prefix("group:")] if filter.begins_with("group:") else _groups_containing(current)
				for group_name: String in targets:
					var members: PackedStringArray = groups.get(group_name, PackedStringArray())
					if members.has(current):
						members.remove_at(members.find(current))
					if members.is_empty():
						groups.erase(group_name)
					else:
						groups[group_name] = members
				if filter.begins_with("group:") and not groups.has(filter.trim_prefix("group:")):
					filter = ""
				_save_meta(GROUPS_KEY, groups)
			Item.DELETE_GROUP:
				groups.erase(filter.trim_prefix("group:"))
				filter = ""
				_save_meta(GROUPS_KEY, groups)
			Item.OPEN_SPLIT:
				# After the menu is done with this click: opening the split moves the tabs around.
				split_requested.emit.call_deferred(current)
			Item.SAVE_SESSION:
				_ask_name("Save Session", "Session name", "", func(session_name: String):
					sessions[session_name] = _capture_session()
					_save_meta(SESSIONS_KEY, sessions))
	tab_manager.update_tabs()

func _on_session_id_pressed(id: int):
	if id >= DELETE_SESSION_BASE:
		var index: int = id - DELETE_SESSION_BASE
		if index < session_names.size():
			sessions.erase(session_names[index])
			_save_meta(SESSIONS_KEY, sessions)
	elif id >= LOAD_BASE:
		var index: int = id - LOAD_BASE
		if index < session_names.size():
			load_session(session_names[index])

func _groups_containing(path: String) -> Array:
	var result: Array = []
	for group_name: String in groups:
		if PackedStringArray(groups[group_name]).has(path):
			result.append(group_name)
	return result
#endregion

#region Sessions
func _capture_session() -> Dictionary:
	var scripts: PackedStringArray = []
	for script: Script in EditorInterface.get_script_editor().get_open_scripts():
		# Built-in scripts can't be reopened on their own, so they aren't saved.
		if not script.resource_path.is_empty() and not script.resource_path.contains("::"):
			scripts.append(script.resource_path)
	return { "scripts": scripts, "current": _current_path() }

## Opens the session's scripts, then (if the setting is on) closes tabs that aren't part of it.
func load_session(session_name: String):
	var data: Dictionary = sessions.get(session_name, {})
	if data.is_empty():
		return
	var paths: PackedStringArray = data.get("scripts", PackedStringArray())
	var opened: PackedStringArray = []
	# Opening each script switches tabs, which with "auto close scripts" on would close the
	# others. This flag is what auto-close checks for.
	tab_manager._closing_tabs = true
	for path: String in paths:
		if ResourceLoader.exists(path):
			EditorInterface.edit_script(load(path))
			opened.append(path)
	var current: String = data.get("current", "")
	if opened.has(current):
		EditorInterface.edit_script(load(current))
	tab_manager._closing_tabs = false
	if opened.is_empty():
		ProjectFiles.toast("None of the scripts in session '%s' exist any more." % session_name)
		return
	if settings_manager.session_close_others:
		tab_manager.close_tabs_except_paths(opened)
	filter = ""
	tab_manager.update_tabs()

## Called when the project files change (a branch checkout changes files too). If the git branch
## changed and per-branch sessions are on, saves the old branch's tabs and restores the new one's.
func check_branch():
	var branch: String = _read_branch()
	if branch.is_empty() or branch == current_branch:
		return
	var previous: String = current_branch
	current_branch = branch
	if not settings_manager.session_per_branch or previous.is_empty():
		return
	sessions[BRANCH_SESSION_PREFIX + previous] = _capture_session()
	_save_meta(SESSIONS_KEY, sessions)
	if sessions.has(BRANCH_SESSION_PREFIX + branch):
		load_session(BRANCH_SESSION_PREFIX + branch)
		ProjectFiles.toast("Switched to branch '%s': reopened the scripts you had open there." % branch)

# The branch name from .git/HEAD in the project folder or up to three folders above it.
# Empty when there's no repository or HEAD is detached.
func _read_branch() -> String:
	var dir: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	for i: int in 4:
		var head: String = dir.path_join(".git/HEAD")
		if FileAccess.file_exists(head):
			var text: String = FileAccess.get_file_as_string(head).strip_edges()
			return text.trim_prefix("ref: refs/heads/") if text.begins_with("ref: refs/heads/") else ""
		var parent: String = dir.get_base_dir()
		if parent == dir:
			break
		dir = parent
	return ""
#endregion

func _ask_name(title: String, placeholder: String, initial: String, action: Callable):
	name_dialog_action = action
	name_dialog.title = title
	name_edit.placeholder_text = placeholder
	name_edit.text = initial
	name_dialog.popup_centered(Vector2i(Vector2(320, 0) * EditorInterface.get_editor_scale()))
	name_edit.select_all()
	name_edit.grab_focus.call_deferred()

func _on_name_confirmed():
	var entered: String = name_edit.text.strip_edges()
	if not entered.is_empty() and name_dialog_action.is_valid():
		name_dialog_action.call(entered)

func _current_path() -> String:
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script or script.resource_path.contains("::"):
		return ""
	return script.resource_path

func _load_meta(key: String, default_value: Variant) -> Variant:
	var value: Variant = EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, key, default_value)
	# Our own copy, so EditorSettings sees a change when we save it back.
	return value.duplicate(true) if value is Dictionary else value.duplicate()

func _save_meta(key: String, value: Variant):
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, key, value.duplicate(true) if value is Dictionary else value.duplicate())

static func _free_named(parent: Node, node_name: StringName):
	var stale: Node = parent.get_node_or_null(NodePath(node_name))
	if stale:
		parent.remove_child(stale)
		stale.queue_free()
