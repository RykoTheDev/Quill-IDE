@tool
class_name OutlineManager

const SymbolParser = preload("res://addons/quill-ide/plugs/symbol_parser.gd")
const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")
const MemberSorter = preload("res://addons/quill-ide/plugs/member_sorter.gd")
const TodoPanel = preload("res://addons/quill-ide/plugs/todo_panel.gd")

## From the right-click menu; the plugin owns the popup that shows the results.
signal find_usages_requested(symbol_name: String, kind: StringName, script_path: String)

enum MenuId { BOOKMARK, FIND_USAGES, GETTER_SETTER, EXPORT_GROUP, DOC_COMMENT, SORT_MEMBERS }

# Metadata type of the "-> Node.method()" rows under a signal.
const CONNECTION_TYPE: StringName = &"connection"

const UNDERSCORE: StringName = &"_"
const INLINE: StringName = &"@"
const GETTER: StringName = &"get"
const SETTER: StringName = &"set"

const ENGINE_FUNCS: StringName = &"Engine Callbacks"
const FUNCS: StringName = &"Functions"
const SIGNALS: StringName = &"Signals"
const EXPORTED: StringName = &"Exported Properties"
const PROPERTIES: StringName = &"Properties"
const CLASSES: StringName = &"Classes"
const CONSTANTS: StringName = &"Constants"
const BOOKMARKS: StringName = &"Bookmarks"
const MAX_BOOKMARKS_HEIGHT: int = 150
const DEFAULT_OUTLINE_WIDTH: int = 250

# Every node we add is named with this prefix so leftovers from a dead instance can be found.
const STALE_NODE_PREFIX: String = "Quill"
const OUTLINE_TREE_NAME: StringName = &"QuillOutlineTree"
const NATIVE_OUTLINE_META: StringName = &"_quill_native_outline"

var outline_container: Control
var outline_parent: Control
var split_container: HSplitContainer
var editor_container: Control
var outline_size_flags: int
var editor_size_flags: int
var outline_width: int = 0
var old_outline: Control
var outline_filter_txt: LineEdit
var sort_btn: Button
var outline_tree: Tree
var outline_root: TreeItem

var category_items: Dictionary[StringName, TreeItem] = {}

# Top-level member under the caret, highlighted when following the cursor.
var followed_symbol: String = ""
var highlighted_item: TreeItem

var collapse_button_container: HBoxContainer
var context_menu: PopupMenu

var bookmarks_container: VBoxContainer
var bookmarks_tree: Tree
var bookmarks_root: TreeItem
var bookmarks_context_menu: PopupMenu
var bookmarks_remove_all_btn: Button
var bookmark_rename_dialog: AcceptDialog
var bookmark_rename_txt: LineEdit
var bookmark_rename_target: Dictionary = {}
# Where next/previous bookmark left off (index into settings_manager.bookmarks).
var bookmark_cursor: int = -1

var outline_cache: OutlineCache
var keywords: Dictionary[String, bool] = {}
var old_script_type: StringName

var settings_manager: QuillSettingsManager
var icon_manager: IconManager

## Returns false (and leaves the editor untouched) if the nodes we need aren't there.
func init(settings_mgr: QuillSettingsManager, icon_mgr: IconManager) -> bool:
	settings_manager = settings_mgr
	icon_manager = icon_mgr

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	split_container = find_or_null(script_editor.find_children("*", "HSplitContainer", true, false))
	if not split_container:
		return false
	# The column with the lists in it. Usually child 0, but a stale instance may have left it on the right.
	for child: Node in split_container.get_children():
		if not child.find_children("*", "ItemList", true, false).is_empty():
			outline_container = child
			break
	if not outline_container:
		split_container = null
		return false

	_recover_from_stale_instance()

	# Find everything first, so if something's missing we bail before changing the editor UI.
	var found_outline: Control = _find_native_outline()
	var found_filter: LineEdit = null
	var found_sort: Button = null
	if found_outline:
		var overview_panel: Node = found_outline.get_parent()
		found_filter = find_or_null(overview_panel.find_children("*", "LineEdit", true, false))
		found_sort = find_or_null(overview_panel.find_children("*", "Button", true, false))
	if not found_outline or not found_filter or not found_sort:
		outline_container = null
		split_container = null
		return false

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if not editor_settings.settings_changed.is_connected(_on_editor_settings_changed):
		editor_settings.settings_changed.connect(_on_editor_settings_changed)

	if outline_container.get_index() != 0:
		split_container.move_child(outline_container, 0)
	editor_container = split_container.get_child(1) if split_container.get_child_count() > 1 else null
	outline_size_flags = outline_container.size_flags_horizontal
	if editor_container:
		editor_size_flags = editor_container.size_flags_horizontal
	# With the outline on the left, Godot's split offset is the panel width.
	if outline_width <= 0:
		outline_width = split_container.split_offset if split_container.split_offset > 0 else roundi(DEFAULT_OUTLINE_WIDTH * EditorInterface.get_editor_scale())
	if not split_container.dragged.is_connected(_on_split_dragged):
		split_container.dragged.connect(_on_split_dragged)

	if settings_manager.is_outline_right:
		update_outline_position()

	old_outline = found_outline
	outline_parent = old_outline.get_parent()
	var old_outline_index: int = old_outline.get_index()
	outline_parent.remove_child(old_outline)
	# Remember the detached native outline on its parent, so a later instance can put it back
	# even if this one dies without running cleanup().
	outline_parent.set_meta(NATIVE_OUTLINE_META, old_outline)

	outline_tree = Tree.new()
	outline_tree.name = OUTLINE_TREE_NAME
	outline_tree.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	outline_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outline_tree.hide_root = true
	outline_tree.allow_reselect = true
	outline_tree.scroll_horizontal_enabled = true
	outline_tree.scroll_vertical_enabled = true
	outline_parent.add_child(outline_tree)
	outline_parent.move_child(outline_tree, old_outline_index)
	outline_tree.item_selected.connect(_on_outline_item_selected)
	outline_tree.item_collapsed.connect(_on_outline_item_collapsed)
	outline_tree.gui_input.connect(_on_outline_tree_gui_input)

	context_menu = PopupMenu.new()
	outline_tree.add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	context_menu.set_meta(&"target_item", null)

	outline_root = outline_tree.create_item()

	outline_filter_txt = found_filter
	outline_filter_txt.gui_input.connect(_on_outline_filter_input)
	outline_filter_txt.text_changed.connect(_on_outline_filter_changed)

	sort_btn = found_sort
	sort_btn.pressed.connect(update_outline)

	if not script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.connect(_on_active_script_changed)

	_add_collapse_buttons()
	_add_bookmarks_section()
	_add_todo_section()
	_add_scroll_buttons()

	_update_outline_ui_visibility()
	return true

# Removes anything a previous instance left in the outline column and puts back the native
# outline it had taken out.
func _recover_from_stale_instance():
	for node: Node in outline_container.find_children(STALE_NODE_PREFIX + "*", "", true, false):
		var parent: Node = node.get_parent()
		if node.name == OUTLINE_TREE_NAME and parent.has_meta(NATIVE_OUTLINE_META):
			var native: Variant = parent.get_meta(NATIVE_OUTLINE_META)
			if is_instance_valid(native) and native.get_parent() == null:
				parent.add_child(native)
				parent.move_child(native, node.get_index())
			parent.remove_meta(NATIVE_OUTLINE_META)
		_free_node(node)

