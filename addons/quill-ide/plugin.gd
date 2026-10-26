@tool
extends EditorPlugin

const BUILT_IN_SCRIPT: StringName = &"::GDScript"
const QUICK_OPEN_INTERVAL: float = 400.0

const QuillSettingsManager = preload("uid://cuc2uwqgbhjmi")
const TabManager = preload("uid://rcrd4dy7nevv")
const OutlineManager = preload("uid://p1uc0k4gy6jr")
const IconManager = preload("uid://dqgi3yvglh3w4")
const IndentGuidelinesManager = preload("res://addons/quill-ide/plugs/indent_guidelines.gd")
const BreadcrumbBar = preload("res://addons/quill-ide/plugs/breadcrumbs.gd")
const NavigationHistory = preload("res://addons/quill-ide/plugs/history.gd")
const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")
const SymbolParser = preload("res://addons/quill-ide/plugs/symbol_parser.gd")
const UsagesPopup = preload("res://addons/quill-ide/plugs/usages_popup.gd")
const SmoothCaretManager = preload("res://addons/quill-ide/plugs/smooth_caret_manager.gd")
const TabExtras = preload("res://addons/quill-ide/plugs/tab_extras.gd")
const SplitView = preload("res://addons/quill-ide/plugs/split_view.gd")
const ZenMode = preload("res://addons/quill-ide/plugs/zen_mode.gd")

const QUICK_OPEN_SCENE: PackedScene = preload("res://addons/quill-ide/plugs/quick_open.tscn")
#TODO dsada
const QUILL: StringName = &"Quill/"
const QUICK_OPEN: StringName = QUILL + &"QuickOpen/"
const OPEN_QUICK_SEARCH_POPUP: StringName = QUICK_OPEN + &"open_quick_search_popup"
const OPEN_QUICK_SEARCH_POPUP_SCENES: StringName = QUICK_OPEN + &"open_quick_search_popup_scenes"
const OPEN_QUICK_SEARCH_POPUP_GDSCRIPTS: StringName = QUICK_OPEN + &"open_quick_search_popup_gdscripts"
const OPEN_QUICK_SEARCH_POPUP_RESOURCES: StringName = QUICK_OPEN + &"open_quick_search_popup_resources"
const TAB_CYCLE_FORWARD: StringName = QUICK_OPEN + &"tab_cycle_forward"
const TAB_CYCLE_BACKWARD: StringName = QUICK_OPEN + &"tab_cycle_backward"

const NAVIGATION: StringName = QUILL + &"Navigation/"
const HISTORY_BACK: StringName = NAVIGATION + &"history_back"
const HISTORY_FORWARD: StringName = NAVIGATION + &"history_forward"
const TOGGLE_BOOKMARK: StringName = NAVIGATION + &"toggle_bookmark"
const NEXT_BOOKMARK: StringName = NAVIGATION + &"next_bookmark"
const PREVIOUS_BOOKMARK: StringName = NAVIGATION + &"previous_bookmark"
const FIND_USAGES: StringName = NAVIGATION + &"find_usages"
const TOGGLE_PIN: StringName = NAVIGATION + &"toggle_pin_tab"
const TOGGLE_SPLIT: StringName = NAVIGATION + &"toggle_split_view"
const TOGGLE_ZEN: StringName = NAVIGATION + &"toggle_zen_mode"

var settings_manager: QuillSettingsManager
var tab_manager: TabManager
var outline_manager: OutlineManager
var icon_manager: IconManager
var indent_guidelines_manager: IndentGuidelinesManager
var breadcrumb_bar: BreadcrumbBar
var navigation_history: NavigationHistory
var history_back_btn: Button
var history_forward_btn: Button
var usages_popup: UsagesPopup
var smooth_caret_manager: SmoothCaretManager
var tab_extras: TabExtras
var split_view: SplitView
var zen_mode: ZenMode

var quick_open_popup: QuickOpenPopup
var quick_open_tween: Tween

