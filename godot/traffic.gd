class_name Traffic
extends Node3D
# Toy-town traffic: cars drive closed polylines from roads.json, stop at
# working traffic lights, keep a gap behind the car in front.
#
# Public API:
#   simulate(seconds, dt)  -- deterministic synchronous stepping (smoke tests)
#   car_count / light_count / travel_total / stop_events / state_changes

const ROUTES_PATH := "res://roads.json"

var car_count := 0
var light_count := 0
var travel_total := 0.0
var stop_events := 0
var state_changes := 0

var _space
var _car_spec := {}
var _routes := {}
var _cars := []
var _lights := []
var _lights_by_route := {}
var _cycle := {"green": 5.0, "yellow": 1.5}
var _raw_routes := {}
var _colors: Array = []
var _time := 0.0
var _running := false
var _built := false
var _was_fast := {}


func _ready() -> void:
	_space = get_world_3d().direct_space_state
	_load_data()
	_running = true


func _process(delta: float) -> void:
	if not _built:
		# Defer geometry to the first process frame so that all colliders
		# (added by the viewer during _ready) are registered in the physics
		# server before the terrain rays are cast.
		_build_routes()
		_spawn_lights()
		_spawn_cars()
		_built = true
	if _running:
		step(delta)


func _build_routes() -> void:
	for rid in _raw_routes:
		_spawn_route_meta(rid, _raw_routes[rid])


func simulate(seconds: float, step_dt: float = 0.1) -> void:
	var n := int(round(seconds / step_dt))
	for i in n:
		step(step_dt)


func step(dt: float) -> void:
	_time += dt
	_update_lights()
	_update_cars(dt)


func _load_data() -> void:
	var f := FileAccess.open(ROUTES_PATH, FileAccess.READ)
	if f == null:
		push_error("Traffic: cannot open " + ROUTES_PATH)
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Traffic: roads.json is not a dict")
		return
	_car_spec = data.get("car", {})
	_cycle = data.get("cycle", _cycle)
	_colors = data.get("colors", [])
	_raw_routes = data.get("routes", {})
	for light in data.get("lights", []):
		_lights.append(light)
		var key: String = str(light["route"])
		if not _lights_by_route.has(key):
			_lights_by_route[key] = []
		_lights_by_route[key].append(light)


func _spawn_route_meta(rid: String, meta: Dictionary) -> void:
	var pts: Array = []
	for p in meta["points"]:
		pts.append(Vector3(float(p[0]), 0.0, float(p[1])))
	# one Chaikin round to soften 90-degree corner cuts
	var smoothed := []
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		smoothed.append(a.lerp(b, 0.25))
		smoothed.append(a.lerp(b, 0.75))
	# terrain height per point
	for i in smoothed.size():
		smoothed[i].y = _ground_y(smoothed[i])
	# cumulative distances (closed loop)
	var cum := [0.0]
	var total := 0.0
	for i in smoothed.size():
		var a: Vector3 = smoothed[i]
		var b: Vector3 = smoothed[(i + 1) % smoothed.size()]
		total += a.distance_to(b)
		cum.append(total)
	_routes[rid] = {
		"pts": smoothed,
		"cum": cum,
		"length": total,
		"closed": meta.get("closed", true),
		"n_cars": int(meta.get("cars", 2)),
		"cruise": meta.get("cruise", [3.5, 4.0]),
	}


func _ground_y(pos: Vector3) -> float:
	if _space == null:
		return 24.0
	var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 30.0, pos + Vector3.DOWN * 55.0)
	var hit = _space.intersect_ray(ray)
	if hit.is_empty():
		return 24.0
	return float(hit["position"].y)


func _spawn_cars() -> void:
	var uid := 0
	for rid in _routes:
		var route: Dictionary = _routes[rid]
		var n: int = route["n_cars"]
		var cruise: Array = route["cruise"]
		for i in n:
			var s: float = float(i) * float(route["length"]) / float(n)
			var spec: Dictionary = _make_car(cruise[i % cruise.size()])
			var car := {
				"node": spec["node"],
				"route": rid,
				"s": s,
				"speed": 0.0,
				"cruise": spec["cruise"],
				"uid": uid,
				"wheels": spec["wheels"],
			}
			add_child(spec["node"])
			_cars.append(car)
			_was_fast[uid] = false
			uid += 1
			_place_car(car)
	car_count = _cars.size()