static func _free_node(node: Node):
	if not is_instance_valid(node):
		return
	if node.get_parent():
		node.get_parent().remove_child(node)
	if not node.is_queued_for_deletion():
		node.queue_free()

# Safe to call more than once, or after a failed init.
func cleanup():
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	if editor_settings.settings_changed.is_connected(_on_editor_settings_changed):
		editor_settings.settings_changed.disconnect(_on_editor_settings_changed)
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)

	if is_instance_valid(split_container):
		if is_instance_valid(outline_container):
			if outline_container.get_parent() != split_container:
				split_container.add_child(outline_container)
			split_container.move_child(outline_container, 0)
			outline_container.size_flags_horizontal = outline_size_flags
			if is_instance_valid(editor_container):
				editor_container.size_flags_horizontal = editor_size_flags
			split_container.split_offset = outline_width
		if split_container.dragged.is_connected(_on_split_dragged):
			split_container.dragged.disconnect(_on_split_dragged)

	if is_instance_valid(outline_filter_txt):
		if outline_filter_txt.gui_input.is_connected(_on_outline_filter_input):
			outline_filter_txt.gui_input.disconnect(_on_outline_filter_input)
		if outline_filter_txt.text_changed.is_connected(_on_outline_filter_changed):
			outline_filter_txt.text_changed.disconnect(_on_outline_filter_changed)
	if is_instance_valid(sort_btn) and sort_btn.pressed.is_connected(update_outline):
		sort_btn.pressed.disconnect(update_outline)

	if is_instance_valid(outline_tree):
		# Put the native outline back where our tree was. The context menu goes with our tree.
		if is_instance_valid(outline_parent) and is_instance_valid(old_outline) and old_outline.get_parent() == null:
			outline_parent.add_child(old_outline)
			outline_parent.move_child(old_outline, outline_tree.get_index())
		if outline_tree.get_parent():
			outline_tree.get_parent().remove_child(outline_tree)
		outline_tree.free()
	if is_instance_valid(outline_parent) and outline_parent.has_meta(NATIVE_OUTLINE_META):
		outline_parent.remove_meta(NATIVE_OUTLINE_META)

	_free_node(bookmarks_container)
	_free_node(collapse_button_container)
	_free_node(scroll_button_container)
	_free_node(todo_container)

	outline_tree = null
	outline_root = null
	context_menu = null
	highlighted_item = null
	category_items.clear()
	bookmarks_container = null
	bookmarks_tree = null
	bookmarks_root = null
	bookmarks_context_menu = null
	bookmark_rename_dialog = null
	collapse_button_container = null
	scroll_button_container = null
	todo_container = null
	outline_filter_txt = null
	sort_btn = null
	old_outline = null
	outline_parent = null
	outline_container = null
	editor_container = null
	split_container = null

func update_editor():
	if not outline_tree:
		return
	update_outline_cache()
	update_outline()
	_update_bookmarks_ui()
	if todo_container:
		todo_container.refresh()

func _on_editor_settings_changed():
	if not settings_manager:
		return
	var old_position: bool = settings_manager.is_outline_right
	var old_hidden: bool = settings_manager.is_outline_hidden
	settings_manager.sync_settings_all()
	if settings_manager.is_outline_right != old_position:
		update_outline_position()
	if settings_manager.is_outline_hidden != old_hidden:
		_update_outline_ui_visibility()
	_update_outline_ui_visibility()
	update_outline_cache()
	update_outline()
	_update_bookmarks_ui()


func _on_active_script_changed(script: Script):
	if not outline_tree:
		return
	update_outline_cache()
	update_outline()

## Called by the plugin when a script is saved to disk (EditorPlugin.resource_saved).
func on_script_saved(script: Script):
	if not outline_tree:
		return
	if script == EditorInterface.get_script_editor().get_current_script():
		update_outline_cache()
		update_outline()
	_cleanup_stale_bookmarks(script)

func update_outline_position():
	if not settings_manager or not split_container or not outline_container:
		return
	# Godot measures split_offset from a default that depends on which child expands. On the
	# right we make the code editor expand, so the offset counts back from the end instead.
	if settings_manager.is_outline_right:
		split_container.move_child(outline_container, 1)
		outline_container.size_flags_horizontal = outline_size_flags & ~Control.SIZE_EXPAND
		if editor_container:
			editor_container.size_flags_horizontal = editor_size_flags | Control.SIZE_EXPAND
		split_container.split_offset = -outline_width
	else:
		split_container.move_child(outline_container, 0)
		outline_container.size_flags_horizontal = outline_size_flags
		if editor_container:
			editor_container.size_flags_horizontal = editor_size_flags
		split_container.split_offset = outline_width

func _on_split_dragged(offset: int):
	outline_width = absi(offset)

func update_keywords(script: Script):
	if script == null:
		return

	var new_script_type: StringName = script.get_instance_base_type()
	if old_script_type != new_script_type:
		old_script_type = new_script_type
		keywords.clear()
		keywords["_static_init"] = true
		register_virtual_methods(new_script_type)

func register_virtual_methods(clazz: String):
	for method_dict in ClassDB.class_get_method_list(clazz):
		if method_dict[&"flags"] & METHOD_FLAG_VIRTUAL > 0:
			keywords[method_dict[&"name"]] = true

func update_outline_cache():
	outline_cache = null
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script:
		return

	update_keywords(script)

	if script.get_path().contains("::GDScript"):
		script = script.duplicate()

	outline_cache = OutlineCache.new()
	for_each_script_member(script, func(array: Array[String], item: String): array.append(item))

	# Only show what this script declares itself, not what it inherits.
	var base_script: Script = script.get_base_script()
	if base_script != null:
		for_each_script_member(base_script, func(array: Array[String], item: String): array.erase(item))

