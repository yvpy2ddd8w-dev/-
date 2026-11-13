-- DragonServer.server.lua
-- Положить в ServerScriptService. Roblox / Luau.
-- Реворк дракона, обновление 2.0: 6 скиллов + 3D-трансформация.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

------------------------------------------------------------------------
-- НАСТРОЙКИ (весь баланс тут)
------------------------------------------------------------------------
local CONFIG = {
	-- Если true, скиллы работают только у игроков с Attribute Class == "Dragon"
	RequireClass = false,
	ClassAttribute = "Class",
	ClassName = "Dragon",

	-- "Serpent" = обновление 2.0 (дракон-змея), "Dragon" = классический дракон
	TransformForm = "Serpent",

	-- Кулдауны скиллов 1..6 (секунды)
	Cooldowns = { 6, 12, 10, 18, 45, 60 },

	-- 1. Огнемёт на малую дистанцию
	Flame = { Duration = 1.5, Range = 22, Tick = 0.1, Damage = 12 },

	-- 2. Притянуть 3 врагов и оттолкнуть
	Pull = { Radius = 50, Count = 3, PullTime = 0.5, HoldTime = 0.6, PushSpeed = 95, PushUp = 35, Damage = 40 },

	-- 3. Огненный шар (тап = быстрый выстрел, зажатие = растёт до 5 сек)
	Fireball = {
		MaxCharge = 5, TapTime = 0.3,
		TapDamage = 40, TapRadius = 8, TapSpeed = 110, TapRange = 120, TapSize = 3,
		MinSize = 3, MaxSize = 14,
		MinDamage = 80, MaxDamage = 600,
		MinRadius = 10, MaxRadius = 30,
		Speed = 90, MinRange = 100, MaxRange = 450,
	},

	-- 4. Взлёт и град снарядов
	Volley = {
		RiseHeight = 30, RiseSpeed = 70, Count = 36, Interval = 0.07,
		Damage = 25, Speed = 110, Turn = 5, Range = 250, ExplosionRadius = 6,
	},

	-- 5. Мини-дракончик
	Mini = { Health = 50000, Lifetime = 30, BiteDamage = 90, BiteInterval = 1, AttackRange = 7, SeekRange = 70 },

	-- 6. Трансформация
	Transform = {
		Duration = 20,        -- сколько длится форма
		Invulnerable = 2,     -- неуязвимость во время превращения
		DamageMult = 1.5,     -- урон всех скиллов
		RangeMult = 1.3,      -- дальность/радиус скиллов
		SpeedMult = 1.25,
		ModelScale = 2.2,     -- размер дракона
		BurstRadius = 30,
	},

	-- Вставь свои SoundId ("rbxassetid://123"), пустая строка = без звука
	Sounds = { Flame = "", Fireball = "", Explosion = "", Transform = "", Roar = "" },
}

------------------------------------------------------------------------
-- БАЗА
------------------------------------------------------------------------
local remote = ReplicatedStorage:FindFirstChild("DragonRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "DragonRemote"
	remote.Parent = ReplicatedStorage
end

local ORANGE = Color3.fromRGB(255, 140, 30)
local states = {}

local function getState(plr)
	local st = states[plr]
	if not st then
		st = { cd = {}, locked = false, transformed = false, token = 0 }
		states[plr] = st
	end
	return st
end

local function getRoot(plr)
	local char = plr.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart"), char:FindFirstChildOfClass("Humanoid"), char
end

local function lerp(a, b, t) return a + (b - a) * t end
local function dmgMult(plr) return getState(plr).transformed and CONFIG.Transform.DamageMult or 1 end
local function rngMult(plr) return getState(plr).transformed and CONFIG.Transform.RangeMult or 1 end

local function playSound(key, parent)
	local id = CONFIG.Sounds[key]
	if not id or id == "" then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 6)
end

local function dealDamage(plr, hum, amount)
	hum:TakeDamage(amount * dmgMult(plr)) -- ForceField автоматически блокирует урон
end

local function groundPos(root)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { root.Parent }
	local r = workspace:Raycast(root.Position, Vector3.new(0, -30, 0), rp)
	return r and r.Position or (root.Position - Vector3.new(0, 3, 0))
end

local function mouthPos(plr)
	local root = getRoot(plr)
	local st = getState(plr)
	if st.form and st.form.mouth and st.form.mouth.Parent then
		return st.form.mouth.Position
	end
	return root.Position + root.CFrame.LookVector * 2.5 + Vector3.new(0, 0.8, 0)
end

-- точка, куда смотрит игрок (направление персонажа)
local function aimPoint(plr, maxDist)
	local root = getRoot(plr)
	if not root then return nil end
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local look = root.CFrame.LookVector
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { plr.Character }
	rp.RespectCanCollide = true
	local res = workspace:Raycast(origin, look * maxDist, rp)
	return res and res.Position or (origin + look * maxDist)
end