var open_quick_search_popup_shc: Shortcut
var open_quick_search_popup_scenes_shc: Shortcut
var open_quick_search_popup_gdscripts_shc: Shortcut
var open_quick_search_popup_resources_shc: Shortcut
var tab_cycle_forward_shc: Shortcut
var tab_cycle_backward_shc: Shortcut
var history_back_shc: Shortcut
var history_forward_shc: Shortcut
var toggle_bookmark_shc: Shortcut
var next_bookmark_shc: Shortcut
var previous_bookmark_shc: Shortcut
var find_usages_shc: Shortcut
var toggle_pin_shc: Shortcut
var toggle_split_shc: Shortcut
var toggle_zen_shc: Shortcut


func _enter_tree() -> void:
	init_quick_open_shortcuts()

	icon_manager = IconManager.new()
	icon_manager.init_icons()

	settings_manager = QuillSettingsManager.new()
	settings_manager.init_settings()

	indent_guidelines_manager = IndentGuidelinesManager.new()
	indent_guidelines_manager.init()

	smooth_caret_manager = SmoothCaretManager.new()
	smooth_caret_manager.init()

	zen_mode = ZenMode.new()
	zen_mode.init(settings_manager, hide_bottom_panel)

	# Each of these hooks into the editor's own UI. If one can't find what it needs (usually after
	# an engine update moved things around) only that feature is switched off, and we say so once.
	var failed_features: PackedStringArray = []

	tab_manager = TabManager.new()
	if tab_manager.init(settings_manager, icon_manager):
		tab_manager.update_tabs()
	else:
		tab_manager.cleanup()
		tab_manager = null
		failed_features.append("Script tabs")

	# Before the breadcrumbs: this unwraps the tabs if a dead instance left them inside its split,
	# and the breadcrumbs need the tabs back in their normal parent.
	var tab_containers: Array[Node] = EditorInterface.get_script_editor().find_children("*", "TabContainer", true, false)
	if not tab_containers.is_empty():
		split_view = SplitView.new()
		split_view.init(tab_containers[0])
	else:
		failed_features.append("Split view")

	if tab_manager:
		tab_extras = TabExtras.new()
		tab_extras.init(tab_manager, settings_manager)
		if split_view:
			tab_extras.split_requested.connect(split_view.open)

	outline_manager = OutlineManager.new()
	if not outline_manager.init(settings_manager, icon_manager):
		outline_manager.cleanup()
		outline_manager = null
		failed_features.append("Outline")

	breadcrumb_bar = BreadcrumbBar.new()
	if not breadcrumb_bar.init(settings_manager, icon_manager):
		breadcrumb_bar.free()
		breadcrumb_bar = null
		failed_features.append("Breadcrumbs")

	if tab_manager and outline_manager:
		tab_manager.script_tab_changed.connect(outline_manager._on_active_script_changed)
	if tab_manager and breadcrumb_bar:
		tab_manager.script_tab_changed.connect(breadcrumb_bar._on_active_script_changed)
	if breadcrumb_bar and outline_manager:
		breadcrumb_bar.top_level_symbol_changed.connect(outline_manager.follow_symbol)

	var base_control: Control = EditorInterface.get_base_control()
	var stale_popup: Node = base_control.get_node_or_null(NodePath(UsagesPopup.NAME))
	if stale_popup:
		base_control.remove_child(stale_popup)
		stale_popup.queue_free()
	usages_popup = UsagesPopup.new()
	base_control.add_child(usages_popup)
	if outline_manager:
		outline_manager.find_usages_requested.connect(usages_popup.show_usages)

	navigation_history = NavigationHistory.new()
	navigation_history.init()
	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)
	if not resource_saved.is_connected(_on_resource_saved):
		resource_saved.connect(_on_resource_saved)
	if breadcrumb_bar:
		_add_history_buttons()

	var file_system: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if not file_system.filesystem_changed.is_connected(schedule_update):
		file_system.filesystem_changed.connect(schedule_update)

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if not editor_settings.settings_changed.is_connected(_on_settings_changed):
		editor_settings.settings_changed.connect(_on_settings_changed)

	if not failed_features.is_empty():
		ProjectFiles.toast("Quill IDE couldn't find parts of the script editor it needs, so these are turned off: %s. Everything else works. (Usually caused by a Godot update; restarting the editor can also help.)" % ", ".join(failed_features))