func for_each_script_member(script: Script, consumer: Callable):
	var hide_private: bool = settings_manager.hide_private_members if settings_manager else false

	for dict in script.get_script_method_list():
		var func_name: String = dict[&"name"]
		if keywords.has(func_name):
			consumer.call(outline_cache.engine_funcs, func_name)
		else:
			if hide_private and func_name.begins_with(UNDERSCORE):
				continue
			if func_name.begins_with(INLINE):
				continue
			consumer.call(outline_cache.funcs, func_name)

	for dict in script.get_script_property_list():
		var property_name: String = dict[&"name"]
		if hide_private and property_name.begins_with(UNDERSCORE):
			continue

		var usage: int = dict[&"usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			# Stored + shown in the inspector = @export.
			if usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR:
				consumer.call(outline_cache.exports, property_name)
			else:
				consumer.call(outline_cache.properties, property_name)

	for dict in script.get_property_list():
		var property_name: String = dict[&"name"]
		if hide_private and property_name.begins_with(UNDERSCORE):
			continue

		var usage: int = dict[&"usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			consumer.call(outline_cache.properties, property_name)

	for dict in script.get_script_signal_list():
		var signal_name: String = dict[&"name"]
		consumer.call(outline_cache.signals, signal_name)

	for name_key in script.get_script_constant_map().keys():
		if hide_private and name_key.begins_with(UNDERSCORE):
			continue
		var obj: Variant = script.get_script_constant_map()[name_key]
		# Inner classes show up as constants holding a GDScript with no source of their own.
		if obj is GDScript and not obj.has_source_code():
			consumer.call(outline_cache.classes, name_key)
		else:
			consumer.call(outline_cache.constants, name_key)

func update_outline():
	if not outline_tree or not outline_root:
		return
	if not icon_manager or not settings_manager:
		return

	highlighted_item = null
	outline_tree.clear()
	outline_root = outline_tree.create_item()
	category_items.clear()

	if outline_cache == null:
		return

	var filter_text: String = outline_filter_txt.get_text().to_lower() if outline_filter_txt else ""
	var scene_connections: Dictionary = _get_scene_connections()

	var categories_data = [
		{&"name": ENGINE_FUNCS, &"items": outline_cache.engine_funcs, &"icon": icon_manager.engine_func_icon, &"type": &"func", &"enabled": settings_manager.show_engine_funcs},
		{&"name": FUNCS, &"items": outline_cache.funcs, &"icon": icon_manager.func_icon, &"type": &"func", &"use_func_icons": true, &"enabled": settings_manager.show_funcs},
		{&"name": SIGNALS, &"items": outline_cache.signals, &"icon": icon_manager.signal_icon, &"type": &"signal", &"enabled": settings_manager.show_signals},
		{&"name": EXPORTED, &"items": outline_cache.exports, &"icon": icon_manager.export_icon, &"type": &"var", &"modifier": &"@export", &"enabled": settings_manager.show_exported},
		{&"name": PROPERTIES, &"items": outline_cache.properties, &"icon": icon_manager.property_icon, &"type": &"var", &"enabled": settings_manager.show_properties},
		{&"name": CLASSES, &"items": outline_cache.classes, &"icon": icon_manager.class_icon, &"type": &"class", &"enabled": settings_manager.show_classes},
		{&"name": CONSTANTS, &"items": outline_cache.constants, &"icon": icon_manager.constant_icon, &"type": &"const", &"modifier": &"enum", &"enabled": settings_manager.show_constants}
	]

	categories_data.sort_custom(func(a, b): return get_category_order(a[&"name"]) < get_category_order(b[&"name"]))

	for category_data in categories_data:
		var items: Array[String] = category_data[&"items"]
		if items.is_empty() or not category_data[&"enabled"]:
			continue

		var filtered_items: Array[String] = []
		for item in items:
			if filter_text.is_empty() or item.to_lower().contains(filter_text):
				filtered_items.append(item)

		if filtered_items.is_empty():
			continue

		if settings_manager.is_sorted():
			filtered_items.sort_custom(func(str1: String, str2: String): return str1.naturalnocasecmp_to(str2) < 0)

		var category_item: TreeItem = outline_tree.create_item(outline_root)
		category_item.set_text(0, category_data[&"name"] + " (" + str(filtered_items.size()) + ")")
		category_item.set_icon(0, category_data[&"icon"])
		category_item.set_selectable(0, false)
		category_item.collapsed = get_category_collapsed_state(category_data[&"name"])
		category_items[category_data[&"name"]] = category_item

		for item in filtered_items:
			var item_node: TreeItem = outline_tree.create_item(category_item)
			item_node.set_text(0, item)

			var item_icon: Texture2D = category_data[&"icon"]
			if category_data.has(&"use_func_icons"):
				item_icon = icon_manager.get_func_icon(item)
			item_node.set_icon(0, item_icon)

			var metadata: Dictionary[StringName, StringName] = {
				&"type": category_data[&"type"],
				&"modifier": category_data.get(&"modifier", &"")
			}
			item_node.set_metadata(0, metadata)

			if category_data[&"type"] == &"signal" and scene_connections.has(item):
				_add_connection_items(item_node, scene_connections[item])

	_apply_followed_symbol(false)

# Connections to this script's signals that were made in the open scene, keyed by signal name.
# Only saved (editor-made) ones; anything connected from code at runtime isn't there to read.
func _get_scene_connections() -> Dictionary:
	var result: Dictionary = {}
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	var root: Node = EditorInterface.get_edited_scene_root()
	if not script or not root or not outline_cache or outline_cache.signals.is_empty():
		return result

	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, true))
	for node: Node in nodes:
		if node.get_script() != script:
			continue
		for signal_name: String in outline_cache.signals:
			for connection: Dictionary in node.get_signal_connection_list(signal_name):
				if not (connection["flags"] & CONNECT_PERSIST):
					continue
				var callable: Callable = connection["callable"]
				var target: Object = callable.get_object()
				if not target is Node:
					continue
				if not result.has(signal_name):
					result[signal_name] = []
				result[signal_name].append({
					&"source": String(root.get_path_to(node)),
					&"target": String(root.get_path_to(target)),
					&"method": String(callable.get_method()),
				})
	return result

func _add_connection_items(signal_item: TreeItem, connections: Array):
	signal_item.set_suffix(0, "  (%d)" % connections.size())
	signal_item.collapsed = false
	# Only worth naming the emitter when more than one node in the scene uses this script.
	var first_source: String = connections[0][&"source"]
	var show_source: bool = connections.any(func(c: Dictionary) -> bool: return c[&"source"] != first_source)
	var slot_icon: Texture2D = EditorInterface.get_editor_theme().get_icon(&"Slot", &"EditorIcons")

	for connection: Dictionary in connections:
		var text: String = "%s.%s()" % [connection[&"target"], connection[&"method"]]
		if show_source:
			text = "%s  ->  %s" % [connection[&"source"], text]
		var child: TreeItem = outline_tree.create_item(signal_item)
		child.set_text(0, text)
		child.set_icon(0, slot_icon)
		child.set_custom_color(0, Color(1, 1, 1, 0.65))
		child.set_tooltip_text(0, "Connected in the open scene. Click to go to the method.")
		child.set_metadata(0, { &"type": CONNECTION_TYPE, &"target": connection[&"target"], &"method": connection[&"method"] })

# Jumps to the receiving method if the target has a script, otherwise selects the node.
func _open_connection(metadata: Dictionary):
	var root: Node = EditorInterface.get_edited_scene_root()
	var target: Node = root.get_node_or_null(NodePath(metadata[&"target"])) if root else null
	if not target:
		return
	var target_script: Script = target.get_script()
	if target_script:
		var path: String = target_script.resource_path
		for symbol: Dictionary in SymbolParser.parse(ProjectFiles.read_lines(path)):
			if symbol[&"kind"] == SymbolParser.KIND_FUNC and symbol[&"name"] == metadata[&"method"]:
				ProjectFiles.open_script_at(path, symbol[&"line"])
				return
	var selection: EditorSelection = EditorInterface.get_selection()
	selection.clear()
	selection.add_node(target)

func follow_symbol(symbol_name: String):
	followed_symbol = symbol_name
	_apply_followed_symbol(true)

# Uses a bg colour instead of selecting, because selecting an item jumps the editor to it.
func _apply_followed_symbol(scroll: bool):
	if not outline_tree:
		return
	if is_instance_valid(highlighted_item):
		highlighted_item.clear_custom_bg_color(0)
	highlighted_item = null

	if followed_symbol.is_empty() or not settings_manager or not settings_manager.is_outline_follow_cursor:
		return

	for category_item: TreeItem in category_items.values():
		for item: TreeItem in category_item.get_children():
			if item.get_text(0) != followed_symbol:
				continue
			# Collapsed category, so mark the category instead.
			highlighted_item = category_item if category_item.collapsed else item
			var color: Color = icon_manager.get_editor_accent_color()
			color.a = 0.25
			highlighted_item.set_custom_bg_color(0, color)
			if scroll:
				outline_tree.scroll_to_item(highlighted_item)
			return


