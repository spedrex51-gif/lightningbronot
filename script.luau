-- Discord: lightningbronot
-- Connected Discord-GitHub
-- Roblox: lightningbronotni
--!strict

-- sentry turrets (server)
-- anything tagged "Turret" with a Stand, Swivel and Gun part starts shooting at humanoids in range.
-- it leads moving targets and accounts for bullet drop. the drones are just stuff to shoot at in the demo.
-- one heartbeat runs everything and all the moved parts go through a single BulkMoveTo

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local TURRET_TAG = "Turret"
local DRONE_TAG = "Drone"
local SHOOT_PLAYERS = true

local RANGE = 110
local SCAN_RATE = 0.2
local TURN_SPEED = 7
local MIN_PITCH, MAX_PITCH = math.rad(-20), math.rad(65)
local AIM_TOLERANCE = math.rad(3)
local FIRE_RATE = 0.3

local BOLT_SPEED = 170
local BOLT_LIFE = 2.5
local BOLT_DAMAGE = 10
local KNOCKBACK = 14
local GRAVITY = Vector3.new(0, -workspace.Gravity * 0.3, 0) -- lower than normal so the arc shows but isnt floaty
local AIM_PASSES = 3
local VEL_SMOOTHING = 10

local RECOIL_DIST = 0.7
local RECOIL_RETURN = 9
local FLASH_BRIGHTNESS = 8
local POOL_SIZE = 48
local DRONE_RESPAWN = 4

-- unused bolts sit way under the map, moving them is a lot cheaper than reparenting them
local PARK = CFrame.new(0, -10000, 0)
local FLASH_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SPARK_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type Target = {
	humanoid: Humanoid,
	root: BasePart,
	lastPos: Vector3,
	vel: Vector3,
}

type Bolt = {
	part: BasePart,
	pos: Vector3,
	vel: Vector3,
	age: number,
}

type Drone = {
	center: Vector3,
	radius: number,
	speed: number,
	phase: number,
}

local boltFolder = Instance.new("Folder")
boltFolder.Name = "SentryBolts"
boltFolder.Parent = workspace

local targets: { [Humanoid]: Target } = {}
local drones: { [Model]: Drone } = {}
local bolts: { Bolt } = {}
local pool: { BasePart } = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- 1 - e^(-rate*dt) so the smoothing looks the same at any framerate
local function smooth(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

-- keeps angles in [-pi, pi) so the turret turns the short way round
local function wrap(angle: number): number
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- time t where |r + v*t| = speed*t. squared out thats (v.v - s^2)t^2 + 2(r.v)t + r.r = 0
-- nil if theres no positive root (target is faster than the bolt and getting away)
local function interceptTime(r: Vector3, v: Vector3, speed: number): number?
	local a = v:Dot(v) - speed * speed
	local b = 2 * r:Dot(v)
	local c = r:Dot(r)
	local disc = b * b - 4 * a * c
	if disc < 0 then
		return nil
	end
	local sq = math.sqrt(disc)
	local t1 = (-b - sq) / (2 * a)
	local t2 = (-b + sq) / (2 * a)
	if t1 > 0 and (t2 <= 0 or t1 < t2) then
		return t1
	end
	return if t2 > 0 then t2 else nil
end

-- the quadratic gives a rough flight time, then each pass aims higher by the drop (0.5*g*t^2)
-- and works t out again for the longer path. 3 passes is plenty
local function getAimDir(origin: Vector3, target: Target): Vector3
	local pos = target.root.Position
	local t = interceptTime(pos - origin, target.vel, BOLT_SPEED) or (pos - origin).Magnitude / BOLT_SPEED
	local aimAt = pos
	for _ = 1, AIM_PASSES do
		aimAt = pos + target.vel * t - GRAVITY * (0.5 * t * t)
		t = (aimAt - origin).Magnitude / BOLT_SPEED
	end
	return (aimAt - origin).Unit
end

local function newBolt(): BasePart
	local part = Instance.new("Part")
	part.Name = "Bolt"
	part.Size = Vector3.new(0.3, 0.3, 2.4)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 170, 60)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = PARK
	part.Parent = boltFolder
	return part
end

