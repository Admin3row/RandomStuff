-- AutoLock (fixed): default = General, mode toggle works while running, AI label updates live
-- Place in StarterPlayer -> StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local cam = workspace.CurrentCamera

-- CONFIG
local INFANTRY_RANGE = 300
local TIER_CLOSE = 700
local TIER_ORANGE = 2000
local PREDICTIVE_RANGE = 1800
local PROJECTILE_SPEED = 800
local VEH_PART_HIGHLIGHT_LIMIT = 10

local PLANE_EXACT = { ["Bomber"]=true, ["Large Bomber"]=true, ["Torpedo Bomber"]=true }
local PLANE_FALLBACK_TOKENS = { "bomber","largebomber","large bomber","torpedobomber","torpedo bomber","plane","aircraft" }
local KNOWN_SPEEDS = { ["large bomber"]=105, ["largebomber"]=105, ["bomber"]=115, ["torpedo bomber"]=115, ["torpedobomber"]=115 }

-- WARNING SOUND CONFIG (added)
local WARNING_INTERVAL = 1.5
local lastWarningTime = 0
local isInDanger = false -- true when currently inside danger zone (dist < TIER_ORANGE)

-- STATE
local enabled = false
local lockConn = nil
local aimCenterConn = nil
local currentTarget = nil
local originalCameraMode = player.CameraMode
local mode = "General" -- << default fixed to General

-- caches
local charHighlight, vehicleHighlightModel
local vehiclePartHighlights = {}
local lastColorTier, lastVehicleModel, lastTarget

-- -------------------
-- Crosshair helpers
-- -------------------
local crosshair
local function findAimInPlayerGui()
    for _, inst in ipairs(playerGui:GetDescendants()) do
        if inst.Name == "Aim" and (inst:IsA("ImageLabel") or inst:IsA("ImageButton")) then
            return inst
        end
    end
    return nil
end
local function centerCrosshair(inst)
    if not inst then return end
    pcall(function() inst.AnchorPoint = Vector2.new(0.5,0.5); inst.Position = UDim2.new(0.5,0,0.5,0) end)
end
local function refreshCrosshair()
    crosshair = findAimInPlayerGui()
    if crosshair then
        centerCrosshair(crosshair)
        pcall(function() crosshair.ImageTransparency = enabled and 0.3 or 0.6; if not enabled then crosshair.ImageColor3 = Color3.new(1,1,1) end end)
    end
end

-- force center each frame
aimCenterConn = RunService.RenderStepped:Connect(function()
    if not crosshair then refreshCrosshair() end
    if crosshair then pcall(function() crosshair.AnchorPoint = Vector2.new(0.5,0.5); crosshair.Position = UDim2.new(0.5,0,0.5,0) end) end
end)
playerGui.DescendantAdded:Connect(function(desc)
    if desc.Name == "Aim" and (desc:IsA("ImageLabel") or desc:IsA("ImageButton")) then
        crosshair = desc; centerCrosshair(crosshair)
        pcall(function() crosshair.ImageTransparency = enabled and 0.3 or 0.6 end)
    end
end)

-- -------------------
-- Utils / naming / targeting
-- -------------------
local function getCharacterHeadPos(ch)
    if not ch then return nil end
    local head = ch:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head.Position end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position + Vector3.new(0,1.5,0) end
    return nil
end

local function validTargetGeneral(p)
    if not p or p == player then return false end
    if p.Team == player.Team then return false end
    local ch = p.Character
    if not ch then return false end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    return true
end

local function nearestEnemy(origin)
    local nearest, bestDist = nil, math.huge
    for _,plr in ipairs(Players:GetPlayers()) do
        if validTargetGeneral(plr) then
            local pos = getCharacterHeadPos(plr.Character)
            if pos then
                local d = (pos - origin).Magnitude
                if d < bestDist then bestDist, nearest = d, plr end
            end
        end
    end
    return nearest, bestDist
end

local function nameMatchesFallbackTokens(name)
    if not name then return false end
    local lower = string.lower(name)
    for _,tok in ipairs(PLANE_FALLBACK_TOKENS) do
        if string.find(lower, tok, 1, true) then return true end
    end
    return false
end

local function nameIsExactPlane(vehicle)
    if not vehicle then return false end
    local nm = tostring(vehicle.Name or "")
    if PLANE_EXACT[nm] then return true end
    local typeVal = vehicle:FindFirstChild("VehicleType")
    if typeVal and typeVal:IsA("StringValue") and PLANE_EXACT[typeVal.Value] then return true end
    if vehicle.GetAttribute then
        local attr = vehicle:GetAttribute("VehicleType")
        if type(attr) == "string" and PLANE_EXACT[attr] then return true end
    end
    return false
