extends Node3D
# Living town v4: pedestrians with independent plans.
#  - each walker: own destination on the plaza loop, lateral offset, yield to
#    the walker ahead (no queues / no following), loiter with a personal stand
#    offset so two people never stand at the exact same spot
#  - shoppers ENTER the kiosk through a real doorway (gap in the front wall),
#    browse the goods shelf inside, then leave the same way
#  - the child plays on the playground: walks to each piece of equipment,
#    circles it with a run-gait (the "play" clip the character set has),
#    then moves to the next activity
# Routes/shops are data-driven from island_life.json; every point is
# probe-verified against the real island collisions (heightmap scan).

const LIFESTYLE_PATH := "res://island_life.json"
# Columns that definitely have floor — "physics is ready" gate.
const PROBE_XZ := [Vector2(-32.0, 3.0), Vector2(-7.0, -10.0), Vector2(5.0, -18.0)]

var walker_count := 0
var shop_count := 0
var visit_count := 0
var travel_total := 0.0
var play_events := 0

# Free-fly camera: pedestrians yield when the observer stands in their path.
var observer: Node3D

var _routes: Array[Dictionary] = []
var _walkers: Array[Dictionary] = []
var _shops: Array[Dictionary] = []
var _models: Array[PackedScene] = []
var _spec: Dictionary = {}
var _route_lead_done := {}
var _built := false
var _frame := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20261010


func _process(_delta: float) -> void:
	_frame += 1
	if not _built:
		if _frame >= 2 and _ground_ready():
			_build()
		elif _frame >= 600:
			push_error("IslandLife: ground never became queryable; pedestrians disabled")
			set_physics_process(false)


func _ground_ready() -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	for p in PROBE_XZ:
		var ray := PhysicsRayQueryParameters3D.create(Vector3(p.x, 45.0, p.y), Vector3(p.x, -25.0, p.y))
		if space.intersect_ray(ray).is_empty():
			return false
	return true


func _physics_process(delta: float) -> void:
	if _built:
		_step(delta)


# Deterministic synchronous stepping (smoke tests / interleaved simulation).
func tick(delta: float) -> void:
	if _built:
		_step(delta)


func simulate(seconds: float, step_dt: float = 0.1) -> void:
	if not _built:
		_build()
	var n := int(round(seconds / step_dt))
	for i in n:
		_step(step_dt)


func _build() -> void:
	if _built:
		return
	_built = true
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIFESTYLE_PATH))
	if parsed is Dictionary:
		_spec = parsed
	if _spec.is_empty():
		push_error("IslandLife: cannot load ", LIFESTYLE_PATH)
		return
	for path in _spec.get("models", []):
		var packed := load(path) as PackedScene
		if packed:
			_models.append(packed)
		else:
			push_warning("IslandLife: model failed to load: ", path)
	for definition in _spec.get("routes", []):
		var rect: Array = definition["rect"]
		var step: float = float(definition.get("step", 0.5))
		var raw := _rect_loop(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]), step)
		var points := _smooth(raw)
		var route := _finalize_route(points)
		route["name"] = str(definition.get("name", "route"))
		route["walkers"] = int(definition.get("walkers", 3))
		route["role"] = str(definition.get("role", ""))
		route["roles"] = definition.get("roles", [])
		route["model"] = int(definition.get("model", -1))
		route["models"] = definition.get("models", [])
		route["scale"] = float(definition.get("scale", 1.0))
		route["speed_min"] = float(definition.get("speed_min", _spec.get("walk_speed_min", 0.7)))
		route["speed_max"] = float(definition.get("speed_max", _spec.get("walk_speed_max", 1.15)))
		route["play_spots"] = definition.get("play_spots", [])
		# child: precompute the route point nearest to each piece of equipment
		route["play_ats"] = []
		route["play_s"] = []
		for spot in route["play_spots"]:
			var best_s := 0.0
			var best_d := 1e9
			for i in int(route["length"] / 0.4):
				var s: float = float(i) * 0.4
				var at: Dictionary = _sample(route, s)
				var d: float = Vector2(float(spot[0]) - at["position"].x, float(spot[1]) - at["position"].z).length()
				if d < best_d:
					best_d = d
					best_s = s
			route["play_s"].append(best_s)
			route["play_ats"].append(_sample(route, best_s)["position"])
		_routes.append(route)
	for definition in _spec.get("shops", []):
		_add_shop(definition)
	shop_count = _shops.size()
	var id := 0
	for route_index in _routes.size():
		var route: Dictionary = _routes[route_index]
		var count: int = int(route["walkers"])
		for i in count:
			_spawn_walker(route_index, id, count, i)
			id += 1
	walker_count = _walkers.size()
	print("ISLAND_LIFE_READY | walkers=%d shops=%d routes=%d" % [walker_count, shop_count, _routes.size()])