func get_category_order(category_name: StringName) -> int:
	var index = settings_manager.outline_order.find(category_name)
	return index if index != -1 else 999

func get_category_collapsed_state(category_name: StringName) -> bool:
	return settings_manager.collapsed_categories.has(category_name)

# We only know a member's name, not its line, so search the source for its declaration.
# Plain text match on purpose; it's good enough and doesn't need the parser.
func find_and_goto_line(name: String, type: StringName, modifier: StringName, script: Script) -> void:
	if not script:
		return

	var with_text: String = type + " " + name
	if type == &"func":
		with_text += "("

	var lines: PackedStringArray = script.get_source_code().split("\n")
	var index: int = 0
	for line in lines:
		if line.begins_with(with_text):
			goto_line(index)
			return
		if modifier != &"" and line.begins_with(modifier):
			if line.begins_with(modifier + " " + with_text):
				goto_line(index)
				return
			elif modifier == &"enum" and line.contains("enum " + name):
				goto_line(index)
				return
		if type == &"var" and line.contains(with_text):
			goto_line(index)
			return
		index += 1

	push_error(with_text + " or " + modifier + " not found in source code")

func scroll_to_outline_item():
	var selected_item: TreeItem = outline_tree.get_selected()
	if not selected_item:
		return
	if not selected_item.get_metadata(0):
		return
	if selected_item.get_metadata(0).get(&"type") == CONNECTION_TYPE:
		_open_connection(selected_item.get_metadata(0))
		return

	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script:
		return

	var text: String = selected_item.get_text(0)
	var metadata: Dictionary = selected_item.get_metadata(0)
	var modifier: StringName = metadata[&"modifier"]
	var type: StringName = metadata[&"type"]

	find_and_goto_line(text, type, modifier, script)

func goto_line(index: int):
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	script_editor.goto_line(index)

	var code_edit: CodeEdit = script_editor.get_current_editor().get_base_editor()
	code_edit.set_caret_line(index)
	code_edit.set_v_scroll(index)
	code_edit.set_caret_column(code_edit.get_line(index).length())
	code_edit.set_h_scroll(0)
	code_edit.grab_focus()

func _on_outline_item_selected():
	var item: TreeItem = outline_tree.get_selected()
	if not item or not item.get_metadata(0):
		return
	scroll_to_outline_item()

func _on_outline_item_collapsed(item: TreeItem):
	for category_name in category_items.keys():
		if category_items[category_name] == item:
			settings_manager.set_category_collapsed(category_name, item.collapsed)
			break
	_apply_followed_symbol(false)

func _on_outline_tree_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var item: TreeItem = outline_tree.get_item_at_position(event.position)
		var metadata: Variant = item.get_metadata(0) if item else null
		# Members get the full menu. Categories, connection rows and empty space only get the
		# script-wide actions.
		if metadata and metadata.get(&"type") != CONNECTION_TYPE:
			item.select(0)
			_show_context_menu(item, event.position)
		else:
			_show_context_menu(null, event.position)
		outline_tree.accept_event()

func _show_context_menu(item: TreeItem, at_position: Vector2):
	context_menu.clear()
	context_menu.set_meta(&"target_item", item)

	if item:
		var metadata: Dictionary = item.get_metadata(0)
		var type: StringName = metadata[&"type"]
		var script: Script = EditorInterface.get_script_editor().get_current_script()
		var bookmarked: bool = script != null and settings_manager.is_bookmarked(script.resource_path, item.get_text(0))

		context_menu.add_icon_item(item.get_icon(0), "Remove Bookmark" if bookmarked else "Add Bookmark", MenuId.BOOKMARK)
		context_menu.add_item("Find Usages", MenuId.FIND_USAGES)
		context_menu.add_separator()
		if type == &"var":
			context_menu.add_item("Generate Getter/Setter", MenuId.GETTER_SETTER)
		if metadata[&"modifier"] == &"@export":
			context_menu.add_item("Add @export_group Above", MenuId.EXPORT_GROUP)
		context_menu.add_item("Add Doc Comment", MenuId.DOC_COMMENT)
		context_menu.add_separator()

	context_menu.add_item("Sort Script Members", MenuId.SORT_MEMBERS)
	context_menu.set_item_tooltip(context_menu.get_item_index(MenuId.SORT_MEMBERS),
		"Reorder the whole script to match the outline's category order. Undo with Ctrl+Z.")

	context_menu.reset_size()
	context_menu.position = Vector2i(outline_tree.get_screen_position()) + Vector2i(at_position)
	context_menu.popup()

func _on_context_menu_id_pressed(id: int):
	if id == MenuId.SORT_MEMBERS:
		sort_script_members()
		return

	# The meta is gone when it was set to null (Object.set_meta erases on null), hence the default.
	# Read it untyped first: if the outline was rebuilt while the menu was open the item is freed,
	# and assigning a freed object to a typed variable errors before we could check it.
	var target: Variant = context_menu.get_meta(&"target_item", null)
	if not is_instance_valid(target) or not target.get_metadata(0):
		return
	var item: TreeItem = target
	var metadata: Dictionary = item.get_metadata(0)
	var name: String = item.get_text(0)
	var type: StringName = metadata[&"type"]

	match id:
		MenuId.BOOKMARK:
			toggle_bookmark(name, type, metadata.get(&"modifier", &""))
			update_outline()
		MenuId.FIND_USAGES:
			var script: Script = EditorInterface.get_script_editor().get_current_script()
			find_usages_requested.emit(name, type, script.resource_path if script else "")
		MenuId.GETTER_SETTER:
			_generate_getter_setter(name)
		MenuId.EXPORT_GROUP:
			_add_export_group(name)
		MenuId.DOC_COMMENT:
			_add_doc_comment(name)

#region Code generation
# These edit the open CodeEdit (not the file), each as a single undo step.

func _get_code_edit() -> CodeEdit:
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if editor_base and editor_base.get_base_editor() is CodeEdit:
		return editor_base.get_base_editor()
	return null

# Finds a top-level member in the live editor text. Empty if it isn't there (e.g. inherited).
func _find_member(code_edit: CodeEdit, name: String) -> Dictionary:
	for symbol: Dictionary in SymbolParser.parse(code_edit.text.split("\n"), code_edit.indent_size):
		if symbol[&"parent"] == -1 and symbol[&"name"] == name:
			return symbol
	return {}

func _indent_unit(code_edit: CodeEdit) -> String:
	return " ".repeat(code_edit.indent_size) if code_edit.indent_use_spaces else "\t"

static func _leading_whitespace(line: String) -> String:
	return line.substr(0, line.length() - line.lstrip(" \t").length())

# First line of the block above a member that belongs to it: annotations and ## doc comments.
static func _block_start(code_edit: CodeEdit, line: int) -> int:
	while line > 0:
		var above: String = code_edit.get_line(line - 1).strip_edges()
		if not (above.begins_with("@") or above.begins_with("##")):
			break
		line -= 1
	return line

