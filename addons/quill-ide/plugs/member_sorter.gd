@tool
extends RefCounted

## Reorders a script's top-level members into the outline's category order.
##
## Works on text. Each top-level declaration becomes a "unit" together with the comments and
## annotations right above it and everything that belongs under it (indented lines, lines inside
## open brackets or multiline strings). Units are then sorted by category, keeping their original
## order inside a category, except engine callbacks, which follow the usual lifecycle order.
## Anything it doesn't understand at the top level makes it refuse rather than guess.

const SymbolParser = preload("res://addons/quill-ide/plugs/symbol_parser.gd")

const ENGINE_FUNCS: String = "Engine Callbacks"
const FUNCS: String = "Functions"
const SIGNALS: String = "Signals"
const EXPORTED: String = "Exported Properties"
const PROPERTIES: String = "Properties"
const CLASSES: String = "Classes"
const CONSTANTS: String = "Constants"

const CALLBACK_ORDER: PackedStringArray = [
	"_static_init", "_init", "_enter_tree", "_ready", "_exit_tree",
	"_process", "_physics_process", "_notification", "_draw",
	"_input", "_shortcut_input", "_unhandled_input", "_unhandled_key_input", "_gui_input",
]

## Returns { ok: bool, text: String, caret_line: int, error: String }.
## engine_callbacks: names of the base class's virtual methods (the outline's keywords).
static func sort(lines: PackedStringArray, category_order: PackedStringArray, engine_callbacks: Dictionary, caret_line: int) -> Dictionary:
	var header: PackedStringArray = []
	var units: Array[Dictionary] = []
	var pending: PackedStringArray = []
	var current: Dictionary = {}
	var in_multiline_string: bool = false
	var depth: int = 0
	var seen_declaration: bool = false

	for i: int in lines.size():
		var line: String = lines[i]
		var stripped: String = line.strip_edges()
		var indented: bool = not stripped.is_empty() and (line.begins_with(" ") or line.begins_with("\t"))
		var continuation: bool = in_multiline_string or depth > 0 or indented or (not stripped.is_empty() and stripped[0] in ")]}")

		if continuation:
			if current.is_empty():
				return _error("Line %d is indented but isn't inside any member." % (i + 1))
			# Blank lines and column-0 comments in the middle of a body stay with it.
			# (Write the array back: a packed array read out of a Dictionary can be a copy.)
			var unit_lines: PackedStringArray = current[&"lines"]
			unit_lines.append_array(pending)
			unit_lines.append(line)
			current[&"lines"] = unit_lines
			pending.clear()
		elif stripped.is_empty() or stripped.begins_with("#"):
			if stripped.begins_with("#region") or stripped.begins_with("#endregion"):
				return _error("The script uses #region at the top level. Sorting would scramble the regions, so it's left alone.")
			pending.append(line)
		elif stripped == "@tool" or stripped == "@static_unload" or stripped.begins_with("@icon(") or stripped.begins_with("extends "):
			if seen_declaration:
				return _error("Line %d (%s) comes after the members; move it to the top first." % [i + 1, stripped])
			header.append_array(pending)
			header.append(line)
			pending.clear()
		else:
			var declaration: RegExMatch = SymbolParser.match_declaration(stripped)
			# Only an enum may be unnamed; anything else nameless isn't a member we can move.
			if declaration and declaration.get_string(3).is_empty() and declaration.get_string(2) != "enum":
				declaration = null
			if declaration == null:
				if stripped.begins_with("@"):
					# Annotation on its own line; it travels with the next member.
					pending.append(line)
				else:
					return _error("Don't know how to move line %d: %s" % [i + 1, stripped])
			elif declaration.get_string(2) == "class_name":
				header.append_array(pending)
				header.append(line)
				pending.clear()
			else:
				var lead: PackedStringArray = pending.duplicate()
				pending.clear()
				if not seen_declaration:
					# Comments split off from the first member by a blank line are the class docs.
					var last_blank: int = _last_blank(lead)
					if last_blank != -1:
						header.append_array(lead.slice(0, last_blank + 1))
						lead = lead.slice(last_blank + 1)
				lead = _strip_leading_blanks(lead)
				seen_declaration = true

				var annotations: String = declaration.get_string(1)
				for lead_line: String in lead:
					if lead_line.strip_edges().begins_with("@"):
						annotations += " " + lead_line
				var unit_lines: PackedStringArray = lead.duplicate()
				unit_lines.append(line)
				current = {
					&"lines": unit_lines,
					&"category": _categorize(declaration.get_string(2), declaration.get_string(3), annotations, engine_callbacks),
					&"name": declaration.get_string(3),
					&"keyword": declaration.get_string(2),
					&"declaration": stripped,
					&"index": units.size(),
					&"start": i - lead.size(),
				}
				units.append(current)

		var state: Array = SymbolParser.scan_line(line, in_multiline_string)
		in_multiline_string = state[0]
		depth = maxi(0, depth + state[1])

	if units.is_empty():
		return _error("No members found to sort.")
	var footer: PackedStringArray = _strip_leading_blanks(_strip_trailing_blanks(pending))

	var sorted: Array[Dictionary] = units.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var rank_a: int = _category_rank(a[&"category"], category_order)
		var rank_b: int = _category_rank(b[&"category"], category_order)
		if rank_a != rank_b:
			return rank_a < rank_b
		if a[&"category"] == ENGINE_FUNCS:
			var callback_a: int = _callback_rank(a[&"name"])
			var callback_b: int = _callback_rank(b[&"name"])
			if callback_a != callback_b:
				return callback_a < callback_b
		return a[&"index"] < b[&"index"])

	var broken: String = _find_broken_dependency(units, sorted)
	if not broken.is_empty():
		return _error(broken)

	# Spacing follows the GDScript style guide: two blank lines around functions and classes,
	# one between categories, none between one-line members of the same kind.
	var out: PackedStringArray = _strip_trailing_blanks(header)
	var previous_category: String = "" if out.is_empty() else "header"
	var previous_spaced: bool = false
	var previous_multiline: bool = false
	var new_starts: Dictionary = {}
	for unit: Dictionary in sorted:
		var spaced: bool = unit[&"category"] in [ENGINE_FUNCS, FUNCS, CLASSES]
		var multiline: bool = unit[&"lines"].size() > 1
		var blanks: int = 0
		if previous_category.is_empty():
			blanks = 0
		elif unit[&"category"] != previous_category:
			blanks = 2 if spaced or previous_spaced else 1
		elif spaced:
			blanks = 2
		elif multiline or previous_multiline:
			blanks = 1
		for b: int in blanks:
			out.append("")
		new_starts[unit[&"index"]] = out.size()
		out.append_array(unit[&"lines"])
		previous_category = unit[&"category"]
		previous_spaced = spaced
		previous_multiline = multiline

	if not footer.is_empty():
		out.append("")
		out.append_array(footer)
	# Keep the file's trailing newline.
	if lines.size() > 0 and lines[lines.size() - 1].is_empty():
		out.append("")

	# Keep the caret inside the member it was in.
	var new_caret: int = mini(caret_line, out.size() - 1)
	for unit: Dictionary in units:
		var start: int = unit[&"start"]
		if caret_line >= start and caret_line < start + unit[&"lines"].size():
			new_caret = new_starts[unit[&"index"]] + caret_line - start
			break

	return { &"ok": true, &"text": "\n".join(out), &"caret_line": new_caret, &"error": "" }

