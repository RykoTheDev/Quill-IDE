@tool
extends EditorPlugin

const BUILT_IN_SCRIPT: StringName = &"::GDScript"
const QUICK_OPEN_INTERVAL: float = 400.0

const QuillSettingsManager = preload("uid://cuc2uwqgbhjmi")
const TabManager = preload("uid://rcrd4dy7nevv")
const OutlineManager = preload("uid://p1uc0k4gy6jr")
const IconManager = preload("uid://dqgi3yvglh3w4")
const IndentGuidelinesManager = preload("res://addons/quill-ide/plugs/indent_guidelines.gd")

const QUICK_OPEN_SCENE: PackedScene = preload("res://addons/quill-ide/plugs/quick_open.tscn")

const QUILL: StringName = &"Quill/"
const QUICK_OPEN: StringName = QUILL + &"QuickOpen/"
const OPEN_QUICK_SEARCH_POPUP: StringName = QUICK_OPEN + &"open_quick_search_popup"
const OPEN_QUICK_SEARCH_POPUP_SCENES: StringName = QUICK_OPEN + &"open_quick_search_popup_scenes"
const OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS: StringName = QUICK_OPEN + &"open_quick_search_popup_gdscripts"
const OPEN_QUICK_SEARCH_POPUP_RESOURCES: StringName = QUICK_OPEN + &"open_quick_search_popup_resources"
const TAB_CYCLE_FORWARD: StringName = QUICK_OPEN + &"tab_cycle_forward"
const TAB_CYCLE_BACKWARD: StringName = QUICK_OPEN + &"tab_cycle_backward"


var settings_manager: QuillSettingsManager
var tab_manager: TabManager
var outline_manager: OutlineManager
var icon_manager: IconManager
var indent_guidelines_manager: IndentGuidelinesManager


var quick_open_popup: QuickOpenPopup
var quick_open_tween: Tween

var open_quick_search_popup_shc: Shortcut
var open_quick_search_popup_scenes_shc: Shortcut
var open_quick_search_popup_gdscripts_shc: Shortcut
var open_quick_search_popup_resources_shc: Shortcut
var tab_cycle_forward_shc: Shortcut
var tab_cycle_backward_shc: Shortcut


func _enter_tree() -> void:
	init_quick_open_shortcuts()

	icon_manager = IconManager.new()
	icon_manager.init_icons()

	settings_manager = QuillSettingsManager.new()
	settings_manager.init_settings()

	indent_guidelines_manager = IndentGuidelinesManager.new()
	indent_guidelines_manager.init()

	tab_manager = TabManager.new()
	tab_manager.init(settings_manager, icon_manager)
	tab_manager.update_tabs()

	outline_manager = OutlineManager.new()
	outline_manager.init(settings_manager, icon_manager)

	tab_manager.script_tab_changed.connect(outline_manager._on_active_script_changed)

	var file_system: EditorFileSystem = EditorInterface.get_resource_filesystem()
	file_system.filesystem_changed.connect(schedule_update)

	EditorInterface.get_editor_settings().settings_changed.connect(_on_settings_changed)

func _exit_tree() -> void:
	var file_system: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if file_system and file_system.filesystem_changed.is_connected(schedule_update):
		file_system.filesystem_changed.disconnect(schedule_update)

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if editor_settings and editor_settings.settings_changed.is_connected(_on_settings_changed):
		editor_settings.settings_changed.disconnect(_on_settings_changed)

	if indent_guidelines_manager:
		indent_guidelines_manager.cleanup()
		indent_guidelines_manager = null

	if outline_manager:
		outline_manager.cleanup()
	if tab_manager:
		tab_manager.cleanup()
	if quick_open_popup != null:
		quick_open_popup.free()

func _process(delta: float) -> void:
	update_editor()
	set_process(false)

func _shortcut_input(event: InputEvent) -> void:
	if (!event.is_pressed() || event.is_echo()):
		return

	if open_quick_search_popup_shc and open_quick_search_popup_shc.matches_event(event):
		if (quick_open_tween != null && quick_open_tween.is_running()):
			get_viewport().set_input_as_handled()
			if (quick_open_tween != null):
				quick_open_tween.kill()

			quick_open_tween = create_tween()
			quick_open_tween.tween_interval(0.2)
			quick_open_tween.tween_callback(open_quick_search_popup)
			quick_open_tween.tween_callback(func(): quick_open_tween = null)
		else:
			quick_open_tween = create_tween()
			quick_open_tween.tween_interval(QUICK_OPEN_INTERVAL / 1000.0)
			quick_open_tween.tween_callback(func(): quick_open_tween = null)
	elif open_quick_search_popup_scenes_shc and open_quick_search_popup_scenes_shc.matches_event(event):
		get_viewport().set_input_as_handled()
		open_quick_search_popup(QuickOpenPopup.Category.SCENES)
	elif open_quick_search_popup_gdscripts_shc and open_quick_search_popup_gdscripts_shc.matches_event(event):
		get_viewport().set_input_as_handled()
		open_quick_search_popup(QuickOpenPopup.Category.GDSCRIPTS)
	elif open_quick_search_popup_resources_shc and open_quick_search_popup_resources_shc.matches_event(event):
		get_viewport().set_input_as_handled()
		open_quick_search_popup(QuickOpenPopup.Category.RESOURCES)

