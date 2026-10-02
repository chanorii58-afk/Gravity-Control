--[[
	GRAVITY CONTROL  v1   (made for Delta / mobile, works on PC too)

	A floating gravity bubble. Tap it and it opens into 4 arrow keys:

	    UP     = gravity pulls you toward what you are FACING
	             (face a wall + press UP and that wall becomes your floor,
	              your old floor becomes the wall behind you)
	    DOWN   = gravity pulls you backwards
	    LEFT   = gravity pulls you to your left
	    RIGHT  = gravity pulls you to your right

	Every press turns "down" from where you are looking, so pressing UP twice flips you upside down,
	LEFT / RIGHT puts you sideways. The "RESET" pill (shows while gravity is changed) brings normal
	gravity back, and so does respawning. Tap the bubble again to close the arrows (drag it to move it).

	It is NOT the same as Spider Wall Walk: Spider Wall Walk sticks you to whatever surface you walk on
	by itself, Gravity Control only changes gravity when YOU press an arrow. If both scripts are loaded,
	turning one on turns the other one off.

	Tweak things in CONFIG below.
]]

------------------------------------------------------------------------------------------------------
-- SERVICES / SETUP
------------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait()
	LocalPlayer = Players.LocalPlayer
end

local env = (getgenv and getgenv()) or _G
if env.__GravityControl then
	pcall(function()
		env.__GravityControl.Destroy()
	end)
	env.__GravityControl = nil
end

local CONFIG = {
	CameraSensitivity = 1.0, -- 1 = normal Roblox feel. 0.7 = slower, 1.3 = faster
	CameraSmoothing = 30, -- lower = smoother / floatier, higher = more direct (20-40 is good)
	JumpMultiplier = 1.2, -- jump strength while gravity is changed
	ButtonSize = 50, -- size of the floating gravity bubble (pixels)
	TurnSpeed = 7, -- how fast you + the camera swing around to the new gravity (lower = slower, floatier)
	MaxFallSpeed = 160, -- speed limit while falling toward the new "down" (stops you tunnelling through walls)
	SnapToSurface = true, -- true = if a wall/floor is in the new gravity direction, line up with it perfectly
	SnapDistance = 80, -- how far (studs) to look for that surface
	SnapAngle = 50, -- the surface may be tilted this many degrees and still be snapped to
	AutoCollapse = 8, -- seconds until the arrows close by themselves (0 = never)
	DefaultZoom = 12.5, -- camera distance if it can't be read from the game's camera
}

local UserGameSettings
pcall(function()
	UserGameSettings = UserSettings():GetService("UserGameSettings")
end)

local GRAV_BIND = "GravCtl_Gravity"
local CAM_BIND = "GravCtl_Camera"

------------------------------------------------------------------------------------------------------
-- MATH / SHARED HELPERS
------------------------------------------------------------------------------------------------------
local ZERO = Vector3.new(0, 0, 0)
local UNIT_Y = Vector3.new(0, 1, 0)
local IDENTITY = CFrame.new()
local PI2 = math.pi * 2

local function clamp(x, a, b)
	if x < a then
		return a
	elseif x > b then
		return b
	end
	return x
end

local function perpendicular(v)
	local a = (math.abs(v.X) < 0.9) and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1)
	return v:Cross(a).Unit
end

-- rotation that takes unit vector u onto unit vector v (axis is used when they point opposite ways)
local function rotationBetween(u, v, axis)
	local dot = u:Dot(v)
	if dot < -0.99999 then
		return CFrame.fromAxisAngle(axis or perpendicular(u), math.pi)
	end
	local c = u:Cross(v)
	local w = 1 + dot
	local len = math.sqrt(c:Dot(c) + w * w)
	return CFrame.new(0, 0, 0, c.X / len, c.Y / len, c.Z / len, w / len)
end

local function makeParams(list)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.IgnoreWater = true
	p.FilterDescendantsInstances = list
	pcall(function()
		p.RespectCanCollide = true
	end)
	return p
end