------------------------------------------------------------------------
-- ЭФФЕКТЫ
------------------------------------------------------------------------
local function makeFire(parent, rate, size, lifetime, speed)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/fire_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 210, 70), Color3.fromRGB(255, 60, 0))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(lifetime * 0.7, lifetime)
	e.Speed = NumberRange.new(speed * 0.8, speed)
	e.Rate = rate
	e.LightEmission = 1
	e.SpreadAngle = Vector2.new(10, 10)
	e.EmissionDirection = Enum.NormalId.Front
	e.Parent = parent
	return e
end

local function ringFX(pos, startR, endR, time, color)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = color or ORANGE
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.5, startR * 2, startR * 2)
	ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.5, endR * 2, endR * 2), Transparency = 1,
	}):Play()
	Debris:AddItem(ring, time + 0.1)
end

local function explosionFX(pos, radius)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Material = Enum.Material.Neon
	ball.Color = ORANGE
	ball.Transparency = 0.2
	ball.Size = Vector3.one * 2
	ball.Position = pos
	ball.Parent = workspace
	TweenService:Create(ball, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * radius * 2, Transparency = 1,
	}):Play()
	local e = makeFire(ball, 0, 6, 0.8, radius * 1.2)
	e.SpreadAngle = Vector2.new(180, 180)
	e:Emit(math.clamp(math.floor(radius * 4), 20, 200))
	Debris:AddItem(ball, 1)
	playSound("Explosion", ball)
end

------------------------------------------------------------------------
-- БОЙ: цели, взрывы, снаряды
------------------------------------------------------------------------
local function isFriendly(model, owner)
	return model == owner.Character or model:GetAttribute("DragonOwner") == owner.UserId
end

local function findTargets(pos, radius, owner)
	local out, seen = {}, {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(pos, radius)) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] then
			seen[model] = true
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and not isFriendly(model, owner) then
				table.insert(out, { model = model, hum = hum, root = model:FindFirstChild("HumanoidRootPart") })
			end
		end
	end
	return out
end

local function explode(plr, pos, radius, damage)
	explosionFX(pos, radius)
	for _, t in ipairs(findTargets(pos, radius, plr)) do
		dealDamage(plr, t.hum, damage)
	end
end

local function homing(target, turn)
	return function(pos, dir, dt)
		local want = target - pos
		if want.Magnitude < 1 then return dir end
		return dir:Lerp(want.Unit, math.clamp(turn * dt, 0, 1)).Unit
	end
end

-- Универсальный снаряд: двигается вручную, взрывается при столкновении
local function launch(plr, part, origin, dir, speed, maxDist, hitRadius, steer, onImpact)
	local st = getState(plr)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { plr.Character, st.mini, part }
	rp.RespectCanCollide = true

	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.lookAt(origin, origin + dir)
	part.Parent = workspace

	local pos, travelled = origin, 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if steer then dir = steer(pos, dir, dt) end
		local step = dir * speed * dt
		local res = workspace:Raycast(pos, step, rp)
		local newPos = res and res.Position or (pos + step)
		travelled += step.Magnitude
		part.CFrame = CFrame.lookAt(newPos, newPos + dir)
		local hit = res ~= nil
		if not hit and #findTargets(newPos, hitRadius, plr) > 0 then hit = true end
		pos = newPos
		if hit or travelled >= maxDist then
			conn:Disconnect()
			part:Destroy()
			onImpact(pos)
		end
	end)
end

local function fireBall(size, color)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = color or ORANGE
	p.Size = Vector3.one * size
	local fire = makeFire(p, 60, size, 0.5, 3)
	fire.SpreadAngle = Vector2.new(180, 180)
	return p
end

------------------------------------------------------------------------
-- ВНЕШНИЙ ВИД ПРЕВРАЩЕНИЯ
------------------------------------------------------------------------
local function hideCharacter(char, hide, t)
	for _, d in ipairs(char:GetDescendants()) do
		if (d:IsA("BasePart") or d:IsA("Decal")) and d.Name ~= "HumanoidRootPart" and not d:FindFirstAncestor("DragonForm") then
			if hide then
				if d:GetAttribute("DragonOrigT") == nil then d:SetAttribute("DragonOrigT", d.Transparency) end
				TweenService:Create(d, TweenInfo.new(t), { Transparency = 1 }):Play()
			else
				local o = d:GetAttribute("DragonOrigT")
				if o ~= nil then
					TweenService:Create(d, TweenInfo.new(t), { Transparency = o }):Play()
					d:SetAttribute("DragonOrigT", nil)
				end
			end
		end
	end
end

local function fadeForm(model, visible, dur)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local target = visible and (d:GetAttribute("T") or 0) or 1
			TweenService:Create(d, TweenInfo.new(dur), { Transparency = target }):Play()
		end
	end
end

