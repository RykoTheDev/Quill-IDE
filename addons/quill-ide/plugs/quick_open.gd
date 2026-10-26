@tool
extends PopupPanel
class_name QuickOpenPopup

const ADDONS: StringName = &"res://addons"
const SEPARATOR: StringName = &" - "
const STRUCTURE_START: StringName = &"("
const STRUCTURE_END: StringName = &")"

const SymbolParser = preload("res://addons/quill-ide/plugs/symbol_parser.gd")
const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

# Typing this first switches from files to symbols across all scripts.
const SYMBOL_PREFIX: String = "@"
const MAX_SYMBOL_RESULTS: int = 200

const ORDER: Dictionary[StringName, int] = {
	&"PackedScene": 0,
	&"GDScript": 1,
	&"Object": 2
}

enum Category {
	ALL = 0, SCENES = 1, GDSCRIPTS = 2, RESOURCES = 3
}


@onready var filter_bar: TabBar = %FilterBar
@onready var search_option_btn: OptionButton = %SearchOptionBtn
@onready var filter_txt: LineEdit = %FilterTxt
@onready var files_list: ItemList = %FilesList


var plugin: EditorPlugin

var scenes: Array[FileData]
var scripts: Array[FileData]
var resources: Array[FileData]
var others: Array[FileData]

var all_files: Array[FileData]

var is_rebuild_cache: bool = true

# Built the first time you type @ after the popup opens, so it's fresh but not rebuilt per key.
var symbols: Array[SymbolData] = []
var symbols_dirty: bool = true


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
	filter_txt.placeholder_text = "Search files, or start with %s to search symbols" % SYMBOL_PREFIX

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
	var metadata: Variant = files_list.get_item_metadata(index)
	if (metadata == null):
		return
	if (metadata is Dictionary):
		open_symbol(metadata)
		return

	var file: String = metadata
	if (plugin != null && plugin.navigation_history != null):
		plugin.navigation_history.record_recent_file(file)

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
	symbols_dirty = true

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
	symbols_dirty = true
	rebuild_cache()
	fill_files_list()

	focus_and_select_first()

func focus_and_select_first():
	filter_txt.grab_focus()

	if (files_list.item_count > 0):
		# The top recent file is usually the one you're already in, so start on the next one.
		var index: int = 0
		if (filter_txt.text.is_empty() && files_list.item_count > 1 && files_list.get_item_metadata(0) == get_current_file()):
			index = 1
		files_list.select(index)

func get_current_file() -> String:
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if (script == null or not EditorInterface.get_script_editor().is_visible_in_tree()):
		var scene_root: Node = EditorInterface.get_edited_scene_root()
		return scene_root.scene_file_path if scene_root != null else ""
	return script.resource_path

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
		# Show the folder after the name, e.g. "player.gd - (scripts/actors)". 6 is len("res://").
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

	if (filter_txt.text.begins_with(SYMBOL_PREFIX)):
		fill_symbols_list(filter_txt.text.substr(SYMBOL_PREFIX.length()).strip_edges())
		return

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

	# Empty search: recent files go on top.
	var recent: Dictionary[String, bool] = {}
	if (filter_text.is_empty() && plugin != null && plugin.navigation_history != null):
		var by_path: Dictionary[String, FileData] = {}
		for file_data: FileData in files:
			by_path[file_data.file] = file_data

		var recent_color: Color = EditorInterface.get_editor_settings().get_setting("interface/theme/accent_color")
		recent_color.a = 0.08
		for path: String in plugin.navigation_history.recent_files:
			if (by_path.has(path)):
				recent[path] = true
				add_file_item(by_path[path])
				files_list.set_item_custom_bg_color(files_list.item_count - 1, recent_color)
				files_list.set_item_tooltip(files_list.item_count - 1, path + "\n(Recently opened)")

	for file_data: FileData in files:
		var file: String = file_data.file
		if (recent.has(file)):
			continue
		if (filter_text.is_empty() || filter_text.is_subsequence_ofn(file)):
			add_file_item(file_data)

func add_file_item(file_data: FileData):
	var icon: Texture2D = EditorInterface.get_base_control().get_theme_icon(file_data.file_type, &"EditorIcons")

	files_list.add_item(file_data.file_name_structure, icon)
	files_list.set_item_metadata(files_list.item_count - 1, file_data.file)
	files_list.set_item_tooltip(files_list.item_count - 1, file_data.file)

func sort_by_order_filter(file_data1: FileData, file_data2: FileData) -> bool:
	var order1: int = ORDER.get(file_data1.file_type, ORDER.size())
	var order2: int = ORDER.get(file_data2.file_type, ORDER.size())

	if (order1 != order2):
		return order1 < order2

	return sort_by_filter(file_data1, file_data2)