func _add_shop(definition: Dictionary) -> void:
	var pos := Vector3(float(definition["pos"][0]), float(definition["pos"][1]), float(definition["pos"][2]))
	var face := Vector3(float(definition["face"][0]), 0.0, float(definition["face"][1])).normalized()
	var route_index: int = int(definition.get("route", 0))
	var route: Dictionary = _routes[route_index]
	# route point nearest to the doorway = the pedestrian's pickup/drop-off
	var best_s := 0.0
	var best_d := 1e9
	for i in int(route["length"] / 0.25):
		var s: float = float(i) * 0.25
		var at: Dictionary = _sample(route, s)
		var d: float = Vector2(at["position"].x - pos.x, at["position"].z - pos.z).length()
		if d < best_d:
			best_d = d
			best_s = s
	var p0: Dictionary = _sample(route, best_s)
	var shop := _make_shop(pos, face, definition)
	shop["node"].position = pos
	add_child(shop["node"])
	var door_world: Vector3 = shop["node"].to_global(Vector3(0.4, 0.0, 1.0))
	var interior_world: Vector3 = shop["node"].to_global(Vector3(0.0, 0.0, -0.35))
	var approach_world := Vector3(door_world.x + face.x * 1.15, door_world.y, door_world.z + face.z * 1.15)
	shop["door_world"] = door_world
	shop["interior_world"] = interior_world
	shop["approach_world"] = approach_world
	shop["p0_world"] = p0["position"]
	shop["s"] = best_s
	# s of the point on the loop nearest to the approach spot: this is where a
	# shopper heading to the store should stop and step off the loop
	var app_s := best_s
	var app_d := 1e9
	for i in int(route["length"] / 0.25):
		var s: float = float(i) * 0.25
		var at: Dictionary = _sample(route, s)
		var d: float = Vector2(at["position"].x - approach_world.x, at["position"].z - approach_world.z).length()
		if d < app_d:
			app_d = d
			app_s = s
	shop["approach_s"] = app_s
	shop["route"] = route_index
	_shops.append(shop)
	if best_d > 2.5:
		push_warning("IslandLife: shop %s door is %.1f m from its route" % [str(definition.get("pos")), best_d])


