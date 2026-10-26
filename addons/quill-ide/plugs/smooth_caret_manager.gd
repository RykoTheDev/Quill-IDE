@tool
extends RefCounted

## Puts a smooth caret overlay on each script editor as it's opened, and keeps them in step with
## the Quill/SmoothCaret settings.

const SmoothCaret = preload("res://addons/quill-ide/plugs/smooth_caret.gd")

const SETTINGS_ROOT: StringName = &"Quill/SmoothCaret/"
# Master switch. Off means Godot's own caret, whatever the other settings say.
const ENABLED: StringName = SETTINGS_ROOT + &"enabled"
const MODE: StringName = SETTINGS_ROOT + &"mode"
const MOTION: StringName = SETTINGS_ROOT + &"motion"
const DURATION_MS: StringName = SETTINGS_ROOT + &"duration_ms"
const SPEED: StringName = SETTINGS_ROOT + &"speed"
const TYPING_DURATION_MS: StringName = SETTINGS_ROOT + &"typing_duration_ms"
const BLINK_STYLE: StringName = SETTINGS_ROOT + &"blink_style"
const SMOOTH_SCROLL: StringName = SETTINGS_ROOT + &"smooth_scroll"

var enabled: bool = true
var config: Dictionary = {
	&"mode": SmoothCaret.Mode.ALWAYS,
	&"motion": SmoothCaret.Motion.GLIDE,
	&"duration": 0.09,
	&"speed": 20.0,
	# Moves caused by typing/deleting. 0 keeps the caret stuck to the text.
	&"typing_duration": 0.0,
	&"blink_style": SmoothCaret.BlinkStyle.FADE,
	&"smooth_scroll": true,
}
var overlays: Array[SmoothCaret] = []

func init():
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	_register(editor_settings, ENABLED, enabled, TYPE_BOOL, PROPERTY_HINT_NONE, "")
	_register(editor_settings, MODE, config[&"mode"], TYPE_INT, PROPERTY_HINT_ENUM, "Off, Always, Only when moving (not while typing)")
	_register(editor_settings, MOTION, config[&"motion"], TYPE_INT, PROPERTY_HINT_ENUM, "Ease out, Glide (fixed time), Trail")
	_register(editor_settings, DURATION_MS, roundi(config[&"duration"] * 1000.0), TYPE_INT, PROPERTY_HINT_RANGE, "30,400,10,suffix:ms")
	_register(editor_settings, SPEED, config[&"speed"], TYPE_FLOAT, PROPERTY_HINT_RANGE, "5,60,1")
	_register(editor_settings, TYPING_DURATION_MS, roundi(config[&"typing_duration"] * 1000.0), TYPE_INT, PROPERTY_HINT_RANGE, "0,150,5,suffix:ms")
	_register(editor_settings, BLINK_STYLE, config[&"blink_style"], TYPE_INT, PROPERTY_HINT_ENUM, "Solid, Fade")
	_register(editor_settings, SMOOTH_SCROLL, config[&"smooth_scroll"], TYPE_BOOL, PROPERTY_HINT_NONE, "")
	_read_settings()

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.connect(_on_active_script_changed)
	_on_active_script_changed(null)

# Safe to call more than once.
func cleanup():
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if script_editor.editor_script_changed.is_connected(_on_active_script_changed):
		script_editor.editor_script_changed.disconnect(_on_active_script_changed)
	_detach_all()

func handle_settings_change(changed_settings: PackedStringArray):
	var ours: bool = false
	for setting: String in changed_settings:
		if setting.begins_with(SETTINGS_ROOT):
			ours = true
			break
	if not ours:
		return
	_read_settings()

	if not _is_active():
		_detach_all()
		return
	_forget_closed()
	for overlay: SmoothCaret in overlays:
		overlay.configure(config)
	_on_active_script_changed(null)

func _is_active() -> bool:
	return enabled and config[&"mode"] != SmoothCaret.Mode.OFF

func _read_settings():
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	enabled = editor_settings.get_setting(ENABLED)
	config[&"mode"] = editor_settings.get_setting(MODE)
	config[&"motion"] = editor_settings.get_setting(MOTION)
	config[&"duration"] = editor_settings.get_setting(DURATION_MS) / 1000.0
	config[&"speed"] = editor_settings.get_setting(SPEED)
	config[&"typing_duration"] = editor_settings.get_setting(TYPING_DURATION_MS) / 1000.0
	config[&"blink_style"] = editor_settings.get_setting(BLINK_STYLE)
	config[&"smooth_scroll"] = editor_settings.get_setting(SMOOTH_SCROLL)

func _on_active_script_changed(_script: Script):
	if not _is_active():
		return
	var editor_base: ScriptEditorBase = EditorInterface.get_script_editor().get_current_editor()
	if not editor_base or not editor_base.get_base_editor() is CodeEdit:
		return
	var code_edit: CodeEdit = editor_base.get_base_editor()

	var existing: Node = code_edit.get_node_or_null(NodePath(SmoothCaret.NAME))
	if existing and overlays.has(existing):
		return
	if existing:
		# Left behind by an instance that never cleaned up. Its caret colour is unreliable, so the
		# new overlay falls back to the editor setting for it.
		code_edit.remove_child(existing)
		existing.queue_free()

	_forget_closed()
	var overlay: SmoothCaret = SmoothCaret.new()
	overlay.attach(code_edit, config)
	overlays.append(overlay)

# Loop variables here are untyped on purpose: an overlay freed along with its editor would error
# the moment it's assigned to a typed variable, before is_instance_valid could check it.
func _detach_all():
	for overlay: Variant in overlays:
		if is_instance_valid(overlay):
			overlay.detach()
	overlays.clear()

# Overlays die with their editor when a script is closed.
func _forget_closed():
	overlays.assign(overlays.filter(func(overlay: Variant) -> bool: return is_instance_valid(overlay)))

func _register(editor_settings: EditorSettings, setting: StringName, default_value: Variant, type: int, hint: int, hint_string: String):
	if not editor_settings.has_setting(setting):
		editor_settings.set_setting(setting, default_value)
	editor_settings.set_initial_value(setting, default_value, false)
	editor_settings.add_property_info({ "name": setting, "type": type, "hint": hint, "hint_string": hint_string })
