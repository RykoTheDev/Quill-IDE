@tool
class_name QuillSettingsManager

const GODOT_IDE: StringName = &"Quill/"

const GENERAL: StringName = GODOT_IDE + &"General/"
const HIDE_PRIVATE_MEMBERS: StringName = GENERAL + &"hide_private_members"
const AUTO_NAVIGATE_IN_FS: StringName = GENERAL + &"auto_navigate_in_filesystem_dock"
const AUTO_CLOSE_SCRIPTS: StringName = GENERAL + &"auto_close_scripts"
const MINIMALISM: StringName = GENERAL + &"minimalism"
const SCRIPT_LIST_VISIBLE: StringName = GENERAL + &"script_list_visible"
const SCRIPT_TABS_VISIBLE: StringName = GENERAL + &"script_tabs_visible"

const OUTLINE: StringName = GODOT_IDE + &"Outline/"
const OUTLINE_ORDER: StringName = OUTLINE + &"outline_order"
const OUTLINE_POSITION_RIGHT: StringName = OUTLINE + &"outline_position_right"
const SHOW_FUNCS: StringName = OUTLINE + &"show_funcs"
const SHOW_SIGNALS: StringName = OUTLINE + &"show_signals"
const SHOW_CONSTANTS: StringName = OUTLINE + &"show_constants"
const SHOW_EXPORTED: StringName = OUTLINE + &"show_exported"
const SHOW_PROPERTIES: StringName = OUTLINE + &"show_properties"
const SHOW_CLASSES: StringName = OUTLINE + &"show_classes"
const SHOW_ENGINE_FUNCS: StringName = OUTLINE + &"show_engine_funcs"
const OUTLINE_COLLAPSED: StringName = OUTLINE + &"outline_collapsed"
const OUTLINE_BOOKMARKS: StringName = OUTLINE + &"outline_bookmarks"
const HIDE_OUTLINE_PANEL: StringName = OUTLINE + &"hide_outline_panel"

var is_outline_right: bool = true
var is_script_list_visible: bool = false
var hide_private_members: bool = false
var is_auto_navigate_in_fs: bool = true
var is_auto_close_scripts: bool = false
var is_minimalism: bool = false
var is_script_tabs_visible: bool = true
var is_outline_hidden: bool = false
var is_script_tabs_top: bool = true
var outline_order: PackedStringArray

var suppress_settings_sync: bool = false

var show_funcs: bool = true
var show_signals: bool = true
var show_constants: bool = true
var show_exported: bool = true
var show_properties: bool = true
var show_classes: bool = true
var show_engine_funcs: bool = true
var collapsed_categories: PackedStringArray
var bookmarks: Array

func init_settings():
	is_outline_right = get_setting(OUTLINE_POSITION_RIGHT, is_outline_right)
	hide_private_members = get_setting(HIDE_PRIVATE_MEMBERS, hide_private_members)
	is_script_list_visible = get_setting(SCRIPT_LIST_VISIBLE, is_script_list_visible)
	is_auto_navigate_in_fs = get_setting(AUTO_NAVIGATE_IN_FS, is_auto_navigate_in_fs)
	is_auto_close_scripts = get_setting(AUTO_CLOSE_SCRIPTS, is_auto_close_scripts)
	is_minimalism = get_setting(MINIMALISM, is_minimalism)
	is_script_tabs_visible = get_setting(SCRIPT_TABS_VISIBLE, is_script_tabs_visible)
	is_outline_hidden = get_setting(HIDE_OUTLINE_PANEL, is_outline_hidden)
	init_outline_order()
	collapsed_categories = load_collapsed_categories()
	bookmarks = load_bookmarks()

	show_funcs = get_setting(SHOW_FUNCS, show_funcs)
	show_signals = get_setting(SHOW_SIGNALS, show_signals)
	show_constants = get_setting(SHOW_CONSTANTS, show_constants)
	show_exported = get_setting(SHOW_EXPORTED, show_exported)
	show_properties = get_setting(SHOW_PROPERTIES, show_properties)
	show_classes = get_setting(SHOW_CLASSES, show_classes)
	show_engine_funcs = get_setting(SHOW_ENGINE_FUNCS, show_engine_funcs)