func _exit_tree() -> void:
	if zen_mode:
		zen_mode.cleanup()
		zen_mode = null

	var file_system: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if file_system and file_system.filesystem_changed.is_connected(schedule_update):
		file_system.filesystem_changed.disconnect(schedule_update)

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if editor_settings and editor_settings.settings_changed.is_connected(_on_settings_changed):
		editor_settings.settings_changed.disconnect(_on_settings_changed)

	if indent_guidelines_manager:
		indent_guidelines_manager.cleanup()
		indent_guidelines_manager = null
	if smooth_caret_manager:
		smooth_caret_manager.cleanup()
		smooth_caret_manager = null

	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if resource_saved.is_connected(_on_resource_saved):
		resource_saved.disconnect(_on_resource_saved)
	# Saves unsaved pane edits and puts the tabs back in their own parent.
	if split_view:
		split_view.cleanup()
		split_view = null
	if tab_extras:
		tab_extras.cleanup()
		tab_extras = null
	if navigation_history:
		navigation_history.cleanup()
		navigation_history = null
	if breadcrumb_bar:
		breadcrumb_bar.cleanup()
		breadcrumb_bar = null
	if outline_manager:
		outline_manager.cleanup()
		outline_manager = null
	if tab_manager:
		tab_manager.cleanup()
		tab_manager = null
	if is_instance_valid(quick_open_popup):
		quick_open_popup.free()
	quick_open_popup = null
	if is_instance_valid(usages_popup):
		usages_popup.queue_free()
	usages_popup = null

func _process(delta: float) -> void:
	update_editor()
	set_process(false)

func _shortcut_input(event: InputEvent) -> void:
	if (!event.is_pressed() || event.is_echo()):
		return

	# Quick open is a double tap (Shift by default): the first press starts a short timer,
	# and a second press while it's still running opens the popup.
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
	# Any other key in between cancels the double tap.
	if (event is InputEventKey):
		if open_quick_search_popup_shc and !open_quick_search_popup_shc.matches_event(event):
			if (quick_open_tween != null):
				quick_open_tween.kill()
				quick_open_tween = null

	_handle_navigation_input(event)

# This lives in _input so we see these before Godot's own script history does.
# It uses the same keys and mouse buttons, and otherwise both would fire.
func _handle_navigation_input(event: InputEvent) -> void:
	if (!event.is_pressed() || event.is_echo()):
		return
	if (!EditorInterface.get_script_editor().is_visible_in_tree()):
		return

	var handled: bool = true
	if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_XBUTTON1) or (history_back_shc and history_back_shc.matches_event(event)):
		if navigation_history: navigation_history.go_back()
	elif (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_XBUTTON2) or (history_forward_shc and history_forward_shc.matches_event(event)):
		if navigation_history: navigation_history.go_forward()
	elif toggle_bookmark_shc and toggle_bookmark_shc.matches_event(event):
		_toggle_bookmark_at_caret()
	elif next_bookmark_shc and next_bookmark_shc.matches_event(event):
		if outline_manager: outline_manager.goto_next_bookmark(1)
	elif previous_bookmark_shc and previous_bookmark_shc.matches_event(event):
		if outline_manager: outline_manager.goto_next_bookmark(-1)
	elif find_usages_shc and find_usages_shc.matches_event(event):
		_find_usages_at_caret()
	elif toggle_pin_shc and toggle_pin_shc.matches_event(event):
		if tab_extras: tab_extras.toggle_pin_current()
	elif toggle_split_shc and toggle_split_shc.matches_event(event):
		if split_view: split_view.toggle()
	elif toggle_zen_shc and toggle_zen_shc.matches_event(event):
		if zen_mode: zen_mode.toggle()
	else:
		handled = false

	if handled:
		get_viewport().set_input_as_handled()

func _toggle_bookmark_at_caret() -> void:
	if not outline_manager or not breadcrumb_bar:
		return
	var symbol: Dictionary = breadcrumb_bar.get_top_level_symbol()
	if symbol.is_empty():
		return

	# Bookmarks find their line again by the outline's type/modifier, so convert to that.
	var type: StringName = symbol[&"kind"]
	var modifier: StringName = &""
	if type == BreadcrumbBar.KIND_VAR and symbol[&"exported"]:
		modifier = &"@export"
	elif type == BreadcrumbBar.KIND_ENUM:
		type = &"const"
		modifier = &"enum"
	outline_manager.toggle_bookmark(symbol[&"name"], type, modifier)