-- ray params that ignore every player's character (used for the surface snap + camera collision)
local worldParams = makeParams({})
local charListTime = 0
local function syncWorldParams()
	local now = os.clock()
	if now - charListTime > 0.5 then
		charListTime = now
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				list[#list + 1] = p.Character
			end
		end
		worldParams.FilterDescendantsInstances = list
	end
end

-- which way is "down" after pressing an arrow? (relative to where you are looking)
local function shiftedDown(dirName, up, look, hrpLook)
	local f = look - up * look:Dot(up)
	if f.Magnitude < 0.3 then
		f = hrpLook - up * hrpLook:Dot(up)
	end
	if f.Magnitude < 0.05 then
		f = perpendicular(up)
	end
	f = f.Unit
	local left = up:Cross(f)
	if dirName == "Up" then
		return f
	elseif dirName == "Down" then
		return -f
	elseif dirName == "Left" then
		return left
	end
	return -left
end

------------------------------------------------------------------------------------------------------
-- CONTROLS  (reads the game's own thumbstick / keyboard so nothing is duplicated)
------------------------------------------------------------------------------------------------------
local Controls = { controls = nil, jumpUntil = 0, conns = {} }

function Controls.Init()
	table.insert(
		Controls.conns,
		UserInputService.JumpRequest:Connect(function()
			Controls.jumpUntil = os.clock() + 0.15
		end)
	)
	task.spawn(function()
		pcall(function()
			local scripts = LocalPlayer:WaitForChild("PlayerScripts", 8)
			local pm = scripts and scripts:WaitForChild("PlayerModule", 8)
			if pm then
				Controls.controls = require(pm):GetControls()
			end
		end)
	end)
end

function Controls.Destroy()
	for _, c in ipairs(Controls.conns) do
		c:Disconnect()
	end
	Controls.conns = {}
end

-- Fallback: turn Humanoid.MoveDirection back into "camera relative" input
local function moveFromHumanoid(hum, camCF)
	local md = hum.MoveDirection
	if md.Magnitude < 0.05 then
		return ZERO
	end
	local _, _, _, R00, R01, R02, _, _, R12, _, _, R22 = camCF:GetComponents()
	local c, s
	if R12 < 1 and R12 > -1 then
		c, s = R22, R02
	else
		c, s = R00, -R01 * math.sign(R12)
	end
	local n = math.sqrt(c * c + s * s)
	if n < 1e-4 then
		return ZERO
	end
	return Vector3.new((c * md.X - s * md.Z) / n, 0, (s * md.X + c * md.Z) / n)
end

function Controls.GetMove(hum, camCF)
	local c = Controls.controls
	if c then
		local ok, v = pcall(c.GetMoveVector, c)
		if ok and typeof(v) == "Vector3" and v.Magnitude > 0.01 then
			return v
		end
	end
	return moveFromHumanoid(hum, camCF)
end

function Controls.IsJumping(hum)
	if os.clock() < Controls.jumpUntil then
		return true
	end
	if hum.Jump then
		return true
	end
	if not UserInputService:GetFocusedTextBox() and UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		return true
	end
	return false
end

------------------------------------------------------------------------------------------------------
-- CAMERA  (turns with your gravity, normal sensitivity, never flips or inverts)
------------------------------------------------------------------------------------------------------
local TOUCH_SENS = Vector2.new(0.00945 * math.pi, 0.003375 * math.pi) -- Roblox default touch feel
local MOUSE_SENS = Vector2.new(0.002 * math.pi, 0.0015 * math.pi) -- Roblox default mouse feel
local MAX_PITCH = math.rad(80)

local CameraCtl = {}
CameraCtl.__index = CameraCtl

function CameraCtl.new()
	local self = setmetatable({}, CameraCtl)
	self.active = false
	self.releasing = false
	self.firstPerson = false
	self.look = Vector3.new(0, 0, -1)
	self.prevUp = UNIT_Y
	self.zoom = 12.5
	self.curDist = 12.5
	self.pendYaw = 0
	self.pendPitch = 0
	self.conns = {}
	self.touches = {}
	return self
end

local function zoomLimits()
	local lo = math.max(LocalPlayer.CameraMinZoomDistance, 0.5)
	local hi = math.max(LocalPlayer.CameraMaxZoomDistance, lo)
	return lo, hi
end

-- where the camera WILL be looking once it has finished swinging around to targetUp
function CameraCtl:PredictLook(targetUp)
	if not self.active or self.releasing then
		return nil
	end
	local prevUp = self.prevUp
	local right = self.look:Cross(prevUp)
	local axis = (right.Magnitude > 1e-4) and right.Unit or perpendicular(prevUp)
	return (rotationBetween(prevUp, targetUp, axis) * self.look).Unit
end

function CameraCtl:InMoveArea(pos)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local tg = pg and pg:FindFirstChild("TouchGui")
	if tg then
		local tcf = tg:FindFirstChild("TouchControlFrame")
		local frame = tcf and (tcf:FindFirstChild("DynamicThumbstickFrame") or tcf:FindFirstChild("ThumbstickFrame"))
		if frame and frame:IsA("GuiObject") and frame.Visible then
			local ap, as = frame.AbsolutePosition, frame.AbsoluteSize
			return pos.X >= ap.X and pos.Y >= ap.Y and pos.X <= ap.X + as.X and pos.Y <= ap.Y + as.Y
		end
		return false
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	local vs = cam.ViewportSize
	if vs.X < vs.Y then
		return pos.Y > vs.Y * 0.6
	end
	return pos.X < vs.X * 0.4 and pos.Y > vs.Y / 3
end

function CameraCtl:AddRotation(delta, sens)
	local invert = 1
	if UserGameSettings then
		pcall(function()
			invert = UserGameSettings:GetCameraYInvertValue()
		end)
	end
	local k = CONFIG.CameraSensitivity
	self.pendYaw = self.pendYaw + delta.X * sens.X * k
	self.pendPitch = self.pendPitch - delta.Y * sens.Y * k * invert
end

function CameraCtl:Pinch()
	local pts = {}
	for _, p in pairs(self.touches) do
		pts[#pts + 1] = p
	end
	if #pts < 2 then
		return
	end
	local d = (pts[1] - pts[2]).Magnitude
	if self.pinchDist then
		local lo, hi = zoomLimits()
		local scale = clamp(d / math.max(self.pinchDist, 0.01), 0.1, 10)
		self.zoom = clamp(self.pinchZoom / scale, lo, hi)
	else
		self.pinchDist = d
		self.pinchZoom = self.zoom
	end
end

function CameraCtl:ConnectInput()
	self:DisconnectInput()
	local conns = {}
	self.conns = conns
	self.touches = {}
	self.moveTouch = nil
	self.pinchDist = nil
	self.rmb = false

	conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			if processed then
				return
			end
			local pos = input.Position
			if not self.moveTouch and self:InMoveArea(pos) then
				self.moveTouch = input
				return
			end
			if self.isBlocked and self.isBlocked(pos) then
				return
			end
			self.touches[input] = Vector2.new(pos.X, pos.Y)
			self.pinchDist = nil
		elseif t == Enum.UserInputType.MouseButton2 then
			if processed then
				return
			end
			self.rmb = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)

	conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			local last = self.touches[input]
			if not last then
				return
			end
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			local delta = pos - last
			self.touches[input] = pos
			local n = 0
			for _ in pairs(self.touches) do
				n = n + 1
			end
			if n == 1 then
				self:AddRotation(delta, TOUCH_SENS)
			elseif n == 2 then
				self:Pinch()
			end
		elseif t == Enum.UserInputType.MouseMovement then
			if self.rmb then
				self:AddRotation(Vector2.new(input.Delta.X, input.Delta.Y), MOUSE_SENS)
			end
		elseif t == Enum.UserInputType.MouseWheel then
			if not processed then
				local lo, hi = zoomLimits()
				self.zoom = clamp(self.zoom * (1 - input.Position.Z * 0.15), lo, hi)
			end
		end
	end)

	conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
		if input == self.moveTouch then
			self.moveTouch = nil
		end
		if self.touches[input] then
			self.touches[input] = nil
			self.pinchDist = nil
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self.rmb = false
			if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end
	end)
end

function CameraCtl:DisconnectInput()
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	self.touches = {}
	if self.rmb then
		self.rmb = false
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end
end

function CameraCtl:SetFirstPerson(fp)
	if fp == self.firstPerson then
		return
	end
	self.firstPerson = fp
	local char = self.character
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and not d:FindFirstAncestorWhichIsA("Tool") then
			d.LocalTransparencyModifier = fp and 1 or 0
		end
	end
end

function CameraCtl:Start(getUp, getFocus, isBlocked, character)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if self.active then
		self:Finish()
	end
	self.active = true
	self.releasing = false
	self.getUp = getUp
	self.getFocus = getFocus
	self.isBlocked = isBlocked
	self.character = character
	self.firstPerson = false
	self.pendYaw, self.pendPitch = 0, 0

	local up = getUp()
	self.prevUp = up
	self.look = cam.CFrame.LookVector
	local lo, hi = zoomLimits()
	local dist = (cam.CFrame.Position - getFocus(up)).Magnitude
	if dist ~= dist or dist < 0.5 then
		dist = CONFIG.DefaultZoom
	end
	self.zoom = clamp(dist, lo, hi)
	self.curDist = self.zoom

	self.savedType = cam.CameraType
	cam.CameraType = Enum.CameraType.Scriptable

	pcall(function()
		RunService:UnbindFromRenderStep(CAM_BIND)
	end)
	RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
		local ok, err = pcall(self.Step, self, dt)
		if not ok then
			self.errors = (self.errors or 0) + 1
			if self.errors == 1 then
				warn("[GravityControl] camera error: " .. tostring(err))
			end
		end
	end)
	self:ConnectInput()
end

-- smooth hand-back: the view rolls back upright over a moment, then the game's camera takes over again
function CameraCtl:Stop(instant)
	if not self.active then
		return
	end
	self:DisconnectInput()
	if instant then
		self:Finish()
		return
	end
	self.releasing = true
	self.releaseTime = 0
	self.relUp = self.prevUp
end

function CameraCtl:Finish()
	pcall(function()
		RunService:UnbindFromRenderStep(CAM_BIND)
	end)
	self:DisconnectInput()
	self:SetFirstPerson(false)
	local cam = Workspace.CurrentCamera
	if cam and self.active then
		cam.CameraType = self.savedType or Enum.CameraType.Custom
	end
	self.active = false
	self.releasing = false
end

function CameraCtl:ResolveDistance(focus, look, dt)
	local lo, hi = zoomLimits()
	self.zoom = clamp(self.zoom, lo, hi)
	local want = self.zoom
	local obs = want
	if want > 1.1 then
		syncWorldParams()
		local res = Workspace:Raycast(focus, -look * (want + 0.4), worldParams)
		if res then
			obs = math.max(res.Distance - 0.4, 0.6)
		end
	end
	if obs < self.curDist then
		self.curDist = obs
	else
		self.curDist = self.curDist + (math.min(want, obs) - self.curDist) * (1 - math.exp(-dt * 10))
	end
	return self.curDist
end

