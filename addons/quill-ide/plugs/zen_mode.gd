@tool
extends RefCounted

## Zen mode: hides everything except the code. Docks (through Godot's own distraction-free mode),
## the bottom panel, the editor's top bar and scene tabs, the script editor's menu bar, script
## list, outline, tabs and breadcrumbs, and optionally goes fullscreen. Toggling it off puts back
## exactly what was showing before, nothing more.
##
## Editor parts are found by class name. Anything a Godot version doesn't have is just skipped.

const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

# Editor-wide parts to hide, by class. (Internal classes, but find_children matches them by name.)
const EDITOR_CLASSES_TO_HIDE: PackedStringArray = ["EditorTitleBar", "EditorSceneTabs", "EditorBottomPanel"]
const BREADCRUMBS_NAME: StringName = &"QuillBreadcrumbs"

var active: bool = false
var settings_manager: QuillSettingsManager
var hide_bottom_panel: Callable

# What we changed, so leaving restores only that.
var hidden_controls: Array[Control] = []
var tab_container: TabContainer
var tabs_were_visible: bool = true
var was_distraction_free: bool = false
var previous_window_mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_WINDOWED
var changed_window_mode: bool = false

## hide_bottom_panel_callable: the plugin's EditorPlugin.hide_bottom_panel (only a plugin has it).
func init(settings_mgr: QuillSettingsManager, hide_bottom_panel_callable: Callable):
	settings_manager = settings_mgr
	hide_bottom_panel = hide_bottom_panel_callable

# Safe to call more than once.
func cleanup():
	if active:
		leave()

func toggle():
	if active:
		leave()
	else:
		enter()

func enter():
	if active:
		return
	active = true
	hidden_controls.clear()

	EditorInterface.set_main_screen_editor(&"Script")
	was_distraction_free = EditorInterface.distraction_free_mode
	EditorInterface.distraction_free_mode = true
	if hide_bottom_panel.is_valid():
		hide_bottom_panel.call()

	var base_control: Control = EditorInterface.get_base_control()
	for class_to_hide: String in EDITOR_CLASSES_TO_HIDE:
		for node: Node in base_control.find_children("*", class_to_hide, true, false):
			_hide(node)

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	_hide(_find_script_menu_bar(script_editor))
	_hide(_find_list_column(script_editor))
	_hide(script_editor.find_child(BREADCRUMBS_NAME, true, false))

	var tab_containers: Array[Node] = script_editor.find_children("*", "TabContainer", true, false)
	tab_container = tab_containers[0] if not tab_containers.is_empty() else null
	if tab_container:
		tabs_were_visible = tab_container.tabs_visible
		tab_container.tabs_visible = false

	changed_window_mode = false
	if settings_manager.zen_fullscreen:
		previous_window_mode = DisplayServer.window_get_mode()
		if previous_window_mode != DisplayServer.WINDOW_MODE_FULLSCREEN and previous_window_mode != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			changed_window_mode = true

	_focus_code()
	ProjectFiles.toast("Zen mode on. Press the Zen shortcut again (Alt+Z by default) to bring everything back.")

func leave():
	if not active:
		return
	active = false

	for control: Variant in hidden_controls:
		if is_instance_valid(control):
			control.visible = true
	hidden_controls.clear()

	if is_instance_valid(tab_container):
		tab_container.tabs_visible = tabs_were_visible
	tab_container = null

	EditorInterface.distraction_free_mode = was_distraction_free
	if changed_window_mode:
		DisplayServer.window_set_mode(previous_window_mode)
		changed_window_mode = false
	_focus_code()

# Only hides what's currently showing, and remembers it.
func _hide(node: Node):
	if node is Control and node.visible:
		node.visible = false
		hidden_controls.append(node)

# The File / Search / Go To / Debug bar: the parent of the script editor's "File" menu button,
# or of its first menu button when the editor isn't in English.
func _find_script_menu_bar(script_editor: ScriptEditor) -> Control:
	var menu_buttons: Array[Node] = script_editor.find_children("*", "MenuButton", true, false)
	for node: Node in menu_buttons:
		if (node as MenuButton).text == "File":
			return node.get_parent() as Control
	return menu_buttons[0].get_parent() as Control if not menu_buttons.is_empty() else null

# The column with the script list and the outline: the split's child that holds an ItemList.
func _find_list_column(script_editor: ScriptEditor) -> Control:
	var splits: Array[Node] = script_editor.find_children("*", "HSplitContainer", true, false)
	if splits.is_empty():
		return null
	for child: Node in splits[0].get_children():
		if child is Control and not child.find_children("*", "ItemList", true, false).is_empty():
			return child
	return null

func _focus_code():
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor_base and editor_base.get_base_editor():
		editor_base.get_base_editor().grab_focus.call_deferred()
