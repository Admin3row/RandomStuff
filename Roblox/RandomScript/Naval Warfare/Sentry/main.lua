-- Version 1.34

-- LocalScript: "Nuke UI" (client-side, non-destructive — only hides / makes things invisible for this client)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local workspace = game:GetService("Workspace")

-- Create the single-message GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoLock_NukeMessage_v1_34"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 9999
screenGui.Parent = playerGui

local background = Instance.new("Frame")
background.Name = "BG"
background.Size = UDim2.new(1, 0, 1, 0)
background.Position = UDim2.new(0, 0, 0, 0)
background.BackgroundColor3 = Color3.fromRGB(10,10,10)
background.BackgroundTransparency = 0.15
background.BorderSizePixel = 0
background.Parent = screenGui

local box = Instance.new("Frame")
box.Name = "MessageBox"
box.Size = UDim2.new(0.7, 0, 0.18, 0)
box.AnchorPoint = Vector2.new(0.5, 0.5)
box.Position = UDim2.new(0.5, 0, 0.5, 0)
box.BackgroundColor3 = Color3.fromRGB(25,25,25)
box.BorderSizePixel = 0
box.ClipsDescendants = true
box.Parent = screenGui

local uicorner = Instance.new("UICorner")
uicorner.CornerRadius = UDim.new(0, 12)
uicorner.Parent = box

local message = Instance.new("TextLabel")
message.Name = "Message"
message.Size = UDim2.new(1, -24, 1, -24)
message.Position = UDim2.new(0, 12, 0, 12)
message.BackgroundTransparency = 1
message.TextScaled = true
message.RichText = false
message.Font = Enum.Font.GothamBold
message.TextColor3 = Color3.fromRGB(255,255,255)
message.Text = "oops, i deleted everything. forgive me gng 💔"
message.TextWrapped = true
message.TextXAlignment = Enum.TextXAlignment.Center
message.TextYAlignment = Enum.TextYAlignment.Center
message.Parent = box

-- Subtle entrance animation (fade-in)
box.Position = UDim2.new(0.5, 0, 0.45, 0)
box.BackgroundTransparency = 1
message.TextTransparency = 1
local startTick = tick()
local animDur = 0.32
local conn
conn = RunService.RenderStepped:Connect(function()
    local t = math.clamp((tick() - startTick) / animDur, 0, 1)
    box.BackgroundTransparency = 1 - (t * 0.85) -- from 1 -> 0.15
    box.Position = UDim2.new(0.5, 0, 0.45 + (0.05 * (1 - t)), 0)
    message.TextTransparency = 1 - t
    if t >= 1 then
        conn:Disconnect()
    end
end)

-- Make the client "appear" to have everything deleted:
-- 1) Hide other GUI objects for this player
pcall(function()
    for _, guiObj in ipairs(playerGui:GetChildren()) do
        if guiObj ~= screenGui then
            if guiObj:IsA("ScreenGui") then
                -- disable other ScreenGuis
                pcall(function() guiObj.Enabled = false end)
            else
                -- hide any GuiObjects not inside our screenGui
                for _, desc in ipairs(guiObj:GetDescendants()) do
                    if desc:IsA("GuiObject") and not desc:IsDescendantOf(screenGui) then
                        pcall(function() desc.Visible = false end)
                    end
                end
            end
        end
    end
end)

-- 2) Make workspace parts invisible for this client (LocalTransparencyModifier = 1)
pcall(function()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") then
            pcall(function()
                -- set to fully transparent for this client only
                obj.LocalTransparencyModifier = math.max(1, (obj.LocalTransparencyModifier or 0))
            end)
        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            pcall(function() obj.Transparency = 1 end)
        elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
            pcall(function() obj.Enabled = false end)
        elseif obj:IsA("Light") then
            pcall(function() obj.Enabled = false end)
        elseif obj:IsA("Sound") then
            pcall(function() obj:Stop() end)
        end
    end
end)

-- 3) Stop all local ambient sounds (local only)
pcall(function()
    local soundService = game:GetService("SoundService")
    for _, s in ipairs(soundService:GetDescendants()) do
        if s:IsA("Sound") then pcall(function() s:Stop() end) end
    end
end)

-- 4) Optional: hide player's character visuals locally (makes it feel fully wiped)
pcall(function()
    local char = player.Character
    if char then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                pcall(function() part.LocalTransparencyModifier = math.max(1, (part.LocalTransparencyModifier or 0)) end)
            elseif part:IsA("Decal") or part:IsA("Texture") then
                pcall(function() part.Transparency = 1 end)
            elseif part:IsA("ParticleEmitter") or part:IsA("Trail") then
                pcall(function() part.Enabled = false end)
            elseif part:IsA("Sound") then
                pcall(function() part:Stop() end)
            end
        end
    end
end)

-- Final confirmation print (client)
pcall(function() print("[AutoLock v1.34] Local wipe complete — message displayed.") end)