function CameraCtl:Step(dt)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	dt = math.min(dt, 0.1)
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local up
	local finishing = false
	if self.releasing then
		self.releaseTime = self.releaseTime + dt
		local axis = self.look:Cross(self.relUp)
		axis = (axis.Magnitude > 1e-4) and axis.Unit or perpendicular(self.relUp)
		local rot = IDENTITY:Lerp(rotationBetween(self.relUp, UNIT_Y, axis), 1 - math.exp(-dt * 9))
		self.relUp = (rot * self.relUp).Unit
		up = self.relUp
		if (up - UNIT_Y).Magnitude < 0.02 or self.releaseTime > 0.8 then
			up = UNIT_Y
			finishing = true
		end
	else
		up = self.getUp()
	end

	-- carry the view along while "up" changes (this is what stops it from flipping / inverting)
	local prevUp = self.prevUp
	if (up - prevUp).Magnitude > 1e-6 then
		local right = self.look:Cross(prevUp)
		local axis = (right.Magnitude > 1e-4) and right.Unit or perpendicular(prevUp)
		self.look = (rotationBetween(prevUp, up, axis) * self.look).Unit
		self.prevUp = up
	end

	-- smoothed input
	local a = 1 - math.exp(-dt * CONFIG.CameraSmoothing)
	local dyaw = self.pendYaw * a
	local dpitch = self.pendPitch * a
	self.pendYaw = self.pendYaw - dyaw
	self.pendPitch = self.pendPitch - dpitch
	dyaw = clamp(dyaw, -0.5, 0.5)
	dpitch = clamp(dpitch, -0.4, 0.4)

	local look = self.look
	if dyaw ~= 0 then
		look = CFrame.fromAxisAngle(up, -dyaw) * look
	end
	local right = look:Cross(up)
	right = (right.Magnitude > 1e-4) and right.Unit or perpendicular(up)
	local pitch = math.asin(clamp(look:Dot(up), -1, 1))
	local newPitch = clamp(pitch + dpitch, -MAX_PITCH, MAX_PITCH)
	if newPitch ~= pitch then
		look = CFrame.fromAxisAngle(right, newPitch - pitch) * look
	end
	look = look.Unit
	self.look = look

	local focus = self.getFocus(up)
	right = look:Cross(up).Unit
	local camUp = right:Cross(look)
	local dist = self:ResolveDistance(focus, look, dt)
	self:SetFirstPerson(dist < 1.1)
	cam.CFrame = CFrame.fromMatrix(focus - look * dist, right, camUp, -look)
	cam.Focus = CFrame.new(focus)

	if finishing then
		self:Finish()
	end
end