local function fireBolt(origin: Vector3, dir: Vector3)
	table.insert(bolts, {
		part = table.remove(pool) or newBolt(),
		pos = origin,
		vel = dir * BOLT_SPEED,
		age = 0,
	})
end

local function spark(pos: Vector3, normal: Vector3)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * 0.6
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 220, 120)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.lookAt(pos, pos + normal)
	part.Parent = boltFolder
	TweenService:Create(part, SPARK_INFO, { Size = Vector3.one * 3, Transparency = 1 }):Play()
	Debris:AddItem(part, SPARK_INFO.Time)
end

-- TakeDamage instead of setting Health so forcefields still work. knockback gets multiplied by mass
-- so small and big crates get pushed the same amount
local function onHit(ray: RaycastResult, vel: Vector3)
	local part = ray.Instance
	local model = part:FindFirstAncestorOfClass("Model")
	local humanoid = if model then model:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid:TakeDamage(BOLT_DAMAGE)
	elseif not part.Anchored then
		part:ApplyImpulseAtPosition(vel.Unit * KNOCKBACK * part.AssemblyMass, ray.Position)
	end
	spark(ray.Position, ray.Normal)
end

-- moves each bolt by v*dt + 0.5*g*dt^2 and raycasts that step so fast bolts cant skip through walls
-- goes backwards so swapping the last bolt into a removed slot doesnt skip anything
local function stepBolts(dt: number, parts: { BasePart }, cframes: { CFrame })
	for i = #bolts, 1, -1 do
		local bolt = bolts[i]
		local step = bolt.vel * dt + GRAVITY * (0.5 * dt * dt)
		local ray = workspace:Raycast(bolt.pos, step, rayParams)
		bolt.age += dt
		if ray or bolt.age >= BOLT_LIFE then
			if ray then
				onHit(ray, bolt.vel)
			end
			bolt.part.CFrame = PARK
			table.insert(pool, bolt.part)
			bolts[i] = bolts[#bolts]
			bolts[#bolts] = nil
		else
			bolt.pos += step
			bolt.vel += GRAVITY * dt
			table.insert(parts, bolt.part)
			table.insert(cframes, CFrame.lookAt(bolt.pos, bolt.pos + bolt.vel))
		end
	end
end

local function track(humanoid: Humanoid, root: BasePart)
	targets[humanoid] = { humanoid = humanoid, root = root, lastPos = root.Position, vel = Vector3.zero }
	local function untrack()
		targets[humanoid] = nil
	end
	humanoid.Died:Once(untrack)
	humanoid.Destroying:Once(untrack)
end

-- velocity from the change in position instead of AssemblyLinearVelocity, the drones are anchored
-- and cframed so roblox just reports 0 for them
local function updateTargets(dt: number)
	-- got a frame with dt = 0 once, the divide made a NaN that stuck in vel and broke every turret
	if dt <= 0 then
		return
	end
	local alpha = smooth(VEL_SMOOTHING, dt)
	for _, target in targets do
		local pos = target.root.Position
		target.vel = target.vel:Lerp((pos - target.lastPos) / dt, alpha)
		target.lastPos = pos
	end
end

local Turret = {}
Turret.__index = Turret

type TurretData = {
	swivel: BasePart,
	gun: BasePart,
	light: PointLight,
	flash: Tween,
	pivot: CFrame,
	gunOffset: CFrame,
	range: number,
	fireRate: number,
	yaw: number,
	pitch: number,
	recoil: number,
	nextShot: number,
	nextScan: number,
	target: Target?,
}

type Turret = typeof(setmetatable({} :: TurretData, Turret))

local function getPart(model: Model, name: string): BasePart?
	local part = model:FindFirstChild(name)
	return if part and part:IsA("BasePart") then part else nil
end

function Turret.new(model: Model): Turret?
	local stand, swivel, gun = getPart(model, "Stand"), getPart(model, "Swivel"), getPart(model, "Gun")
	if not stand or not swivel or not gun then
		warn(`{model:GetFullName()} needs a Stand, Swivel and Gun part to work as a turret`)
		return nil
	end
	swivel.Anchored = true
	gun.Anchored = true

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 180, 80)
	light.Range = 14
	light.Brightness = 0
	light.Parent = gun

	-- pivot sits on top of the stand and copies its rotation, so the stand's front is yaw 0
	local pivot = stand.CFrame * CFrame.new(0, (stand.Size.Y + swivel.Size.Y) / 2, 0)

	return setmetatable({
		swivel = swivel,
		gun = gun,
		light = light,
		flash = TweenService:Create(light, FLASH_INFO, { Brightness = 0 }),
		pivot = pivot,
		gunOffset = CFrame.new(0, 0, -(swivel.Size.Z + gun.Size.Z) / 2),
		range = (model:GetAttribute("Range") :: number?) or RANGE,
		fireRate = (model:GetAttribute("FireInterval") :: number?) or FIRE_RATE,
		yaw = 0,
		pitch = 0,
		recoil = 0,
		nextShot = 0,
		nextScan = 0,
		target = nil,
	} :: TurretData, Turret)
end

function Turret.canSee(self: Turret, target: Target, offset: Vector3): boolean
	local ray = workspace:Raycast(self.pivot.Position, offset, rayParams)
	return ray == nil or ray.Instance:IsDescendantOf(target.root.Parent :: Instance)
end

-- checking targets[humanoid] == target also catches respawned players since they get a new table
function Turret.stillValid(self: Turret, target: Target): boolean
	if targets[target.humanoid] ~= target or target.humanoid.Health <= 0 then
		return false
	end
	local offset = target.root.Position - self.pivot.Position
	return offset.Magnitude <= self.range and self:canSee(target, offset)
end

-- closest target it can see. distance gets checked first so it only raycasts when it needs to
function Turret.findTarget(self: Turret): Target?
	local origin = self.pivot.Position
	local best: Target? = nil
	local bestDist = self.range
	for _, target in targets do
		local offset = target.root.Position - origin
		local dist = offset.Magnitude
		if dist < bestDist and target.humanoid.Health > 0 and self:canSee(target, offset) then
			best, bestDist = target, dist
		end
	end
	return best
end

-- turns the world direction into yaw/pitch in the pivot's local space so tilted turrets still work
-- atan2(-x, -z) because forward is -Z in roblox
function Turret.aim(self: Turret, dir: Vector3, dt: number)
	if dir ~= dir then -- NaN ~= NaN, dont let a bad direction get into yaw/pitch
		return
	end
	local localDir = self.pivot:VectorToObjectSpace(dir)
	local yaw = math.atan2(-localDir.X, -localDir.Z)
	local pitch = math.clamp(math.atan2(localDir.Y, math.sqrt(localDir.X ^ 2 + localDir.Z ^ 2)), MIN_PITCH, MAX_PITCH)
	local alpha = smooth(TURN_SPEED, dt)
	self.yaw = wrap(self.yaw + wrap(yaw - self.yaw) * alpha)
	self.pitch += (pitch - self.pitch) * alpha
end

function Turret.shoot(self: Turret, gunCF: CFrame, now: number)
	self.nextShot = now + self.fireRate
	self.recoil = 1
	local muzzle = gunCF * CFrame.new(0, 0, -self.gun.Size.Z / 2)
	fireBolt(muzzle.Position, muzzle.LookVector)
	self.light.Brightness = FLASH_BRIGHTNESS
	self.flash:Play()
end

-- only rescans every SCAN_RATE and keeps its target while its still valid so it doesnt flick between
-- two. parts get queued for the BulkMoveTo, and it wont shoot until the gun is actually lined up
function Turret.update(self: Turret, dt: number, now: number, parts: { BasePart }, cframes: { CFrame })
	if now >= self.nextScan then
		self.nextScan = now + SCAN_RATE
		local current = self.target
		if not (current and self:stillValid(current)) then
			self.target = self:findTarget()
		end
	end

	local target = self.target
	local dir: Vector3
	if target then
		dir = getAimDir(self.pivot.Position, target)
	else
		local sweep = math.sin(now * 0.6) * math.rad(50) -- idle back and forth
		dir = self.pivot:VectorToWorldSpace(Vector3.new(-math.sin(sweep), 0, -math.cos(sweep)))
	end
	self:aim(dir, dt)

	self.recoil *= math.exp(-RECOIL_RETURN * dt)
	local swivelCF = self.pivot * CFrame.fromEulerAnglesYXZ(self.pitch, self.yaw, 0)
	local gunCF = swivelCF * self.gunOffset * CFrame.new(0, 0, self.recoil * RECOIL_DIST)
	table.insert(parts, self.swivel)
	table.insert(cframes, swivelCF)
	table.insert(parts, self.gun)
	table.insert(cframes, gunCF)

	if target and now >= self.nextShot then
		local off = math.acos(math.clamp(gunCF.LookVector:Dot(dir), -1, 1))
		if off <= AIM_TOLERANCE then
			self:shoot(gunCF, now)
		end
	end
end

function Turret.destroy(self: Turret)
	self.flash:Destroy()
	self.light:Destroy()
end

local turrets: { [Model]: Turret } = {}

-- turrets are left out of raycasts so they dont block each other. only rebuilt when the turret list changes
local function updateFilter()
	local list: { Instance } = { boltFolder }
	for model in turrets do
		table.insert(list, model)
	end
	rayParams.FilterDescendantsInstances = list
end

local function addTurret(instance: Instance)
	if not instance:IsA("Model") or turrets[instance] then
		return
	end
	local turret = Turret.new(instance)
	if turret then
		turrets[instance] = turret
		updateFilter()
	end
end

local function removeTurret(instance: Instance)
	local model = instance :: Model
	local turret = turrets[model]
	if turret then
		turret:destroy()
		turrets[model] = nil
		updateFilter()
	end
end

-- center gets saved as an attribute before cloning so the respawned drone flies the same path
-- when it dies the parts get unanchored so it actually falls, then a fresh clone takes its place
local function addDrone(instance: Instance)
	local humanoid = instance:FindFirstChildOfClass("Humanoid")
	if not instance:IsA("Model") or not humanoid or not instance.PrimaryPart then
		return
	end
	local model = instance
	local root = model.PrimaryPart :: BasePart
	local center = (model:GetAttribute("Center") :: Vector3?) or model:GetPivot().Position
	model:SetAttribute("Center", center)
	local copy = model:Clone()
	local parent = model.Parent

	drones[model] = {
		center = center,
		radius = (model:GetAttribute("Radius") :: number?) or 30,
		speed = (model:GetAttribute("Speed") :: number?) or 0.4,
		phase = (model:GetAttribute("Phase") :: number?) or 0,
	}
	track(humanoid, root)

	humanoid.Died:Once(function()
		drones[model] = nil
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = false
				part.Color = Color3.fromRGB(40, 40, 40)
				part.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))
			end
		end
		task.delay(DRONE_RESPAWN, function()
			model:Destroy()
			copy.Parent = parent
		end)
	end)
