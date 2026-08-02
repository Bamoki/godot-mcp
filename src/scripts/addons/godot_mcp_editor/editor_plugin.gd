@tool
extends EditorPlugin

const PORT: int = 9091

var _server: TCPServer = null
var _client: StreamPeerTCP = null
var _buffer: String = ""

func _enter_tree() -> void:
	_server = TCPServer.new()
	var err: int = _server.listen(PORT, "127.0.0.1")
	if err == OK:
		print("Godot MCP Editor Server listening on 127.0.0.1:%d" % PORT)
	else:
		push_error("Godot MCP Editor Server: failed to listen on port %d (err %d)" % [PORT, err])
	add_tool_menu_item("Godot MCP: Restart Editor", Callable(self, "_restart_from_menu"))

func _exit_tree() -> void:
	remove_tool_menu_item("Godot MCP: Restart Editor")
	if _client != null:
		_client.disconnect_from_host()
		_client = null
	if _server != null:
		_server.stop()
		_server = null

func _restart_from_menu() -> void:
	EditorInterface.restart_editor(true)

func _process(_delta: float) -> void:
	if _server == null:
		return
	if _client == null:
		_client = _server.take_connection()
		if _client != null:
			_buffer = ""
		return
	_client.poll()
	var status: int = _client.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_client = null
		_buffer = ""
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return
	while _client.get_available_bytes() > 0:
		var data: Array = _client.get_data(_client.get_available_bytes())
		if data[0] == OK:
			_buffer += (data[1] as PackedByteArray).get_string_from_utf8()
	var newline_idx: int = _buffer.find("\n")
	while newline_idx != -1:
		var line: String = _buffer.substr(0, newline_idx).strip_edges()
		_buffer = _buffer.substr(newline_idx + 1)
		if not line.is_empty():
			_handle_command(line)
		newline_idx = _buffer.find("\n")

func _handle_command(line: String) -> void:
	var data: Variant = JSON.parse_string(line)
	if data == null or not data is Dictionary:
		return
	var command: String = data.get("command", "")
	var params: Dictionary = data.get("params", {})
	match command:
		"restart_editor":
			_cmd_restart_editor(params)
		"save_all_scenes":
			EditorInterface.save_all_scenes()
			_send_response({"success": true, "action": "save_all_scenes"})
		"get_open_scenes":
			_send_response({"success": true, "action": "get_open_scenes", "scenes": EditorInterface.get_open_scenes()})
		"get_current_scene":
			var scene: Node = EditorInterface.get_edited_scene_root()
			_send_response({"success": true, "action": "get_current_scene", "scene": str(scene.get_path()) if scene != null else ""})
		"play_main_scene":
			EditorInterface.play_main_scene()
			_send_response({"success": true, "action": "play_main_scene"})
		"get_plugins":
			_send_response({"success": true, "action": "get_plugins", "plugins": _plugin_list()})
		"set_plugin_enabled":
			var plugin_name: String = params.get("name", "")
			var enabled: bool = params.get("enabled", true)
			if plugin_name.is_empty():
				_send_response({"error": "name is required"})
				return
			EditorInterface.set_plugin_enabled(plugin_name, enabled)
			_send_response({"success": true, "action": "set_plugin_enabled", "name": plugin_name, "enabled": enabled})
		"rescan":
			EditorInterface.get_resource_filesystem().scan()
			_send_response({"success": true, "action": "rescan"})
		"resume":
			_cmd_resume()
		"reload_scripts":
			_cmd_reload_scripts(params)
		"eval":
			_cmd_eval(params)
		"ping":
			_send_response({"success": true, "action": "ping", "godot": Engine.get_version_info()})
		_:
			_send_response({"error": "Unknown editor command: %s" % command})

func _cmd_restart_editor(params: Dictionary) -> void:
	var save: bool = params.get("save", true)
	_send_response({"success": true, "action": "restart_editor", "save": save})
	var timer: SceneTreeTimer = get_tree().create_timer(0.5)
	timer.timeout.connect(func() -> void:
		EditorInterface.restart_editor(save)
	)