------------------------------------------------------------------------------------------------------
-- ANIMATION + SOUND  (PlatformStand switches the game's own animations off, so we drive them -
-- using YOUR animation pack from the character's Animate script)
------------------------------------------------------------------------------------------------------
-- Default Roblox animations (only used if the game's Animate script has none)
local DEFAULT_PACK = {
	R15 = {
		idle = { { 507766388, 9 }, { 507766666, 1 }, { 507766951, 1 } },
		walk = { { 507777826, 1 } },
		run = { { 507767714, 1 } },
		jump = { { 507765000, 1 } },
		fall = { { 507767968, 1 } },
	},
	R6 = {
		idle = { { 180435571, 9 }, { 180435792, 1 } },
		walk = { { 180426354, 1 } },
		jump = { { 125750702, 1 } },
		fall = { { 180436148, 1 } },
	},
}

local function readPack(character, rig)
	local pack = {}
	local animate = character:FindFirstChild("Animate")
	for _, name in ipairs({ "idle", "walk", "run", "jump", "fall" }) do
		local list = {}
		local folder = animate and animate:FindFirstChild(name)
		if folder then
			local kids = folder:GetChildren()
			table.sort(kids, function(x, y)
				return x.Name < y.Name
			end)
			for _, a in ipairs(kids) do
				if a:IsA("Animation") and a.AnimationId ~= "" then
					local w = 1
					local wo = a:FindFirstChild("Weight")
					if wo and (wo:IsA("NumberValue") or wo:IsA("IntValue")) then
						w = wo.Value
					end
					list[#list + 1] = { a.AnimationId, w }
				end
			end
		end
		if #list == 0 then
			list = DEFAULT_PACK[rig][name] or {}
		end
		pack[name] = list
	end
	return pack
end

local AnimCtl = {}
AnimCtl.__index = AnimCtl

function AnimCtl.new(humanoid, character)
	local self = setmetatable({}, AnimCtl)
	self.rig = (humanoid.RigType == Enum.HumanoidRigType.R6) and "R6" or "R15"
	self.state = nil
	self.dead = false
	self.lastMove = nil
	self.idleTrack = nil
	self.idle = {}
	self.all = {}
	self.conns = {}

	local loader = humanoid:FindFirstChildOfClass("Animator") or humanoid
	local pack = readPack(character, self.rig)

	local function load(entry, looped)
		if not entry then
			return nil
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = (type(entry[1]) == "number") and ("rbxassetid://" .. entry[1]) or entry[1]
		local ok, track = pcall(function()
			return loader:LoadAnimation(anim)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = looped
			self.all[#self.all + 1] = track
			return track
		end
		return nil
	end

	local multi = #pack.idle > 1
	for _, e in ipairs(pack.idle) do
		local t = load(e, not multi)
		if t then
			self.idle[#self.idle + 1] = { track = t, weight = e[2] }
			if multi then
				-- like the default Animate script: when one idle finishes, pick the next one
				table.insert(
					self.conns,
					t.Ended:Connect(function()
						if not self.dead and self.state == "idle" and self.idleTrack == t then
							self:PlayIdle()
						end
					end)
				)
			end
		end
	end
	self.walk = load(pack.walk[1], true)
	self.run = (self.rig == "R15") and load(pack.run[1], true) or nil
	self.jump = load(pack.jump[1], false)
	self.fall = load(pack.fall[1], true)
	return self
end

function AnimCtl:PlayIdle()
	local set = self.idle
	if #set == 0 then
		return
	end
	local total = 0
	for _, e in ipairs(set) do
		total = total + e.weight
	end
	local roll = math.random() * total
	local pick = set[1]
	for _, e in ipairs(set) do
		roll = roll - e.weight
		if roll <= 0 then
			pick = e
			break
		end
	end
	self.idleTrack = pick.track
	pick.track:Play(0.15)
end

local function stopTrack(t, fade)
	if t then
		t:Stop(fade)
	end
end

function AnimCtl:StopState(state)
	if state == "idle" then
		for _, e in ipairs(self.idle) do
			e.track:Stop(0.15)
		end
	elseif state == "move" then
		stopTrack(self.walk, 0.15)
		stopTrack(self.run, 0.15)
	elseif state == "jump" then
		stopTrack(self.jump, 0.1)
	elseif state == "fall" then
		stopTrack(self.fall, 0.15)
	end
end

function AnimCtl:StartState(state)
	if state == "idle" then
		self:PlayIdle()
	elseif state == "move" then
		if self.walk then
			self.walk:Play(0.15)
		end
		if self.run then
			self.run:Play(0.15)
		end
	elseif state == "jump" then
		if self.jump then
			self.jump:Play(0.1)
		end
	elseif state == "fall" then
		if self.fall then
			self.fall:Play(0.2)
		end
	end
end

function AnimCtl:UpdateMove(speed)
	local walk, run = self.walk, self.run
	if self.rig == "R6" or not (walk and run) then
		local only = walk or run
		if only then
			local sp = (self.rig == "R6") and (speed / 14.5) or (speed / 16 * 1.25)
			if not self.lastMove or math.abs(sp - self.lastMove) > 0.03 then
				only:AdjustSpeed(sp)
				self.lastMove = sp
			end
		end
		return
	end
	-- R15: blend your walk and run animations by speed (same way the default Animate script does)
	local rs = speed / 16 * 1.25
	if self.lastMove and math.abs(rs - self.lastMove) < 0.02 then
		return
	end
	self.lastMove = rs
	local eps = 0.0001
	local ww, rw
	if rs < 0.33 then
		ww, rw = 1, eps
	elseif rs < 0.66 then
		local w = (rs - 0.33) / 0.33
		ww, rw = 1 - w + eps, w + eps
	else
		ww, rw = eps, 1
	end
	walk:AdjustWeight(ww)
	run:AdjustWeight(rw)
	walk:AdjustSpeed(rs)
	run:AdjustSpeed(rs)
end

function AnimCtl:Set(state, speed)
	if state ~= self.state then
		local old = self.state
		self.state = state
		self.lastMove = nil
		if old then
			self:StopState(old)
		end
		self:StartState(state)
	end
	if state == "move" then
		self:UpdateMove(speed or 0)
	end
end

function AnimCtl:Destroy()
	self.dead = true
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	for _, t in ipairs(self.all) do
		pcall(function()
			t:Stop(0.1)
			t:Destroy()
		end)
	end
	self.all = {}
end

local SoundCtl = {}
SoundCtl.__index = SoundCtl

function SoundCtl.new(hrp)
	local self = setmetatable({}, SoundCtl)
	local run = hrp:FindFirstChild("Running")
	if not (run and run:IsA("Sound")) then
		run = Instance.new("Sound")
		run.Name = "GC_Running"
		run.SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"
		run.Looped = true
		run.Pitch = 1.85
		run.Volume = 0.65
		run.RollOffMaxDistance = 150
		run.Parent = hrp
		self.own = run
	end
	self.run = run
	local jump = hrp:FindFirstChild("Jumping")
	self.jump = (jump and jump:IsA("Sound")) and jump or nil
	return self
end

function SoundCtl:SetRunning(on)
	if self.run.Playing ~= on then
		self.run.Playing = on
	end
end

function SoundCtl:Jump()
	if self.jump then
		self.jump.TimePosition = 0
		self.jump.Playing = true
	end
end

function SoundCtl:Destroy()
	pcall(function()
		self.run.Playing = false
		if self.own then
			self.own:Destroy()
		end
	end)
end

------------------------------------------------------------------------------------------------------
-- GRAVITY CONTROLLER  (gravity only changes when YOU press an arrow)
------------------------------------------------------------------------------------------------------
local WALK_FORCE = 200 / 3

local Gravity = {}
Gravity.__index = Gravity

function Gravity.new(character, humanoid, hrp, hooks)
	local self = setmetatable({}, Gravity)
	self.Character = character
	self.Humanoid = humanoid
	self.HRP = hrp
	self.Hooks = hooks or {}
	self.TargetUp = UNIT_Y -- real gravity direction (physics switches at once)
	self.GravityUp = UNIT_Y -- smoothed version (body + camera swing around to it)
	self.AutoRelease = false
	self.Releasing = false
	self.Jumped = false
	self.JumpTick = 0
	self.Conns = {}
	self.Destroyed = false
	self.LastPart = nil
	self.LastPartCFrame = nil

	-- clean up leftovers from an earlier run
	for _, inst in ipairs(character:GetDescendants()) do
		if string.sub(inst.Name, 1, 3) == "GC_" then
			inst:Destroy()
		end
	end

	self.GroundParams = makeParams({ character })

	-- how high the root part sits above the ground (works for R6 / R15 / scaled avatars)
	local height
	local res = Workspace:Raycast(hrp.Position, Vector3.new(0, -12, 0), self.GroundParams)
	if res and res.Distance > 1.5 and res.Distance < 9 then
		height = res.Distance
	elseif humanoid.RigType == Enum.HumanoidRigType.R6 then
		height = hrp.Size.Y / 2 + 2
	else
		height = hrp.Size.Y / 2 + humanoid.HipHeight
	end
	local radius = clamp(height / 3, 0.6, 3)
	local drop = height - radius + 0.05
	self.Radius = radius

	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		self.HeadOffset = 1.5
	elseif humanoid.AutomaticScalingEnabled then
		self.HeadOffset = 1.5 + (hrp.Size.Y / 2 - 1)
	else
		self.HeadOffset = 2
	end

	-- ball under the feet (this is what actually touches the surface)
	local collider = Instance.new("Part")
	collider.Name = "GC_Collider"
	collider.Shape = Enum.PartType.Ball
	collider.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	collider.Transparency = 1
	collider.CanCollide = true
	collider.CanQuery = false
	collider.CanTouch = false
	collider.Massless = true
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
	pcall(function()
		collider.CollisionGroup = hrp.CollisionGroup
	end)
	collider.CFrame = hrp.CFrame * CFrame.new(0, -drop, 0)
	collider.Parent = character
	local weld = Instance.new("Weld")
	weld.Name = "GC_Weld"
	weld.Part0 = hrp
	weld.Part1 = collider
	weld.C0 = CFrame.new(0, -drop, 0)
	weld.Parent = collider
	self.Collider = collider

	local att = Instance.new("Attachment")
	att.Name = "GC_Attachment"
	att.Parent = hrp
	self.Attachment = att

	local vf = Instance.new("VectorForce")
	vf.Name = "GC_Force"
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = ZERO
	vf.Parent = hrp
	self.VForce = vf

	local ao = Instance.new("AlignOrientation")
	ao.Name = "GC_Align"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.MaxTorque = math.huge
	ao.MaxAngularVelocity = math.huge
	ao.Responsiveness = 50
	ao.CFrame = hrp.CFrame - hrp.CFrame.Position
	ao.Parent = hrp
	self.Align = ao

	self.SavedPlatformStand = humanoid.PlatformStand
	humanoid.PlatformStand = true

	self.Anim = AnimCtl.new(humanoid, character)
	self.Sound = SoundCtl.new(hrp)

	pcall(function()
		RunService:UnbindFromRenderStep(GRAV_BIND)
	end)
	RunService:BindToRenderStep(GRAV_BIND, Enum.RenderPriority.Input.Value + 1, function(dt)
		local ok, err = pcall(self.Step, self, dt)
		if not ok then
			self.StepErrors = (self.StepErrors or 0) + 1
			if self.StepErrors == 1 then
				warn("[GravityControl] step error: " .. tostring(err))
			end
		end
	end)
	table.insert(
		self.Conns,
		RunService.Heartbeat:Connect(function()
			pcall(self.OnHeartbeat, self)
		end)
	)
	table.insert(
		self.Conns,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:Destroy()
			end
		end)
	)
	return self
end

function Gravity:SetTargetUp(up)
	self.TargetUp = up.Unit
	self.AutoRelease = self.TargetUp:Dot(UNIT_Y) > 0.99995 -- back to normal gravity -> hand control back
	self.Releasing = false
end

function Gravity:GetFocus(up)
	local hrp = self.HRP
	return hrp.Position + up * self.HeadOffset + hrp.CFrame:VectorToWorldSpace(self.Humanoid.CameraOffset)
end

function Gravity:Grounded()
	local res = Workspace:Raycast(
		self.Collider.Position,
		-self.TargetUp * (self.Radius + 0.6),
		self.GroundParams
	)
	return res ~= nil
end

function Gravity:OnHeartbeat()
	if self.Destroyed then
		return
	end
	local res = Workspace:Raycast(
		self.Collider.Position,
		-self.TargetUp * (self.Radius * 1.1),
		self.GroundParams
	)
	local hit = res and res.Instance
	local cf = hit and hit.CFrame
	if hit and hit == self.LastPart and cf ~= self.LastPartCFrame and self.LastPartCFrame then
		-- ride moving platforms
		local offset = self.LastPartCFrame:ToObjectSpace(self.HRP.CFrame)
		self.HRP.CFrame = cf:ToWorldSpace(offset)
	end
	self.LastPart = hit
	self.LastPartCFrame = cf
end

local function jumpSpeed(hum)
	if hum.UseJumpPower then
		return hum.JumpPower
	end
	return math.sqrt(2 * Workspace.Gravity * hum.JumpHeight)
end

function Gravity:Step(dt)
	if self.Destroyed then
		return
	end
	local cam = Workspace.CurrentCamera
	local hrp, hum = self.HRP, self.Humanoid
	if not cam or not hrp.Parent then
		return
	end
	dt = clamp(dt, 1 / 240, 1 / 15)

	-- 1. gravity direction: physics switches at once, the body + camera swing around smoothly
	local tu = self.TargetUp
	local oldUp = self.GravityUp
	local camCF = cam.CFrame
	local ax = camCF.RightVector - oldUp * camCF.RightVector:Dot(oldUp)
	ax = (ax.Magnitude > 1e-3) and ax.Unit or perpendicular(oldUp)
	local rot = IDENTITY:Lerp(rotationBetween(oldUp, tu, ax), 1 - math.exp(-dt * CONFIG.TurnSpeed))
	local su = (rot * oldUp).Unit
	self.GravityUp = su

	-- back to normal gravity and fully upright again -> give the game's own controls back
	if self.AutoRelease and not self.Releasing and su:Dot(UNIT_Y) > 0.9995 then
		self.Releasing = true
		task.defer(function()
			self:Destroy()
		end)
	end

	-- 2. input -> move direction (camera relative, along the surface you are standing on)
	local move = Controls.GetMove(hum, camCF)
	local fDot = camCF.LookVector:Dot(su)
	local cForward = (math.abs(fDot) > 0.5) and (camCF.UpVector * -math.sign(fDot)) or camCF.LookVector
	local left = cForward:Cross(-su)
	if left.Magnitude < 1e-3 then
		left = perpendicular(su)
	else
		left = left.Unit
	end
	local back = su:Cross(left)
	local moveSU = back * move.Z - left * move.X
	if moveSU.Magnitude > 1 then
		moveSU = moveSU.Unit
	end
	local moving = moveSU.Magnitude > 0.02
	-- the physical walking plane follows the REAL gravity direction
	local moveTU = moveSU - tu * moveSU:Dot(tu)
	if moveTU.Magnitude > 1 then
		moveTU = moveTU.Unit
	end

	-- 3. body orientation (stand on the new floor, face the way you walk)
	local hrpLook = hrp.CFrame.LookVector
	local charF = back * hrpLook:Dot(back) + left * hrpLook:Dot(left)
	if charF.Magnitude < 0.05 then
		charF = -back
	end
	charF = charF.Unit
	local charCF = CFrame.fromMatrix(ZERO, charF:Cross(su).Unit, su, -charF)
	local turn = IDENTITY
	if moving then
		turn = IDENTITY:Lerp(rotationBetween(charF, moveSU.Unit, su), 1 - 0.3 ^ (dt * 60))
	end
	local charRot = turn * charCF
	if self.Hooks.firstPersonLook then
		local fp = self.Hooks.firstPersonLook()
		if fp then
			local hlv = fp - su * su:Dot(fp)
			if hlv.Magnitude > 0.05 then
				hlv = hlv.Unit
				charRot = CFrame.fromMatrix(ZERO, hlv:Cross(su).Unit, su, -hlv)
			end
		end
	end

	-- 4. jump (away from the new floor)
	local now = os.clock()
	local grounded = self:Grounded()
	if self.Jumped and now - self.JumpTick > 0.25 then
		self.Jumped = false
	end
	if grounded and not self.Jumped and Controls.IsJumping(hum) then
		hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + tu * (jumpSpeed(hum) * CONFIG.JumpMultiplier)
		self.Jumped = true
		self.JumpTick = now
		self.Sound:Jump()
	end

	-- 5. forces
	local mass = hrp.AssemblyMass
	local gForce = Workspace.Gravity * mass * (UNIT_Y - tu)
	local cVel = hrp.AssemblyLinearVelocity
	local upVel = cVel:Dot(tu)
	if upVel < -CONFIG.MaxFallSpeed then
		cVel = cVel - tu * (upVel + CONFIG.MaxFallSpeed)
		hrp.AssemblyLinearVelocity = cVel
		upVel = -CONFIG.MaxFallSpeed
	end
	local hVel = cVel - upVel * tu
	if hVel:Dot(hVel) < 1 then
		hVel = ZERO
	end
	local dVel = moveTU * hum.WalkSpeed - hVel
	local fMag = math.min(10000, WALK_FORCE * mass * dVel.Magnitude / (dt * 60))
	local walkForce = (fMag > 0) and (dVel.Unit * fMag) or ZERO
	self.VForce.Force = walkForce + gForce
	self.Align.CFrame = charRot

	-- 6. animation (your animation pack) + sound
	local state = "idle"
	if grounded then
		if moving then
			state = "move"
		end
	elseif self.Jumped and upVel > 0 then
		state = "jump"
	else
		state = "fall"
	end
	self.Anim:Set(state, hVel.Magnitude)
	self.Sound:SetRunning(grounded and moving and hVel.Magnitude > 2)
end

function Gravity:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	pcall(function()
		RunService:UnbindFromRenderStep(GRAV_BIND)
	end)
	for _, c in ipairs(self.Conns) do
		c:Disconnect()
	end
	self.Conns = {}
	if self.Anim then
		self.Anim:Destroy()
	end
	if self.Sound then
		self.Sound:Destroy()
	end
	for _, inst in ipairs({ self.Collider, self.VForce, self.Align, self.Attachment }) do
		pcall(function()
			inst:Destroy()
		end)
	end
	local hrp, hum = self.HRP, self.Humanoid
	if hum and hum.Parent and hum.Health > 0 then
		if hrp and hrp.Parent then
			-- stand upright again, same spot, same heading
			local look = hrp.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 0.1 then
				local u = hrp.CFrame.UpVector
				flat = Vector3.new(u.X, 0, u.Z)
			end
			if flat.Magnitude < 0.1 then
				flat = Vector3.new(0, 0, -1)
			end
			local pos = hrp.Position
			hrp.CFrame = CFrame.new(pos, pos + flat.Unit)
			hrp.AssemblyAngularVelocity = ZERO
		end
		hum.PlatformStand = false
	end
	if self.Hooks.onDestroy then
		self.Hooks.onDestroy(self)
	end
end

------------------------------------------------------------------------------------------------------
-- GRAVITY BUBBLE  (floating bubble that opens into 4 arrow keys)
------------------------------------------------------------------------------------------------------
local C_VIOLET = Color3.fromRGB(140, 110, 255)
local C_CYAN = Color3.fromRGB(80, 225, 255)
local C_PINK = Color3.fromRGB(255, 96, 196)
local C_PANEL = Color3.fromRGB(16, 14, 40)

local function easeOutCubic(x)
	return 1 - (1 - x) ^ 3
end

local function easeOutBack(x)
	local c1 = 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

local function addCorner(inst, scale)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = inst
	return c
end

local function newLine(parent, x1, y1, x2, y2, th, color, z)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.ZIndex = z
	local dx, dy = x2 - x1, y2 - y1
	f.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + 0.6, th)
	f.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	f.Rotation = math.deg(math.atan2(dy, dx))
	addCorner(f, 0.5)
	f.Parent = parent
	return f
end

local function placeSegment(frame, th, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.6 then
		frame.Visible = false
		return
	end
	frame.Visible = true
	frame.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	frame.Size = UDim2.fromOffset(len + th * 0.6, th)
	frame.Rotation = math.deg(math.atan2(dy, dx))
end

-- an arrow icon drawn out of 3 thin rounded lines, pointing along (dx, dy)
local function buildArrow(parent, dx, dy, size, th, color, z)
	local c = size / 2
	local s = size * 0.26
	local tipX, tipY = c + dx * s, c + dy * s
	newLine(parent, c - dx * s, c - dy * s, tipX, tipY, th, color, z)
	for _, sgn in ipairs({ 1, -1 }) do
		local a = math.rad(42 * sgn)
		local bx, by = -dx, -dy
		local rx = bx * math.cos(a) - by * math.sin(a)
		local ry = bx * math.sin(a) + by * math.cos(a)
		newLine(parent, tipX, tipY, tipX + rx * s * 1.05, tipY + ry * s * 1.05, th, color, z)
	end
end

local UI = {}
UI.__index = UI

function UI.new(handlers)
	local self = setmetatable({}, UI)
	local SIZE = CONFIG.ButtonSize
	local HALF = SIZE / 2
	local scale = SIZE / 50
	local ARROW = math.floor(SIZE * 0.68 + 0.5)
	local DIST = SIZE * 0.84
	local DIAL = 2 * (DIST + ARROW / 2 + 6 * scale)
	self.size, self.half, self.scale, self.dialSize = SIZE, HALF, scale, DIAL
	self.conns = {}
	self.t = 0
	self.blend, self.blendTarget = 0, 0
	self.engaged = false
	self.expand, self.expandTarget, self.expandEased = 0, 0, 0
	self.lastExpand = -1
	self.idleT = 0
	self.pillA = 0
	self.dragging = false
	self.scaleTarget = 1
	self.pos, self.targetPos = nil, nil
	self.strokes = {}
	self.gravityDir = nil

	local gui = Instance.new("ScreenGui")
	gui.Name = "GravityControlUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 998
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	self.gui = gui

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(SIZE, SIZE)
	holder.Position = UDim2.new(1, -70, 0.62, 0)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	self.holder = holder

	local uiScale = Instance.new("UIScale") -- gentle "lift" while you drag it
	uiScale.Parent = holder
	self.uiScale = uiScale

	local function addStroke(inst, thickness, transparency)
		local st = Instance.new("UIStroke")
		st.Thickness = thickness
		st.Color = C_VIOLET
		st.Transparency = transparency or 0
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = inst
		self.strokes[#self.strokes + 1] = st
		return st
	end

	-- dial (the bubble "expands" into this)
	local dial = Instance.new("Frame")
	dial.Name = "Dial"
	dial.AnchorPoint = Vector2.new(0.5, 0.5)
	dial.Position = UDim2.fromOffset(HALF, HALF)
	dial.Size = UDim2.fromOffset(SIZE, SIZE)
	dial.BackgroundColor3 = C_PANEL
	dial.BackgroundTransparency = 1
	dial.BorderSizePixel = 0
	dial.ZIndex = 1
	addCorner(dial, 0.5)
	self.dialStroke = addStroke(dial, 1.5, 1)
	dial.Parent = holder
	self.dialFrame = dial

	-- 4 arrow keys
	local dirs = {
		{ name = "Up", dx = 0, dy = -1 },
		{ name = "Down", dx = 0, dy = 1 },
		{ name = "Left", dx = -1, dy = 0 },
		{ name = "Right", dx = 1, dy = 0 },
	}
	self.arrows = {}
	for _, d in ipairs(dirs) do
		local f = Instance.new("Frame")
		f.Name = "Arrow" .. d.name
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(HALF, HALF)
		f.Size = UDim2.fromOffset(ARROW, ARROW)
		f.BackgroundColor3 = C_PANEL
		f.BorderSizePixel = 0
		f.ZIndex = 3
		f.Visible = false
		addCorner(f, 0.5)
		addStroke(f, 1.5)
		local sc = Instance.new("UIScale")
		sc.Scale = 0
		sc.Parent = f
		buildArrow(f, d.dx, d.dy, ARROW, math.max(2, 2.6 * scale), C_CYAN, 4)
		local btn = Instance.new("TextButton")
		btn.Name = "Press"
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Size = UDim2.fromScale(1, 1)
		btn.ZIndex = 6
		btn.Parent = f
		f.Parent = holder
		local arrow = { frame = f, scale = sc, dx = d.dx, dy = d.dy, press = 0, name = d.name }
		btn.Activated:Connect(function()
			arrow.press = 1
			self.idleT = 0
			self:Pulse()
			handlers.onShift(arrow.name)
		end)
		self.arrows[#self.arrows + 1] = arrow
	end

	-- the bubble itself
	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.AnchorPoint = Vector2.new(0.5, 0.5)
	bubble.Position = UDim2.fromOffset(HALF, HALF)
	bubble.Size = UDim2.fromOffset(SIZE, SIZE)
	bubble.BackgroundColor3 = Color3.new(1, 1, 1)
	bubble.BorderSizePixel = 0
	bubble.ZIndex = 4
	addCorner(bubble, 0.5)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(34, 28, 78), Color3.fromRGB(6, 6, 16))
	grad.Rotation = 90
	grad.Parent = bubble
	addStroke(bubble, math.max(1.5, 2 * scale))
	bubble.Parent = holder
	self.bubble = bubble

	local planet = Instance.new("Frame")
	planet.Name = "Planet"
	planet.AnchorPoint = Vector2.new(0.5, 0.5)
	planet.Position = UDim2.fromScale(0.5, 0.5)
	local pSize = SIZE * 0.34
	planet.Size = UDim2.fromOffset(pSize, pSize)
	planet.BackgroundColor3 = Color3.new(1, 1, 1)
	planet.BorderSizePixel = 0
	planet.ZIndex = 5
	addCorner(planet, 0.5)
	local pg = Instance.new("UIGradient")
	pg.Color = ColorSequence.new(C_CYAN, C_VIOLET)
	pg.Rotation = 45
	pg.Parent = planet
	planet.Parent = bubble

	local ring = Instance.new("Frame")
	ring.Name = "OrbitRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(SIZE * 0.8, SIZE * 0.26)
	ring.BackgroundTransparency = 1
	ring.Rotation = -24
	ring.ZIndex = 5
	addCorner(ring, 0.5)
	addStroke(ring, math.max(1.2, 1.6 * scale))
	ring.Parent = bubble
	self.ring = ring

	-- little orbs that keep falling into the bubble (a tiny gravity well)
	self.orbs = {}
	for i = 1, 5 do
		local o = Instance.new("Frame")
		o.Name = "Orb"
		o.AnchorPoint = Vector2.new(0.5, 0.5)
		o.BackgroundColor3 = C_CYAN
		o.BorderSizePixel = 0
		o.ZIndex = 6
		o.Size = UDim2.fromOffset(4 * scale, 4 * scale)
		addCorner(o, 0.5)
		o.Parent = bubble
		self.orbs[i] = {
			frame = o,
			p = (i - 1) / 5,
			ang = i * 1.7,
			dir = (i % 2 == 0) and -1 or 1,
			speed = 0.28 + 0.05 * i,
		}
	end

	-- shows which way "down" is on your screen while gravity is changed
	local ind = { stem = newLine(bubble, 0, 0, 1, 0, 2, Color3.new(1, 1, 1), 7) }
	ind.arm1 = newLine(bubble, 0, 0, 1, 0, 2, Color3.new(1, 1, 1), 7)
	ind.arm2 = newLine(bubble, 0, 0, 1, 0, 2, Color3.new(1, 1, 1), 7)
	ind.dot = Instance.new("Frame")
	ind.dot.AnchorPoint = Vector2.new(0.5, 0.5)
	ind.dot.Position = UDim2.fromOffset(HALF, HALF)
	ind.dot.Size = UDim2.fromOffset(5 * scale, 5 * scale)
	ind.dot.BackgroundColor3 = Color3.new(1, 1, 1)
	ind.dot.BorderSizePixel = 0
	ind.dot.ZIndex = 7
	addCorner(ind.dot, 0.5)
	ind.dot.Parent = bubble
	for _, f in pairs(ind) do
		f.Visible = false
	end
	self.indicator = ind

	-- reset pill (only while gravity is changed)
	local pill = Instance.new("TextButton")
	pill.Name = "ResetPill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromOffset(HALF, HALF + DIAL / 2 + 12 * scale)
	pill.Size = UDim2.fromOffset(66 * scale + 8, 22)
	pill.BackgroundColor3 = C_PANEL
	pill.BackgroundTransparency = 1
	pill.BorderSizePixel = 0
	pill.AutoButtonColor = false
	pill.Font = Enum.Font.GothamBold
	pill.Text = "RESET"
	pill.TextSize = 11
	pill.TextColor3 = Color3.new(1, 1, 1)
	pill.TextTransparency = 1
	pill.ZIndex = 8
	pill.Visible = false
	addCorner(pill, 0.5)
	local pst = Instance.new("UIStroke")
	pst.Thickness = 1.5
	pst.Color = C_PINK
	pst.Transparency = 1
	pst.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	pst.Parent = pill
	pill.Parent = holder
	pill.Activated:Connect(function()
		self.idleT = 0
		handlers.onReset()
	end)
	self.pill, self.pillStroke = pill, pst

	-- tap (open / close) + smooth drag; hit area is a little bigger than the bubble
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.new(1, 10, 1, 10)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.ZIndex = 10
	hit.Parent = holder
	addCorner(hit, 0.5)

	local dragInput, dragStart, anchorPos, dragMoved
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			dragInput = input
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragMoved = false
		end
	end)
	table.insert(
		self.conns,
		UserInputService.InputChanged:Connect(function(input)
			if not dragInput then
				return
			end
			local isDrag = input == dragInput
				or (
					dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement
				)
			if not isDrag then
				return
			end
			local cur = Vector2.new(input.Position.X, input.Position.Y)
			if not dragMoved and (cur - dragStart).Magnitude > 8 then
				dragMoved = true
				local ap, as = holder.AbsolutePosition, holder.AbsoluteSize
				anchorPos = Vector2.new(ap.X + as.X / 2, ap.Y + as.Y / 2)
				self.pos = anchorPos
				self.targetPos = anchorPos
				self.dragging = true
				self.scaleTarget = 1.12
			end
			if dragMoved then
				local cam = Workspace.CurrentCamera
				local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
				local p = anchorPos + (cur - dragStart)
				local m = HALF + 6
				self.targetPos = Vector2.new(clamp(p.X, m, vp.X - m), clamp(p.Y, m, vp.Y - m))
			end
		end)
	)
	table.insert(
		self.conns,
		UserInputService.InputEnded:Connect(function(input)
			if input == dragInput then
				dragInput = nil
				if dragMoved then
					self.dragging = false
					self.scaleTarget = 1
				else
					self.expandTarget = (self.expandTarget > 0) and 0 or 1
					self.idleT = 0
				end
			end
		end)
	)

	table.insert(
		self.conns,
		RunService.RenderStepped:Connect(function(dt)
			self:Step(math.min(dt, 0.1))
		end)
	)

	-- mount (hidden gui container first, then CoreGui, then PlayerGui)
	local candidates = {}
	pcall(function()
		if gethui then
			candidates[#candidates + 1] = gethui()
		end
	end)
	pcall(function()
		candidates[#candidates + 1] = game:GetService("CoreGui")
	end)
	candidates[#candidates + 1] = LocalPlayer:WaitForChild("PlayerGui")
	for _, parent in ipairs(candidates) do
		local ok = pcall(function()
			gui.Parent = parent
		end)
		if ok and gui.Parent == parent then
			break
		end
	end

	return self
end

function UI:ApplyAccent()
	local c = C_VIOLET:Lerp(C_PINK, self.blend)
	for _, st in ipairs(self.strokes) do
		st.Color = c
	end
end

function UI:Pulse()
	local SIZE = self.size
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(SIZE, SIZE)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 2
	addCorner(ring, 0.5)
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = C_CYAN:Lerp(C_PINK, self.blend)
	st.Parent = ring
	ring.Parent = self.holder
	local info = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, { Size = UDim2.fromOffset(SIZE * 2.2, SIZE * 2.2) }):Play()
	TweenService:Create(st, info, { Transparency = 1 }):Play()
	task.delay(0.55, function()
		ring:Destroy()
	end)
end

function UI:SetEngaged(on)
	self.engaged = on and true or false
	self.blendTarget = self.engaged and 1 or 0
end

function UI:Collapse()
	self.expandTarget = 0
end

-- is this screen position on the bubble / open dial? (the camera ignores touches there)
function UI:IsOver(pos)
	local ap, as = self.holder.AbsolutePosition, self.holder.AbsoluteSize
	local cx, cy = ap.X + as.X / 2, ap.Y + as.Y / 2
	local sc = self.uiScale.Scale
	local r = (self.half + 10 + (self.dialSize - self.size) / 2 * self.expandEased) * sc
	local dx, dy = pos.X - cx, pos.Y - cy
	return dx * dx + dy * dy <= r * r
end

function UI:UpdateIndicator()
	local ind = self.indicator
	local half, scale = self.half, self.scale
	local v = (self.blend > 0.05 and self.gravityDir) and self.gravityDir() or nil
	if not v then
		for _, f in pairs(ind) do
			f.Visible = false
		end
		return
	end
	local mag = math.min(1, v.Magnitude)
	if mag < 0.15 then
		-- gravity points toward / away from the camera: just a dot
		ind.stem.Visible, ind.arm1.Visible, ind.arm2.Visible = false, false, false
		ind.dot.Visible = true
		return
	end
	ind.dot.Visible = false
	local dir = v.Unit
	local len = (6 + 9 * mag) * scale
	local tx, ty = half + dir.X * len, half + dir.Y * len
	placeSegment(ind.stem, 2, half, half, tx, ty)
	for i, arm in ipairs({ ind.arm1, ind.arm2 }) do
		local a = math.rad((i == 1) and 35 or -35)
		local bx, by = -dir.X, -dir.Y
		local rx = bx * math.cos(a) - by * math.sin(a)
		local ry = bx * math.sin(a) + by * math.cos(a)
		placeSegment(arm, 2, tx, ty, tx + rx * 5 * scale, ty + ry * 5 * scale)
	end
end

function UI:Step(dt)
	self.t = self.t + dt
	local t = self.t
	local half, scale, size = self.half, self.scale, self.size

	-- smooth dragging: the bubble eases toward your finger instead of snapping to it
	if self.targetPos then
		local a = 1 - math.exp(-dt * 26)
		self.pos = self.pos:Lerp(self.targetPos, a)
		if not self.dragging and (self.targetPos - self.pos).Magnitude < 0.05 then
			self.pos = self.targetPos
			self.targetPos = nil
		end
		self.holder.Position = UDim2.fromOffset(self.pos.X, self.pos.Y)
	end
	local sc = self.uiScale.Scale
	if sc ~= self.scaleTarget then
		sc = sc + (self.scaleTarget - sc) * (1 - math.exp(-dt * 16))
		if math.abs(sc - self.scaleTarget) < 0.002 then
			sc = self.scaleTarget
		end
		self.uiScale.Scale = sc
	end

	-- colour: violet when gravity is normal, pink while it is changed
	if self.blend ~= self.blendTarget then
		local step = dt / 0.4
		if self.blendTarget > self.blend then
			self.blend = math.min(self.blendTarget, self.blend + step)
		else
			self.blend = math.max(self.blendTarget, self.blend - step)
		end
		self:ApplyAccent()
	end

	-- open / close
	if self.expand ~= self.expandTarget then
		local step = dt / 0.38
		if self.expandTarget > self.expand then
			self.expand = math.min(self.expandTarget, self.expand + step)
		else
			self.expand = math.max(self.expandTarget, self.expand - step)
		end
	end
	local p = self.expand
	local ec = easeOutCubic(p)
	self.expandEased = ec
	if p ~= self.lastExpand then
		self.lastExpand = p
		local ds = size + (self.dialSize - size) * ec
		self.dialFrame.Size = UDim2.fromOffset(ds, ds)
		self.dialFrame.BackgroundTransparency = 1 - 0.72 * ec
		self.dialStroke.Transparency = 1 - 0.6 * ec
		local act = p > 0.05
		if self.dialFrame.Active ~= act then
			self.dialFrame.Active = act -- the open dial catches touches so the camera doesn't spin under it
		end
	end
	if p > 0.001 then
		local eb = easeOutBack(p)
		local dist = size * 0.84
		for _, a in ipairs(self.arrows) do
			a.press = math.max(0, a.press - dt * 5)
			a.frame.Visible = true
			a.frame.Position = UDim2.fromOffset(half + a.dx * dist * eb, half + a.dy * dist * eb)
			a.scale.Scale = ec * (1 - 0.2 * a.press)
		end
	elseif self.arrows[1].frame.Visible then
		for _, a in ipairs(self.arrows) do
			a.frame.Visible = false
		end
	end

	-- auto close
	if p > 0 and self.expandTarget == 1 and not self.dragging and CONFIG.AutoCollapse > 0 then
		self.idleT = self.idleT + dt
		if self.idleT > CONFIG.AutoCollapse then
			self.expandTarget = 0
		end
	end

	-- bubble: floats, ring wobbles, orbs fall in (faster while gravity is changed)
	self.bubble.Position = UDim2.fromOffset(half, half + math.sin(t * 1.7) * 2 * scale * (1 - p * 0.7))
	self.ring.Rotation = -24 + math.sin(t * 1.1) * 7
	local R = half - 4 * scale
	local pr = size * 0.17
	local boost = 1 + 1.3 * self.blend
	for _, o in ipairs(self.orbs) do
		o.p = o.p + dt * o.speed * boost
		if o.p >= 1 then
			o.p = o.p - 1
			o.ang = math.random() * PI2
		end
		o.ang = o.ang + o.dir * dt * (2 + 6 * o.p) * boost
		local r = R - (R - pr) * (o.p ^ 1.3)
		o.frame.Position = UDim2.fromOffset(half + math.cos(o.ang) * r, half + math.sin(o.ang) * r)
		local s = 4 * scale * (1 - 0.55 * o.p)
		o.frame.Size = UDim2.fromOffset(s, s)
		o.frame.BackgroundTransparency = 0.1 + 0.85 * o.p ^ 3
	end

	self:UpdateIndicator()

	-- reset pill fades in while gravity is changed and the dial is open
	local pillTarget = (self.engaged and p > 0.85) and 1 or 0
	if self.pillA ~= pillTarget then
		local step = dt * 8
		if pillTarget > self.pillA then
			self.pillA = math.min(pillTarget, self.pillA + step)
		else
			self.pillA = math.max(pillTarget, self.pillA - step)
		end
		local a = self.pillA
		self.pill.Visible = a > 0.02
		self.pill.BackgroundTransparency = 1 - 0.85 * a
		self.pill.TextTransparency = 1 - a
		self.pillStroke.Transparency = 1 - a
	end
end

function UI:Destroy()
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	pcall(function()
		self.gui:Destroy()
	end)
end

------------------------------------------------------------------------------------------------------
-- MANAGER  (arrow presses, respawn, sitting)
------------------------------------------------------------------------------------------------------
local Manager = {}
Manager.__index = Manager

function Manager.new(cameraCtl)
	local self = setmetatable({}, Manager)
	self.controller = nil
	self.camera = cameraCtl
	self.conns = {}
	self.charConns = {}
	return self
end

function Manager:GetCharacter()
	local char = LocalPlayer.Character
	if not char or not char.Parent then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart") or (hum and hum.RootPart)
	if not hum or not hrp or hum.Health <= 0 or hum.Sit then
		return nil
	end
	return char, hum, hrp
end

function Manager:SetChanged(on)
	if self.onChanged then
		self.onChanged(on)
	end
end

-- takes over the character (only while gravity is actually changed)
function Manager:Engage()
	if self.controller and not self.controller.Destroyed then
		return self.controller
	end
	local char, hum, hrp = self:GetCharacter()
	if not char then
		return nil
	end

	-- Spider Wall Walk and Gravity Control can't both run: turn the other one off
	local sw = env.__SpiderWallWalk
	if sw and sw.Disable then
		pcall(sw.Disable)
	end

	local camera = self.camera
	local hooks = {
		firstPersonLook = function()
			if camera.firstPerson then
				return camera.look
			end
			return nil
		end,
		onDestroy = function(ctl)
			if self.controller == ctl then
				self.controller = nil
				camera:Stop()
				self:SetChanged(false)
			end
		end,
	}
	local ok, ctl = pcall(Gravity.new, char, hum, hrp, hooks)
	if not ok then
		warn("[GravityControl] could not start: " .. tostring(ctl))
		return nil
	end
	self.controller = ctl
	camera:Start(function()
		return ctl.GravityUp
	end, function(up)
		return ctl:GetFocus(up)
	end, self.isBlocked, char)
	return ctl
end

-- an arrow was pressed
function Manager:Shift(dirName)
	local char, _, hrp = self:GetCharacter()
	if not char then
		return
	end
	local ctl = self.controller
	if ctl and ctl.Destroyed then
		ctl = nil
	end
	local up = ctl and ctl.TargetUp or UNIT_Y

	-- where am I looking (once the camera has finished swinging around to the current gravity)?
	local cam = Workspace.CurrentCamera
	local look = ctl and self.camera:PredictLook(up) or nil
	look = look or (cam and cam.CFrame.LookVector) or Vector3.new(0, 0, -1)

	local down = shiftedDown(dirName, up, look, hrp.CFrame.LookVector)
	local newUp = -down

	-- a wall / floor in that direction? then line up with it exactly so you can walk on it
	if CONFIG.SnapToSurface then
		syncWorldParams()
		local res = Workspace:Raycast(hrp.Position, down * CONFIG.SnapDistance, worldParams)
		if res and res.Normal:Dot(newUp) > math.cos(math.rad(CONFIG.SnapAngle)) then
			newUp = res.Normal
		end
	end

	ctl = self:Engage()
	if not ctl then
		return
	end
	ctl:SetTargetUp(newUp)
	self:SetChanged(ctl.TargetUp:Dot(UNIT_Y) < 0.9998)
end

function Manager:Reset()
	local ctl = self.controller
	if ctl and not ctl.Destroyed then
		ctl:SetTargetUp(UNIT_Y)
	end
	self:SetChanged(false)
end

function Manager:StopController()
	local ctl = self.controller
	if ctl then
		ctl:Destroy()
	end
end

function Manager:BindCharacter(char)
	for _, c in ipairs(self.charConns) do
		c:Disconnect()
	end
	self.charConns = {}
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then
		return
	end
	table.insert(
		self.charConns,
		hum.Died:Connect(function()
			self:StopController()
		end)
	)
	table.insert(
		self.charConns,
		hum.Seated:Connect(function(active)
			if active then
				self:StopController()
			end
		end)
	)
end

function Manager:Init()
	if LocalPlayer.Character then
		task.spawn(function()
			self:BindCharacter(LocalPlayer.Character)
		end)
	end
	table.insert(
		self.conns,
		LocalPlayer.CharacterAdded:Connect(function(char)
			self:SetChanged(false) -- respawning brings normal gravity back
			task.spawn(function()
				self:BindCharacter(char)
			end)
		end)
	)
end

-- instant, used when Spider Wall Walk takes over
function Manager:Disable()
	self:StopController()
	self.camera:Stop(true)
	self:SetChanged(false)
end

function Manager:Destroy()
	self:StopController()
	self.camera:Stop(true)
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	for _, c in ipairs(self.charConns) do
		c:Disconnect()
	end
	self.conns, self.charConns = {}, {}
end

------------------------------------------------------------------------------------------------------
-- BOOT
------------------------------------------------------------------------------------------------------
Controls.Init()

local cameraCtl = CameraCtl.new()
local manager = Manager.new(cameraCtl)
local ui = UI.new({
	onShift = function(dirName)
		manager:Shift(dirName)
	end,
	onReset = function()
		manager:Reset()
	end,
})
manager.isBlocked = function(pos)
	return ui:IsOver(pos)
end
manager.onChanged = function(engaged)
	ui:SetEngaged(engaged)
end
-- which way is "down" on the screen (for the little arrow inside the bubble)
ui.gravityDir = function()
	local ctl = manager.controller
	local cam = Workspace.CurrentCamera
	if not ctl or ctl.Destroyed or not cam then
		return nil
	end
	local down = -ctl.TargetUp
	local cf = cam.CFrame
	return Vector2.new(down:Dot(cf.RightVector), -down:Dot(cf.UpVector))
end
manager:Init()

env.__GravityControl = {
	Destroy = function()
		manager:Destroy()
		ui:Destroy()
		Controls.Destroy()
	end,
	Disable = function()
		manager:Disable()
		ui:Collapse()
	end,
}