end

-- returns (inPlane:boolean, vehicleModel, exactMatch:boolean)
local function isPlayerInPlane(plr)
    if not plr or not plr.Character then return false, nil, false end
    local hum = plr.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return false, nil, false end
    local seat = hum.SeatPart
    if not seat then return false, nil, false end
    local node = seat
    while node and not node:IsA("Model") do node = node.Parent end
    local vehicle = node or seat.Parent
    if not vehicle then return false, nil, false end
    if nameIsExactPlane(vehicle) then return true, vehicle, true end
    local nm = tostring(vehicle.Name or "")
    if nameMatchesFallbackTokens(nm) then return true, vehicle, false end
    local typeVal = vehicle:FindFirstChild("VehicleType")
    if typeVal and typeVal:IsA("StringValue") then
        if PLANE_EXACT[typeVal.Value] then return true, vehicle, true end
        if nameMatchesFallbackTokens(typeVal.Value) then return true, vehicle, false end
    end
    if vehicle.GetAttribute then
        local attr = vehicle:GetAttribute("VehicleType")
        if type(attr) == "string" then
            if PLANE_EXACT[attr] then return true, vehicle, true end
            if nameMatchesFallbackTokens(attr) then return true, vehicle, false end
        end
    end
    return false, vehicle, false
end

-- Anti-air target selection:
-- eligible if (A) seated in confirmed plane OR (B) NOT seated (on-foot) AND within INFANTRY_RANGE
local function nearestAntiAirTarget(origin)
    local nearest, bestDist = nil, math.huge
    for _,plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Team ~= player.Team then
            local ch = plr.Character
            if ch then
                local hum = ch:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local headPos = getCharacterHeadPos(ch)
                    if headPos then
                        local dist = (headPos - origin).Magnitude
                        local seat = hum.SeatPart
                        local inPlane, vehicleModel = isPlayerInPlane(plr)
                        local eligible = false
                        if inPlane then
                            eligible = true
                        else
                            if not seat and dist <= INFANTRY_RANGE then eligible = true end
                        end
                        if eligible and dist < bestDist then bestDist, nearest = dist, plr end
                    end
                end
            end
        end
    end
    return nearest, bestDist
end

local function getVehicleModelFromSeat(seat)
    if not seat then return nil end
    local node = seat
    while node and not node:IsA("Model") do node = node.Parent end
    return node
end

-- velocity fallback (unchanged)
local function getTargetVelocityAndFallbackSpeed(targetPlayer)
    if not targetPlayer or not targetPlayer.Character then return Vector3.new(0,0,0), nil end
    local hum = targetPlayer.Character:FindFirstChildOfClass("Humanoid")
    local hrp = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
    if hum then
        local seat = hum.SeatPart
        if seat then
            local vehicle = getVehicleModelFromSeat(seat)
            if vehicle then
                local vel = nil
                if vehicle.PrimaryPart then vel = vehicle.PrimaryPart.AssemblyLinearVelocity end
                if (not vel or vel.Magnitude < 0.01) and seat.AssemblyLinearVelocity then vel = seat.AssemblyLinearVelocity end
                if (not vel or vel.Magnitude < 0.01) then
                    for _,v in ipairs(vehicle:GetDescendants()) do
                        if v:IsA("BasePart") and v.AssemblyLinearVelocity then vel = v.AssemblyLinearVelocity break end
                    end
                end
                if not vel or vel.Magnitude < 0.5 then
                    local name = string.lower(tostring(vehicle.Name or ""))
                    local fallbackSpeed = nil
                    for key,s in pairs(KNOWN_SPEEDS) do if string.find(name, key, 1, true) then fallbackSpeed = s break end end
                    if fallbackSpeed then
                        local dir = nil
                        if vehicle.PrimaryPart then dir = vehicle.PrimaryPart.CFrame.LookVector end
                        if (not dir or dir.Magnitude < 0.1) and seat and seat.CFrame then dir = seat.CFrame.LookVector end
                        if (not dir or dir.Magnitude < 0.1) and hrp then dir = hrp.CFrame.LookVector end
                        dir = (dir and dir.Magnitude>0 and dir.Unit) or Vector3.new(0,0,0)
                        vel = dir * fallbackSpeed
                        return vel, fallbackSpeed
                    end
                else
                    return vel, vel.Magnitude
                end
            end
        end
    end
    if hrp and hrp.Velocity then return hrp.Velocity, hrp.Velocity.Magnitude end
    return Vector3.new(0,0,0), nil