# Splits off a trailing # comment, ignoring # inside strings. Returns [code, comment].
static func _split_comment(line: String) -> PackedStringArray:
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var c: String = line[i]
		if not quote.is_empty():
			if c == "\\":
				i += 1
			elif c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "#":
			return [line.substr(0, i), line.substr(i)]
		i += 1
	return [line, ""]

func _generate_getter_setter(name: String):
	var code_edit: CodeEdit = _get_code_edit()
	if not code_edit:
		return
	var symbol: Dictionary = _find_member(code_edit, name)
	if symbol.is_empty() or symbol[&"kind"] != SymbolParser.KIND_VAR:
		return
	var line_index: int = symbol[&"line"]
	var parts: PackedStringArray = _split_comment(code_edit.get_line(line_index))
	var code: String = parts[0].rstrip(" \t")
	# Something indented under it already means accessors (or a multi-line value); don't touch.
	if symbol[&"end_line"] != line_index or code.ends_with(":"):
		ProjectFiles.toast("'%s' already has a getter/setter or spans several lines, so it was left alone." % name)
		return

	var base: String = _leading_whitespace(code)
	var unit: String = _indent_unit(code_edit)
	var declaration: String = code + ":" + (("  " + parts[1]) if not parts[1].is_empty() else "")
	var body: PackedStringArray = [
		"",
		base + unit + "get:",
		base + unit + unit + "return " + name,
		base + unit + "set(value):",
		base + unit + unit + name + " = value",
	]

	code_edit.begin_complex_operation()
	code_edit.set_line(line_index, declaration)
	code_edit.insert_text("\n".join(body), line_index, declaration.length())
	code_edit.end_complex_operation()

	code_edit.set_caret_line(line_index + 4)
	code_edit.set_caret_column(code_edit.get_line(line_index + 4).length())
	code_edit.grab_focus()

func _add_export_group(name: String):
	var code_edit: CodeEdit = _get_code_edit()
	if not code_edit:
		return
	var symbol: Dictionary = _find_member(code_edit, name)
	if symbol.is_empty():
		return
	var insert_at: int = _block_start(code_edit, symbol[&"line"])
	var group_line: String = _leading_whitespace(code_edit.get_line(symbol[&"line"])) + "@export_group(\"Group\")"

	code_edit.begin_complex_operation()
	code_edit.insert_line_at(insert_at, group_line)
	code_edit.end_complex_operation()

	# Leave "Group" selected so you can just type the name.
	var column: int = group_line.find("Group")
	code_edit.select(insert_at, column, insert_at, column + "Group".length())
	code_edit.grab_focus()

func _add_doc_comment(name: String):
	var code_edit: CodeEdit = _get_code_edit()
	if not code_edit:
		return
	var symbol: Dictionary = _find_member(code_edit, name)
	if symbol.is_empty():
		return
	var line_index: int = symbol[&"line"]
	var insert_at: int = _block_start(code_edit, line_index)
	# Already documented: just put the caret there.
	if code_edit.get_line(insert_at).strip_edges().begins_with("##"):
		code_edit.set_caret_line(insert_at)
		code_edit.set_caret_column(code_edit.get_line(insert_at).length())
		code_edit.grab_focus()
		return

	var base: String = _leading_whitespace(code_edit.get_line(line_index))
	var doc: PackedStringArray = [base + "## "]
	if symbol[&"kind"] == SymbolParser.KIND_FUNC or symbol[&"kind"] == SymbolParser.KIND_SIGNAL:
		for param: String in _parse_params(code_edit, line_index):
			doc.append(base + "## [param %s] " % param)

	code_edit.begin_complex_operation()
	code_edit.insert_text("\n".join(doc) + "\n", insert_at, 0)
	code_edit.end_complex_operation()

	code_edit.set_caret_line(insert_at)
	code_edit.set_caret_column(doc[0].length())
	code_edit.grab_focus()

# Parameter names of the func/signal declared on this line (the list may span several lines).
static func _parse_params(code_edit: CodeEdit, line_index: int) -> PackedStringArray:
	# No ( on the declaration line means no parameter list at all (e.g. "signal died"). Don't go
	# looking further down, or we'd pick up the next function's parameters.
	var text: String = _split_comment(code_edit.get_line(line_index))[0]
	var open: int = text.find("(")
	if open == -1:
		return PackedStringArray()
	# Only pull in following lines while the list is still open.
	var next_line: int = line_index + 1
	while text.count("(") > text.count(")") and next_line < mini(line_index + 30, code_edit.get_line_count()):
		text += " " + _split_comment(code_edit.get_line(next_line))[0]
		next_line += 1

	# Walk to the matching ), splitting on commas that aren't nested in a default value.
	var params: PackedStringArray = []
	var depth: int = 0
	var current: String = ""
	for i: int in range(open + 1, text.length()):
		var c: String = text[i]
		if c in "([{":
			depth += 1
		elif c in ")]}":
			if depth == 0:
				params.append(current)
				break
			depth -= 1
		elif c == "," and depth == 0:
			params.append(current)
			current = ""
			continue
		current += c

	var names: PackedStringArray = []
	for param: String in params:
		var param_name: String = param.strip_edges()
		for separator: String in [":", "=", " "]:
			param_name = param_name.get_slice(separator, 0)
		if not param_name.is_empty():
			names.append(param_name)
	return names
#endregion

## Reorders the current script's members into the outline's category order, as one undo step.
func sort_script_members():
	var code_edit: CodeEdit = _get_code_edit()
	if not code_edit or not EditorInterface.get_script_editor().get_current_script() is GDScript:
		return
	var result: Dictionary = MemberSorter.sort(code_edit.text.split("\n"), settings_manager.outline_order, keywords, code_edit.get_caret_line())
	if not result[&"ok"]:
		ProjectFiles.toast("Couldn't sort the members: " + result[&"error"])
		return
	if result[&"text"] == code_edit.text:
		return

	code_edit.begin_complex_operation()
	code_edit.select_all()
	code_edit.insert_text_at_caret(result[&"text"])
	code_edit.end_complex_operation()

	code_edit.deselect()
	code_edit.set_caret_line(result[&"caret_line"])
	code_edit.center_viewport_to_caret()
	code_edit.grab_focus()

func _on_bookmarks_tree_item_selected():
	var item: TreeItem = bookmarks_tree.get_selected()
	if not item or not item.get_metadata(0):
		return
	var metadata: Dictionary = item.get_metadata(0)
	_navigate_to_bookmark(metadata)

func _on_bookmarks_tree_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var item: TreeItem = bookmarks_tree.get_item_at_position(event.position)
		if item and item.get_metadata(0):
			item.select(0)
			_show_bookmarks_context_menu(item, event.position)

