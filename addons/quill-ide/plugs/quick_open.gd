@tool
extends PopupPanel
class_name QuickOpenPopup

const ADDONS: StringName = &"res://addons"
const SEPARATOR: StringName = &" - "
const STRUCTURE_START: StringName = &"("
const STRUCTURE_END: StringName = &")"

const ORDER: Dictionary[StringName, int] = {
	&"PackedScene": 0,
	&"GDScript": 1,
	&"Object": 2
}

enum Category {
	ALL = 0, SCENES = 1, GDSCRIPTS = 2, RESOURCES = 3
}

#region UI
@onready var filter_bar: TabBar = %FilterBar
@onready var search_option_btn: OptionButton = %SearchOptionBtn
@onready var filter_txt: LineEdit = %FilterTxt
@onready var files_list: ItemList = %FilesList
#endregion

var plugin: EditorPlugin

var scenes: Array[FileData]
var scripts: Array[FileData]
var resources: Array[FileData]
var others: Array[FileData]

var all_files: Array[FileData]

var is_rebuild_cache: bool = true

#region Plugin and Shortcut processing
func _ready() -> void:
	popup_window = true
	
	filter_bar.clear_tabs()
	filter_bar.add_tab(&"All")
	filter_bar.add_tab(&"Scenes")
	filter_bar.add_tab(&"Scripts")
	filter_bar.add_tab(&"Resources")
	filter_bar.add_tab(&"Others")
	filter_bar.current_tab = 0
	filter_bar.tab_alignment = TabBar.ALIGNMENT_LEFT
	
	search_option_btn.clear()
	search_option_btn.add_item(&"Hide Addons", 0)
	search_option_btn.add_item(&"Show Addons", 1)
	search_option_btn.selected = load_show_addons_setting()
	
	files_list.item_selected.connect(open_file)
	search_option_btn.item_selected.connect(_on_show_addons_changed.unbind(1))
	search_option_btn.item_selected.connect(rebuild_cache_and_ui.unbind(1))
	filter_txt.text_changed.connect(fill_files_list.unbind(1))

	filter_bar.tab_changed.connect(change_fill_files_list.unbind(1))

	about_to_popup.connect(on_show)

	var file_system: EditorFileSystem = EditorInterface.get_resource_filesystem()
	file_system.filesystem_changed.connect(schedule_rebuild)

	filter_txt.gui_input.connect(navigate_in_files_list)

func load_show_addons_setting() -> int:
	if (plugin != null and plugin.has_meta(&"quick_open_show_addons")):
		return 1 if plugin.get_meta(&"quick_open_show_addons") else 0
	return 0

func _on_show_addons_changed():
	if (plugin != null):
		plugin.set_meta(&"quick_open_show_addons", search_option_btn.get_selected_id() == 1)

func _shortcut_input(event: InputEvent) -> void:
	if (!event.is_pressed() || event.is_echo()):
		return

	if (plugin.tab_cycle_forward_shc.matches_event(event)):
		get_viewport().set_input_as_handled()

		var new_tab: int = filter_bar.current_tab + 1
		if (new_tab == filter_bar.get_tab_count()):
			new_tab = 0
		filter_bar.current_tab = new_tab
	elif (plugin.tab_cycle_backward_shc.matches_event(event)):
		get_viewport().set_input_as_handled()

		var new_tab: int = filter_bar.current_tab - 1
		if (new_tab == -1):
			new_tab = filter_bar.get_tab_count() - 1
		filter_bar.current_tab = new_tab
#endregion

func _input(event: InputEvent) -> void:
	if (event is InputEventKey and event.pressed and not event.is_echo()):
		if (event.keycode == KEY_ESCAPE):
			var viewport: Viewport = get_viewport()
			hide()
			if (viewport != null):
				viewport.set_input_as_handled()

func navigate_in_files_list(event: InputEvent):
	plugin.navigate_on_list(event, files_list, open_file)

func set_category(category: Category):
	var old_tab: int = filter_bar.current_tab
	filter_bar.current_tab = category

	if (old_tab == category):
		fill_files_list()

	focus_and_select_first()

func open_file(index: int):
	var file: String = files_list.get_item_metadata(index)

	if (ResourceLoader.exists(file)):
		var res: Resource = load(file)

		if (res is Script):
			EditorInterface.edit_script(res)
			EditorInterface.set_main_screen_editor.call_deferred(&"Script")
		else:
			EditorInterface.edit_resource(res)

		if (res is PackedScene):
			EditorInterface.open_scene_from_path(file)

			var root: Node = EditorInterface.get_edited_scene_root()
			if (root is Node3D):
				EditorInterface.set_main_screen_editor.call_deferred(&"3D")
			else:
				EditorInterface.set_main_screen_editor.call_deferred(&"2D")
	else:
		EditorInterface.select_file(file)

	hide.call_deferred()