func _input(event: InputEvent) -> void:
	if (event is InputEventKey):
		if open_quick_search_popup_shc and !open_quick_search_popup_shc.matches_event(event):
			if (quick_open_tween != null):
				quick_open_tween.kill()
				quick_open_tween = null

func schedule_update() -> void:
	set_process(true)

func update_editor() -> void:
	if tab_manager:
		tab_manager.update_editor()
	if outline_manager:
		outline_manager.update_editor()

func _on_settings_changed() -> void:
	var changed_settings: PackedStringArray = EditorInterface.get_editor_settings().get_changed_settings()

	if settings_manager:
		settings_manager.sync_settings(changed_settings)
	if icon_manager:
		icon_manager.handle_settings_change(changed_settings)
	if indent_guidelines_manager:
		indent_guidelines_manager.handle_settings_change(changed_settings)
	if tab_manager and settings_manager:
		tab_manager.handle_settings_change(changed_settings, settings_manager)

	sync_quick_open_settings(changed_settings)

func get_current_script() -> Script:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	return script_editor.get_current_script()

func goto_line(index: int) -> void:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	script_editor.goto_line(index)

	var code_edit: CodeEdit = script_editor.get_current_editor().get_base_editor()
	code_edit.set_caret_line(index)
	code_edit.set_v_scroll(index)
	code_edit.set_caret_column(code_edit.get_line(index).length())
	code_edit.set_h_scroll(0)
	code_edit.grab_focus()

func navigate_on_list(event: InputEvent, list: ItemList, submit: Callable) -> void:
	if (event.is_action_pressed(&"ui_text_submit")):
		list.accept_event()

		var index: int = get_list_index(list)
		if (index == -1):
			return

		submit.call(index)
		list.accept_event()
	elif (event.is_action_pressed(&"ui_down", true)):
		var index: int = get_list_index(list)
		if (index == list.item_count - 1):
			return

		navigate_list(list, index, 1)
	elif (event.is_action_pressed(&"ui_up", true)):
		var index: int = get_list_index(list)
		if (index <= 0):
			return

		navigate_list(list, index, -1)
	elif (event.is_action_pressed(&"ui_page_down", true)):
		var index: int = get_list_index(list)
		if (index == list.item_count - 1):
			return

		navigate_list(list, index, 5)
	elif (event.is_action_pressed(&"ui_page_up", true)):
		var index: int = get_list_index(list)
		if (index <= 0):
			return

		navigate_list(list, index, -5)
	elif (event is InputEventKey && list.item_count > 0 && !list.is_anything_selected()):
		list.select(0)

func get_list_index(list: ItemList) -> int:
	var items: PackedInt32Array = list.get_selected_items()

	if (items.is_empty()):
		return -1

	return items[0]

func navigate_list(list: ItemList, index: int, amount: int) -> void:
	index = clampi(index + amount, 0, list.item_count - 1)

	list.select(index)
	list.ensure_current_is_visible()
	list.accept_event()

