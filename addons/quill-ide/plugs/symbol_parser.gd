@tool
extends RefCounted

## Text-only GDScript symbol scanner. It never loads or compiles anything, so it's safe to run
## over every script in the project (loading a script would run its static initialisers).

const KIND_FUNC: StringName = &"func"
const KIND_CLASS: StringName = &"class"
const KIND_CLASS_NAME: StringName = &"class_name"
const KIND_VAR: StringName = &"var"
const KIND_CONST: StringName = &"const"
const KIND_SIGNAL: StringName = &"signal"
const KIND_ENUM: StringName = &"enum"

static var _symbol_regex: RegEx

## Returns symbols in line order: { name, kind, line, end_line, indent, exported, parent }.
## parent is an index into the returned array, or -1 for top-level symbols.
##
## Scopes come from indentation: a symbol runs until the next code line at its indent or less.
## Comments, blank lines, multiline strings and lines starting with ) ] } don't count, so a
## dict closing on column 0 doesn't end its const early.
static func parse(lines: PackedStringArray, indent_size: int = 4) -> Array[Dictionary]:
	var symbols: Array[Dictionary] = []
	var stack: Array[int] = []
	var last_code_line: int = -1
	var in_multiline_string: bool = false
	var pending_annotations: String = ""

	for i: int in lines.size():
		var line: String = lines[i]
		var stripped: String = line.strip_edges()
		var state: Array = scan_line(line, in_multiline_string)

		if in_multiline_string:
			in_multiline_string = state[0]
			if not in_multiline_string:
				last_code_line = i
			continue
		if stripped.is_empty() or stripped.begins_with("#"):
			continue

		var indent: int = indent_width(line, indent_size)
		if not stripped[0] in ")]}":
			while not stack.is_empty() and indent <= symbols[stack.back()][&"indent"]:
				symbols[stack.pop_back()][&"end_line"] = last_code_line

		var result: RegExMatch = match_declaration(stripped)
		# Unnamed declarations (enum {A, B}, a bare func(): lambda) are code, but not symbols.
		if result and result.get_string(3).is_empty():
			pending_annotations = ""
		elif result:
			var annotations: String = pending_annotations + " " + result.get_string(1)
			symbols.append({
				&"name": result.get_string(3),
				&"kind": StringName(result.get_string(2)),
				&"line": i,
				&"end_line": i,
				&"indent": indent,
				&"exported": annotations.contains("@export"),
				&"parent": stack.back() if not stack.is_empty() else -1,
			})
			stack.push_back(symbols.size() - 1)
			pending_annotations = ""
		elif stripped.begins_with("@"):
			# Annotation on its own line, e.g. @export above a var. Hang on to it for the next symbol.
			pending_annotations += " " + stripped
		else:
			pending_annotations = ""

		last_code_line = i
		in_multiline_string = state[0]

	for index: int in stack:
		symbols[index][&"end_line"] = last_code_line
	return symbols

## Matches a declaration on an already-stripped line. Groups: 1 = inline annotations,
## 2 = keyword (func, var, ...), 3 = name, which is empty for e.g. an unnamed enum {...}.
## Returns null if the line isn't a declaration. The \b after the keyword keeps words like
## "enumerate" or "signal_bus" from counting.
static func match_declaration(stripped: String) -> RegExMatch:
	if _symbol_regex == null:
		_symbol_regex = RegEx.create_from_string(
			"^((?:@[\\w.]+(?:\\(.*?\\))?\\s+)*)(?:static\\s+)?(class_name|func|class|var|const|signal|enum)\\b(?:\\s+([A-Za-z_]\\w*))?")
	return _symbol_regex.search(stripped)

## Walks one line and returns [still inside a multiline string, bracket depth change].
## Quotes and brackets inside strings and comments don't count.
static func scan_line(line: String, in_multiline_string: bool) -> Array:
	var depth: int = 0
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var triple: String = line.substr(i, 3)
		if in_multiline_string:
			if triple == "\"\"\"" or triple == "'''":
				in_multiline_string = false
				i += 3
				continue
			i += 1
			continue
		var c: String = line[i]
		if not quote.is_empty():
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if triple == "\"\"\"" or triple == "'''":
			in_multiline_string = true
			i += 3
			continue
		if c == "\"" or c == "'":
			quote = c
		elif c == "#":
			break
		elif c in "([{":
			depth += 1
		elif c in ")]}":
			depth -= 1
		i += 1
	return [in_multiline_string, depth]

static func indent_width(line: String, indent_size: int) -> int:
	var width: int = 0
	for c: String in line:
		if c == "\t":
			width += indent_size
		elif c == " ":
			width += 1
		else:
			break
	return width