end

-- intercept math (same quadratic solver)
local function computeInterceptPoint(origin, targetPos, targetVel, projectileSpeed)
    if not projectileSpeed or projectileSpeed <= 0 then return nil end
    local r = targetPos - origin
    local v = targetVel
    local a = v:Dot(v) - projectileSpeed * projectileSpeed
    local b = 2 * v:Dot(r)
    local c = r:Dot(r)
    if math.abs(a) < 1e-6 then
        if math.abs(b) < 1e-6 then return nil end
        local t = -c / b
        if t > 0 then return targetPos + v * t end
        return nil
    end
    local disc = b*b - 4*a*c
    if disc < 0 then return nil end
    local sqrtD = math.sqrt(disc)
    local t1 = (-b - sqrtD) / (2*a)
    local t2 = (-b + sqrtD) / (2*a)
    local t = nil
    if t1 > 0 and t2 > 0 then t = math.min(t1,t2)
    elseif t1 > 0 then t = t1
    elseif t2 > 0 then t = t2
    else return nil end
    if t and t > 10 then return nil end
    return targetPos + v * t
end

-- -------------------
-- UI BUILD
-- -------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoLockToggleGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local btn = Instance.new("TextButton")
btn.Name = "AutoLockButton"
btn.Size = UDim2.new(0,160,0,72)
btn.Position = UDim2.new(0,20,0,120)
btn.Font = Enum.Font.SourceSansSemibold
btn.TextSize = 18
btn.AutoButtonColor = false
btn.BackgroundColor3 = Color3.fromRGB(60,60,60)
btn.TextColor3 = Color3.fromRGB(255,255,255)
btn.BorderSizePixel = 0
btn.Parent = screenGui
btn.Active = true
btn.Selectable = true

local dot = Instance.new("Frame")
dot.Name = "Indicator"
dot.Size = UDim2.new(0,12,0,12)
dot.Position = UDim2.new(1,-18,0.5,-6)
dot.BackgroundColor3 = Color3.fromRGB(200,50,50)
dot.BorderSizePixel = 0
dot.Parent = btn

local distLabel = Instance.new("TextLabel")
distLabel.Name = "DistanceLabel"
distLabel.Size = UDim2.new(1,-10,0,18)
distLabel.Position = UDim2.new(0,6,0,34)
distLabel.BackgroundTransparency = 1
distLabel.Font = Enum.Font.SourceSans
distLabel.TextSize = 14
distLabel.TextColor3 = Color3.fromRGB(200,200,200)
distLabel.TextXAlignment = Enum.TextXAlignment.Left
distLabel.Text = "Enemy distance: N/A"
distLabel.Parent = btn

local vehicleLabel = Instance.new("TextLabel")
vehicleLabel.Name = "VehicleLabel"
vehicleLabel.Size = UDim2.new(1,-10,0,18)
vehicleLabel.Position = UDim2.new(0,6,0,52)
vehicleLabel.BackgroundTransparency = 1
vehicleLabel.Font = Enum.Font.SourceSans
vehicleLabel.TextSize = 14
vehicleLabel.TextColor3 = Color3.fromRGB(200,200,200)
vehicleLabel.TextXAlignment = Enum.TextXAlignment.Left
vehicleLabel.Text = "Vehicle: N/A"
vehicleLabel.Parent = btn

-- mode toggle positioned relative to btn
local modeBtn = Instance.new("TextButton")
modeBtn.Name = "ModeToggle"
modeBtn.Size = UDim2.new(0,160,0,28)
modeBtn.Position = UDim2.new(btn.Position.X.Scale, btn.Position.X.Offset, btn.Position.Y.Scale, btn.Position.Y.Offset + 80)
modeBtn.Font = Enum.Font.SourceSans
modeBtn.TextSize = 14
modeBtn.Text = "Mode: General"
modeBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
modeBtn.TextColor3 = Color3.fromRGB(220,220,220)
modeBtn.BorderSizePixel = 0
modeBtn.Parent = screenGui