func _show_bookmarks_context_menu(item: TreeItem, at_position: Vector2):
	bookmarks_context_menu.clear()

	var metadata: Dictionary = item.get_metadata(0)
	var item_icon: Texture2D = item.get_icon(0)
	bookmarks_context_menu.set_meta(&"target_item", item)
	bookmarks_context_menu.add_icon_item(item_icon, "Remove Bookmark", 0)
	bookmarks_context_menu.add_item("Rename...", 1)
	bookmarks_context_menu.add_separator()
	bookmarks_context_menu.add_item("Move Up", 2)
	bookmarks_context_menu.add_item("Move Down", 3)

	var index: int = settings_manager.find_bookmark(metadata[&"script_path"], metadata[&"bookmark_name"])
	bookmarks_context_menu.set_item_disabled(bookmarks_context_menu.get_item_index(2), index <= 0)
	bookmarks_context_menu.set_item_disabled(bookmarks_context_menu.get_item_index(3), index == -1 or index >= settings_manager.bookmarks.size() - 1)

	bookmarks_context_menu.position = Vector2i(bookmarks_tree.get_screen_position()) + Vector2i(at_position)
	bookmarks_context_menu.popup()

func _on_bookmarks_context_menu_id_pressed(id: int):
	# Untyped first, in case the list was rebuilt (and the item freed) while the menu was open.
	var target: Variant = bookmarks_context_menu.get_meta(&"target_item", null)
	if not is_instance_valid(target):
		return
	var item: TreeItem = target

	var metadata: Dictionary = item.get_metadata(0)
	var script_path: String = metadata[&"script_path"]
	var bookmark_name: String = metadata[&"bookmark_name"]

	match id:
		0: settings_manager.remove_bookmark(script_path, bookmark_name)
		1:
			_show_bookmark_rename_dialog(metadata)
			return
		2: settings_manager.move_bookmark(script_path, bookmark_name, -1)
		3: settings_manager.move_bookmark(script_path, bookmark_name, 1)
	_update_bookmarks_ui()

func _show_bookmark_rename_dialog(metadata: Dictionary):
	bookmark_rename_target = metadata
	var index: int = settings_manager.find_bookmark(metadata[&"script_path"], metadata[&"bookmark_name"])
	bookmark_rename_txt.text = settings_manager.bookmarks[index].get(&"label", "") if index != -1 else ""
	bookmark_rename_txt.placeholder_text = metadata[&"bookmark_name"]
	bookmark_rename_dialog.popup_centered(Vector2i(Vector2(320, 0) * EditorInterface.get_editor_scale()))
	bookmark_rename_txt.select_all()
	bookmark_rename_txt.grab_focus.call_deferred()

func _on_bookmark_rename_confirmed():
	if bookmark_rename_target.is_empty():
		return
	settings_manager.set_bookmark_label(bookmark_rename_target[&"script_path"], bookmark_rename_target[&"bookmark_name"], bookmark_rename_txt.text)
	bookmark_rename_target = {}
	_update_bookmarks_ui()

## Adds or removes a bookmark on a member of the current script.
func toggle_bookmark(name: String, type: StringName, modifier: StringName):
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script or script.resource_path.is_empty() or name.is_empty():
		return
	if settings_manager.is_bookmarked(script.resource_path, name):
		settings_manager.remove_bookmark(script.resource_path, name)
	else:
		settings_manager.add_bookmark(script.resource_path, name, type, modifier)
	_update_bookmarks_ui()

## step is 1 for next, -1 for previous. Wraps around and goes across scripts.
func goto_next_bookmark(step: int):
	var count: int = settings_manager.bookmarks.size()
	if count == 0:
		return
	if bookmark_cursor == -1:
		bookmark_cursor = 0 if step > 0 else count - 1
	else:
		bookmark_cursor = posmod(bookmark_cursor + step, count)
	_navigate_to_bookmark(_get_bookmark_metadata(settings_manager.bookmarks[bookmark_cursor]))

func _get_bookmark_metadata(bookmark: Dictionary) -> Dictionary:
	return {
		&"is_bookmark": true,
		&"script_path": bookmark[&"script_path"],
		&"bookmark_name": bookmark[&"name"],
		&"type": bookmark.get(&"type", &"func"),
		&"modifier": bookmark.get(&"modifier", &"")
	}

func _navigate_to_bookmark(metadata: Dictionary) -> void:
	var script_path: String = metadata.get(&"script_path", &"")
	if script_path.is_empty():
		return
	var script: Script = load(script_path)
	if not script:
		return
	EditorInterface.edit_resource(script)
	# Give the script editor a frame to actually switch before we move the caret.
	call_deferred("_navigate_to_bookmark_deferred", metadata)

func _navigate_to_bookmark_deferred(metadata: Dictionary) -> void:
	var script_path: String = metadata.get(&"script_path", &"")
	if script_path.is_empty():
		return
	var script: Script = load(script_path)
	find_and_goto_line(
		metadata.get(&"bookmark_name", &""),
		metadata.get(&"type", &""),
		metadata.get(&"modifier", &""),
		script
	)

func _add_bookmarks_section():
	bookmarks_container = VBoxContainer.new()
	bookmarks_container.name = &"QuillBookmarks"
	bookmarks_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bookmarks_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bookmarks_container.custom_minimum_size.y = 24

	var header: HBoxContainer = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 24

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	var base_color: Color = editor_settings.get_setting("interface/theme/base_color")

	var header_normal: StyleBoxFlat = StyleBoxFlat.new()
	header_normal.bg_color = base_color.darkened(0.2)
	header_normal.corner_radius_top_left = 8
	header_normal.corner_radius_top_right = 8
	header_normal.corner_radius_bottom_right = 8
	header_normal.corner_radius_bottom_left = 8
	header_normal.expand_margin_top = -2
	header_normal.expand_margin_bottom = -2
	header_normal.expand_margin_left = -2
	header_normal.expand_margin_right = -2

	var header_hover: StyleBoxFlat = header_normal.duplicate()
	header_hover.bg_color = base_color.lightened(0.1)

	var header_focus: StyleBoxFlat = header_normal.duplicate()
	header_focus.bg_color = base_color.darkened(0.3)

	var bookmarks_label: Label = Label.new()
	bookmarks_label.text = BOOKMARKS + " (0)"
	bookmarks_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bookmarks_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bookmarks_label.add_theme_font_size_override("font_size", 12)
	header.add_child(bookmarks_label)

	var remove_all_btn: Button = Button.new()
	remove_all_btn.text = "Remove All"
	remove_all_btn.tooltip_text = "Remove all bookmarks"
	remove_all_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	bookmarks_remove_all_btn = remove_all_btn
	remove_all_btn.pressed.connect(_remove_all_bookmarks)
	remove_all_btn.custom_minimum_size.x = 80
	remove_all_btn.add_theme_stylebox_override("hover", header_hover)
	remove_all_btn.add_theme_stylebox_override("normal", header_normal)
	remove_all_btn.add_theme_stylebox_override("pressed", header_focus)
	header.add_child(remove_all_btn)

	bookmarks_container.add_child(header)

	var bookmarks_scroll: ScrollContainer = ScrollContainer.new()
	bookmarks_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bookmarks_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bookmarks_scroll.custom_minimum_size.y = 0
	bookmarks_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bookmarks_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bookmarks_container.add_child(bookmarks_scroll)

	bookmarks_tree = Tree.new()
	bookmarks_tree.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	bookmarks_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bookmarks_tree.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bookmarks_tree.custom_minimum_size.y = 0
	bookmarks_tree.hide_root = true
	bookmarks_tree.allow_reselect = true
	bookmarks_tree.scroll_horizontal_enabled = false
	bookmarks_tree.scroll_vertical_enabled = false
	bookmarks_root = bookmarks_tree.create_item()
	bookmarks_tree.item_selected.connect(_on_bookmarks_tree_item_selected)
	bookmarks_tree.gui_input.connect(_on_bookmarks_tree_gui_input)
	bookmarks_scroll.add_child(bookmarks_tree)

	bookmarks_context_menu = PopupMenu.new()
	bookmarks_tree.add_child(bookmarks_context_menu)
	bookmarks_context_menu.id_pressed.connect(_on_bookmarks_context_menu_id_pressed)
	bookmarks_context_menu.set_meta(&"target_item", null)

	bookmark_rename_dialog = AcceptDialog.new()
	bookmark_rename_dialog.title = "Rename Bookmark"
	bookmark_rename_txt = LineEdit.new()
	bookmark_rename_dialog.add_child(bookmark_rename_txt)
	bookmark_rename_dialog.register_text_enter(bookmark_rename_txt)
	bookmark_rename_dialog.confirmed.connect(_on_bookmark_rename_confirmed)
	bookmarks_tree.add_child(bookmark_rename_dialog)

	outline_parent.add_child(bookmarks_container)
	var scroll_idx: int = outline_parent.get_child_count() - 1
	outline_parent.move_child(bookmarks_container, scroll_idx)

	_update_bookmarks_ui()