-- Классический 3D-дракон из частей, привязанных к игроку
local function buildDragon(root)
	local S = CONFIG.Transform.ModelScale
	local RED = Color3.fromRGB(150, 25, 25)
	local DARK = Color3.fromRGB(90, 15, 15)
	local BELLY = Color3.fromRGB(225, 165, 85)
	local GLOW = Color3.fromRGB(255, 210, 40)

	local model = Instance.new("Model")
	model.Name = "DragonForm"

	local function sc(cf) return CFrame.new(cf.Position * S) * (cf - cf.Position) end

	local function mk(parent, size, off, color, mesh, shape, mat)
		local p = Instance.new("Part")
		p.Size = size * S
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Transparency = 1
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape then p.Shape = shape end
		if mesh then
			local m = Instance.new("SpecialMesh")
			m.MeshType = mesh
			m.Parent = p
		end
		p.Parent = model
		local w = Instance.new("Weld")
		w.Part0 = parent
		w.Part1 = p
		w.C0 = sc(off)
		w.Parent = p
		return p, w
	end

	local body = Instance.new("Part")
	body.Size = Vector3.new(4.5, 4.5, 8) * S
	body.Color = RED
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.Massless = true
	body.Transparency = 1
	local bm = Instance.new("SpecialMesh")
	bm.MeshType = Enum.MeshType.Sphere
	bm.Parent = body
	body.CFrame = root.CFrame
	body.Parent = model
	model.PrimaryPart = body

	local yFinal = 4.3 * S - 3
	local rootWeld = Instance.new("Weld")
	rootWeld.Part0 = root
	rootWeld.Part1 = body
	rootWeld.C0 = CFrame.new(0, yFinal - 6 * S, 0)
	rootWeld.Parent = body
	model.Parent = root.Parent

	local Sphere = Enum.MeshType.Sphere
	local Cyl = Enum.PartType.Cylinder
	local Neon = Enum.Material.Neon

	mk(body, Vector3.new(3.6, 3, 6.4), CFrame.new(0, -0.9, 0), BELLY, Sphere)
	mk(body, Vector3.new(2.4, 2.4, 4), CFrame.new(0, 1.8, -4.2) * CFrame.Angles(math.rad(35), 0, 0), RED, Sphere)
	mk(body, Vector3.new(2.8, 2.4, 3.6), CFrame.new(0, 3.6, -6.4), RED, Sphere)
	local snout = mk(body, Vector3.new(1.8, 1.2, 2.4), CFrame.new(0, 3.2, -8.2), DARK, Sphere)
	mk(body, Vector3.new(1.5, 0.5, 2.2), CFrame.new(0, 2.6, -8), DARK)
	for _, side in ipairs({ -1, 1 }) do
		mk(body, Vector3.new(2.2, 0.45, 0.45), CFrame.new(side * 0.9, 4.9, -6) * CFrame.Angles(math.rad(35), 0, math.rad(90)), DARK, nil, Cyl)
		mk(body, Vector3.new(0.55, 0.55, 0.55), CFrame.new(side * 0.95, 3.9, -7.4), GLOW, Sphere, nil, Neon)
		for _, z in ipairs({ -2.4, 2.4 }) do
			mk(body, Vector3.new(1.3, 2.6, 1.3), CFrame.new(side * 1.9, -3, z), RED)
		end
	end
	for i = 0, 5 do
		mk(body, Vector3.new(0.7, 1.3, 0.7), CFrame.new(0, 2.6, -3 + i * 1.2), DARK)
	end

	-- крылья (шарнир на спине, C0/C1 обновляются в update)
	local wingL, wlW = mk(body, Vector3.new(9, 0.25, 5.5), CFrame.new(), DARK)
	local wingR, wrW = mk(body, Vector3.new(9, 0.25, 5.5), CFrame.new(), DARK)
	wlW.C1 = CFrame.new(4.5 * S, 0, 0)
	wrW.C1 = CFrame.new(-4.5 * S, 0, 0)
	mk(wingL, Vector3.new(8.8, 0.45, 0.45), CFrame.new(0, 0.15, -2.5), RED)
	mk(wingR, Vector3.new(8.8, 0.45, 0.45), CFrame.new(0, 0.15, -2.5), RED)

	-- хвост
	local tail = {}
	local prev = body
	local sizes = { 2.6, 2.2, 1.8, 1.4, 1.0, 0.7 }
	for i, sz in ipairs(sizes) do
		local off = (i == 1) and Vector3.new(0, -0.3, 4.2) or Vector3.new(0, 0, 2.2)
		local p, w = mk(prev, Vector3.new(sz, sz, sz), CFrame.new(off), (i < 4) and RED or DARK, Sphere)
		table.insert(tail, { w = w, base = CFrame.new(off * S) })
		prev = p
	end

	local form = { model = model, mouth = snout }
	local birth = os.clock()
	function form.update(t)
		local p = math.clamp((os.clock() - birth) / 1.0, 0, 1)
		local e = 1 - (1 - p) ^ 3
		rootWeld.C0 = CFrame.new(0, yFinal - (1 - e) * 6 * S, 0)
		local a = lerp(-1.25, 0.15 + math.sin(t * 5) * 0.5, e)
		wlW.C0 = CFrame.new(Vector3.new(-1.6, 2.2, -0.5) * S) * CFrame.Angles(0, 0, -a)
		wrW.C0 = CFrame.new(Vector3.new(1.6, 2.2, -0.5) * S) * CFrame.Angles(0, 0, a)
		for i, seg in ipairs(tail) do
			seg.w.C0 = seg.base * CFrame.Angles(0, math.sin(t * 3 - i * 0.8) * 0.22, 0)
		end
	end
	function form.fade(visible, dur) fadeForm(model, visible, dur) end
	function form.destroy() model:Destroy() end
	return form
