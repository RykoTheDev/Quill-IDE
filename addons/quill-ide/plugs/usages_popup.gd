@tool
extends AcceptDialog

## "Find Usages" results: every whole-word match in project scripts, plus scene connections
## from .tscn files, which Godot's own Find in Files doesn't treat as references.

const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

const NAME: StringName = &"QuillUsagesPopup"

var icon_manager: IconManager
var results_tree: Tree
var summary_label: Label
var attribute_regex: RegEx = RegEx.create_from_string("(\\w+)=\"([^\"]*)\"")

func _init():
	name = NAME
	title = "Find Usages"
	ok_button_text = "Close"
	# Not modal: you can click a result, look at the code, and come back for the next one.
	exclusive = false
	transient = true

	var vbox: VBoxContainer = VBoxContainer.new()
	add_child(vbox)

	summary_label = Label.new()
	vbox.add_child(summary_label)

	results_tree = Tree.new()
	results_tree.hide_root = true
	results_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_tree.custom_minimum_size = Vector2(0, 300)
	results_tree.allow_reselect = true
	results_tree.item_selected.connect(_on_item_activated)
	vbox.add_child(results_tree)

## kind is the outline type (&"func", &"signal", &"var", ...), or empty if unknown.
## declaring_path decides whether addons get searched: only if the symbol itself lives in one.
func show_usages(symbol_name: String, kind: StringName, declaring_path: String):
	results_tree.clear()
	var root: TreeItem = results_tree.create_item()
	var include_addons: bool = declaring_path.begins_with(ProjectFiles.ADDONS)
	var word_regex: RegEx = RegEx.create_from_string("\\b" + symbol_name + "\\b")
	var total: int = 0

	for path: String in ProjectFiles.find_files(["gd"], include_addons):
		var file_item: TreeItem = null
		var lines: PackedStringArray = ProjectFiles.read_lines(path)
		for i: int in lines.size():
			var line: String = lines[i]
			var stripped: String = line.strip_edges()
			if stripped.begins_with("#"):
				continue
			var result: RegExMatch = word_regex.search(line)
			if not result:
				continue
			if not file_item:
				file_item = _add_file_item(root, path)
			var is_declaration: bool = path == declaring_path and _is_declaration(stripped, symbol_name)
			var item: TreeItem = results_tree.create_item(file_item)
			item.set_text(0, "%d:  %s%s" % [i + 1, stripped, "   (declaration)" if is_declaration else ""])
			item.set_metadata(0, { &"path": path, &"line": i, &"column": result.get_start() })
			total += 1
		_finish_file_item(file_item)

	# Connections made in the editor live in the scene file, not in any script.
	# An empty kind means we don't know what the word is, so check both sides of a connection.
	var keys: PackedStringArray = []
	if kind == &"signal" or kind.is_empty():
		keys.append("signal")
	if kind == &"func" or kind.is_empty():
		keys.append("method")
	if not keys.is_empty():
		for path: String in ProjectFiles.find_files(["tscn"], include_addons):
			var file_item: TreeItem = null
			var lines: PackedStringArray = ProjectFiles.read_lines(path)
			for i: int in lines.size():
				var line: String = lines[i]
				if not line.begins_with("[connection "):
					continue
				var attributes: Dictionary = {}
				for attribute: RegExMatch in attribute_regex.search_all(line):
					attributes[attribute.get_string(1)] = attribute.get_string(2)
				var matched_key: String = ""
				for key: String in keys:
					if attributes.get(key, "") == symbol_name:
						matched_key = key
				if matched_key.is_empty():
					continue
				if not file_item:
					file_item = _add_file_item(root, path)
				var item: TreeItem = results_tree.create_item(file_item)
				item.set_text(0, "%s.%s  →  %s.%s()" % [attributes.get("from", "?"), attributes.get("signal", "?"), attributes.get("to", "?"), attributes.get("method", "?")])
				# Select the node on the side we searched from: the emitter for signals, the receiver for methods.
				var node_path: String = attributes.get("from", ".") if matched_key == "signal" else attributes.get("to", ".")
				item.set_metadata(0, { &"scene": path, &"node": node_path })
				total += 1
			_finish_file_item(file_item)

	title = "Usages of '%s'" % symbol_name
	summary_label.text = "%d result%s" % [total, "" if total == 1 else "s"] if total > 0 else "No usages found."
	popup_centered(Vector2i(Vector2(720, 420) * EditorInterface.get_editor_scale()))

func _add_file_item(root: TreeItem, path: String) -> TreeItem:
	var item: TreeItem = results_tree.create_item(root)
	item.set_text(0, path.trim_prefix("res://"))
	item.set_selectable(0, false)
	var icon_name: StringName = &"PackedScene" if path.get_extension() == "tscn" else &"GDScript"
	item.set_icon(0, EditorInterface.get_editor_theme().get_icon(icon_name, &"EditorIcons"))
	return item

func _finish_file_item(file_item: TreeItem):
	if file_item:
		file_item.set_text(0, "%s  (%d)" % [file_item.get_text(0), file_item.get_child_count()])

func _is_declaration(stripped: String, symbol_name: String) -> bool:
	# \b after the name, so looking for "foo" doesn't flag "func foobar" as the declaration.
	var regex: RegEx = RegEx.create_from_string("\\b(func|signal|var|const|enum|class)\\s+" + symbol_name + "\\b")
	return regex.search(stripped) != null

func _on_item_activated():
	var item: TreeItem = results_tree.get_selected()
	if not item or item.get_metadata(0) == null:
		return
	var metadata: Dictionary = item.get_metadata(0)
	if metadata.has(&"scene"):
		_open_scene_node(metadata[&"scene"], metadata[&"node"])
	else:
		ProjectFiles.open_script_at(metadata[&"path"], metadata[&"line"], metadata[&"column"])

func _open_scene_node(scene_path: String, node_path: String):
	EditorInterface.open_scene_from_path(scene_path)
	var root: Node = EditorInterface.get_edited_scene_root()
	if not root:
		return
	EditorInterface.set_main_screen_editor(&"3D" if root is Node3D else &"2D")
	var node: Node = root.get_node_or_null(NodePath(node_path))
	if node:
		var selection: EditorSelection = EditorInterface.get_selection()
		selection.clear()
		selection.add_node(node)