func _add_todo_section():
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	var base_color: Color = editor_settings.get_setting("interface/theme/base_color")
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = base_color.darkened(0.2)
	normal.set_corner_radius_all(8)
	normal.set_expand_margin_all(-2)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = base_color.lightened(0.1)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = base_color.darkened(0.3)

	todo_container = TodoPanel.new()
	todo_container.init(settings_manager, normal, hover, pressed)
	outline_parent.add_child(todo_container)

func _update_bookmarks_ui():
	if not bookmarks_tree or not bookmarks_root:
		return

	bookmarks_tree.clear()
	bookmarks_root = bookmarks_tree.create_item()

	var bookmarks_data: Array = settings_manager.bookmarks
	var count: int = bookmarks_data.size()

	var header: HBoxContainer = bookmarks_container.get_child(0) if bookmarks_container.get_child_count() > 0 else null
	if header:
		var label: Label = header.get_child(0)
		if label:
			label.text = BOOKMARKS + " (" + str(count) + ")"

	if count == 0:
		bookmarks_tree.visible = false
		bookmarks_container.custom_minimum_size.y = 24
		bookmarks_remove_all_btn.visible = false
		return

	bookmarks_tree.visible = true
	bookmarks_remove_all_btn.visible = true
	bookmarks_container.custom_minimum_size.y = MAX_BOOKMARKS_HEIGHT

	for bookmark in bookmarks_data:
		var script_filename: String = bookmark[&"script_path"].get_file()
		var location_text: String = script_filename + " > " + bookmark[&"name"]
		var label: String = bookmark.get(&"label", "")

		var bm_item: TreeItem = bookmarks_tree.create_item(bookmarks_root)
		bm_item.set_text(0, label + "  (" + location_text + ")" if not label.is_empty() else location_text)
		bm_item.set_tooltip_text(0, bookmark[&"script_path"] + " > " + bookmark[&"name"])

		var item_type: StringName = bookmark.get(&"type", &"func")
		var item_name: String = bookmark[&"name"]
		var modifier: StringName = bookmark.get(&"modifier", &"")
		if item_type == &"func" and item_name.begins_with("get"):
			bm_item.set_icon(0, icon_manager.func_get_icon)
		elif item_type == &"func" and item_name.begins_with("set"):
			bm_item.set_icon(0, icon_manager.func_set_icon)
		elif item_type == &"func" and keywords.has(item_name):
			bm_item.set_icon(0, icon_manager.engine_func_icon)
		else:
			match item_type:
				&"signal": bm_item.set_icon(0, icon_manager.signal_icon)
				&"var":
					if modifier == &"@export":
						bm_item.set_icon(0, icon_manager.export_icon)
					else:
						bm_item.set_icon(0, icon_manager.property_icon)
				&"const": bm_item.set_icon(0, icon_manager.constant_icon)
				&"class": bm_item.set_icon(0, icon_manager.class_icon)
				_: bm_item.set_icon(0, icon_manager.func_icon)

		bm_item.set_metadata(0, _get_bookmark_metadata(bookmark))

func _remove_all_bookmarks():
	settings_manager.clear_all_bookmarks()
	_update_bookmarks_ui()

# Drops bookmarks for members that no longer exist in the current script (renamed or deleted).
# Names come from parsing the saved source text, not from the outline's member list: that list
# leaves out private members when they're hidden, and is empty while the script has a parse
# error, either of which would wrongly delete bookmarks.
func _cleanup_stale_bookmarks(script: Script) -> void:
	if not script or not script.has_source_code():
		return
	var script_path: String = script.resource_path
	if script_path.is_empty():
		return

	var existing: Dictionary = {}
	for symbol: Dictionary in SymbolParser.parse(script.source_code.split("\n")):
		if symbol[&"parent"] == -1:
			existing[symbol[&"name"]] = true
	# Nothing parsed at all (empty file, or the text isn't what we expect): don't delete anything.
	if existing.is_empty():
		return

	var changed: bool = false
	var i: int = 0
	while i < settings_manager.bookmarks.size():
		var bm: Dictionary = settings_manager.bookmarks[i]
		if bm["script_path"] == script_path and not existing.has(bm["name"]):
			settings_manager.bookmarks.remove_at(i)
			changed = true
		else:
			i += 1

	if changed:
		settings_manager._persist_bookmarks()
		_update_bookmarks_ui()

func _collapse_all():
	settings_manager.set_all_categories_collapsed(true)
	for category_item in category_items.values():
		category_item.collapsed = true

func _expand_all():
	settings_manager.set_all_categories_collapsed(false)
	for category_item in category_items.values():
		category_item.collapsed = false

func _on_outline_filter_input(event: InputEvent):
	navigate_on_tree(event, outline_tree)

func _on_outline_filter_changed(text: String):
	update_outline()

# Lets you drive the outline with the arrow keys while typing in the filter box.
func navigate_on_tree(event: InputEvent, tree: Tree):
	if event.is_action_pressed(&"ui_text_submit"):
		scroll_to_outline_item()
		tree.accept_event()
	elif event.is_action_pressed(&"ui_down", true):
		var selected: TreeItem = tree.get_selected()
		if selected:
			var next: TreeItem = selected.get_next_in_tree()
			if next:
				next.select(0)
				tree.ensure_cursor_is_visible()
		elif tree.get_root() and tree.get_root().get_first_child():
			tree.get_root().get_first_child().select(0)
		tree.accept_event()
	elif event.is_action_pressed(&"ui_up", true):
		var selected: TreeItem = tree.get_selected()
		if selected:
			var prev: TreeItem = selected.get_prev_in_tree()
			if prev:
				prev.select(0)
				tree.ensure_cursor_is_visible()
		tree.accept_event()
	elif event.is_action_pressed(&"ui_right", true):
		var selected: TreeItem = tree.get_selected()
		if selected and selected.get_children():
			selected.collapsed = false
		tree.accept_event()
	elif event.is_action_pressed(&"ui_left", true):
		var selected: TreeItem = tree.get_selected()
		if selected:
			if selected.get_children() and not selected.collapsed:
				selected.collapsed = true
			else:
				var parent: TreeItem = selected.get_parent()
				if parent and parent != tree.get_root():
					parent.select(0)
		tree.accept_event()
	elif event is InputEventKey and tree.get_root() and tree.get_root().get_first_child():
		if not tree.get_selected():
			tree.get_root().get_first_child().select(0)