func _make_car(cruise: float) -> Dictionary:
	var root := Node3D.new()
	root.name = "ToyCar"
	var ci := _cars.size()
	var col := Color(0.8, 0.8, 0.85)
	if _colors.size() > 0:
		col = Color(_colors[ci % _colors.size()][0], _colors[ci % _colors.size()][1], _colors[ci % _colors.size()][2])
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = col
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(float(_car_spec.get("width", 1.0)), 0.5, float(_car_spec.get("length", 2.5)))
	body.mesh = bm
	body.material_override = body_mat
	body.position = Vector3(0, 0.5, 0)
	root.add_child(body)
	var cabin_mat := StandardMaterial3D.new()
	cabin_mat.albedo_color = Color(0.15, 0.2, 0.28)
	cabin_mat.roughness = 0.2
	var cabin := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(float(_car_spec.get("width", 1.0)) * 0.92, 0.42, float(_car_spec.get("length", 2.5)) * 0.5)
	cabin.mesh = cm
	cabin.material_override = cabin_mat
	cabin.position = Vector3(0, 0.92, 0.12)
	root.add_child(cabin)
	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.08, 0.08, 0.09)
	var wl := float(_car_spec.get("width", 1.0)) * 0.5
	var ll := float(_car_spec.get("length", 2.5)) * 0.5
	var wheels := []
	for wx in [-1, 1]:
		for wz in [-1, 1]:
			var wheel := MeshInstance3D.new()
			var wm := CylinderMesh.new()
			wm.top_radius = 0.26
			wm.bottom_radius = 0.26
			wm.height = 0.16
			wheel.mesh = wm
			wheel.material_override = wheel_mat
			wheel.rotation.z = PI / 2.0
			wheel.position = Vector3(wx * (wl + 0.02), 0.26, wz * (ll - 0.5))
			root.add_child(wheel)
			wheels.append(wheel)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(1, 0.98, 0.85)
	head_mat.emission = Color(1, 0.95, 0.7)
	head_mat.emission_energy_multiplier = 1.6
	var tail_mat := StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.5, 0.05, 0.05)
	tail_mat.emission = Color(1, 0.1, 0.08)
	tail_mat.emission_energy_multiplier = 1.4
	for hx in [-1, 1]:
		var head := MeshInstance3D.new()
		var hm := BoxMesh.new()
		hm.size = Vector3(0.18, 0.12, 0.06)
		head.mesh = hm
		head.material_override = head_mat
		head.position = Vector3(hx * 0.38, 0.52, -(ll + 0.01))
		root.add_child(head)
		var tail := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.2, 0.12, 0.06)
		tail.mesh = tm
		tail.material_override = tail_mat
		tail.position = Vector3(hx * 0.38, 0.52, ll + 0.01)
		root.add_child(tail)
	return {"node": root, "cruise": cruise, "wheels": wheels}


func _place_car(car: Dictionary, dt: float = 0.0) -> void:
	var route: Dictionary = _routes[car["route"]]
	var sample := _sample(route, car["s"])
	var node: Node3D = car["node"]
	node.position = sample["pos"]
	var dir: Vector3 = _heading(route, car["s"], float(car["speed"]))
	if dir.length_squared() <= 0.0001:
		return
	if not car.get("oriented", false):
		node.look_at(node.position + dir, Vector3.UP)
		car["oriented"] = true
	else:
		var target := Basis.looking_at(dir, Vector3.UP)
		# fast catch-up slerp: heading stays glued to the path, corners look soft
		node.basis = node.basis.slerp(target, 1.0 - exp(-14.0 * maxf(dt, 0.016)))
	# wheel spin
	var spin: float = float(car["speed"]) / 0.26 * maxf(dt, 0.0)
	if spin > 0.0:
		for wheel in car.get("wheels", []):
			wheel.rotate_object_local(Vector3.UP, spin)


func _heading(route: Dictionary, s: float, speed: float) -> Vector3:
	# Chord over a small arc ahead of the car: the heading changes gradually
	# through corners (geometric lead, no temporal lag -> no extra clipping).
	var a: Vector3 = _sample(route, s - 0.4)["pos"]
	var b: Vector3 = _sample(route, s + 0.55 + 0.12 * speed)["pos"]
	var dir := b - a
	if dir.length_squared() < 0.0001:
		return _sample(route, s)["dir"]
	return dir.normalized()


func _sample(route: Dictionary, s: float) -> Dictionary:
	var pts: Array = route["pts"]
	var cum: Array = route["cum"]
	var length: float = route["length"]
	s = fposmod(s, length)
	var lo := 0
	var hi := pts.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	var a: Vector3 = pts[lo]
	var b: Vector3 = pts[(lo + 1) % pts.size()]
	var seg_len: float = a.distance_to(b)
	var t: float = 0.0 if seg_len < 0.0001 else (s - float(cum[lo])) / seg_len
	var pos := a.lerp(b, t)
	var dir := (b - a)
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	dir = dir.normalized()
	return {"pos": pos, "dir": dir}


func _spawn_lights() -> void:
	for light in _lights:
		var route: Dictionary = _routes[light["route"]]
		var jx: float = float(light["junction"][0])
		var jz: float = float(light["junction"][1])
		var j_idx := 0
		for i in route["pts"].size():
			var p: Vector3 = route["pts"][i]
			if absf(p.x - jx) < 0.6 and absf(p.z - jz) < 0.6:
				j_idx = i
				break
		light["stop_s"] = fposmod(route["cum"][j_idx] - 0.9, route["length"])
		light["state"] = 2
		light["root"] = _make_light(light)
		add_child(light["root"])
	light_count = _lights.size()