# Files whose names start with the typed text float up; ties fall back to alphabetical.
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

#region Symbols
func rebuild_symbols():
	symbols_dirty = false
	symbols.clear()

	var include_addons: bool = search_option_btn.get_selected_id() == 1
	for path: String in ProjectFiles.find_files(["gd"], include_addons):
		var parsed: Array[Dictionary] = SymbolParser.parse(ProjectFiles.read_lines(path))
		for symbol: Dictionary in parsed:
			# Skip locals: anything declared inside a function body.
			var parent: int = symbol[&"parent"]
			if (parent != -1 && parsed[parent][&"kind"] == SymbolParser.KIND_FUNC):
				continue

			var data: SymbolData = SymbolData.new()
			data.name = symbol[&"name"]
			data.kind = symbol[&"kind"]
			data.exported = symbol[&"exported"]
			data.path = path
			data.line = symbol[&"line"]
			data.owner_name = parsed[parent][&"name"] if parent != -1 else ""
			symbols.append(data)

func fill_symbols_list(query: String):
	if (symbols_dirty):
		rebuild_symbols()

	var lower_query: String = query.to_lower()
	var matches: Array[SymbolData] = []
	for data: SymbolData in symbols:
		data.score = score_symbol(data.name.to_lower(), lower_query)
		if (data.score > 0):
			matches.append(data)

	# Best match first, then shorter names, then alphabetical.
	matches.sort_custom(func(a: SymbolData, b: SymbolData) -> bool:
		if (a.score != b.score):
			return a.score > b.score
		if (a.name.length() != b.name.length()):
			return a.name.length() < b.name.length()
		return a.name.naturalnocasecmp_to(b.name) < 0)

	for i: int in mini(matches.size(), MAX_SYMBOL_RESULTS):
		var data: SymbolData = matches[i]
		var label: String = data.name + ("()" if data.kind == SymbolParser.KIND_FUNC else "")
		if (!data.owner_name.is_empty()):
			label = data.owner_name + "." + label
		label += SEPARATOR + data.path.get_file() + ":" + str(data.line + 1)

		files_list.add_item(label, get_symbol_icon(data))
		files_list.set_item_metadata(files_list.item_count - 1, { &"path": data.path, &"line": data.line })
		files_list.set_item_tooltip(files_list.item_count - 1, "%s %s\n%s:%d" % [data.kind, data.name, data.path, data.line + 1])

	if (matches.size() > MAX_SYMBOL_RESULTS):
		files_list.add_item("... %d more, keep typing to narrow it down" % (matches.size() - MAX_SYMBOL_RESULTS))
		files_list.set_item_disabled(files_list.item_count - 1, true)
		files_list.set_item_selectable(files_list.item_count - 1, false)

# 3 = name starts with the query, 2 = contains it, 1 = letters in order (fuzzy), 0 = no match.
func score_symbol(lower_name: String, lower_query: String) -> int:
	if (lower_query.is_empty()):
		return 1
	if (lower_name.begins_with(lower_query)):
		return 3
	if (lower_name.contains(lower_query)):
		return 2
	if (lower_query.is_subsequence_of(lower_name)):
		return 1
	return 0

func get_symbol_icon(data: SymbolData) -> Texture2D:
	var icons: IconManager = plugin.icon_manager if plugin != null else null
	if (icons == null):
		return null
	if (data.kind == SymbolParser.KIND_FUNC):
		return icons.get_func_icon(data.name)
	elif (data.kind == SymbolParser.KIND_SIGNAL):
		return icons.signal_icon
	elif (data.kind == SymbolParser.KIND_CLASS || data.kind == SymbolParser.KIND_CLASS_NAME):
		return icons.class_icon
	elif (data.kind == SymbolParser.KIND_CONST || data.kind == SymbolParser.KIND_ENUM):
		return icons.constant_icon
	elif (data.kind == SymbolParser.KIND_VAR):
		return icons.export_icon if data.exported else icons.property_icon
	return null

func open_symbol(metadata: Dictionary):
	var path: String = metadata[&"path"]
	if (plugin != null && plugin.navigation_history != null):
		plugin.navigation_history.record_recent_file(path)
	ProjectFiles.open_script_at(path, metadata[&"line"])
	hide.call_deferred()
#endregion

class SymbolData:
	var name: String
	var kind: StringName
	var exported: bool
	var path: String
	var line: int
	# Enclosing inner class, if any.
	var owner_name: String
	var score: int

class FileData:
	var file: String
	var file_name: String
	var file_name_structure: String
	var file_type: StringName