# Usages of the word under the caret. If it's declared in this script we know whether it's a
# signal or a function, which narrows down the scene connections we look at.
func _find_usages_at_caret() -> void:
	if not is_instance_valid(usages_popup):
		return
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if not editor_base or not editor_base.get_base_editor() is CodeEdit:
		return
	var code_edit: CodeEdit = editor_base.get_base_editor()
	var word: String = code_edit.get_word_under_caret()
	if word.is_empty() or not word.is_valid_identifier():
		return

	var kind: StringName = &""
	for symbol: Dictionary in SymbolParser.parse(code_edit.text.split("\n"), code_edit.indent_size):
		if symbol[&"name"] == word:
			kind = symbol[&"kind"]
			break
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	usages_popup.show_usages(word, kind, script.resource_path if script else "")

func _add_history_buttons() -> void:
	var editor_theme: Theme = EditorInterface.get_editor_theme()

	history_back_btn = Button.new()
	history_back_btn.flat = true
	history_back_btn.focus_mode = Control.FOCUS_NONE
	history_back_btn.icon = editor_theme.get_icon(&"Back", &"EditorIcons")
	history_back_btn.tooltip_text = "Go Back"
	history_back_btn.pressed.connect(navigation_history.go_back)
	breadcrumb_bar.add_leading_control(history_back_btn)

	history_forward_btn = Button.new()
	history_forward_btn.flat = true
	history_forward_btn.focus_mode = Control.FOCUS_NONE
	history_forward_btn.icon = editor_theme.get_icon(&"Forward", &"EditorIcons")
	history_forward_btn.tooltip_text = "Go Forward"
	history_forward_btn.pressed.connect(navigation_history.go_forward)
	breadcrumb_bar.add_leading_control(history_forward_btn)

	navigation_history.changed.connect(_update_history_buttons)
	_update_history_buttons()

func _update_history_buttons() -> void:
	if not navigation_history or not is_instance_valid(history_back_btn):
		return
	history_back_btn.disabled = not navigation_history.can_go_back()
	history_forward_btn.disabled = not navigation_history.can_go_forward()

# The script editor has no "script saved" signal of its own; every save goes through here.
func _on_resource_saved(resource: Resource) -> void:
	if not resource is Script:
		return
	if tab_manager:
		tab_manager.on_script_saved(resource)
	if outline_manager:
		outline_manager.on_script_saved(resource)

func _on_scene_changed(scene_root: Node) -> void:
	if navigation_history and scene_root and not scene_root.scene_file_path.is_empty():
		navigation_history.record_recent_file(scene_root.scene_file_path)
	# Signal connections shown in the outline come from the open scene.
	if outline_manager:
		outline_manager.update_outline()

func _get_window_layout(configuration: ConfigFile) -> void:
	if outline_manager and outline_manager.outline_width > 0:
		configuration.set_value("Quill-IDE", "outline_width", outline_manager.outline_width)

# Godot restores its own split offset around here, and that one assumes the outline is on
# the left. So put ours back right after it.
func _set_window_layout(configuration: ConfigFile) -> void:
	if not outline_manager:
		return
	var width: int = configuration.get_value("Quill-IDE", "outline_width", 0)
	if width > 0:
		outline_manager.outline_width = width
	outline_manager.update_outline_position.call_deferred()

func schedule_update() -> void:
	set_process(true)

func update_editor() -> void:
	# A branch checkout shows up as a filesystem change.
	if tab_extras:
		tab_extras.check_branch()
	# Picks up the split pane's file being changed by something else.
	if split_view:
		split_view.on_filesystem_changed()
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
	if smooth_caret_manager:
		smooth_caret_manager.handle_settings_change(changed_settings)
	if tab_manager and settings_manager:
		tab_manager.handle_settings_change(changed_settings, settings_manager)
	if breadcrumb_bar:
		breadcrumb_bar.handle_settings_change()
	if split_view:
		split_view.handle_settings_change()

	sync_quick_open_settings(changed_settings)
	sync_navigation_settings(changed_settings)