# One walker with its own plan: role, model, speed, lateral offset, stand
# offset, shop assignment (shopper -> nearest kiosk), play rotation (child).
func _spawn_walker(route_index: int, id: int, _group_size: int, walker_index: int) -> void:
	var route: Dictionary = _routes[route_index]
	var role := str(route.get("role", ""))
	var roles: Array = route.get("roles", [])
	if walker_index < roles.size():
		role = str(roles[walker_index])
	var model_id := int(route.get("model", -1))
	var models: Array = route.get("models", [])
	if walker_index < models.size():
		model_id = int(models[walker_index])
	if model_id < 0 or model_id >= _models.size():
		model_id = id % _models.size() if _models.size() > 0 else 0
	var speed := lerpf(float(route.get("speed_min", 0.75)), float(route.get("speed_max", 1.05)), _rng.randf())
	var start: float = fposmod(float(id) * float(route["length"]) / 12.0, float(route["length"]))
	# the child starts right before the first piece of playground equipment so
	# the play cycle begins within the first seconds
	if str(route.get("role", "")) == "child" and (route["play_s"] as Array).size() > 0:
		start = fposmod(float((route["play_s"] as Array)[0]) - 1.5, float(route["length"]))
	var at0: Dictionary = _sample(route, start)
	var root := Node3D.new()
	root.name = "Islander_%02d" % id
	add_child(root)
	var visual: Node3D = _models[model_id].instantiate()
	var s: float = float(route.get("scale", 1.0))
	visual.scale = Vector3(s, s, s)
	root.add_child(visual)
	var players := visual.find_children("*", "AnimationPlayer", true, false)
	var animation: AnimationPlayer = players[0] as AnimationPlayer if players.size() > 0 else null
	root.position = at0["position"]
	root.rotation.y = atan2(at0["direction"].x, at0["direction"].z)
	if animation:
		var clip := animation.get_animation("Walk")
		if clip:
			clip.loop_mode = Animation.LOOP_LINEAR
		animation.play("Walk")
		animation.seek(_rng.randf(), true)
	# shop assignment: each shopper is bound to the nearest kiosk on his loop
	var shop_index := -1
	if role == "shopper":
		for si in _shops.size():
			var sh: Dictionary = _shops[si]
			if int(sh["route"]) == route_index:
				shop_index = si
				break
	# the first shopper of a route is the "lead shopper": he starts right
	# before the kiosk and is already in the mood to buy, so the first store
	# visit of the simulation happens within the first seconds
	var is_lead := false
	if role == "shopper" and shop_index >= 0 and not _route_lead_done.has(route_index):
		_route_lead_done[route_index] = true
		is_lead = true
	if is_lead:
		start = fposmod(float(_shops[shop_index]["approach_s"]) - 2.0, float(route["length"]))
	var cool0: float = 0.0 if is_lead else _rng.randf() * 10.0
	var dest0: float = float(_shops[shop_index]["approach_s"]) if is_lead else fposmod(start + float(route["length"]) * 0.5, float(route["length"]))
	var walker := {
		"node": root, "animation": animation, "route": route_index,
		"s": start, "dest": dest0,
		"speed": speed, "role": role, "shop": shop_index,
		"offset": (float(id % 3) - 1.0) * 0.3,
		"stand_off": 0.2 + float(id % 4) * 0.35,
		"state": "walk",
		"state_left": 0.0, "state_yaw": 0.0,
		"cool": cool0,
		"browse_off": (float(id % 2) * 2.0 - 1.0) * 0.28,
		"detour": [], "detour_i": 0,
		"play_index": id % ((route["play_s"] as Array).size()) if (route["play_s"] as Array).size() > 0 else 0,
		"play_angle": _rng.randf() * TAU,
		"travelled": 0.0,
	}
	_walkers.append(walker)


func _step(delta: float) -> void:
	for walker in _walkers:
		var route: Dictionary = _routes[int(walker["route"])]
		var node: Node3D = walker["node"]
		var animation: AnimationPlayer = walker["animation"]
		var speed: float = float(walker["speed"])
		match str(walker["state"]):
			"loiter":
				_do_loiter(walker, route, node, animation, delta)
			"play":
				_do_play(walker, route, node, animation, delta)
			"shop_go":
				_do_detour(walker, node, animation, delta)
			"shop_in":
				_do_shop_in(walker, node, animation, delta)
			_:
				_do_walk(walker, route, node, animation, delta)


# ---- states -------------------------------------------------------------