local dangerLabel = Instance.new("TextLabel")
dangerLabel.Name = "DangerIndicator"
dangerLabel.AnchorPoint = Vector2.new(0.5,0.5)
dangerLabel.Position = UDim2.new(0.5, 0, 0.65, 0)
dangerLabel.Size = UDim2.new(0.6, 0, 0.06, 0)
dangerLabel.BackgroundTransparency = 1
dangerLabel.Text = "!! DANGER !!"
dangerLabel.TextSize = 30
dangerLabel.Visible = false
dangerLabel.Parent = screenGui

local aiLabel = Instance.new("TextLabel")
aiLabel.Name = "AIControlLabel"
aiLabel.AnchorPoint = Vector2.new(0.5,0.5)
aiLabel.Position = UDim2.new(0.5,0,0.7,0)
aiLabel.Size = UDim2.new(0.6,0,0.06,0)
aiLabel.BackgroundTransparency = 1
aiLabel.TextSize = 24
aiLabel.Visible = false
aiLabel.Parent = screenGui

pcall(function()
    dangerLabel.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
    aiLabel.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
end)

-- WARNING SOUND (added)
local warnSound = Instance.new("Sound")
warnSound.Name = "AutoLockWarning"
warnSound.SoundId = "rbxassetid://18645445371"
warnSound.Volume = 2 -- 200%
warnSound.Looped = false
warnSound.PlayOnRemove = false
warnSound.Parent = screenGui

-- dragging: modeBtn follows exactly (offset +80)
local draggingBtn = false
local dragInput, dragStart, startPos
btn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        draggingBtn = true
        dragStart = input.Position
        startPos = btn.Position
        input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then draggingBtn = false end end)
    end
end)
btn.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end
end)
UIS.InputChanged:Connect(function(input)
    if input == dragInput and draggingBtn and dragStart and startPos then
        local delta = input.Position - dragStart
        btn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        modeBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + 80 + delta.Y)
    end
end)

-- update AI label text/color based on mode
local function updateAILabelForMode()
    if mode == "General" then
        aiLabel.Text = "Sentry Mode: General"
        aiLabel.TextColor3 = Color3.fromRGB(255,0,0) -- red
        modeBtn.Text = "Mode: General"
    else
        aiLabel.Text = "Sentry Mode: Anti-air"
        aiLabel.TextColor3 = Color3.fromRGB(0,120,255) -- blue
        modeBtn.Text = "Mode: Anti-air"
    end
    -- make it visible if lock enabled
    aiLabel.Visible = enabled
end

-- single connection for mode toggle (works while running)
modeBtn.MouseButton1Click:Connect(function()
    mode = (mode == "General") and "Anti-air" or "General"
    updateAILabelForMode()
end)

-- --------------
-- Highlights (unchanged but compact)
-- --------------
local function clearCharHighlight()
    if charHighlight and charHighlight.Parent then pcall(function() charHighlight:Destroy() end) end
    charHighlight = nil
end
local function clearVehicleHighlights()
    if vehicleHighlightModel and vehicleHighlightModel.Parent then pcall(function() vehicleHighlightModel:Destroy() end) end
    vehicleHighlightModel = nil
    for _,hl in ipairs(vehiclePartHighlights) do if hl and hl.Parent then pcall(function() hl:Destroy() end) end end
    vehiclePartHighlights = {}
    lastVehicleModel = nil