func init_outline_order():
	var editor_settings: EditorSettings = get_editor_settings()
	if editor_settings.has_setting(OUTLINE_ORDER):
		outline_order = editor_settings.get_setting(OUTLINE_ORDER)
	else:
		outline_order = ["Engine Callbacks", "Functions", "Signals", "Exported Properties", "Properties", "Constants", "Classes"]
		editor_settings.set_setting(OUTLINE_ORDER, outline_order)


func sync_settings(changed_settings: PackedStringArray):
	if suppress_settings_sync: return

	for setting: String in changed_settings:
		if !setting.begins_with(GODOT_IDE): continue

		match setting:
			OUTLINE_COLLAPSED: collapsed_categories = load_collapsed_categories()
			OUTLINE_ORDER: init_outline_order()
			OUTLINE_POSITION_RIGHT: is_outline_right = get_setting(setting, is_outline_right)
			HIDE_PRIVATE_MEMBERS: hide_private_members = get_setting(setting, hide_private_members)
			SCRIPT_LIST_VISIBLE: is_script_list_visible = get_setting(setting, is_script_list_visible)
			SCRIPT_TABS_VISIBLE: is_script_tabs_visible = get_setting(setting, is_script_tabs_visible)
			AUTO_NAVIGATE_IN_FS: is_auto_navigate_in_fs = get_setting(setting, is_auto_navigate_in_fs)
			AUTO_CLOSE_SCRIPTS: is_auto_close_scripts = get_setting(setting, is_auto_close_scripts)
			MINIMALISM: is_minimalism = get_setting(setting, is_minimalism)
			HIDE_OUTLINE_PANEL: is_outline_hidden = get_setting(setting, is_outline_hidden)
			SHOW_FUNCS: show_funcs = get_setting(setting, show_funcs)
			SHOW_SIGNALS: show_signals = get_setting(setting, show_signals)
			SHOW_CONSTANTS: show_constants = get_setting(setting, show_constants)
			SHOW_EXPORTED: show_exported = get_setting(setting, show_exported)
			SHOW_PROPERTIES: show_properties = get_setting(setting, show_properties)
			SHOW_CLASSES: show_classes = get_setting(setting, show_classes)
			SHOW_ENGINE_FUNCS: show_engine_funcs = get_setting(setting, show_engine_funcs)

func sync_settings_all():
	if suppress_settings_sync: return

	is_outline_right = get_setting(OUTLINE_POSITION_RIGHT, is_outline_right)
	hide_private_members = get_setting(HIDE_PRIVATE_MEMBERS, hide_private_members)
	is_script_list_visible = get_setting(SCRIPT_LIST_VISIBLE, is_script_list_visible)
	is_auto_navigate_in_fs = get_setting(AUTO_NAVIGATE_IN_FS, is_auto_navigate_in_fs)
	is_auto_close_scripts = get_setting(AUTO_CLOSE_SCRIPTS, is_auto_close_scripts)
	is_minimalism = get_setting(MINIMALISM, is_minimalism)
	is_script_tabs_visible = get_setting(SCRIPT_TABS_VISIBLE, is_script_tabs_visible)
	is_outline_hidden = get_setting(HIDE_OUTLINE_PANEL, is_outline_hidden)
	init_outline_order()
	collapsed_categories = load_collapsed_categories()
	bookmarks = load_bookmarks()

	show_funcs = get_setting(SHOW_FUNCS, show_funcs)
	show_signals = get_setting(SHOW_SIGNALS, show_signals)
	show_constants = get_setting(SHOW_CONSTANTS, show_constants)
	show_exported = get_setting(SHOW_EXPORTED, show_exported)
	show_properties = get_setting(SHOW_PROPERTIES, show_properties)
	show_classes = get_setting(SHOW_CLASSES, show_classes)
	show_engine_funcs = get_setting(SHOW_ENGINE_FUNCS, show_engine_funcs)