func _do_walk(walker: Dictionary, route: Dictionary, node: Node3D, animation: AnimationPlayer, delta: float) -> void:
	var length: float = route["length"]
	var role: String = str(walker["role"])
	# the child's destination is always the next piece of playground equipment
	var play_s: Array = route["play_s"]
	if role == "child" and play_s.size() > 0:
		walker["dest"] = float(play_s[int(walker["play_index"])])
	else:
		# independent destination: a fresh point 25..85% of the loop ahead;
		# shoppers deliberately aim for their kiosk about 60% of the time
		var ahead: float = fposmod(float(walker["dest"]) - float(walker["s"]), length)
		if ahead < 0.2 or ahead > 0.9 * length:
			var shop_index: int = int(walker["shop"])
			if role == "shopper" and shop_index >= 0 and _rng.randf() < 0.6:
				walker["dest"] = float(_shops[shop_index]["approach_s"])
			else:
				walker["dest"] = fposmod(float(walker["s"]) + length * _rng.randf_range(0.25, 0.8), length)
	# yield: a walker close ahead (same loop) gets right of way — prevents
	# queues and body overlap; the leader keeps moving, so the gap opens.
	var move_speed: float = float(walker["speed"])
	for other in _walkers:
		if other == walker or int(other["route"]) != int(walker["route"]):
			continue
		var d: float = fposmod(float(other["s"]) - float(walker["s"]), length)
		if d > 0.25 and d < 1.6:
			move_speed = 0.0
			break
	if is_instance_valid(observer):
		var to_obs: Vector3 = observer.global_position - node.global_position
		if Vector3(to_obs.x, 0.0, to_obs.z).length() < 1.0:
			move_speed = 0.0
	walker["s"] = fposmod(float(walker["s"]) + move_speed * delta, length)
	var at: Dictionary = _sample(route, float(walker["s"]))
	var perp := Vector3(-at["direction"].z, 0.0, at["direction"].x)
	node.position = at["position"] + perp * float(walker["offset"])
	var target_yaw: float = atan2(at["direction"].x, at["direction"].z)
	node.rotation.y = lerp_angle(node.rotation.y, target_yaw, 1.0 - exp(-10.0 * delta))
	if animation:
		animation.speed_scale = move_speed / 0.9
	var moved: float = move_speed * delta
	walker["travelled"] = float(walker["travelled"]) + moved
	travel_total += moved
	walker["cool"] = float(walker["cool"]) - delta
	# arrived?
	if fposmod(float(walker["s"]) - float(walker["dest"]), length) < 0.25 or fposmod(float(walker["dest"]) - float(walker["s"]), length) < 0.25:
		var shop_index: int = int(walker["shop"])
		if role == "child" and play_s.size() > 0:
			walker["state"] = "play"
			walker["state_left"] = _rng.randf_range(2.5, 5.0)
			walker["play_angle"] = _rng.randf() * TAU
			walker["s"] = float(walker["dest"])
			play_events += 1
			return
		elif role == "shopper" and shop_index >= 0 and float(walker["cool"]) <= 0.0:
			var sh: Dictionary = _shops[shop_index]
			if node.global_position.distance_to(sh["approach_world"]) < 2.4:
				# a personal spot in the doorway gap and at the goods shelf so
				# two customers never occupy the same point
				var boff: Vector3 = sh["node"].basis.x * float(walker["browse_off"])
				walker["state"] = "shop_go"
				walker["browse_pos"] = sh["interior_world"] + boff
				walker["detour"] = [
					node.global_position,
					sh["approach_world"] + boff,
					sh["door_world"] + boff,
					walker["browse_pos"],
				]
				walker["detour_i"] = 1
				return
		# default: personal pause — look around, then a new destination
		walker["state"] = "loiter"
		walker["state_left"] = _rng.randf_range(1.5, 4.0)
		walker["state_yaw"] = node.rotation.y + _rng.randf_range(-2.4, 2.4)


func _do_loiter(walker: Dictionary, route: Dictionary, node: Node3D, animation: AnimationPlayer, delta: float) -> void:
	# stands with a personal stand-off (no two walkers share the exact spot),
	# slowly turns the head/body to look around
	var at: Dictionary = _sample(route, float(walker["s"]))
	var perp := Vector3(-at["direction"].z, 0.0, at["direction"].x)
	node.position = at["position"] + perp * float(walker["offset"]) + at["direction"] * float(walker["stand_off"])
	node.rotation.y = lerp_angle(node.rotation.y, float(walker["state_yaw"]), 1.0 - exp(-2.0 * delta))
	if animation:
		animation.speed_scale = 0.0
	walker["state_left"] = float(walker["state_left"]) - delta
	if float(walker["state_left"]) <= 0.0:
		walker["state"] = "walk"
		walker["dest"] = fposmod(float(walker["s"]) + float(route["length"]) * _rng.randf_range(0.25, 0.8), float(route["length"]))