func init_quick_open_shortcuts() -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()

	if (!editor_settings.has_setting(OPEN_QUICK_SEARCH_POPUP)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.keycode = KEY_SHIFT

		shortcut.events = [event]
		editor_settings.set_setting(OPEN_QUICK_SEARCH_POPUP, shortcut)

	if (!editor_settings.has_setting(OPEN_QUICK_SEARCH_POPUP_SCENES)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.command_or_control_autoremap = true
		event.shift_pressed = true
		event.keycode = KEY_F

		shortcut.events = [event]
		editor_settings.set_setting(OPEN_QUICK_SEARCH_POPUP_SCENES, shortcut)

	if (!editor_settings.has_setting(OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.command_or_control_autoremap = true
		event.shift_pressed = true
		event.keycode = KEY_O

		shortcut.events = [event]
		editor_settings.set_setting(OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS, shortcut)

	if (!editor_settings.has_setting(OPEN_QUICK_SEARCH_POPUP_RESOURCES)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.command_or_control_autoremap = true
		event.shift_pressed = true
		event.keycode = KEY_R

		shortcut.events = [event]
		editor_settings.set_setting(OPEN_QUICK_SEARCH_POPUP_RESOURCES, shortcut)

	if (!editor_settings.has_setting(TAB_CYCLE_FORWARD)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.keycode = KEY_TAB
		event.ctrl_pressed = true

		shortcut.events = [event]
		editor_settings.set_setting(TAB_CYCLE_FORWARD, shortcut)

	if (!editor_settings.has_setting(TAB_CYCLE_BACKWARD)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.keycode = KEY_TAB
		event.shift_pressed = true
		event.ctrl_pressed = true

		shortcut.events = [event]
		editor_settings.set_setting(TAB_CYCLE_BACKWARD, shortcut)

	open_quick_search_popup_shc = editor_settings.get_setting(OPEN_QUICK_SEARCH_POPUP)
	open_quick_search_popup_scenes_shc = editor_settings.get_setting(OPEN_QUICK_SEARCH_POPUP_SCENES)
	open_quick_search_popup_gdscripts_shc = editor_settings.get_setting(OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS)
	open_quick_search_popup_resources_shc = editor_settings.get_setting(OPEN_QUICK_SEARCH_POPUP_RESOURCES)
	tab_cycle_forward_shc = editor_settings.get_setting(TAB_CYCLE_FORWARD)
	tab_cycle_backward_shc = editor_settings.get_setting(TAB_CYCLE_BACKWARD)

func sync_quick_open_settings(changed_settings: PackedStringArray) -> void:
	for setting: String in changed_settings:
		if (!setting.begins_with(QUICK_OPEN)):
			continue

		match (setting):
			OPEN_QUICK_SEARCH_POPUP:
				open_quick_search_popup_shc = EditorInterface.get_editor_settings().get_setting(OPEN_QUICK_SEARCH_POPUP)
			OPEN_QUICK_SEARCH_POPUP_SCENES:
				open_quick_search_popup_scenes_shc = EditorInterface.get_editor_settings().get_setting(OPEN_QUICK_SEARCH_POPUP_SCENES)
			OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS:
				open_quick_search_popup_gdscripts_shc = EditorInterface.get_editor_settings().get_setting(OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS)
			OPEN_QUICK_SEARCH_POPUP_RESOURCES:
				open_quick_search_popup_resources_shc = EditorInterface.get_editor_settings().get_setting(OPEN_QUICK_SEARCH_POPUP_RESOURCES)
			TAB_CYCLE_FORWARD:
				tab_cycle_forward_shc = EditorInterface.get_editor_settings().get_setting(TAB_CYCLE_FORWARD)
			TAB_CYCLE_BACKWARD:
				tab_cycle_backward_shc = EditorInterface.get_editor_settings().get_setting(TAB_CYCLE_BACKWARD)

func open_quick_search_popup(category: QuickOpenPopup.Category = QuickOpenPopup.Category.ALL) -> void:
	if (quick_open_popup != null && quick_open_popup.visible):
		quick_open_popup.set_category(category)
		return

	var pref_size: Vector2
	if (quick_open_popup == null):
		quick_open_popup = QUICK_OPEN_SCENE.instantiate()
		quick_open_popup.plugin = self
		quick_open_popup.set_unparent_when_invisible(true)
		pref_size = Vector2(700, 400) * EditorInterface.get_editor_scale()
	else:
		pref_size = quick_open_popup.size
		var parent: Node = quick_open_popup.get_parent()
		if (parent != null):
			parent.remove_child(quick_open_popup)

	var center_rect: Rect2i = get_center_editor_rect(pref_size)
	quick_open_popup.popup_exclusive_on_parent(EditorInterface.get_script_editor(), center_rect)
	quick_open_popup.position = center_rect.position
	quick_open_popup.set_category(category)

func get_center_editor_rect(pref_size: Vector2 = Vector2(500, 400)) -> Rect2i:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var position: Vector2 = script_editor.global_position + script_editor.size / 2 - pref_size / 2
	return Rect2i(position, pref_size)

static func find_or_null(arr: Array[Node], index: int = 0) -> Node:
	if arr.is_empty():
		push_error("""
		Node that is needed for Quill-IDE not found.
		Plugin will not work correctly.
		This might be due to some other plugins or changes in the Engine.
		Please open an issue on Quill's Github, so we can figure out a fix.
		""")
		return null
	return arr[index]

func load_rel(path: String) -> Variant:
	var script_path: String = get_script().get_path().get_base_dir()
	return load(script_path.path_join(path))