func schedule_rebuild():
	is_rebuild_cache = true

func on_show():
	search_option_btn.selected = load_show_addons_setting()

	if (is_rebuild_cache):
		rebuild_cache()

	fill_files_list()
	filter_txt.select_all()

func rebuild_cache():
	is_rebuild_cache = false

	all_files.clear()
	scenes.clear()
	scripts.clear()
	resources.clear()
	others.clear()

	build_file_cache()

func rebuild_cache_and_ui():
	rebuild_cache()
	fill_files_list()

	focus_and_select_first()

func focus_and_select_first():
	filter_txt.grab_focus()

	if (files_list.item_count > 0):
		files_list.select(0)

func build_file_cache():
	var dir: EditorFileSystemDirectory = EditorInterface.get_resource_filesystem().get_filesystem()
	build_file_cache_dir(dir)

	scenes.sort_custom(sort_by_filter)
	scripts.sort_custom(sort_by_filter)
	resources.sort_custom(sort_by_filter)
	others.sort_custom(sort_by_filter)

	all_files.append_array(scenes)
	all_files.append_array(scripts)
	all_files.append_array(resources)
	all_files.append_array(others)

func build_file_cache_dir(dir: EditorFileSystemDirectory):
	for index: int in dir.get_subdir_count():
		build_file_cache_dir(dir.get_subdir(index))

	for index: int in dir.get_file_count():
		var file: String = dir.get_file_path(index)
		if (search_option_btn.get_selected_id() == 0 && file.begins_with(ADDONS)):
			continue

		var last_delimiter: int = file.rfind(&"/")

		var file_name: String = file.substr(last_delimiter + 1)
		var file_structure: String = &""
		if (file_name.length() + 6 != file.length()):
			file_structure = SEPARATOR + STRUCTURE_START + file.substr(6, last_delimiter - 6) + STRUCTURE_END

		var file_data: FileData = FileData.new()
		file_data.file = file
		file_data.file_name = file_name
		file_data.file_name_structure = file_name + file_structure
		file_data.file_type = dir.get_file_type(index)

		if (file_data.file_type == &"Resource"):
			file_data.file_type = &"Object"

		match (file.get_extension()):
			&"tscn": scenes.append(file_data)
			&"gd": scripts.append(file_data)
			&"tres": resources.append(file_data)
			&"gdshader": resources.append(file_data)
			_: others.append(file_data)

func change_fill_files_list():
	fill_files_list()

	focus_and_select_first()

func fill_files_list():
	files_list.clear()

	if (filter_bar.current_tab == 0):
		fill_files_list_with(all_files, sort_by_order_filter)
	elif (filter_bar.current_tab == 1):
		fill_files_list_with(scenes, sort_by_filter)
	elif (filter_bar.current_tab == 2):
		fill_files_list_with(scripts, sort_by_filter)
	elif (filter_bar.current_tab == 3):
		fill_files_list_with(resources, sort_by_filter)
	elif (filter_bar.current_tab == 4):
		fill_files_list_with(others, sort_by_filter)

func fill_files_list_with(files: Array[FileData], comparator: Callable):
	var filter_text: String = filter_txt.text

	if (!filter_text.is_empty()):
		files.sort_custom(comparator)

	for file_data: FileData in files:
		var file: String = file_data.file
		if (filter_text.is_empty() || filter_text.is_subsequence_ofn(file)):
			var icon: Texture2D = EditorInterface.get_base_control().get_theme_icon(file_data.file_type, &"EditorIcons")

			files_list.add_item(file_data.file_name_structure, icon)
			files_list.set_item_metadata(files_list.item_count - 1, file)
			files_list.set_item_tooltip(files_list.item_count - 1, file)

func sort_by_order_filter(file_data1: FileData, file_data2: FileData) -> bool:
	var order1: int = ORDER.get(file_data1.file_type, ORDER.size())
	var order2: int = ORDER.get(file_data2.file_type, ORDER.size())

	if (order1 != order2):
		return order1 < order2

	return sort_by_filter(file_data1, file_data2)

func sort_by_filter(file_data1: FileData, file_data2: FileData) -> bool:
	var filter_text: String = filter_txt.text

	var name1: String = file_data1.file_name
	var name2: String = file_data2.file_name

	for index: int in filter_text.length():
		var a_oob: bool = index >= name1.length()
		var b_oob: bool = index >= name2.length()

		if (a_oob && b_oob):
			return false
		elif (a_oob):
			return true
		elif (b_oob):
			return false

		var char: String = filter_text[index]
		var a_match: bool = char == name1[index]
		var b_match: bool = char == name2[index]

		if (a_match && !b_match):
			return true
		elif (b_match && !a_match):
			return false

	return name1 < name2

class FileData:
	var file: String
	var file_name: String
	var file_name_structure: String
	var file_type: StringName
