-- DragonClient.client.lua
-- Положить в StarterPlayer > StarterPlayerScripts. Roblox / Luau.
-- Ввод (клавиши 1-6), панель скиллов с кулдаунами, тряска камеры и вспышка.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("DragonRemote")
local camera = workspace.CurrentCamera

-- Поворачивать персонажа по взгляду камеры при касте (чтобы скиллы летели туда, куда смотришь)
local FACE_CAMERA_ON_CAST = true

local KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}
local NAMES = { "Огонь", "Рывок", "Шар", "Град", "Дракончик", "Форма" }

local function getChar()
	local char = player.Character
	return char, char and char:FindFirstChild("HumanoidRootPart"), char and char:FindFirstChildOfClass("Humanoid")
end

local function faceCamera()
	local _, root = getChar()
	if not root then return end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then return end
	root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
end

------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "DragonHUD"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local holder = Instance.new("Frame")
holder.AnchorPoint = Vector2.new(0.5, 1)
holder.Position = UDim2.new(0.5, 0, 1, -16)
holder.Size = UDim2.fromOffset(6 * 66, 60)
holder.BackgroundTransparency = 1
holder.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Padding = UDim.new(0, 6)
layout.Parent = holder

local slots = {}
for i = 1, 6 do
	local f = Instance.new("TextButton")
	f.AutoButtonColor = false
	f.Text = ""
	f.Size = UDim2.fromOffset(60, 60)
	f.BackgroundColor3 = Color3.fromRGB(35, 20, 20)
	f.BorderSizePixel = 0
	f.LayoutOrder = i
	f.ClipsDescendants = true
	f.Parent = holder
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new("UIStroke", f)
	stroke.Color = Color3.fromRGB(255, 140, 30)
	stroke.Thickness = 1.5

	local key = Instance.new("TextLabel")
	key.BackgroundTransparency = 1
	key.Position = UDim2.fromOffset(4, 2)
	key.Size = UDim2.fromOffset(20, 18)
	key.Text = tostring(i)
	key.TextColor3 = Color3.fromRGB(255, 200, 100)
	key.Font = Enum.Font.GothamBold
	key.TextSize = 14
	key.TextXAlignment = Enum.TextXAlignment.Left
	key.Parent = f

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.AnchorPoint = Vector2.new(0, 1)
	name.Position = UDim2.new(0, 0, 1, -2)
	name.Size = UDim2.new(1, 0, 0, 16)
	name.Text = NAMES[i]
	name.TextColor3 = Color3.new(1, 1, 1)
	name.Font = Enum.Font.Gotham
	name.TextSize = 11
	name.Parent = f

	local cover = Instance.new("Frame")
	cover.AnchorPoint = Vector2.new(0, 1)
	cover.Position = UDim2.new(0, 0, 1, 0)
	cover.Size = UDim2.new(1, 0, 0, 0)
	cover.BackgroundColor3 = Color3.new(0, 0, 0)
	cover.BackgroundTransparency = 0.35
	cover.BorderSizePixel = 0
	cover.Parent = f

	local count = Instance.new("TextLabel")
	count.BackgroundTransparency = 1
	count.Size = UDim2.fromScale(1, 1)
	count.Text = ""
	count.TextColor3 = Color3.new(1, 1, 1)
	count.Font = Enum.Font.GothamBold
	count.TextSize = 20
	count.ZIndex = 3
	count.Parent = f

	slots[i] = { cover = cover, count = count, untilT = 0, total = 1 }

	-- нажатие по кнопке (для телефона)
	f.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if FACE_CAMERA_ON_CAST then faceCamera() end
			remote:FireServer(i, "Down")
		end
	end)
	f.InputEnded:Connect(function(input)
		if i == 3 and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
			remote:FireServer(3, "Up")
		end
	end)
end

RunService.RenderStepped:Connect(function()
	local now = os.clock()
	for _, s in ipairs(slots) do
		local left = s.untilT - now
		if left > 0 then
			s.cover.Size = UDim2.new(1, 0, left / s.total, 0)
			s.count.Text = string.format("%.1f", left)
		else
			s.cover.Size = UDim2.new(1, 0, 0, 0)
			s.count.Text = ""
		end
	end
end)

------------------------------------------------------------------------
-- ВВОД
------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	local skill = KEYS[input.KeyCode]
	if not skill then return end
	if FACE_CAMERA_ON_CAST then faceCamera() end
	remote:FireServer(skill, "Down")
end)

UserInputService.InputEnded:Connect(function(input)
	if KEYS[input.KeyCode] == 3 then
		remote:FireServer(3, "Up")
	end
end)

------------------------------------------------------------------------
-- СОБЫТИЯ С СЕРВЕРА
------------------------------------------------------------------------
local aiming = false

RunService.RenderStepped:Connect(function()
	-- пока держим шар или висим в воздухе, персонаж следит за камерой
	if aiming and FACE_CAMERA_ON_CAST then faceCamera() end
end)

local function shake(duration, magnitude)
	task.spawn(function()
		local _, _, hum = getChar()
		if not hum then return end
		local t0 = os.clock()
		while os.clock() - t0 < duration do
			local f = 1 - (os.clock() - t0) / duration
			hum.CameraOffset = Vector3.new((math.random() - 0.5) * magnitude * f, (math.random() - 0.5) * magnitude * f, 0)
			RunService.RenderStepped:Wait()
		end
		hum.CameraOffset = Vector3.zero
	end)
end

local function flash()
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BorderSizePixel = 0
	f.ZIndex = 100
	f.Parent = gui
	TweenService:Create(f, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	task.delay(0.8, function() f:Destroy() end)
end

remote.OnClientEvent:Connect(function(kind, a, b)
	if kind == "Cooldown" then
		local s = slots[a]
		if s then
			s.total = b
			s.untilT = os.clock() + b
		end
	elseif kind == "Aim" then
		aiming = a
	elseif kind == "Shake" then
		shake(a, b)
	elseif kind == "Flash" then
		flash()
	end
end)
