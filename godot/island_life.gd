extends Node3D
# Живой городок: пешеходы (walk-модели из character-набора) обходят открытые
# площади острова, иногда останавливаются у лавок «поглядеть товар».
# Маршруты и места лавок заданы в island_life.json — все точки проверены
# clearance-пробой по реальным коллизиям острова.

const LIFESTYLE_PATH := "res://island_life.json"
# Колонки на площадях, где точно есть пол — гейт «физика готова».
const PROBE_XZ := [Vector2(-32.0, 3.0), Vector2(-7.0, -10.0), Vector2(5.0, -18.0)]

var walker_count := 0
var shop_count := 0
var visit_count := 0
var travel_total := 0.0

# Свободная камера: пешеходы останавливаются, если наблюдатель на их пути.
var observer: Node3D

var _routes: Array[Dictionary] = []
var _walkers: Array[Dictionary] = []
var _shops: Array[Dictionary] = []
var _models: Array[PackedScene] = []
var _spec: Dictionary = {}
var _built := false
var _frame := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 20261010

func _process(_delta: float) -> void:
	_frame += 1
	# Физика должна успеть зарегистрировать коллизии острова, иначе лучи
	# высоты уйдут в пустоту (гонка _ready). Ждём контрольные колонки.
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
	for definition in _spec.get("routes", []):
		var rect: Array = definition["rect"]
		var step: float = float(definition.get("step", 0.5))
		var raw := _rect_loop(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]), step)
		var points := _smooth(raw)
		var route := _finalize_route(points)
		route["name"] = definition.get("name", "route")
		route["walkers"] = int(definition.get("walkers", 3))
		# Роль и параметры маршрута: ребёнок/шопер/прогуляк ходят по-разному.
		route["role"] = str(definition.get("role", ""))
		route["roles"] = definition.get("roles", [])
		route["model"] = int(definition.get("model", -1))
		route["scale"] = float(definition.get("scale", 1.0))
		route["speed_min"] = float(definition.get("speed_min", _spec.get("walk_speed_min", 0.7)))
		route["speed_max"] = float(definition.get("speed_max", _spec.get("walk_speed_max", 1.15)))
		route["browse_chance"] = float(definition.get("browse_chance", _spec.get("browse_chance", 0.55)))
		route["browse_min"] = float(definition.get("browse_min", _spec.get("browse_min", 3.0)))
		route["browse_max"] = float(definition.get("browse_max", _spec.get("browse_max", 7.0)))
		route["browse_cool"] = float(definition.get("browse_cooldown", _spec.get("browse_cooldown", 15.0)))
		route["loiter_min"] = float(definition.get("loiter_min", 1.5))
		route["loiter_max"] = float(definition.get("loiter_max", 3.5))
		route["loiter_cd_min"] = float(definition.get("loiter_cd_min", 10.0))
		route["loiter_cd_max"] = float(definition.get("loiter_cd_max", 26.0))
		_routes.append(route)
	for definition in _spec.get("shops", []):
		var pos: Vector3 = Vector3(float(definition["pos"][0]), float(definition["pos"][1]), float(definition["pos"][2]))
		var entry: Vector3 = Vector3(float(definition["entry"][0]), float(definition["entry"][1]), float(definition["entry"][2]))
		var shop := _make_shop(pos, entry, definition)
		_shops.append(shop)
		add_child(shop["node"])
		var route_index: int = int(definition.get("route", 0))
		if route_index < _routes.size():
			_routes[route_index]["stops"].append(entry)
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

# Детерминированная симуляция для smoke-теста.
func simulate(seconds: float, step_dt: float = 0.1) -> void:
	if not _built:
		_build()
	var n := int(round(seconds / step_dt))
	for i in n:
		_step(step_dt)