# Best-effort: continue a debugger that is paused on a breakpoint or script
# error. The game itself is frozen while paused, so this must run in the editor
# process. Uses internal editor nodes via duck-typing; harmless if unavailable.
func _cmd_resume() -> void:
	var resumed: bool = false
	var detail: String = ""
	var dbg: Node = get_tree().root.find_child("EditorDebuggerNode", true, false)
	if dbg != null:
		detail = "EditorDebuggerNode found (%s)" % dbg.get_path()
		if dbg.has_method("get_paused_debugger"):
			var paused: Object = dbg.call("get_paused_debugger")
			if paused != null and paused.has_method("_debug_continue"):
				paused.call("_debug_continue")
				resumed = true
			else:
				detail += "; no paused debugger to continue"
		else:
			detail += "; get_paused_debugger unavailable"
	else:
		detail = "EditorDebuggerNode not found"
	_send_response({"success": resumed, "action": "resume", "resumed": resumed, "detail": detail})

# Best-effort hot reload from the editor: reloads script resources from disk and
# asks the editor's script debugger to push the updated scripts to a running game.
func _cmd_reload_scripts(params: Dictionary) -> void:
	var paths: Array = params.get("scripts", [])
	var reloaded: Array = []
	var errors: Array = []
	if paths is Array and paths.size() > 0:
		for p in paths:
			var script_path: String = str(p)
			if not script_path.ends_with(".gd"):
				continue
			if ResourceLoader.exists(script_path):
				var fresh: Resource = ResourceLoader.load(script_path, "Script", ResourceLoader.CACHE_MODE_REPLACE)
				reloaded.append({"script": script_path, "loaded": fresh != null})
			else:
				errors.append({"script": script_path, "error": "resource not found"})
	else:
		EditorInterface.get_resource_filesystem().scan()
	var dbg: Node = get_tree().root.find_child("EditorDebuggerNode", true, false)
	var pushed: bool = false
	if dbg != null and dbg.has_method("reload_scripts"):
		dbg.call("reload_scripts")
		pushed = true
	_send_response({
		"success": true,
		"action": "reload_scripts",
		"reloaded": reloaded,
		"errors": errors,
		"pushed_to_debugger": pushed,
	})

func _cmd_eval(params: Dictionary) -> void:
	var code: String = params.get("code", "")
	if code.is_empty():
		_send_response({"error": "code is required"})
		return
	var lines: PackedStringArray = code.split("\n")
	var indented: PackedStringArray = PackedStringArray()
	for line in lines:
		indented.append("\t" + line)
	var source: String = "extends RefCounted\n\nfunc _mcp_eval() -> Variant:\n" + "\n".join(indented) + "\n\treturn null\n"
	var script: GDScript = GDScript.new()
	script.source_code = source
	var err: int = script.reload()
	if err != OK:
		_send_response({"error": "Eval script failed to compile: %s" % error_string(err)})
		return
	var instance: RefCounted = script.new()
	if instance == null:
		_send_response({"error": "Eval script failed to instantiate"})
		return
	var result: Variant = instance.call("_mcp_eval")
	_send_response({"success": true, "action": "eval", "result": _variant_to_json(result)})

func _plugin_list() -> Array:
	var result: Array = []
	var enabled: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	for cfg in enabled:
		result.append({"path": cfg, "enabled": true})
	var addons_root: String = "res://addons"
	var dir: DirAccess = DirAccess.open(addons_root)
	if dir == null:
		return result
	for addon in dir.get_directories():
		var cfg_path: String = "%s/%s/plugin.cfg" % [addons_root, addon]
		if not ResourceLoader.exists(cfg_path):
			continue
		var cfg: ConfigFile = ConfigFile.new()
		cfg.load(cfg_path)
		var is_enabled: bool = enabled.has(cfg_path)
		result.append({
			"name": cfg.get_value("plugin", "name", addon),
			"path": cfg_path,
			"enabled": is_enabled,
		})
	return result

func _send_response(data: Dictionary) -> void:
	if _client == null:
		return
	_client.put_data((JSON.stringify(data) + "\n").to_utf8_buffer())

func _variant_to_json(value: Variant) -> Variant:
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	elif value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	elif value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	elif value is Node:
		return str(value.get_path())
	elif value is Object:
		return str(value)
	elif value is Array:
		var out: Array = []
		for item in value:
			out.append(_variant_to_json(item))
		return out
	elif value is Dictionary:
		var out: Dictionary = {}
		for key in value:
			out[key] = _variant_to_json(value[key])
		return out
	return value