func get_setting(property: StringName, alt: bool) -> bool:
	var editor_settings: EditorSettings = get_editor_settings()
	if editor_settings.has_setting(property):
		return editor_settings.get_setting(property)
	else:
		editor_settings.set_setting(property, alt)
		return alt

func set_setting(property: StringName, value: bool):
	var editor_settings: EditorSettings = get_editor_settings()
	suppress_settings_sync = true
	editor_settings.set_setting(property, value)
	suppress_settings_sync = false

func get_editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()

func load_collapsed_categories() -> PackedStringArray:
	var editor_settings: EditorSettings = get_editor_settings()
	if editor_settings.has_setting(OUTLINE_COLLAPSED):
		return editor_settings.get_setting(OUTLINE_COLLAPSED)
	else:
		var default_collapsed: PackedStringArray = [
			"Engine Callbacks", "Functions", "Signals",
			"Exported Properties", "Properties", "Constants", "Classes"
		]
		editor_settings.set_setting(OUTLINE_COLLAPSED, default_collapsed)
		return default_collapsed

func set_category_collapsed(category_name: String, collapsed: bool):
	if collapsed:
		if not collapsed_categories.has(category_name):
			collapsed_categories.append(category_name)
	else:
		var idx: int = collapsed_categories.find(category_name)
		if idx != -1:
			collapsed_categories.remove_at(idx)

	_persist_collapsed_categories()

func set_all_categories_collapsed(collapsed: bool):
	var all_categories: PackedStringArray = [
		"Engine Callbacks", "Functions", "Signals",
		"Exported Properties", "Properties", "Constants", "Classes"
	]
	if collapsed:
		collapsed_categories = all_categories
	else:
		collapsed_categories = PackedStringArray()

	_persist_collapsed_categories()

func _persist_collapsed_categories():
	suppress_settings_sync = true
	get_editor_settings().set_setting(OUTLINE_COLLAPSED, collapsed_categories)
	suppress_settings_sync = false

func load_bookmarks() -> Array:
	var editor_settings: EditorSettings = get_editor_settings()
	if editor_settings.has_setting(OUTLINE_BOOKMARKS):
		return editor_settings.get_setting(OUTLINE_BOOKMARKS)
	else:
		editor_settings.set_setting(OUTLINE_BOOKMARKS, [])
		return []

func add_bookmark(script_path: String, name: String, type: StringName, modifier: StringName) -> void:
	for bm: Dictionary in bookmarks:
		if bm["script_path"] == script_path and bm["name"] == name:
			return
	bookmarks.append({
		&"script_path": script_path,
		&"name": name,
		&"type": type,
		&"modifier": modifier
	})
	_persist_bookmarks()

func remove_bookmark(script_path: String, name: String) -> void:
	var idx: int = -1
	for i: int in bookmarks.size():
		if bookmarks[i]["script_path"] == script_path and bookmarks[i]["name"] == name:
			idx = i
			break
	if idx != -1:
		bookmarks.remove_at(idx)
		_persist_bookmarks()

func is_bookmarked(script_path: String, name: String) -> bool:
	for bm: Dictionary in bookmarks:
		if bm["script_path"] == script_path and bm["name"] == name:
			return true
	return false

func clear_all_bookmarks() -> void:
	bookmarks.clear()
	_persist_bookmarks()

func _persist_bookmarks() -> void:
	suppress_settings_sync = true
	get_editor_settings().set_setting(OUTLINE_BOOKMARKS, bookmarks)
	suppress_settings_sync = false

func is_sorted() -> bool:
	return get_editor_settings().get_setting("text_editor/script_list/sort_members_outline_alphabetically")