func _do_play(walker: Dictionary, route: Dictionary, node: Node3D, animation: AnimationPlayer, delta: float) -> void:
	# the child alternates two play phases around a piece of equipment:
	# "fiddle" — stands close to it facing it with a small fidgeting gait
	# (reaching/touching it), "circle" — runs around it at a fast gait.
	# After a while it moves on to the next piece of equipment.
	var play_s: Array = route["play_s"]
	var idx: int = int(walker["play_index"])
	var center: Vector3 = (route["play_ats"] as Array)[idx]
	var spot: Vector3 = Vector3(float((route["play_spots"] as Array)[idx][0]), center.y, float((route["play_spots"] as Array)[idx][1]))
	walker["play_t"] = float(walker.get("play_t", 0.0)) + delta
	var fiddle: bool = fposmod(float(walker["play_t"]), 3.4) < 1.4
	if not fiddle:
		walker["play_angle"] = float(walker["play_angle"]) + delta * 1.6
	var a: float = float(walker["play_angle"])
	var radius: float = 0.5 if fiddle else 0.9
	var pos := center + Vector3(cos(a), 0.0, sin(a)) * radius
	pos.y = center.y
	node.position = pos
	if fiddle:
		node.rotation.y = lerp_angle(node.rotation.y, atan2(spot.x - pos.x, spot.z - pos.z), 1.0 - exp(-8.0 * delta))
		if animation:
			animation.speed_scale = 0.25
	else:
		var tangent := Vector3(-sin(a), 0.0, cos(a))
		node.rotation.y = lerp_angle(node.rotation.y, atan2(tangent.x, tangent.z), 1.0 - exp(-10.0 * delta))
		if animation:
			animation.speed_scale = 1.5
	walker["state_left"] = float(walker["state_left"]) - delta
	walker["s"] = float(play_s[idx])
	var played_moved: float = delta * (0.4 if fiddle else 1.4)
	walker["travelled"] = float(walker["travelled"]) + played_moved
	travel_total += played_moved
	if float(walker["state_left"]) <= 0.0:
		walker["state"] = "walk"
		walker["play_t"] = 0.0
		walker["play_index"] = (idx + 1) % play_s.size()
		walker["dest"] = fposmod(float(walker["s"]) + float(route["length"]) * _rng.randf_range(0.3, 0.7), float(route["length"]))


# Detour walking (to the kiosk door and back). Waypoints carry their own Y
# (probe level of the plaza), so the path stays glued to the floor.
func _do_detour(walker: Dictionary, node: Node3D, animation: AnimationPlayer, delta: float) -> void:
	var detour: Array = walker["detour"]
	var i: int = int(walker["detour_i"])
	if i >= detour.size():
		# returned to the loop
		walker["state"] = "walk"
		walker["dest"] = fposmod(float(walker["s"]) + float(_routes[int(walker["route"])]["length"]) * 0.5, float(_routes[int(walker["route"])]["length"]))
		return
	# interior waypoint: the shopper is inside — browse the goods
	if detour.size() == 4 and i == 3:
		node.position = detour[3]
		walker["state"] = "shop_in"
		walker["state_left"] = _rng.randf_range(3.5, 7.0)
		walker["cool"] = _rng.randf_range(25.0, 40.0)
		walker["detour"] = [detour[2], detour[1], detour[0]]
		walker["detour_i"] = 0
		visit_count += 1
		return
	var target: Vector3 = detour[i]
	var to: Vector3 = target - node.global_position
	var dist: float = to.length()
	if dist < 0.12:
		walker["detour_i"] = i + 1
		return
	var dir: Vector3 = to.normalized()
	var moved: float = minf(dist, float(walker["speed"]) * delta)
	node.position = node.global_position + dir * moved
	node.rotation.y = lerp_angle(node.rotation.y, atan2(dir.x, dir.z), 1.0 - exp(-12.0 * delta))
	if animation:
		animation.speed_scale = float(walker["speed"]) / 0.9
	walker["travelled"] = float(walker["travelled"]) + moved
	travel_total += moved


func _do_shop_in(walker: Dictionary, node: Node3D, animation: AnimationPlayer, delta: float) -> void:
	# inside the kiosk: stands before the goods shelf (facing the back wall)
	var shop_index: int = int(walker["shop"])
	if shop_index < 0:
		walker["state"] = "walk"
		return
	var sh: Dictionary = _shops[shop_index]
	var face: Vector3 = sh["node"].basis.z
	node.position = walker.get("browse_pos", sh["interior_world"])
	node.rotation.y = lerp_angle(node.rotation.y, atan2(-face.x, -face.z), 1.0 - exp(-4.0 * delta))
	if animation:
		animation.speed_scale = 0.0
	walker["state_left"] = float(walker["state_left"]) - delta
	if float(walker["state_left"]) <= 0.0:
		walker["state"] = "shop_go"