func _step(delta: float) -> void:
	for walker in _walkers:
		var route: Dictionary = _routes[walker["route"]]
		var node: Node3D = walker["node"]
		var animation: AnimationPlayer = walker["animation"]
		if walker["state"] == "browse":
			walker["browse_left"] = float(walker["browse_left"]) - delta
			var face: Vector3 = (walker["browse_target"] as Vector3) - node.global_position
			node.rotation.y = lerp_angle(node.rotation.y, atan2(face.x, face.z), 1.0 - exp(-8.0 * delta))
			if animation:
				animation.speed_scale = 0.0
			if float(walker["browse_left"]) <= 0.0:
				walker["state"] = "walk"
			continue
		if walker["state"] == "loiter":
			# Пауза на маршруте: стоит и неторопливо оглядывается.
			walker["loiter_left"] = float(walker["loiter_left"]) - delta
			node.rotation.y = lerp_angle(node.rotation.y, float(walker["loiter_yaw"]), 1.0 - exp(-2.0 * delta))
			if animation:
				animation.speed_scale = 0.0
			if float(walker["loiter_left"]) <= 0.0:
				walker["state"] = "walk"
			continue
		var blocked := false
		if is_instance_valid(observer):
			var difference: Vector3 = observer.global_position - node.global_position
			var flat := Vector3(difference.x, 0.0, difference.z)
			if flat.length() < 1.0:
				blocked = true
		if blocked:
			if animation:
				animation.speed_scale = 0.0
			continue
		var speed: float = float(walker["speed"])
		var new_distance: float = fposmod(float(walker["distance"]) + speed * delta, float(route["length"]))
		walker["distance"] = new_distance
		var at: Dictionary = _sample(route, new_distance)
		node.position = at["position"]
		node.rotation.y = lerp_angle(node.rotation.y, atan2(at["direction"].x, at["direction"].z), 1.0 - exp(-10.0 * delta))
		if animation:
			animation.speed_scale = speed / 0.9
		walker["travelled"] = float(walker["travelled"]) + speed * delta
		travel_total += speed * delta
		# Точка входа в лавку: один бросок на каждое вхождение в зону.
		var in_zone := false
		var zone_stop: Vector3 = at["position"]
		for stop in route["stops"]:
			if node.global_position.distance_to(stop) < float(_spec.get("trigger_radius", 1.3)):
				in_zone = true
				zone_stop = stop
				break
		if in_zone and not bool(walker["prev_in_zone"]) and float(walker["cool"]) <= 0.0:
			if _rng.randf() < float(walker["browse_chance"]):
				walker["state"] = "browse"
				walker["browse_left"] = lerpf(float(walker["browse_min"]), float(walker["browse_max"]), _rng.randf())
				walker["browse_target"] = zone_stop
				walker["cool"] = float(walker["browse_cool"])
				visit_count += 1
		walker["prev_in_zone"] = in_zone
		walker["cool"] = float(walker["cool"]) - delta
		# Случайная пауза: остановиться, оглядеться, продолжить путь.
		walker["loiter_cd"] = float(walker["loiter_cd"]) - delta
		if float(walker["loiter_cd"]) <= 0.0:
			walker["state"] = "loiter"
			walker["loiter_left"] = lerpf(float(walker["loiter_min"]), float(walker["loiter_max"]), _rng.randf())
			walker["loiter_yaw"] = node.rotation.y + (2.0 * _rng.randf() - 1.0) * 2.4
			walker["loiter_cd"] = lerpf(float(walker["loiter_cd_min"]), float(walker["loiter_cd_max"]), _rng.randf())