end

-- Дракон-змея (обновление 2.0): длинное тело следует за головой волнами
local function buildSerpent(root)
	local K = CONFIG.Transform.ModelScale / 2.2
	local N = 20
	local INTRO = 1.4
	local model = Instance.new("Model")
	model.Name = "DragonForm"

	local segs = {}
	local start = root.Position
	for i = 1, N do
		local a = (i - 1) / (N - 1)
		local size = lerp(5.5, 1.1, a ^ 0.8) * K
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.one * size
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Color = Color3.fromRGB(150, 25, 25):Lerp(Color3.fromRGB(70, 10, 10), a)
		p.Transparency = 1
		p.Parent = model
		segs[i] = { part = p, size = size, pos = start }
		if i > 1 then
			local s = Instance.new("Part")
			s.Size = Vector3.new(0.5 * K, size * 0.7, size * 0.5)
			s.Color = ORANGE
			s.Material = Enum.Material.Neon
			s.CanCollide = false
			s.CanQuery = false
			s.CanTouch = false
			s.Massless = true
			s.Transparency = 1
			s.Parent = model
			local w = Instance.new("Weld")
			w.Part0 = p
			w.Part1 = s
			w.C0 = CFrame.new(0, size * 0.55, 0)
			w.Parent = s
		end
	end

	local head = segs[1].part
	local function hw(size, off, color, mesh, shape, mat)
		local p = Instance.new("Part")
		p.Size = size * K
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.Transparency = 1
		if shape then p.Shape = shape end
		if mesh then
			local m = Instance.new("SpecialMesh")
			m.MeshType = mesh
			m.Parent = p
		end
		p.Parent = model
		local w = Instance.new("Weld")
		w.Part0 = head
		w.Part1 = p
		w.C0 = CFrame.new(off.Position * K) * (off - off.Position)
		w.Parent = p
		return p
	end

	local snout = hw(Vector3.new(3, 2, 3.4), CFrame.new(0, -0.5, -2.8), Color3.fromRGB(100, 15, 15), Enum.MeshType.Sphere)
	for _, side in ipairs({ -1, 1 }) do
		hw(Vector3.new(3, 0.5, 0.5), CFrame.new(side * 1.2, 2.4, -0.3) * CFrame.Angles(math.rad(40), 0, math.rad(90)), Color3.fromRGB(90, 15, 15), nil, Enum.PartType.Cylinder)
		hw(Vector3.new(0.7, 0.7, 0.7), CFrame.new(side * 1.5, 0.8, -1.6), Color3.fromRGB(255, 210, 40), Enum.MeshType.Sphere, nil, Enum.Material.Neon)
		hw(Vector3.new(6, 0.15, 0.15), CFrame.new(side * 3.2, -0.5, -2.8) * CFrame.Angles(0, side * math.rad(15), 0), Color3.fromRGB(255, 210, 40), nil, Enum.PartType.Cylinder, Enum.Material.Neon)
	end

	local form = { model = model, mouth = snout }
	local birth = os.clock()
	local last = os.clock()
	model.Parent = root.Parent

	function form.update(t)
		local now = os.clock()
		local dt = math.min(now - last, 0.1)
		last = now
		local age = now - birth
		local base = root.Position
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
		local right = Vector3.new(-flat.Z, 0, flat.X)

		local target
		if age < INTRO then
			local p = age / INTRO
			local r = 8 * (1 - p)
			local a = p * 14
			target = base + Vector3.new(math.cos(a) * r, 2 + p * 9, math.sin(a) * r)
		else
			target = base + flat * 3 + Vector3.new(0, 8 + math.sin(t * 2), 0)
		end
		segs[1].pos = segs[1].pos:Lerp(target, math.clamp(10 * dt, 0, 1))

		for i = 2, N do
			local prev = segs[i - 1].pos
			local d = segs[i].pos - prev
			local dist = d.Magnitude
			if dist < 1e-3 then d = Vector3.new(0, 0, 1) dist = 1 end
			local spacing = (segs[i - 1].size + segs[i].size) * 0.32
			segs[i].pos = prev + d / dist * spacing
		end

		for i, s in ipairs(segs) do
			local wave = right * math.sin(t * 4 - i * 0.55) * math.min(i, 6) * 0.35 * K
			local pos = s.pos + wave
			local minY = base.Y - 2.5 + s.size / 2
			if pos.Y < minY then pos = Vector3.new(pos.X, minY, pos.Z) end
			local face
			if i == 1 then
				face = pos + flat
			else
				face = segs[i - 1].pos
				if (face - pos).Magnitude < 1e-3 then face = pos + flat end
			end
			s.part.CFrame = CFrame.lookAt(pos, face)
		end
	end
	function form.fade(visible, dur) fadeForm(model, visible, dur) end
	function form.destroy() model:Destroy() end
	return form
end