# ---- geometry -----------------------------------------------------------

func _rect_loop(x0: float, z0: float, x1: float, z1: float, step: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	var x := x0
	points.append(Vector3(x0, 0.0, z0))
	while x < x1 - 0.001:
		x += step
		points.append(Vector3(minf(x, x1), 0.0, z0))
	var z := z0
	while z < z1 - 0.001:
		z += step
		points.append(Vector3(x1, 0.0, minf(z, z1)))
	while x > x0 + 0.001:
		x -= step
		points.append(Vector3(maxf(x, x0), 0.0, z1))
	while z > z0 + 0.001:
		z -= step
		points.append(Vector3(x0, 0.0, maxf(z, z0)))
	return points


func _smooth(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := points.size()
	for i in n:
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % n]
		out.append(a.lerp(b, 0.25))
		out.append(a.lerp(b, 0.75))
	return out


func _finalize_route(points: PackedVector3Array) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var first_ys := []
	for point in points:
		var hs: Array = _column_hits(point, space, 45.0, -25.0, 6)
		first_ys.append(float(hs[0]) if hs.size() > 0 else -999.0)
	var level := _median(first_ys)
	var refined := PackedVector3Array()
	var prev_y := level
	for point in points:
		prev_y = _nearest_surface(point, space, prev_y)
		refined.append(Vector3(point.x, prev_y, point.z))
	refined.append(refined[0])
	var cum := PackedFloat32Array([0.0])
	for i in range(1, refined.size()):
		cum.append(cum[-1] + refined[i].distance_to(refined[i - 1]))
	return {"points": refined, "cum": cum, "length": cum[-1]}


func _column_hits(pos: Vector3, space, top: float, bottom: float, max_hits: int) -> Array:
	var out := []
	var from := Vector3(pos.x, top, pos.z)
	for i in max_hits:
		var ray := PhysicsRayQueryParameters3D.create(from, Vector3(pos.x, bottom, pos.z))
		var hit: Dictionary = space.intersect_ray(ray)
		if hit.is_empty():
			break
		out.append(hit.position.y)
		from = Vector3(pos.x, hit.position.y - 0.06, pos.z)
		if from.y < bottom:
			break
	return out


func _median(ys: Array) -> float:
	var good := []
	for y in ys:
		if float(y) > -900.0:
			good.append(float(y))
	good.sort()
	return float(good[good.size() / 2]) if good.size() > 0 else 20.0


func _nearest_surface(pos: Vector3, space, level: float) -> float:
	var best := level
	var best_diff := 1.2
	var hs: Array = _column_hits(pos, space, 45.0, -25.0, 6)
	for y in hs:
		var d := absf(float(y) - level)
		if d < best_diff:
			best = float(y)
			best_diff = d
	return best


func _sample(route: Dictionary, distance: float) -> Dictionary:
	var points: PackedVector3Array = route["points"]
	var cum: PackedFloat32Array = route["cum"]
	distance = fposmod(distance, float(route["length"]))
	var lo := 0
	var hi := cum.size() - 1
	while hi - lo > 1:
		var mid: int = (lo + hi) / 2
		if cum[mid] <= distance:
			lo = mid
		else:
			hi = mid
	var span: float = maxf(cum[hi] - cum[lo], 0.0001)
	var weight: float = (distance - cum[lo]) / span
	var a: Vector3 = points[lo]
	var b: Vector3 = points[hi]
	var position: Vector3 = a.lerp(b, weight)
	var direction := Vector3((b - a).x, 0.0, (b - a).z)
	if direction.length_squared() < 0.0001:
		direction = Vector3.FORWARD
	return {"position": position, "direction": direction.normalized()}


# ---- enterable kiosk ----------------------------------------------------

func _make_shop(pos: Vector3, face: Vector3, definition: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "Shop_%02d" % _shops.size()
	root.rotation.y = atan2(face.x, face.z)
	var awning_color := Color(definition.get("awning", "#e2574c"))
	var sign_color := Color(definition.get("sign", "#ffd23e"))
	var light_color := Color(definition.get("light", "#ffdf9e"))
	# walls: back, sides, and a FRONT wall with a 0.8 m doorway gap
	_box(root, Vector3(2.6, 1.6, 0.12), Vector3(0, 0.8, -1.0), Color("6b5648"), 0.8)
	_box(root, Vector3(0.12, 1.6, 2.0), Vector3(-1.3, 0.8, 0.0), Color("6b5648"), 0.8)
	_box(root, Vector3(0.12, 1.6, 2.0), Vector3(1.3, 0.8, 0.0), Color("6b5648"), 0.8)
	_box(root, Vector3(0.65, 1.6, 0.12), Vector3(-0.975, 0.8, 1.0), Color("6b5648"), 0.8)
	_box(root, Vector3(0.55, 1.6, 0.12), Vector3(1.075, 0.8, 1.0), Color("6b5648"), 0.8)
	# door frame around the gap
	_box(root, Vector3(0.1, 1.6, 0.16), Vector3(0.0, 0.8, 1.0), Color("3a2f28"), 0.7)
	_box(root, Vector3(0.1, 1.6, 0.16), Vector3(0.8, 0.8, 1.0), Color("3a2f28"), 0.7)
	_box(root, Vector3(0.9, 0.1, 0.16), Vector3(0.4, 1.6, 1.0), Color("3a2f28"), 0.7)
	# roof + front posts + awning
	_box(root, Vector3(3.0, 0.08, 2.5), Vector3(0, 1.72, 0.1), Color("4a3b33"), 0.7)
	_cylinder(root, 0.05, 1.7, Vector3(-1.35, 0.85, 1.2), Color("3a2f28"))
	_cylinder(root, 0.05, 1.7, Vector3(1.35, 0.85, 1.2), Color("3a2f28"))
	var awning := _box(root, Vector3(2.9, 0.07, 1.3), Vector3(0, 1.66, 1.4), awning_color, 0.5)
	awning.rotation.x = -0.12
	# sign (emissive)
	_box(root, Vector3(2.3, 0.5, 0.1), Vector3(0, 2.05, 1.25), sign_color, 0.2, true, sign_color, 2.8)
	# counter + goods + back shelf
	_box(root, Vector3(2.2, 0.95, 0.45), Vector3(0, 0.475, 0.55), Color("8a6d52"), 0.6)
	_box(root, Vector3(2.2, 0.3, 0.25), Vector3(0, 0.95, -0.85), Color("7a5f48"), 0.7)
	var goods := [Color("d84343"), Color("43b0d8"), Color("e8c33e"), Color("58b368")]
	for i in 4:
		_box(root, Vector3(0.34, 0.3, 0.34), Vector3(-0.8 + float(i) * 0.53, 1.18, 0.55), goods[i], 0.4)
	for i in 3:
		_box(root, Vector3(0.4, 0.26, 0.2), Vector3(-0.7 + float(i) * 0.7, 1.1, -0.85), goods[(i + 1) % 4], 0.4)
	var light := SpotLight3D.new()
	light.light_color = light_color
	light.light_energy = 1.2
	light.spot_range = 7.0
	if "spot_attenuation" in light:
		light.spot_attenuation = 1.1
	if "spot_fov" in light:
		light.spot_fov = 75.0
	light.position = Vector3(0, 1.9, 0.3)
	light.rotation.x = -PI / 2.0
	root.add_child(light)
	# collision: the kiosk is solid (the player camera body respects it)
	var body := StaticBody3D.new()
	root.add_child(body)
	for wall in [
		Vector3(2.6, 1.6, 0.12), Vector3(0.12, 1.6, 2.0), Vector3(0.12, 1.6, 2.0),
		Vector3(0.65, 1.6, 0.12), Vector3(0.55, 1.6, 0.12)
	]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = wall
		shape.shape = box
		shape.position = Vector3(0, 0.8, 0)
		body.add_child(shape)
	return {"node": root}


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color, roughness: float,
		emissive := false, emit_color: Color = Color.WHITE, energy := 1.0) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	if emissive:
		mat.emission = emit_color
		mat.emission_energy_multiplier = energy
	node.material_override = mat
	parent.add_child(node)
	return node


func _cylinder(parent: Node3D, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	node.mesh = mesh
	node.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	node.material_override = mat
	parent.add_child(node)
	return node