end

-- figure 8 (x = sin t, z = sin t cos t) with a bit of bob. faces along the derivative of that,
-- which is never zero so lookAt always has a direction
local function moveDrones(now: number)
	for model, drone in drones do
		local t = now * drone.speed + drone.phase
		local pos = drone.center + Vector3.new(math.sin(t), 0.15 * math.sin(3 * t), math.sin(t) * math.cos(t)) * drone.radius
		local facing = Vector3.new(math.cos(t), 0.45 * math.cos(3 * t), math.cos(2 * t))
		model:PivotTo(CFrame.lookAt(pos, pos + facing))
	end
end

local function onCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	track(humanoid, root)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

for _ = 1, POOL_SIZE do
	table.insert(pool, newBolt())
end
updateFilter()

CollectionService:GetInstanceAddedSignal(TURRET_TAG):Connect(addTurret)
CollectionService:GetInstanceRemovedSignal(TURRET_TAG):Connect(removeTurret)
for _, turret in CollectionService:GetTagged(TURRET_TAG) do
	addTurret(turret)
end

CollectionService:GetInstanceAddedSignal(DRONE_TAG):Connect(addDrone)
for _, drone in CollectionService:GetTagged(DRONE_TAG) do
	addDrone(drone)
end

if SHOOT_PLAYERS then
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

-- reused every frame so it isnt making new tables 60 times a second
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

-- order matters here: drones move, then velocities get sampled, then turrets aim, then bolts step
RunService.Heartbeat:Connect(function(dt: number)
	local now = os.clock()
	moveDrones(now)
	updateTargets(dt)
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, turret in turrets do
		turret:update(dt, now, moveParts, moveCFrames)
	end
	stepBolts(dt, moveParts, moveCFrames)
	workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end)