func sync_navigation_settings(changed_settings: PackedStringArray) -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	for setting: String in changed_settings:
		match StringName(setting):
			HISTORY_BACK: history_back_shc = editor_settings.get_setting(HISTORY_BACK)
			HISTORY_FORWARD: history_forward_shc = editor_settings.get_setting(HISTORY_FORWARD)
			TOGGLE_BOOKMARK: toggle_bookmark_shc = editor_settings.get_setting(TOGGLE_BOOKMARK)
			NEXT_BOOKMARK: next_bookmark_shc = editor_settings.get_setting(NEXT_BOOKMARK)
			PREVIOUS_BOOKMARK: previous_bookmark_shc = editor_settings.get_setting(PREVIOUS_BOOKMARK)
			FIND_USAGES: find_usages_shc = editor_settings.get_setting(FIND_USAGES)
			TOGGLE_PIN: toggle_pin_shc = editor_settings.get_setting(TOGGLE_PIN)
			TOGGLE_SPLIT: toggle_split_shc = editor_settings.get_setting(TOGGLE_SPLIT)
			TOGGLE_ZEN: toggle_zen_shc = editor_settings.get_setting(TOGGLE_ZEN)

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

	history_back_shc = ensure_shortcut(HISTORY_BACK, KEY_LEFT, true, false)
	history_forward_shc = ensure_shortcut(HISTORY_FORWARD, KEY_RIGHT, true, false)
	toggle_bookmark_shc = ensure_shortcut(TOGGLE_BOOKMARK, KEY_B, true, false)
	next_bookmark_shc = ensure_shortcut(NEXT_BOOKMARK, KEY_N, true, false)
	previous_bookmark_shc = ensure_shortcut(PREVIOUS_BOOKMARK, KEY_N, true, true)
	find_usages_shc = ensure_shortcut(FIND_USAGES, KEY_F12, false, true)
	toggle_pin_shc = ensure_shortcut(TOGGLE_PIN, KEY_P, true, false)
	# Not VS Code's Ctrl+\: Godot already uses that for "Toggle Scripts Panel", and on many
	# keyboard layouts backslash needs AltGr anyway. A briefly shipped Ctrl+\ default is replaced.
	_replace_old_default(TOGGLE_SPLIT, KEY_BACKSLASH)
	toggle_split_shc = ensure_shortcut(TOGGLE_SPLIT, KEY_S, true, false)
	toggle_zen_shc = ensure_shortcut(TOGGLE_ZEN, KEY_Z, true, false)

# Drops a stored shortcut that still has an old default key, so ensure_shortcut writes the new one.
func _replace_old_default(setting: StringName, old_keycode: Key) -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if not editor_settings.has_setting(setting):
		return
	var shortcut: Shortcut = editor_settings.get_setting(setting)
	if shortcut and shortcut.events.size() == 1 and shortcut.events[0] is InputEventKey and shortcut.events[0].keycode == old_keycode:
		editor_settings.erase(setting)

## Gets the shortcut from editor settings, adding it with this default if it's not there yet.
func ensure_shortcut(setting: StringName, keycode: Key, alt: bool, shift: bool, ctrl: bool = false) -> Shortcut:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if (!editor_settings.has_setting(setting)):
		var shortcut: Shortcut = Shortcut.new()
		var event: InputEventKey = InputEventKey.new()
		event.device = -1
		event.keycode = keycode
		event.alt_pressed = alt
		event.shift_pressed = shift
		event.command_or_control_autoremap = ctrl

		shortcut.events = [event]
		editor_settings.set_setting(setting, shortcut)
	return editor_settings.get_setting(setting)

func sync_quick_open_settings(changed_settings: PackedStringArray) -> void:
	for setting: String in changed_settings:
		if (!setting.begins_with(QUICK_OPEN)):
			continue

		match StringName(setting):
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

# Missing nodes are reported once as a toast at startup, so no error here.
static func find_or_null(arr: Array[Node], index: int = 0) -> Node:
	if index >= arr.size():
		return null
	return arr[index]

func load_rel(path: String) -> Variant:
	var script_path: String = get_script().get_path().get_base_dir()
	return load(script_path.path_join(path))