------------------------------------------------------------------------
-- СБРОС / ОКОНЧАНИЕ ФОРМЫ
------------------------------------------------------------------------
local function endTransform(plr, quick)
	local st = getState(plr)
	if st.formConn then st.formConn:Disconnect() st.formConn = nil end
	local root, hum, char = getRoot(plr)
	local form = st.form
	st.form = nil
	if form then
		if quick or not root then
			form.destroy()
		else
			local g = groundPos(root)
			ringFX(g, 3, 25, 0.7, ORANGE)
			form.fade(false, 0.5)
			task.delay(0.6, form.destroy)
		end
	end
	st.transformed = false
	if char then
		hideCharacter(char, false, 0.3)
		local hl = char:FindFirstChild("DragonHighlight")
		if hl then hl:Destroy() end
		if hum and hum.Health > 0 then
			hum.WalkSpeed = st.baseSpeed or 16
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
		if root and not st.locked then root.Anchored = false end
	end
end

local function resetState(plr)
	local st = getState(plr)
	st.token += 1
	st.locked = false
	if st.charge then
		if st.charge.conn then st.charge.conn:Disconnect() end
		if st.charge.ball then st.charge.ball:Destroy() end
		st.charge = nil
	end
	if st.mini then st.mini:Destroy() st.mini = nil end
	if st.formConn then st.formConn:Disconnect() st.formConn = nil end
	if st.form then st.form.destroy() st.form = nil end
	st.transformed = false
	remote:FireClient(plr, "Aim", false)
end

------------------------------------------------------------------------
-- СКИЛЛЫ
------------------------------------------------------------------------
local SKILLS = {}

-- 1. Огнемёт
SKILLS[1] = function(plr)
	local root, hum = getRoot(plr)
	local c = CONFIG.Flame
	local range = c.Range * rngMult(plr)

	local part = Instance.new("Part")
	part.Size = Vector3.one
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CFrame = CFrame.lookAt(mouthPos(plr), mouthPos(plr) + root.CFrame.LookVector)
	part.Parent = workspace
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = part
	w.Parent = part
	makeFire(part, 500, 7, 0.6, range / 0.6).SpreadAngle = Vector2.new(12, 12)
	playSound("Flame", part)

	local t = 0
	while t < c.Duration and root.Parent and hum.Health > 0 do
		local origin = mouthPos(plr)
		local look = root.CFrame.LookVector
		for _, tg in ipairs(findTargets(origin + look * range / 2, range, plr)) do
			if tg.root then
				local v = tg.root.Position - origin
				if v.Magnitude <= range and v.Unit:Dot(look) > 0.6 then
					dealDamage(plr, tg.hum, c.Damage)
				end
			end
		end
		task.wait(c.Tick)
		t += c.Tick
	end
	for _, e in ipairs(part:GetChildren()) do
		if e:IsA("ParticleEmitter") then e.Enabled = false end
	end
	Debris:AddItem(part, 1)
	return true
end