var scroll_button_container: HBoxContainer
var todo_container: TodoPanel

func _update_outline_ui_visibility():
	if not settings_manager or not outline_tree:
		return
	var hidden: bool = settings_manager.is_outline_hidden

	outline_tree.visible = not hidden
	if collapse_button_container:
		collapse_button_container.visible = not hidden
	if bookmarks_container:
		bookmarks_container.visible = not hidden
	if todo_container:
		todo_container.visible = not hidden and settings_manager.show_todos
	if scroll_button_container:
		scroll_button_container.visible = not hidden
	if outline_filter_txt:
		outline_filter_txt.visible = not hidden
	if sort_btn:
		sort_btn.visible = not hidden

func _add_collapse_buttons():
	if collapse_button_container:
		collapse_button_container.free()

	collapse_button_container = HBoxContainer.new()
	collapse_button_container.name = &"QuillOutlineCollapse"
	collapse_button_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse_button_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	collapse_button_container.custom_minimum_size.y = 28

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	var base_color: Color = editor_settings.get_setting("interface/theme/base_color")

	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = base_color.darkened(0.2)
	normal.corner_radius_top_left = 8
	normal.corner_radius_top_right = 8
	normal.corner_radius_bottom_right = 8
	normal.corner_radius_bottom_left = 8
	normal.expand_margin_top = -2
	normal.expand_margin_bottom = -2
	normal.expand_margin_left = -2
	normal.expand_margin_right = -2

	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = base_color.lightened(0.1)

	var focus: StyleBoxFlat = normal.duplicate()
	focus.bg_color = base_color.darkened(0.3)

	var collapse_all_btn: Button = Button.new()
	collapse_all_btn.text = "Collapse"
	collapse_all_btn.tooltip_text = "Collapse all outline categories"
	collapse_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse_all_btn.pressed.connect(_collapse_all)
	collapse_all_btn.custom_minimum_size.x = 80
	collapse_all_btn.add_theme_stylebox_override("hover", hover)
	collapse_all_btn.add_theme_stylebox_override("normal", normal)
	collapse_all_btn.add_theme_stylebox_override("pressed", focus)
	collapse_button_container.add_child(collapse_all_btn)

	var expand_all_btn: Button = Button.new()
	expand_all_btn.text = "Expand"
	expand_all_btn.tooltip_text = "Expand all outline categories"
	expand_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	expand_all_btn.pressed.connect(_expand_all)
	expand_all_btn.custom_minimum_size.x = 80
	expand_all_btn.add_theme_stylebox_override("hover", hover)
	expand_all_btn.add_theme_stylebox_override("normal", normal)
	expand_all_btn.add_theme_stylebox_override("pressed", focus)
	collapse_button_container.add_child(expand_all_btn)

	outline_parent.add_child(collapse_button_container)
	outline_parent.move_child(collapse_button_container, 0)

func _add_scroll_buttons():
	if scroll_button_container:
		scroll_button_container.free()

	scroll_button_container = HBoxContainer.new()
	scroll_button_container.name = &"QuillOutlineScroll"
	scroll_button_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_button_container.size_flags_vertical = Control.SIZE_FILL
	scroll_button_container.custom_minimum_size.y = 60

	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	var base_color: Color = editor_settings.get_setting("interface/theme/base_color")

	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = base_color.darkened(0.2)
	normal.corner_radius_top_left = 12
	normal.corner_radius_top_right = 12
	normal.corner_radius_bottom_right = 12
	normal.corner_radius_bottom_left = 12
	normal.expand_margin_bottom = -3
	normal.expand_margin_top = -3
	normal.expand_margin_left = -3
	normal.expand_margin_right = -3

	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = base_color.lightened(0.1)

	var focus: StyleBoxFlat = normal.duplicate()
	focus.bg_color = base_color.darkened(0.3)

	var scroll_top_btn: Button = Button.new()
	scroll_top_btn.icon = icon_manager.scroll_top
	scroll_top_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	scroll_top_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_top_btn.pressed.connect(_scroll_to_top)
	scroll_top_btn.custom_minimum_size.x = 60
	scroll_top_btn.add_theme_stylebox_override("hover", hover)
	scroll_top_btn.add_theme_stylebox_override("normal", normal)
	scroll_top_btn.add_theme_stylebox_override("pressed", focus)
	scroll_top_btn.tooltip_text = "Scroll to Top"
	scroll_button_container.add_child(scroll_top_btn)

	var scroll_bottom_btn: Button = Button.new()
	scroll_bottom_btn.icon = icon_manager.scroll_bottom
	scroll_bottom_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	scroll_bottom_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_bottom_btn.pressed.connect(_scroll_to_bottom)
	scroll_bottom_btn.custom_minimum_size.x = 60
	scroll_bottom_btn.add_theme_stylebox_override("hover", hover)
	scroll_bottom_btn.add_theme_stylebox_override("normal", normal)
	scroll_bottom_btn.add_theme_stylebox_override("pressed", focus)
	scroll_bottom_btn.tooltip_text = "Scroll to Bottom"
	scroll_button_container.add_child(scroll_bottom_btn)

	outline_parent.add_child(scroll_button_container)
	outline_parent.move_child(scroll_button_container, outline_parent.get_child_count())

func _scroll_to_top():
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script:
		return

	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if not editor_base:
		return
	var code_edit: CodeEdit = editor_base.get_base_editor()
	if not code_edit:
		return
	code_edit.set_caret_line(0)
	code_edit.set_v_scroll(0)
	code_edit.set_caret_column(0)
	code_edit.set_h_scroll(0)
	code_edit.grab_focus()

func _scroll_to_bottom():
	var script: Script = EditorInterface.get_script_editor().get_current_script()
	if not script:
		return

	var lines: PackedStringArray = script.get_source_code().split("\n")
	var last_index: int = lines.size() - 1

	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if not editor_base:
		return
	var code_edit: CodeEdit = editor_base.get_base_editor()
	if not code_edit:
		return
	code_edit.set_caret_line(last_index)
	code_edit.set_v_scroll(last_index)
	code_edit.set_caret_column(lines[last_index].length())
	code_edit.set_h_scroll(0)
	code_edit.grab_focus()


# 4.8 replaced the members ItemList with a DocumentOutline (filter row + a Tree).
# Before that it was the second ItemList, right after the script list.
func _find_native_outline() -> Control:
	for tree: Node in outline_container.find_children("*", "Tree", true, false):
		if not String(tree.name).begins_with(STALE_NODE_PREFIX):
			return tree
	return find_or_null(outline_container.find_children("*", "ItemList", true, false), 1)

# Missing nodes are reported once by the plugin as a toast, so no error here.
func find_or_null(arr: Array[Node], index: int = 0) -> Node:
	if index >= arr.size():
		return null
	return arr[index]

class OutlineCache:
	var classes: Array[String] = []
	var constants: Array[String] = []
	var signals: Array[String] = []
	var exports: Array[String] = []
	var properties: Array[String] = []
	var funcs: Array[String] = []
	var engine_funcs: Array[String] = []