func _make_light(light: Dictionary) -> Node3D:
	var px := float(light["pole"][0])
	var pz := float(light["pole"][1])
	var root := Node3D.new()
	root.name = "TrafficLight_" + str(light.get("id", ""))
	var gy := _ground_y(Vector3(px, 0, pz))
	root.position = Vector3(px, gy, pz)
	# face the approaching car (approach direction from the route at the stop line)
	var route: Dictionary = _routes[light["route"]]
	var sample := _sample(route, light["stop_s"])
	var toward: Vector3 = -Vector3(sample["dir"])
	root.rotation.y = atan2(toward.x, toward.z)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.25, 0.27, 0.3)
	pole_mat.roughness = 0.6
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.09
	pm.bottom_radius = 0.12
	pm.height = 4.3
	pole.mesh = pm
	pole.material_override = pole_mat
	pole.position = Vector3(0, 2.15, 0)
	root.add_child(pole)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.1, 0.11, 0.13)
	head_mat.roughness = 0.4
	var head := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.44, 1.25, 0.4)
	head.mesh = hm
	head.material_override = head_mat
	head.position = Vector3(0, 3.7, 0)
	root.add_child(head)
	light["lamps"] = {}
	for kind in ["red", "yellow", "green"]:
		var c := Color.WHITE
		if kind == "red":
			c = Color(1, 0.12, 0.08)
		elif kind == "yellow":
			c = Color(1, 0.75, 0.1)
		else:
			c = Color(0.2, 1, 0.35)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = c.darkened(0.75)
		mat.emission = c
		mat.emission_energy_multiplier = 0.06
		var lamp := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.3, 0.3, 0.08)
		lamp.mesh = lm
		lamp.material_override = mat
		var y := 4.15 if kind == "red" else (3.7 if kind == "yellow" else 3.25)
		lamp.position = Vector3(0, y, 0.22)
		root.add_child(lamp)
		light["lamps"][kind] = lamp
	return root


func _update_lights() -> void:
	var green: float = _cycle["green"]
	var yellow: float = _cycle["yellow"]
	var total := green + 2.0 * yellow + green
	for light in _lights:
		var t: float = fposmod(_time + float(light.get("phase", 0.0)), total)
		var st := 0
		if t >= green and t < green + yellow:
			st = 1
		elif t >= green + yellow:
			st = 2
		if st != light["state"]:
			light["state"] = st
			state_changes += 1
		var red: MeshInstance3D = light["lamps"]["red"]
		var yellow_l: MeshInstance3D = light["lamps"]["yellow"]
		var green_l: MeshInstance3D = light["lamps"]["green"]
		_set_lamp(red, st == 2)
		_set_lamp(yellow_l, st == 1)
		_set_lamp(green_l, st == 0)


func _set_lamp(lamp: MeshInstance3D, on: bool) -> void:
	var mat: StandardMaterial3D = lamp.material_override
	mat.emission_energy_multiplier = 3.2 if on else 0.06
	mat.albedo_color = mat.emission if on else mat.emission.darkened(0.75)


func _update_cars(dt: float) -> void:
	var accel: float = float(_car_spec.get("accel", 3.0))
	var decel: float = float(_car_spec.get("decel", 4.5))
	var gap: float = float(_car_spec.get("follow_gap", 6.0))
	var range_m: float = float(_car_spec.get("follow_range", 14.0))
	for car in _cars:
		var route: Dictionary = _routes[car["route"]]
		var target: float = car["cruise"]
		# traffic lights on this route
		for light in _lights_by_route.get(car["route"], []):
			var d: float = fposmod(float(light["stop_s"]) - float(car["s"]), float(route["length"]))
			if d < 4.2:
				if light["state"] == 2:
					if d > 0.45:
						target = minf(target, 0.0)
				elif light["state"] == 1:
					var need: float = car["speed"] * car["speed"] / (2.0 * decel) + 0.6
					if d > need:
						target = minf(target, 0.0)
		# car following: kinematic (can brake to a stop before the car ahead)
		for other in _cars:
			if other["uid"] == car["uid"] or other["route"] != car["route"]:
				continue
			var d: float = fposmod(float(other["s"]) - float(car["s"]), float(route["length"]))
			if d > 0.01 and d < range_m:
				var allowed: float = sqrt(2.0 * decel * maxf(d - 1.6, 0.0))
				if d < gap:
					# platoon: match the leader, small allowance so a standing
						# queue can start moving without a deadlock
					allowed = minf(allowed, float(other["speed"]) + 0.4)
				target = minf(target, allowed)
		if car["speed"] < target:
			car["speed"] = minf(target, car["speed"] + accel * dt)
		else:
			car["speed"] = maxf(target, car["speed"] - decel * dt)
		car["s"] = fposmod(car["s"] + car["speed"] * dt, route["length"])
		travel_total += car["speed"] * dt
		_place_car(car, dt)
		# stop event bookkeeping
		var was: bool = _was_fast[car["uid"]]
		var now_fast: bool = car["speed"] > 0.5
		if was and not now_fast:
			stop_events += 1
		_was_fast[car["uid"]] = now_fast