-- 2. Притянуть 3 врагов и оттолкнуть
SKILLS[2] = function(plr)
	local root, hum = getRoot(plr)
	local c = CONFIG.Pull
	local radius = c.Radius * rngMult(plr)

	local targets = {}
	for _, t in ipairs(findTargets(root.Position, radius, plr)) do
		if t.root then table.insert(targets, t) end
	end
	table.sort(targets, function(a, b)
		return (a.root.Position - root.Position).Magnitude < (b.root.Position - root.Position).Magnitude
	end)
	if #targets == 0 then return false end

	ringFX(groundPos(root), 3, radius * 0.6, 0.5, Color3.fromRGB(180, 80, 255))
	local picked = {}
	for i = 1, math.min(c.Count, #targets) do picked[i] = targets[i] end

	for i, t in ipairs(picked) do
		t.hum.PlatformStand = true
		t.root.Anchored = true
		local base = root.CFrame * CFrame.Angles(0, (i - (#picked + 1) / 2) * 0.6, 0) * CFrame.new(0, 0, -7)
		TweenService:Create(t.root, TweenInfo.new(c.PullTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.lookAt(base.Position, root.Position),
		}):Play()
	end
	task.wait(c.PullTime + c.HoldTime)

	for _, t in ipairs(picked) do
		if t.root.Parent then
			t.root.Anchored = false
			local away = t.root.Position - root.Position
			away = Vector3.new(away.X, 0, away.Z)
			away = away.Magnitude > 0.1 and away.Unit or root.CFrame.LookVector
			t.root.AssemblyLinearVelocity = away * c.PushSpeed + Vector3.new(0, c.PushUp, 0)
			dealDamage(plr, t.hum, c.Damage)
			explosionFX(t.root.Position, 5)
			task.delay(0.8, function()
				if t.hum.Parent then t.hum.PlatformStand = false end
			end)
		end
	end
	return true
end

-- 3. Огненный шар: нажатие / зажатие
local function chargeBegin(plr)
	local st = getState(plr)
	local root, hum = getRoot(plr)
	local c = CONFIG.Fireball
	st.cd[3] = math.huge

	local ball = fireBall(c.MinSize)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Parent = workspace

	local charge = { start = os.clock(), ball = ball }
	st.charge = charge
	remote:FireClient(plr, "Aim", true)

	charge.conn = RunService.Heartbeat:Connect(function()
		if not root.Parent or hum.Health <= 0 then
			resetState(plr)
			st.cd[3] = nil
			return
		end
		local a = math.min(os.clock() - charge.start, c.MaxCharge) / c.MaxCharge
		local size = lerp(c.MinSize, c.MaxSize, a) * rngMult(plr)
		ball.Size = Vector3.one * size
		local look = root.CFrame.LookVector
		ball.Position = mouthPos(plr) + look * (size / 2 + 2) + Vector3.new(0, 1, 0)
	end)
end

local function chargeRelease(plr)
	local st = getState(plr)
	local charge = st.charge
	if not charge then return end
	st.charge = nil
	charge.conn:Disconnect()
	remote:FireClient(plr, "Aim", false)

	local root = getRoot(plr)
	local ball = charge.ball
	if not root or not root.Parent then
		ball:Destroy()
		st.cd[3] = nil
		return
	end

	local c = CONFIG.Fireball
	local held = math.min(os.clock() - charge.start, c.MaxCharge)
	local a = held / c.MaxCharge
	local rm = rngMult(plr)

	local size, speed, range, damage, radius
	if held < c.TapTime then
		size, speed, range, damage, radius = c.TapSize, c.TapSpeed, c.TapRange, c.TapDamage, c.TapRadius
	else
		size = lerp(c.MinSize, c.MaxSize, a)
		speed = c.Speed
		range = lerp(c.MinRange, c.MaxRange, a)
		damage = lerp(c.MinDamage, c.MaxDamage, a)
		radius = lerp(c.MinRadius, c.MaxRadius, a)
	end
	size *= rm
	range *= rm
	radius *= rm

	ball.Size = Vector3.one * size
	local origin = ball.Position
	local look = root.CFrame.LookVector
	playSound("Fireball", ball)
	launch(plr, ball, origin, look, speed, range, size / 2 + 1, nil, function(pos)
		explode(plr, pos, radius, damage)
	end)

	local cd = CONFIG.Cooldowns[3]
	st.cd[3] = os.clock() + cd
	remote:FireClient(plr, "Cooldown", 3, cd)
end

-- 4. Взлёт и град снарядов в точку, куда смотрит игрок
SKILLS[4] = function(plr)
	local root, hum = getRoot(plr)
	local c = CONFIG.Volley

	local att = Instance.new("Attachment")
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lv.LineDirection = Vector3.yAxis
	lv.LineVelocity = c.RiseSpeed
	lv.MaxForce = math.huge
	lv.Parent = root

	remote:FireClient(plr, "Aim", true)
	task.wait(c.RiseHeight / c.RiseSpeed)
	lv.LineVelocity = 0 -- зависаем и не падаем

	local count = math.floor(c.Count * (getState(plr).transformed and 1.5 or 1))
	for _ = 1, count do
		if not root.Parent or hum.Health <= 0 then break end
		local target = aimPoint(plr, c.Range)
		local cf = root.CFrame
		local side = math.random() * 2 - 1
		local origin = root.Position + cf.RightVector * side * 4 + Vector3.new(0, 1 + math.random() * 2, 0)
		local dir = (cf.RightVector * side + Vector3.new(0, 0.35, 0) + cf.LookVector * 0.5).Unit
		launch(plr, fireBall(1.4), origin, dir, c.Speed, c.Range * 2.5, 1.5, homing(target, c.Turn), function(pos)
			explode(plr, pos, c.ExplosionRadius * rngMult(plr), c.Damage)
		end)
		task.wait(c.Interval)
	end

	task.wait(0.3)
	lv:Destroy()
	att:Destroy()
	remote:FireClient(plr, "Aim", false)
	return true
end

-- 5. Мини-дракончик
local function buildMini(plr, cf)
	local RED = Color3.fromRGB(170, 40, 30)
	local DARK = Color3.fromRGB(100, 20, 20)
	local model = Instance.new("Model")
	model.Name = plr.Name .. "_MiniDragon"

	local function mk(name, size, color, mesh, mat)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = mat or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CanCollide = false
		if mesh then
			local m = Instance.new("SpecialMesh")
			m.MeshType = mesh
			m.Parent = p
		end
		p.Parent = model
		return p
	end

	local root = mk("HumanoidRootPart", Vector3.new(3, 2.4, 5), RED, Enum.MeshType.Sphere)
	root.CanCollide = true
	root.CFrame = cf
	model.PrimaryPart = root

	local function att(p, off)
		p.CFrame = root.CFrame * off
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = p
	end

	att(mk("Head", Vector3.new(2, 1.8, 2.2), RED, Enum.MeshType.Sphere), CFrame.new(0, 1, -3))
	att(mk("Snout", Vector3.new(1.2, 0.8, 1.4), DARK, Enum.MeshType.Sphere), CFrame.new(0, 0.7, -4.2))
	for _, side in ipairs({ -1, 1 }) do
		att(mk("Horn", Vector3.new(0.3, 1, 0.3), DARK), CFrame.new(side * 0.6, 2.1, -3))
		att(mk("Eye", Vector3.new(0.4, 0.4, 0.4), Color3.fromRGB(255, 220, 60), Enum.MeshType.Sphere, Enum.Material.Neon), CFrame.new(side * 0.7, 1.4, -3.9))
		att(mk("Wing", Vector3.new(4, 0.15, 2.5), DARK), CFrame.new(side * 3.3, 1.3, 0) * CFrame.Angles(0, 0, -side * 0.4))
	end
	att(mk("Tail1", Vector3.new(1.4, 1.4, 1.8), RED, Enum.MeshType.Sphere), CFrame.new(0, -0.2, 3.2))
	att(mk("Tail2", Vector3.new(0.9, 0.9, 1.6), DARK, Enum.MeshType.Sphere), CFrame.new(0, -0.2, 4.6))

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = 2.5
	hum.MaxHealth = CONFIG.Mini.Health
	hum.Health = CONFIG.Mini.Health
	hum.WalkSpeed = 30
	hum.DisplayName = "Дракончик"
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
	hum.BreakJointsOnDeath = false
	hum.Parent = model

	model:SetAttribute("DragonOwner", plr.UserId)
	model.Parent = workspace
	root:SetNetworkOwner(nil)
	return model, hum, root
end

SKILLS[5] = function(plr)
	local root = getRoot(plr)
	local st = getState(plr)
	local m = CONFIG.Mini
	if st.mini then st.mini:Destroy() st.mini = nil end

	local model, hum, mroot = buildMini(plr, root.CFrame * CFrame.new(5, 2, -4))
	st.mini = model
	ringFX(groundPos(mroot), 2, 10, 0.6, ORANGE)
	explosionFX(mroot.Position, 6)
	hum.Died:Connect(function() model:Destroy() end)

	task.spawn(function()
		local born = os.clock()
		local lastBite = 0
		while model.Parent and hum.Health > 0 and os.clock() - born < m.Lifetime and plr.Parent do
			local oRoot = getRoot(plr)
			if oRoot then
				local nearest, nd = nil, math.huge
				for _, t in ipairs(findTargets(mroot.Position, m.SeekRange, plr)) do
					if t.root then
						local d = (t.root.Position - mroot.Position).Magnitude
						if d < nd then nearest, nd = t, d end
					end
				end
				if nearest then
					if nd > m.AttackRange then
						hum:MoveTo(nearest.root.Position)
					elseif os.clock() - lastBite >= m.BiteInterval then
						lastBite = os.clock()
						mroot.CFrame = CFrame.lookAt(mroot.Position, Vector3.new(nearest.root.Position.X, mroot.Position.Y, nearest.root.Position.Z))
						dealDamage(plr, nearest.hum, m.BiteDamage)
						explosionFX(nearest.root.Position, 3)
					end
				else
					local d = (oRoot.Position - mroot.Position).Magnitude
					if d > 90 then
						model:PivotTo(oRoot.CFrame * CFrame.new(5, 2, -4))
					elseif d > 12 then
						hum:MoveTo(oRoot.Position)
					end
				end
			end
			task.wait(0.2)
		end
		if st.mini == model then st.mini = nil end
		if model.Parent then
			explosionFX(mroot.Position, 5)
			model:Destroy()
		end
	end)
	return true
end

-- 6. Трансформация
SKILLS[6] = function(plr)
	local root, hum, char = getRoot(plr)
	local st = getState(plr)
	local T = CONFIG.Transform
	if st.transformed or st.locked then return false end

	st.locked = true
	st.token += 1
	local tok = st.token
	local function alive()
		return st.token == tok and char.Parent ~= nil and hum.Health > 0 and root.Parent ~= nil
	end

	st.baseSpeed = hum.WalkSpeed
	local ff = Instance.new("ForceField")
	ff.Visible = false
	ff.Parent = char
	Debris:AddItem(ff, T.Invulnerable)

	hum.WalkSpeed = 0
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	root.Anchored = true
	playSound("Transform", root)

	-- Фаза 1: сбор энергии
	local CHARGE = 1.0
	remote:FireClient(plr, "Shake", CHARGE, 0.35)
	local hl = Instance.new("Highlight")
	hl.Name = "DragonHighlight"
	hl.FillColor = ORANGE
	hl.OutlineColor = Color3.new(1, 1, 1)
	hl.FillTransparency = 0.8
	hl.Parent = char
	TweenService:Create(hl, TweenInfo.new(CHARGE), { FillTransparency = 0 }):Play()

	local g = groundPos(root)
	ringFX(g, 24, 2, 1.0, ORANGE)
	task.delay(0.5, function()
		if alive() then ringFX(g, 24, 2, 0.5, Color3.fromRGB(255, 230, 120)) end
	end)

	local orbs = {}
	for i = 1, 16 do
		local o = Instance.new("Part")
		o.Shape = Enum.PartType.Ball
		o.Size = Vector3.one * 1.3
		o.Anchored = true
		o.CanCollide = false
		o.CanQuery = false
		o.CanTouch = false
		o.Material = Enum.Material.Neon
		o.Color = ORANGE
		o.Parent = workspace
		orbs[i] = { p = o, a = (i / 16) * math.pi * 2, h = 2 + math.random() * 10 }
	end
	local function clearOrbs()
		for _, o in ipairs(orbs) do o.p:Destroy() end
	end

	local t0 = os.clock()
	while true do
		if not alive() then clearOrbs() return false end
		local p = (os.clock() - t0) / CHARGE
		if p >= 1 then break end
		local center = root.Position
		for _, o in ipairs(orbs) do
			local r = 22 * (1 - p) ^ 1.5 + 1
			local a = o.a + p * 12
			o.p.Position = center + Vector3.new(math.cos(a) * r, o.h * (1 - p) - 1, math.sin(a) * r)
			o.p.Size = Vector3.one * (1.3 + p * 1.5)
		end
		RunService.Heartbeat:Wait()
	end
	clearOrbs()
	if not alive() then return false end

	-- Фаза 2: взрыв энергии, персонаж исчезает
	remote:FireClient(plr, "Flash")
	remote:FireClient(plr, "Shake", 0.8, 1.2)
	local gp = groundPos(root)
	ringFX(gp, 3, 40, 0.7, Color3.new(1, 1, 1))
	ringFX(gp, 3, 60, 1.0, ORANGE)
	ringFX(gp, 3, 85, 1.3, Color3.fromRGB(255, 70, 20))

	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.new(1, 1, 1)
	flash.Size = Vector3.one * 4
	flash.Position = root.Position
	flash.Parent = workspace
	TweenService:Create(flash, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * 45, Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.6)

	local pillar = Instance.new("Part")
	pillar.Shape = Enum.PartType.Cylinder
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = ORANGE
	pillar.Size = Vector3.new(120, 10, 10)
	pillar.CFrame = CFrame.new(gp + Vector3.new(0, 60, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pillar.Parent = workspace
	TweenService:Create(pillar, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(120, 0.5, 0.5), Transparency = 1,
	}):Play()
	Debris:AddItem(pillar, 1.3)

	local burst = Instance.new("Part")
	burst.Size = Vector3.one
	burst.Transparency = 1
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.Position = root.Position
	burst.Parent = workspace
	local be = makeFire(burst, 0, 10, 1.2, 45)
	be.SpreadAngle = Vector2.new(180, 180)
	be:Emit(150)
	Debris:AddItem(burst, 2)

	for _, tg in ipairs(findTargets(root.Position, T.BurstRadius, plr)) do
		if tg.root then
			local away = tg.root.Position - root.Position
			away = Vector3.new(away.X, 0, away.Z)
			away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
			tg.root.AssemblyLinearVelocity = away * 70 + Vector3.new(0, 30, 0)
		end
	end

	hideCharacter(char, true, 0.25)
	hl:Destroy()

	-- Фаза 3: появление дракона
	local form = (CONFIG.TransformForm == "Serpent") and buildSerpent(root) or buildDragon(root)
	st.form = form
	st.transformed = true
	local formStart = os.clock()
	st.formConn = RunService.Heartbeat:Connect(function()
		form.update(os.clock() - formStart)
	end)
	form.fade(true, 1.0)
	playSound("Roar", root)
	task.wait(1.0)

	-- Фаза 4: игрок снова может двигаться
	if not alive() then return false end
	root.Anchored = false
	hum.WalkSpeed = (st.baseSpeed or 16) * T.SpeedMult
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	st.locked = false

	task.delay(math.max(T.Duration - 2.0, 1), function()
		if st.token == tok and st.transformed then
			endTransform(plr, false)
		end
	end)
	return true
end

------------------------------------------------------------------------
-- ВВОД С КЛИЕНТА
------------------------------------------------------------------------
local function startCooldown(plr, skill)
	local st = getState(plr)
	local cd = CONFIG.Cooldowns[skill]
	st.cd[skill] = os.clock() + cd
	remote:FireClient(plr, "Cooldown", skill, cd)
end

remote.OnServerEvent:Connect(function(plr, skill, phase)
	if typeof(skill) ~= "number" or skill % 1 ~= 0 or skill < 1 or skill > 6 then return end
	if phase ~= "Down" and phase ~= "Up" then return end
	if CONFIG.RequireClass and plr:GetAttribute(CONFIG.ClassAttribute) ~= CONFIG.ClassName then return end

	local st = getState(plr)
	local root, hum = getRoot(plr)
	if not root or not hum or hum.Health <= 0 then return end

	if phase == "Up" then
		if skill == 3 then chargeRelease(plr) end
		return
	end

	if st.locked then return end
	if st.cd[skill] and os.clock() < st.cd[skill] then return end

	if skill == 3 then
		if not st.charge then chargeBegin(plr) end
		return
	end

	st.cd[skill] = math.huge -- защита от двойного нажатия
	task.spawn(function()
		local ok, res = pcall(SKILLS[skill], plr)
		if not ok then
			warn("[Dragon] skill " .. skill .. " error: " .. tostring(res))
			st.cd[skill] = nil
		elseif res == false then
			st.cd[skill] = nil
		else
			startCooldown(plr, skill)
		end
	end)
end)

------------------------------------------------------------------------
-- ИГРОКИ
------------------------------------------------------------------------
local function setupPlayer(plr)
	getState(plr)
	plr.CharacterAdded:Connect(function(char)
		resetState(plr)
		local hum = char:WaitForChild("Humanoid")
		hum.Died:Connect(function() resetState(plr) end)
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end

Players.PlayerRemoving:Connect(function(plr)
	resetState(plr)
	states[plr] = nil
end)