func _rect_loop(x0: float, z0: float, x1: float, z1: float, step: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	var x := x0
	var z := z0
	points.append(Vector3(x0, 0.0, z0))
	while x < x1 - 0.001:
		x += step
		points.append(Vector3(minf(x, x1), 0.0, z0))
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

# Одна итерация Chaikina: скругляет углы прямоугольника, крайние линии
# остаются на месте (маршрут не уезжает с проверенной плиты).
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
	# Уровень площадки — медиана верхних попаданий; каждая точка берёт
	# ближайшую к нему поверхность (яма/перекладина не могут утащить
	# пешехода вниз или поставить на крышу).
	var first_ys := []
	for point in points:
		var hs: Array = _column_hits(point, space, 45.0, -25.0, 6)
		first_ys.append(float(hs[0]) if hs.size() > 0 else -999.0)
	var level := _road_level(first_ys)
	var refined := PackedVector3Array()
	for point in points:
		refined.append(Vector3(point.x, _nearest_surface(point, space, level), point.z))
	refined.append(refined[0])
	var cum := PackedFloat32Array([0.0])
	for i in range(1, refined.size()):
		cum.append(cum[-1] + refined[i].distance_to(refined[i - 1]))
	return {
		"points": refined,
		"cum": cum,
		"length": cum[-1],
		"stops": [],
	}


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


func _road_level(ys: Array) -> float:
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

func _spawn_walker(route_index: int, id: int, group_size: int, walker_index: int) -> void:
	var route: Dictionary = _routes[route_index]
	var role := str(route.get("role", ""))
	var roles: Array = route.get("roles", [])
	if walker_index < roles.size():
		role = str(roles[walker_index])
	var model_id := int(route.get("model", -1))
	if model_id < 0 or model_id >= _models.size():
		model_id = id % _models.size() if _models.size() > 0 else 0
	# Эффективные параметры поведения: роль переопределяет параметры маршрута.
	var browse_chance := float(route.get("browse_chance", 0.5))
	var browse_min := float(route.get("browse_min", 3.0))
	var browse_max := float(route.get("browse_max", 6.0))
	var browse_cool := float(route.get("browse_cool", 14.0))
	var loiter_min := float(route.get("loiter_min", 1.5))
	var loiter_max := float(route.get("loiter_max", 3.5))
	var loiter_cd_min := float(route.get("loiter_cd_min", 10.0))
	var loiter_cd_max := float(route.get("loiter_cd_max", 26.0))
	if role == "shopper":
		# Взрослый идёт за покупками: у лавки останавливается всегда.
		browse_chance = 1.0
		browse_min = maxf(browse_min, 4.0)
		browse_max = maxf(browse_max, 6.5)
		browse_cool = 30.0
	elif role == "stroller":
		browse_chance = minf(browse_chance, 0.15)
		loiter_min = maxf(loiter_min, 2.0)
		loiter_max = maxf(loiter_max, 4.0)
	elif role == "child":
		browse_chance = 0.0
		loiter_cd_min = minf(loiter_cd_min, 8.0)
		loiter_cd_max = minf(loiter_cd_max, 14.0)
	var root := Node3D.new()
	root.name = "Islander_%02d" % id
	add_child(root)
	var visual: Node3D = _models[model_id].instantiate()
	var s: float = float(route.get("scale", 1.0))
	visual.scale = Vector3(s, s, s)
	root.add_child(visual)
	var players := visual.find_children("*", "AnimationPlayer", true, false)
	var animation: AnimationPlayer = players[0] as AnimationPlayer if players.size() > 0 else null
	var speed := lerpf(float(route.get("speed_min", 0.75)), float(route.get("speed_max", 1.05)), _rng.randf())
	var start: float = fposmod(float(id) * float(route["length"]) / float(group_size), float(route["length"]))
	var at: Dictionary = _sample(route, start)
	root.position = at["position"]
	root.rotation.y = atan2(at["direction"].x, at["direction"].z)
	if animation:
		var clip := animation.get_animation("Walk")
		if clip:
			clip.loop_mode = Animation.LOOP_LINEAR
		animation.play("Walk")
		animation.seek(_rng.randf(), true)
	var at0: Dictionary = _sample(route, start)
	var walker := {
		"node": root, "animation": animation, "route": route_index,
		"distance": start, "speed": speed, "model": model_id, "role": role, "travelled": 0.0,
		"state": "walk", "browse_left": 0.0, "browse_target": at0["position"],
		"cool": 0.0, "prev_in_zone": false,
		"browse_chance": browse_chance, "browse_min": browse_min, "browse_max": browse_max,
		"browse_cool": browse_cool,
		"loiter_left": 0.0, "loiter_yaw": 0.0,
		"loiter_min": loiter_min, "loiter_max": loiter_max,
		"loiter_cd": lerpf(loiter_cd_min, loiter_cd_max, _rng.randf()),
		"loiter_cd_min": loiter_cd_min, "loiter_cd_max": loiter_cd_max,
	}
	_walkers.append(walker)

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

func _make_shop(pos: Vector3, entry: Vector3, definition: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "Shop_%02d" % (_shops.size())
	root.position = pos
	var facing: Vector3 = entry - pos
	root.rotation.y = atan2(facing.x, facing.z)
	var awning_color := Color(definition.get("awning", "#e2574c"))
	var sign_color := Color(definition.get("sign", "#ffd23e"))
	var light_color := Color(definition.get("light", "#ffdf9e"))
	_box(root, Vector3(2.4, 0.85, 1.1), Vector3(0, 0.425, 0), Color("4a3b33"), 0.7)
	_box(root, Vector3(2.4, 1.5, 0.12), Vector3(0, 0.75, -0.6), Color("6b5648"), 0.8)
	_box(root, Vector3(0.12, 1.5, 1.2), Vector3(-1.2, 0.75, -0.05), Color("6b5648"), 0.8)
	_box(root, Vector3(0.12, 1.5, 1.2), Vector3(1.2, 0.75, -0.05), Color("6b5648"), 0.8)
	var awning := _box(root, Vector3(3.0, 0.08, 1.9), Vector3(0, 1.62, 0.35), awning_color, 0.5)
	awning.rotation.x = -0.1
	for side in [-1.0, 1.0]:
		_cylinder(root, 0.05, 1.6, Vector3(side * 1.35, 0.8, 0.8), Color("3a2f28"))
	_box(root, Vector3(2.3, 0.55, 0.14), Vector3(0, 2.0, 0.75), sign_color, 0.2, true, sign_color, 2.8)
	var goods := [Color("d84343"), Color("43b0d8"), Color("e8c33e")]
	for i in 3:
		_box(root, Vector3(0.4, 0.3, 0.4), Vector3(-0.7 + float(i) * 0.7, 1.0, 0.25), goods[i], 0.4)
	var light := SpotLight3D.new()
	light.light_color = light_color
	light.light_energy = 1.2
	light.spot_range = 7.0
	if "spot_attenuation" in light:
		light.spot_attenuation = 1.1
	if "spot_fov" in light:
		light.spot_fov = 75.0
	light.position = Vector3(0, 1.9, 0.4)
	light.rotation.y = PI
	light.rotate_object_local(Vector3.RIGHT, -deg_to_rad(25.0))
	root.add_child(light)
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