end
local function applyVehicleHighlight(vehicleModel, color)
    clearVehicleHighlights()
    if not vehicleModel then return end
    local ok, modelHl = pcall(function()
        local h = Instance.new("Highlight")
        h.Adornee = vehicleModel
        h.FillColor = color; h.OutlineColor = color
        h.FillTransparency = 0.85; h.OutlineTransparency = 0
        h.Parent = vehicleModel
        return h
    end)
    if ok and modelHl and modelHl.Parent then vehicleHighlightModel = modelHl lastVehicleModel = vehicleModel return end
    local parts = {}
    for _,v in ipairs(vehicleModel:GetDescendants()) do if v:IsA("BasePart") then table.insert(parts, {part=v, vol=math.abs(v.Size.X*v.Size.Y*v.Size.Z)}) end end
    table.sort(parts, function(a,b) return a.vol > b.vol end)
    local count = math.min(VEH_PART_HIGHLIGHT_LIMIT, #parts)
    for i=1,count do
        local p = parts[i].part
        local ok2, ph = pcall(function()
            local h = Instance.new("Highlight")
            h.Adornee = p
            h.FillColor = color; h.OutlineColor = color
            h.FillTransparency = 0.85; h.OutlineTransparency = 0
            h.Parent = p
            return h
        end)
        if ok2 and ph and ph.Parent then table.insert(vehiclePartHighlights, ph) end
    end
    lastVehicleModel = vehicleModel
end

local function colorForDistance(dist)
    if dist >= TIER_ORANGE then return Color3.fromRGB(255,0,0), "far"
    elseif dist >= TIER_CLOSE then return Color3.fromRGB(255,165,0), "mid"
    else return Color3.fromRGB(0,200,0), "close" end
end

local function setHighlightsIfNeeded(targetPlayer, distance)
    local vehicleModelName = "N/A"
    local color, tier = colorForDistance(distance or math.huge)
    local targetChanged = (targetPlayer ~= lastTarget)
    local tierChanged = (tier ~= lastColorTier)
    if not targetChanged and not tierChanged then return end
    clearCharHighlight(); clearVehicleHighlights()
    lastTarget = targetPlayer; lastColorTier = tier
    if not targetPlayer or not targetPlayer.Character then
        vehicleLabel.Text = "Vehicle: N/A"
        if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
        aiLabel.Visible = false; dangerLabel.Visible = false
        return
    end
    local ok, chHl = pcall(function()
        local h = Instance.new("Highlight")
        h.Adornee = targetPlayer.Character
        h.FillColor = color; h.OutlineColor = color
        h.FillTransparency = 0.7; h.OutlineTransparency = 0
        h.Parent = targetPlayer.Character
        return h
    end)
    if ok and chHl and chHl.Parent then charHighlight = chHl end
    local hum = targetPlayer.Character:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if seat then
        local vehicleModel = getVehicleModelFromSeat(seat)
        if vehicleModel then vehicleModelName = tostring(vehicleModel.Name); applyVehicleHighlight(vehicleModel, color) end
    end
    vehicleLabel.Text = "Vehicle: " .. (vehicleModelName or "N/A")
    if crosshair then pcall(function() crosshair.ImageColor3 = color end) end
    aiLabel.Visible = enabled and true or false
    if distance and distance < TIER_ORANGE then
        dangerLabel.Visible = true
        if tier == "mid" then dangerLabel.TextColor3 = Color3.fromRGB(255,165,0)
        elseif tier == "close" then dangerLabel.TextColor3 = Color3.fromRGB(255,0,0) end
    else dangerLabel.Visible = false end
end

-- -------------------
-- Main lock loop
-- -------------------
local function updateButtonVisual()
    btn.Text = enabled and "AutoLock: ON" or "AutoLock: OFF"
    dot.BackgroundColor3 = enabled and Color3.fromRGB(50,200,50) or Color3.fromRGB(200,50,50)
end

local function startLock()
    if lockConn then lockConn:Disconnect() end
    enabled = true; updateButtonVisual()
    if crosshair then pcall(function() crosshair.ImageTransparency = 0.3 end) end
    updateAILabelForMode()
    dangerLabel.Visible = false
    originalCameraMode = player.CameraMode or originalCameraMode
    pcall(function() player.CameraMode = Enum.CameraMode.LockFirstPerson end)

    lockConn = RunService.RenderStepped:Connect(function()
        if not player.Character then
            cam.CameraType = Enum.CameraType.Custom
            distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A"
            clearCharHighlight(); clearVehicleHighlights()
            currentTarget = nil
            if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
            aiLabel.Visible = false; dangerLabel.Visible = false
            isInDanger = false
            return
        end

        local head = player.Character:FindFirstChild("Head")
        local origin = head and head.Position or (player.Character:FindFirstChild("HumanoidRootPart") and (player.Character.HumanoidRootPart.Position + Vector3.new(0,1.5,0)))
        if not origin then
            cam.CameraType = Enum.CameraType.Custom
            distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A"
            clearCharHighlight(); clearVehicleHighlights()
            currentTarget = nil
            if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
            aiLabel.Visible = false; dangerLabel.Visible = false
            isInDanger = false
            return
        end

        local target = nil
        if mode == "General" then target, _ = nearestEnemy(origin) else target, _ = nearestAntiAirTarget(origin) end
        currentTarget = target

        if currentTarget then
            local targetPos = getCharacterHeadPos(currentTarget.Character)
            local hum = currentTarget.Character and currentTarget.Character:FindFirstChildOfClass("Humanoid")
            if targetPos and hum and hum.Health > 0 then
                local distVal = (targetPos - origin).Magnitude
                local aimPoint = targetPos
                local inPlane, vehicleModel = isPlayerInPlane(currentTarget)
                local shouldPredict = false
                if mode == "Anti-air" and inPlane and distVal <= PREDICTIVE_RANGE then shouldPredict = true end
                if mode == "General" and distVal <= PREDICTIVE_RANGE then shouldPredict = true end

                if shouldPredict then
                    local targetVel, fallbackSpeed = getTargetVelocityAndFallbackSpeed(currentTarget)
                    if targetVel.Magnitude < 0.5 and fallbackSpeed then
                        local seat = hum.SeatPart
                        local vehicle = seat and getVehicleModelFromSeat(seat)
                        local dir = nil
                        if vehicle and vehicle.PrimaryPart then dir = vehicle.PrimaryPart.CFrame.LookVector end
                        if (not dir or dir.Magnitude < 0.1) and (currentTarget.Character:FindFirstChild("HumanoidRootPart")) then
                            dir = currentTarget.Character.HumanoidRootPart.CFrame.LookVector
                        end
                        if dir and dir.Magnitude > 0 then targetVel = dir.Unit * fallbackSpeed end
                    end

                    if targetVel and targetVel.Magnitude > 0.01 then
                        local interceptPoint = computeInterceptPoint(origin, targetPos, targetVel, PROJECTILE_SPEED)
                        if interceptPoint then aimPoint = interceptPoint else aimPoint = targetPos + targetVel * 0.25 end
                    end
                end

                cam.CameraType = Enum.CameraType.Scriptable
                cam.CFrame = CFrame.lookAt(origin, aimPoint)

                distLabel.Text = string.format("Enemy distance: %.1f studs", distVal)
                -- play warning sound if in anti-air mode and inside danger zone (dist < TIER_ORANGE)
                local _, tier = colorForDistance(distVal)
                if mode == "Anti-air" and enabled and distVal < TIER_ORANGE then
                    local now = tick()
                    if not isInDanger then
                        -- just entered danger zone: play immediately and start timer
                        isInDanger = true
                        lastWarningTime = now
                        pcall(function()
                            warnSound:Stop()
                            warnSound:Play()
                        end)
                    else
                        -- already in danger: repeat every WARNING_INTERVAL
                        if now - lastWarningTime >= WARNING_INTERVAL then
                            lastWarningTime = now
                            pcall(function()
                                warnSound:Stop()
                                warnSound:Play()
                            end)
                        end
                    end
                else
                    -- not in danger (or not anti-air) -> reset edge state
                    isInDanger = false
                end

                setHighlightsIfNeeded(currentTarget, distVal)
                return
            else
                currentTarget = nil
                clearCharHighlight(); clearVehicleHighlights()
                if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
                aiLabel.Visible = false; dangerLabel.Visible = false
                isInDanger = false
            end
        end

        cam.CameraType = Enum.CameraType.Custom
        distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A"
        clearCharHighlight(); clearVehicleHighlights()
        if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
        aiLabel.Visible = false; dangerLabel.Visible = false
        isInDanger = false
    end)
end

local function stopLock()
    if lockConn then lockConn:Disconnect() lockConn = nil end
    enabled = false; currentTarget = nil; updateButtonVisual()
    clearCharHighlight(); clearVehicleHighlights()
    vehicleLabel.Text = "Vehicle: N/A"
    if crosshair then pcall(function() crosshair.ImageTransparency = 0.6 crosshair.ImageColor3 = Color3.new(1,1,1) end) end
    aiLabel.Visible = false; dangerLabel.Visible = false
    pcall(function() player.CameraMode = originalCameraMode or Enum.CameraMode.Classic end)
    cam.CameraType = Enum.CameraType.Custom
    distLabel.Text = "Enemy distance: N/A"
    isInDanger = false
end

-- main toggle
btn.MouseButton1Click:Connect(function()
    if enabled then stopLock() else startLock() end
end)

-- respawn handling
player.CharacterAdded:Connect(function()
    task.wait(0.05)
    refreshCrosshair()
    updateAILabelForMode()
    if enabled then pcall(function() player.CameraMode = Enum.CameraMode.LockFirstPerson end); if crosshair then pcall(function() crosshair.ImageTransparency = 0.3 end) end; aiLabel.Visible = true end
end)

Players.PlayerRemoving:Connect(function(rem) if rem == player then stopLock() end end)

-- init
refreshCrosshair()
updateButtonVisual()
updateAILabelForMode()