static func _categorize(keyword: String, name: String, annotations: String, engine_callbacks: Dictionary) -> String:
	match keyword:
		"signal": return SIGNALS
		"const", "enum": return CONSTANTS
		"class": return CLASSES
		"var": return EXPORTED if annotations.contains("@export") else PROPERTIES
		"func": return ENGINE_FUNCS if engine_callbacks.has(name) else FUNCS
	return FUNCS

# Member vars are initialised top to bottom, so "var b = a * 2" only works while a is above b.
# Returns a message if the new order would put a var above one its initialiser uses.
# (It errs on the safe side: a mention anywhere in the unit, setter bodies included, counts.)
static func _find_broken_dependency(units: Array[Dictionary], sorted: Array[Dictionary]) -> String:
	var new_position: Dictionary = {}
	for i: int in sorted.size():
		new_position[sorted[i][&"index"]] = i

	for user: Dictionary in units:
		if user[&"keyword"] != "var" or not user[&"declaration"].contains("="):
			continue
		var text: String = "\n".join(user[&"lines"])
		for used: Dictionary in units:
			if used[&"keyword"] != "var" or used[&"index"] >= user[&"index"]:
				continue
			if new_position[used[&"index"]] < new_position[user[&"index"]]:
				continue
			if RegEx.create_from_string("\\b" + used[&"name"] + "\\b").search(text):
				return "'%s' uses '%s' when it's initialised, and sorting would move it above '%s', which would change what it gets set to. Move one of them by hand first." % [user[&"name"], used[&"name"], used[&"name"]]
	return ""

static func _category_rank(category: String, category_order: PackedStringArray) -> int:
	var index: int = category_order.find(category)
	return index if index != -1 else 999

static func _callback_rank(func_name: String) -> int:
	var index: int = CALLBACK_ORDER.find(func_name)
	return index if index != -1 else CALLBACK_ORDER.size()

static func _last_blank(lines: PackedStringArray) -> int:
	for i: int in range(lines.size() - 1, -1, -1):
		if lines[i].strip_edges().is_empty():
			return i
	return -1

static func _strip_leading_blanks(lines: PackedStringArray) -> PackedStringArray:
	var start: int = 0
	while start < lines.size() and lines[start].strip_edges().is_empty():
		start += 1
	return lines.slice(start)

static func _strip_trailing_blanks(lines: PackedStringArray) -> PackedStringArray:
	var end: int = lines.size()
	while end > 0 and lines[end - 1].strip_edges().is_empty():
		end -= 1
	return lines.slice(0, end)

static func _error(message: String) -> Dictionary:
	return { &"ok": false, &"text": "", &"caret_line": 0, &"error": message }
