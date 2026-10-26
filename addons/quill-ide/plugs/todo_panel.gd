@tool
extends VBoxContainer

## TODO / FIXME / HACK / BUG / NOTE comments across the project's scripts, click to jump.
## Lives under the bookmarks in the outline column.

const ProjectFiles = preload("res://addons/quill-ide/plugs/project_files.gd")

const MAX_HEIGHT: int = 150
const TAG_COLORS: Dictionary[String, Color] = {
	"TODO": Color(0.95, 0.8, 0.35),
	"FIXME": Color(1.0, 0.45, 0.4),
	"BUG": Color(1.0, 0.45, 0.4),
	"HACK": Color(1.0, 0.65, 0.3),
	"XXX": Color(1.0, 0.65, 0.3),
	"NOTE": Color(0.5, 0.75, 1.0),
}

var settings_manager: QuillSettingsManager
var header_label: Label
var toggle_btn: Button
var items_tree: Tree
var tag_regex: RegEx = RegEx.create_from_string("#\\s*(TODO|FIXME|BUG|HACK|XXX|NOTE)\\b:?\\s*(.*)$")
var expanded: bool = true

func init(settings_mgr: QuillSettingsManager, header_style_normal: StyleBox, header_style_hover: StyleBox, header_style_pressed: StyleBox):
	settings_manager = settings_mgr
	name = &"QuillTodos"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var header: HBoxContainer = HBoxContainer.new()
	header.custom_minimum_size.y = 24
	add_child(header)

	header_label = Label.new()
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_label.add_theme_font_size_override("font_size", 12)
	header.add_child(header_label)

	toggle_btn = Button.new()
	toggle_btn.text = "Hide"
	toggle_btn.custom_minimum_size.x = 60
	toggle_btn.add_theme_stylebox_override("normal", header_style_normal)
	toggle_btn.add_theme_stylebox_override("hover", header_style_hover)
	toggle_btn.add_theme_stylebox_override("pressed", header_style_pressed)
	toggle_btn.pressed.connect(_on_toggle_pressed)
	header.add_child(toggle_btn)

	var refresh_btn: Button = Button.new()
	refresh_btn.icon = EditorInterface.get_editor_theme().get_icon(&"Reload", &"EditorIcons")
	refresh_btn.flat = true
	refresh_btn.tooltip_text = "Rescan the project"
	refresh_btn.pressed.connect(refresh)
	header.add_child(refresh_btn)

	items_tree = Tree.new()
	items_tree.hide_root = true
	items_tree.allow_reselect = true
	items_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	items_tree.custom_minimum_size.y = 0
	items_tree.item_selected.connect(_on_item_selected)
	add_child(items_tree)

	refresh()

func refresh():
	if not items_tree:
		return
	items_tree.clear()
	var root: TreeItem = items_tree.create_item()
	var count: int = 0

	for path: String in ProjectFiles.find_files(["gd"], settings_manager.scan_addons):
		var lines: PackedStringArray = ProjectFiles.read_lines(path)
		for i: int in lines.size():
			# Cheap check first; the regex only runs on lines that have a comment at all.
			if not lines[i].contains("#"):
				continue
			var result: RegExMatch = tag_regex.search(lines[i])
			if not result:
				continue
			var tag: String = result.get_string(1)
			var text: String = result.get_string(2).strip_edges()
			var item: TreeItem = items_tree.create_item(root)
			item.set_text(0, "%s  %s" % [tag, text if not text.is_empty() else "(no text)"])
			item.set_custom_color(0, TAG_COLORS.get(tag, Color.WHITE))
			item.set_suffix(0, "  %s:%d" % [path.get_file(), i + 1])
			item.set_tooltip_text(0, "%s:%d" % [path, i + 1])
			item.set_metadata(0, { &"path": path, &"line": i, &"column": result.get_start() })
			count += 1

	header_label.text = "TODOs (%d)" % count
	_update_size(count)

func _update_size(count: int):
	items_tree.visible = expanded and count > 0
	toggle_btn.visible = count > 0
	toggle_btn.text = "Hide" if expanded else "Show"
	custom_minimum_size.y = MAX_HEIGHT if items_tree.visible else 24

func _on_toggle_pressed():
	expanded = not expanded
	_update_size(items_tree.get_root().get_child_count() if items_tree.get_root() else 0)

func _on_item_selected():
	var item: TreeItem = items_tree.get_selected()
	if not item or item.get_metadata(0) == null:
		return
	var metadata: Dictionary = item.get_metadata(0)
	ProjectFiles.open_script_at(metadata[&"path"], metadata[&"line"], metadata[&"column"])
