-- Version 1.33
-- AutoLock — full LocalScript with targeted vehicle/HP + danger fixes
-- Place in StarterPlayer -> StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local cam = Workspace.CurrentCamera

local MODE_CONFIG = {
    ["Anti-air"] = { TIER_ORANGE = 2200, PREDICTIVE_RANGE = 2000, TIER_CLOSE = 700, CRITICAL_SOUND = true, PREDICTIVE_SPEED = 800 },
    ["Anti-ship"] = { TIER_ORANGE = 2300, PREDICTIVE_RANGE = 2100, TIER_CLOSE = 1000, CRITICAL_SOUND = false },
    ["General"]  = { TIER_ORANGE = 2000, PREDICTIVE_RANGE = 1800, TIER_CLOSE = 700, CRITICAL_SOUND = false, PREDICTIVE_SPEED = 800 },
}

local INFANTRY_RANGE = 300
local VEH_PART_HIGHLIGHT_LIMIT = 10
local MAX_CACHE_DISTANCE = 3000
local POS_SMOOTH_ALPHA = 0.35

local PLANE_EXACT = { ["Bomber"]=true, ["Large Bomber"]=true, ["Torpedo Bomber"]=true }
local PLANE_TOKENS = { "bomber", "torpedo", "plane", "aircraft" }

local SHIP_EXACT = { ["Battleship"]=true, ["Carrier"]=true, ["Destroyer"]=true, ["Cruiser"]=true, ["Heavy Cruiser"]=true }
local SHIP_PRIORITY_ORDER = { "N/A", "Battleship", "Carrier", "Destroyer", "Cruiser", "Heavy Cruiser" }

local KNOWN_SPEEDS = {
    ["large bomber"] = 105, ["largebomber"] = 105,
    ["bomber"] = 115,
    ["torpedo bomber"] = 115, ["torpedobomber"] = 115
}

local BULLET_TYPES = {
    Battleship = { Speed = 821, Mass = 2.8, AntiGravityForce = 457.79998779296875 },
    Normal     = { Speed = 821, Mass = 1.792, AntiGravityForce = 292.992 },
}

local WARNING_SOUND_ID = "rbxassetid://18645445371"
local WARNING_INTERVAL = 1.5
local PREDICTIVE_SOUND_ID = "rbxassetid://98846874631020"
local PREDICTIVE_VOLUME = 1.5
local CRITICAL_SOUND_ID = "rbxassetid://95303400990791"
local CRITICAL_VOLUME = 1

local enabled = false
local lockConn = nil
local currentTarget = nil
local originalCameraMode = player.CameraMode
local mode = "Anti-air"
local priorityIndex = 1
local bulletTypeName = "Battleship"

local positionCache = {}
local charHighlight, vehicleHighlightModel
local vehiclePartHighlights = {}
local lastColorTier, lastTarget, lastVehicleModel, lastVehicleHP

local isInDanger = false
local lastWarningTime = 0
local isInCritical = false
local lastPredicting = false
local lastPredictTarget = nil

local crosshair = nil

local function findAimInPlayerGui()
    for _,inst in ipairs(playerGui:GetDescendants()) do
        if inst.Name == "Aim" and (inst:IsA("ImageLabel") or inst:IsA("ImageButton")) then
            return inst
        end
    end
    return nil
end

local function centerCrosshair(inst)
    if not inst then return end
    pcall(function()
        inst.AnchorPoint = Vector2.new(0.5,0.5)
        inst.Position = UDim2.new(0.5,0,0.5,0)
    end)
end

local function refreshCrosshair()
    crosshair = findAimInPlayerGui()
    if crosshair then
        centerCrosshair(crosshair)
        pcall(function() crosshair.ImageTransparency = enabled and 0.3 or 0.6 end)
    end
end

RunService.RenderStepped:Connect(function()
    if not crosshair then refreshCrosshair() end
    if crosshair then pcall(function() crosshair.AnchorPoint = Vector2.new(0.5,0.5); crosshair.Position = UDim2.new(0.5,0,0.5,0) end) end
end)
playerGui.DescendantAdded:Connect(function(desc)
    if desc.Name == "Aim" and (desc:IsA("ImageLabel") or desc:IsA("ImageButton")) then
        crosshair = desc; centerCrosshair(crosshair)
        pcall(function() crosshair.ImageTransparency = enabled and 0.3 or 0.6 end)
    end
end)

local function getCharacterHeadPos(ch)
    if not ch then return nil end
    local head = ch:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head.Position end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position + Vector3.new(0,1.5,0) end
    return nil
end

local function getVehicleModelFromSeat(seat)
    if not seat then return nil end
    local node = seat
    while node and not node:IsA("Model") do node = node.Parent end
    return node or seat.Parent
end

local function isPlayerSeated(plr)
    if not plr or not plr.Character then return false, nil end
    local hum = plr.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return false, nil end
    local seat = hum.SeatPart
    if not seat then return false, nil end
    return true, getVehicleModelFromSeat(seat)
end

local function stringContainsTokenInsensitive(str, tokens)
    if not str then return false end
    local lower = string.lower(str)
    for _,tok in ipairs(tokens) do
        if string.find(lower, tok, 1, true) then return true end
    end
    return false
end

local function isPlayerInPlane(plr)
    if not plr or not plr.Character then return false, nil, false end
    local hum = plr.Character:FindFirstChildOfClass("Humanoid")
    if not hum then return false, nil, false end
    local seat = hum.SeatPart
    if not seat then return false, nil, false end
    local vehicle = getVehicleModelFromSeat(seat)
    if not vehicle then return false, nil, false end
    local ok, nm = pcall(function() return tostring(vehicle.Name or "") end)
    nm = (ok and nm) or ""
    if PLANE_EXACT[nm] then return true, vehicle, true end
    if stringContainsTokenInsensitive(nm, PLANE_TOKENS) then return true, vehicle, false end
    local okType, tv = pcall(function() return vehicle:FindFirstChild("VehicleType") end)
    if okType and tv and tv:IsA("StringValue") then
        local v = tostring(tv.Value or "")
        if PLANE_EXACT[v] then return true, vehicle, true end
        if stringContainsTokenInsensitive(v, PLANE_TOKENS) then return true, vehicle, false end
    end
    if vehicle.GetAttribute then
        local okAttr, av = pcall(function() return vehicle:GetAttribute("VehicleType") end)
        if okAttr and type(av) == "string" then
            if PLANE_EXACT[av] then return true, vehicle, true end
            if stringContainsTokenInsensitive(av, PLANE_TOKENS) then return true, vehicle, false end
        end
    end
    return false, vehicle, false
end

local function isShipExact(vehicle)
    if not vehicle then return false end
    local ok, nm = pcall(function() return tostring(vehicle.Name or "") end)
    nm = (ok and nm) or ""
    if SHIP_EXACT[nm] then return true end
    local okType, tv = pcall(function() return vehicle:FindFirstChild("VehicleType") end)
    if okType and tv and tv:IsA("StringValue") then
        if SHIP_EXACT[tostring(tv.Value or "")] then return true end
    end
    if vehicle.GetAttribute then
        local okAttr, av = pcall(function() return vehicle:GetAttribute("VehicleType") end)
        if okAttr and type(av) == "string" and SHIP_EXACT[av] then return true end
    end
    return false
end

local function isVehicleDead(vehicle)
    if not vehicle then return false, nil end
    local hpObj = vehicle:FindFirstChild("HP")
    if hpObj and (hpObj:IsA("IntValue") or hpObj:IsA("NumberValue")) then
        return hpObj.Value <= 0, hpObj.Value
    end
    local ok, attr = pcall(function() return vehicle:GetAttribute("HP") end)
    if ok and type(attr) == "number" then
        return attr <= 0, attr
    end
    return false, nil
end

local function validTargetGeneral(p)
    if not p or p == player then return false end
    if p.Team == player.Team then return false end
    local ch = p.Character
    if not ch then return false end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local seated, vehicle = isPlayerSeated(p)
    if seated and vehicle then
        local dead, _ = isVehicleDead(vehicle)
        if dead then return false end
    end
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
                        local inPlane, vehicleModel = isPlayerInPlane(plr)
                        local eligible = false
                        if inPlane then
                            local dead, _ = isVehicleDead(vehicleModel)
                            if not dead then eligible = true end
                        else
                            if dist <= INFANTRY_RANGE then eligible = true end
                        end
                        if eligible and dist < bestDist then bestDist, nearest = dist, plr end
                    end
                end
            end
        end
    end
    return nearest, bestDist
end

local function nearestEnemyWithVehicleHP(origin)
    local nearest, bestDist = nil, math.huge
    for _,plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Team ~= player.Team then
            local ch = plr.Character
            if ch then
                local hum = ch:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local pos = getCharacterHeadPos(ch)
                    if pos then
                        local seated, vehicle = isPlayerSeated(plr)
                        local skip = false
                        if seated and vehicle then
                            local dead, _ = isVehicleDead(vehicle)
                            if dead then skip = true end
                        end
                        if not skip then
                            local d = (pos - origin).Magnitude
                            if d < bestDist then bestDist, nearest = d, plr end
                        end
                    end
                end
            end
        end
    end
    return nearest, bestDist
end

local function nearestAntiShipTarget(origin)
    local prefer = SHIP_PRIORITY_ORDER[priorityIndex]
    local candidates = {}
    for _,plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Team ~= player.Team then
            local ch = plr.Character
            if ch then
                local hum = ch:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    local headPos = getCharacterHeadPos(ch)
                    if headPos then
                        local seated, vehicle = isPlayerSeated(plr)
                        if seated and vehicle and isShipExact(vehicle) then
                            local dead, _ = isVehicleDead(vehicle)
                            if not dead then
                                local ok, nm = pcall(function() return tostring(vehicle.Name or "") end)
                                nm = (ok and nm) or ""
                                table.insert(candidates, { player = plr, pos = headPos, vehicle = vehicle, name = nm })
                            end
                        end
                    end
                end
            end
        end
    end
    local best, bestDist = nil, math.huge
    if prefer ~= "N/A" then
        for _, cand in ipairs(candidates) do
            if cand.name == prefer then
                local d = (cand.pos - origin).Magnitude
                if d < bestDist then bestDist, best = d, cand.player end
            end
        end
        if not best then
            for _, cand in ipairs(candidates) do
                local d = (cand.pos - origin).Magnitude
                if d < bestDist then bestDist, best = d, cand.player end
            end
        end
    else
        for _, cand in ipairs(candidates) do
            local d = (cand.pos - origin).Magnitude
            if d < bestDist then bestDist, best = d, cand.player end
        end
    end
    return best, (best and bestDist) or math.huge
end

local function updatePositionCache(origin)
    local now = tick()
    for _,plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch then
            local ok,pos = pcall(function() return getCharacterHeadPos(ch) end)
            if not ok or not pos then
                local hrp = ch:FindFirstChild("HumanoidRootPart")
                if hrp then pos = hrp.Position end
            end
            if pos then
                local dist = (pos - origin).Magnitude
                if dist <= MAX_CACHE_DISTANCE then
                    local prev = positionCache[plr]
                    if prev and prev.pos and prev.time and now - prev.time > 0 then
                        local dt = math.max(1e-4, now - prev.time)
                        local rawVel = (pos - prev.pos) / dt
                        local sm = prev.vel and (prev.vel * (1 - POS_SMOOTH_ALPHA) + rawVel * POS_SMOOTH_ALPHA) or rawVel
                        positionCache[plr] = { pos = pos, time = now, vel = sm }
                    else
                        positionCache[plr] = { pos = pos, time = now, vel = Vector3.new(0,0,0) }
                    end
                else
                    positionCache[plr] = nil
                end
            else
                positionCache[plr] = nil
            end
        else
            positionCache[plr] = nil
        end
    end
end

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
                if vehicle.PrimaryPart then
                    local ok,v = pcall(function() return vehicle.PrimaryPart.AssemblyLinearVelocity end)
                    if ok and v then vel = v end
                end
                if (not vel or vel.Magnitude < 0.01) then
                    local ok2,v2 = pcall(function() return seat.AssemblyLinearVelocity end)
                    if ok2 and v2 then vel = v2 end
                end
                if (not vel or vel.Magnitude < 0.01) then
                    for _,d in ipairs(vehicle:GetDescendants()) do
                        if d:IsA("BasePart") then
                            local ok3,av = pcall(function() return d.AssemblyLinearVelocity end)
                            if ok3 and av and av.Magnitude > 0.01 then vel = av; break end
                        end
                    end
                end
                if vel and vel.Magnitude >= 0.5 then return vel, vel.Magnitude end
                local cache = positionCache[targetPlayer]
                if cache and cache.vel and cache.vel.Magnitude >= 0.5 then return cache.vel, cache.vel.Magnitude end
                local nm = string.lower(tostring(vehicle.Name or ""))
                for key,s in pairs(KNOWN_SPEEDS) do
                    if string.find(nm, key, 1, true) then
                        local dir = nil
                        if vehicle.PrimaryPart then dir = vehicle.PrimaryPart.CFrame.LookVector end
                        if (not dir or dir.Magnitude < 0.1) and seat and seat.CFrame then dir = seat.CFrame.LookVector end
                        if (not dir or dir.Magnitude < 0.1) and hrp then dir = hrp.CFrame.LookVector end
                        dir = (dir and dir.Magnitude>0 and dir.Unit) or Vector3.new(0,0,0)
                        if dir.Magnitude > 0 then return dir * s, s end
                    end
                end
            end
        end
    end
    if hrp and hrp.Velocity and hrp.Velocity.Magnitude >= 0.5 then return hrp.Velocity, hrp.Velocity.Magnitude end
    local cache2 = positionCache[targetPlayer]
    if cache2 and cache2.vel and cache2.vel.Magnitude >= 0.5 then return cache2.vel, cache2.vel.Magnitude end
    return Vector3.new(0,0,0), nil
end

local function computeInterceptPointNoGravity(origin, targetPos, targetVel, projectileSpeed)
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
    return targetPos + targetVel * t
end

local function computeInterceptPointWithGravity(origin, targetPos, targetVel, projectileSpeed, gravityVec, maxTime)
    maxTime = maxTime or 10
    if projectileSpeed <= 0 then return nil end
    local r = targetPos - origin
    local function f(t)
        local term = r + targetVel * t - 0.5 * gravityVec * (t*t)
        local lhs = (projectileSpeed * t) * (projectileSpeed * t)
        local rhs = term:Dot(term)
        return lhs - rhs
    end
    local tmin, tmax = 0.01, maxTime
    local step = 0.05
    local prevT = tmin
    local prevF = f(prevT)
    local foundT = nil
    local t = prevT
    while t < tmax do
        t = t + step
        local curF = f(t)
        if prevF == 0 then foundT = prevT; break end
        if prevF * curF < 0 then
            local a,b = prevT, t
            for i=1,28 do
                local m = (a + b) / 2
                if f(a) * f(m) <= 0 then b = m else a = m end
            end
            foundT = (a + b) / 2
            break
        end
        prevT, prevF = t, curF
    end
    if not foundT then return nil end
    if foundT <= 0 or foundT > maxTime then return nil end
    local u = (r + targetVel * foundT - 0.5 * gravityVec * (foundT * foundT)) / foundT
    local aimPoint = origin + u * foundT
    return aimPoint
end

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
    lastVehicleHP = nil
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
    if ok and modelHl and modelHl.Parent then vehicleHighlightModel = modelHl; lastVehicleModel = vehicleModel; return end
    local parts = {}
    for _,v in ipairs(vehicleModel:GetDescendants()) do
        if v:IsA("BasePart") then
            table.insert(parts, { part = v, vol = math.abs(v.Size.X * v.Size.Y * v.Size.Z) })
        end
    end
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

local function colorForDistance(dist, currentMode)
    local cfg = MODE_CONFIG[currentMode] or MODE_CONFIG["General"]
    local orange = cfg.TIER_ORANGE
    local close = cfg.TIER_CLOSE
    if dist >= orange then
        return Color3.fromRGB(255,0,0), "far"
    elseif dist >= close then
        return Color3.fromRGB(255,165,0), "mid"
    else
        return Color3.fromRGB(0,200,0), "close"
    end
end

local function detectVehicleModelForPlayer(plr)
    if not plr or not plr.Character then return nil end
    local char = plr.Character
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        local seat = hum.SeatPart
        if seat then
            local node = seat
            for i=1,12 do
                if not node then break end
                if node:IsA("Model") and node ~= char then
                    return node
                end
                node = node.Parent
            end
            local bySeat = getVehicleModelFromSeat(seat)
            if bySeat and bySeat ~= char then return bySeat end
        end
    end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local node = hrp
        for i=1,12 do
            if not node then break end
            if node:IsA("Model") and node ~= char then return node end
            node = node.Parent
        end
    end
    for _,part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            local node = part
            for i=1,12 do
                if not node then break end
                if node:IsA("Model") and node ~= char then
                    if node:FindFirstChild("HP") or node:FindFirstChild("VehicleType") or node.PrimaryPart then
                        return node
                    else
                        return node
                    end
                end
                node = node.Parent
            end
        end
    end
    return nil
end

local function setHighlightsIfNeeded(targetPlayer, distance, currentMode)
    local vehicleModelName = "N/A"
    local hpVal = nil
    local color, tier = colorForDistance(distance or math.huge, currentMode)
    local targetChanged = (targetPlayer ~= lastTarget)
    local tierChanged = (tier ~= lastColorTier)
    local vehicleModel = nil
    local vehicleModelChanged = false
    local vehicleHPChanged = false

    if targetPlayer and targetPlayer.Character then
        vehicleModel = detectVehicleModelForPlayer(targetPlayer)
        if vehicleModel ~= lastVehicleModel then vehicleModelChanged = true end

        if vehicleModel then
            local okHP, hpObj = pcall(function() return vehicleModel:FindFirstChild("HP") end)
            if okHP and hpObj and (hpObj:IsA("IntValue") or hpObj:IsA("NumberValue")) then
                hpVal = hpObj.Value
            else
                local okAttr, attr = pcall(function() return vehicleModel:GetAttribute("HP") end)
                if okAttr and type(attr) == "number" then hpVal = attr end
            end
            if hpVal ~= lastVehicleHP then vehicleHPChanged = true end
            local okName, nm = pcall(function() return tostring(vehicleModel.Name or "N/A") end)
            vehicleModelName = (okName and nm) or "N/A"
        end
    end

    local shouldRecreateHighlights = targetChanged or tierChanged or vehicleModelChanged

    if shouldRecreateHighlights then
        clearCharHighlight()
        if vehicleModelChanged then clearVehicleHighlights() end
    end

    if targetChanged then
        lastTarget = targetPlayer
        lastColorTier = tier
    else
        lastColorTier = tier
    end

    if targetPlayer and targetPlayer.Character then
        if shouldRecreateHighlights then
            local ok, chHl = pcall(function()
                local h = Instance.new("Highlight")
                h.Adornee = targetPlayer.Character
                h.FillColor = color; h.OutlineColor = color
                h.FillTransparency = 0.7; h.OutlineTransparency = 0
                h.Parent = targetPlayer.Character
                return h
            end)
            if ok and chHl and chHl.Parent then charHighlight = chHl end
            if vehicleModel then
                applyVehicleHighlight(vehicleModel, color)
            end
        else
            if vehicleModelChanged then
                applyVehicleHighlight(vehicleModel, color)
            end
        end
    else
        pcall(function() vehicleLabel.Text = "Vehicle: N/A | HP: N/A"; velocityLabel.Text = "Velocity: N/A" end)
        if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
        if aiLabel then pcall(function() aiLabel.Visible = false end) end
        if dangerLabel then pcall(function() dangerLabel.Visible = false end) end
        lastVehicleModel = nil
        lastVehicleHP = nil
        return
    end

    pcall(function()
        if hpVal ~= nil then
            vehicleLabel.Text = string.format("Vehicle: %s | HP: %d", vehicleModelName or "N/A", hpVal)
        else
            vehicleLabel.Text = string.format("Vehicle: %s | HP: N/A", vehicleModelName or "N/A")
        end
    end)

    if crosshair then pcall(function() crosshair.ImageColor3 = color end) end
    if aiLabel then pcall(function() aiLabel.Visible = enabled end) end

    local cfg = MODE_CONFIG[currentMode] or MODE_CONFIG["General"]
    if distance and distance < cfg.TIER_ORANGE then
        if dangerLabel then pcall(function() dangerLabel.Visible = true end) end
        if tier == "mid" then pcall(function() dangerLabel.TextColor3 = Color3.fromRGB(255,165,0) end)
        elseif tier == "close" then pcall(function() dangerLabel.TextColor3 = Color3.fromRGB(255,0,0) end) end
    else
        if dangerLabel then pcall(function() dangerLabel.Visible = false end) end
    end

    lastVehicleModel = vehicleModel
    lastVehicleHP = hpVal
end

-- UI build
local UI_WIDTH = 160
local X_OFFSET = 20
local Y_OFFSET = 120
local GAP_UI = 2
local INFO_HEIGHT = 56

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoLockToggleGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local toggleBtn = Instance.new("TextButton")
toggleBtn.Name = "AutoLockToggleBtn"
toggleBtn.Size = UDim2.new(0, UI_WIDTH, 0, 42)
toggleBtn.Position = UDim2.new(0, X_OFFSET, 0, Y_OFFSET)
toggleBtn.Font = Enum.Font.SourceSansSemibold
toggleBtn.TextSize = 18
toggleBtn.AutoButtonColor = false
toggleBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)
toggleBtn.TextColor3 = Color3.fromRGB(255,255,255)
toggleBtn.BorderSizePixel = 0
toggleBtn.Parent = screenGui
toggleBtn.Active = true; toggleBtn.Selectable = true

local indicator = Instance.new("Frame")
indicator.Name = "Indicator"
indicator.Size = UDim2.new(0,12,0,12)
indicator.Position = UDim2.new(1,-18,0.5,-6)
indicator.BackgroundColor3 = Color3.fromRGB(200,50,50)
indicator.BorderSizePixel = 0
indicator.Parent = toggleBtn

local infoFrame = Instance.new("Frame")
infoFrame.Name = "AutoLockInfo"
infoFrame.Size = UDim2.new(0, UI_WIDTH, 0, INFO_HEIGHT)
infoFrame.Position = UDim2.new(0, X_OFFSET, 0, Y_OFFSET + toggleBtn.Size.Y.Offset + GAP_UI)
infoFrame.BackgroundTransparency = 0.08
infoFrame.BackgroundColor3 = Color3.fromRGB(40,40,40)
infoFrame.BorderSizePixel = 0
infoFrame.Parent = screenGui

local distLabel = Instance.new("TextLabel")
distLabel.Name = "DistanceLabel"
distLabel.Size = UDim2.new(1,-8,0,16)
distLabel.Position = UDim2.new(0,4,0,4)
distLabel.BackgroundTransparency = 1
distLabel.Font = Enum.Font.SourceSans
distLabel.TextSize = 13
distLabel.TextColor3 = Color3.fromRGB(200,200,200)
distLabel.TextXAlignment = Enum.TextXAlignment.Left
distLabel.Text = "Enemy distance: N/A"
distLabel.Parent = infoFrame

local vehicleLabel = Instance.new("TextLabel")
vehicleLabel.Name = "VehicleLabel"
vehicleLabel.Size = UDim2.new(1,-8,0,16)
vehicleLabel.Position = UDim2.new(0,4,0,4 + 16 + 2)
vehicleLabel.BackgroundTransparency = 1
vehicleLabel.Font = Enum.Font.SourceSans
vehicleLabel.TextSize = 13
vehicleLabel.TextColor3 = Color3.fromRGB(200,200,200)
vehicleLabel.TextXAlignment = Enum.TextXAlignment.Left
vehicleLabel.Text = "Vehicle: N/A | HP: N/A"
vehicleLabel.Parent = infoFrame

local velocityLabel = Instance.new("TextLabel")
velocityLabel.Name = "VelocityLabel"
velocityLabel.Size = UDim2.new(1,-8,0,16)
velocityLabel.Position = UDim2.new(0,4,0,4 + 16*2 + 4)
velocityLabel.BackgroundTransparency = 1
velocityLabel.Font = Enum.Font.SourceSans
velocityLabel.TextSize = 13
velocityLabel.TextColor3 = Color3.fromRGB(200,200,200)
velocityLabel.TextXAlignment = Enum.TextXAlignment.Left
velocityLabel.Text = "Velocity: N/A"
velocityLabel.Parent = infoFrame

local modeBtn = Instance.new("TextButton")
modeBtn.Name = "ModeToggle"
modeBtn.Size = UDim2.new(0, UI_WIDTH, 0, 28)
modeBtn.Position = UDim2.new(0, X_OFFSET, 0, Y_OFFSET + toggleBtn.Size.Y.Offset + GAP_UI + infoFrame.Size.Y.Offset + GAP_UI)
modeBtn.Font = Enum.Font.SourceSans
modeBtn.TextSize = 14
modeBtn.Text = "Mode: " .. mode
modeBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
modeBtn.TextColor3 = Color3.fromRGB(220,220,220)
modeBtn.BorderSizePixel = 0
modeBtn.Parent = screenGui

local priorityBtn = Instance.new("TextButton")
priorityBtn.Name = "PriorityBtn"
priorityBtn.Size = UDim2.new(0, UI_WIDTH, 0, 26)
priorityBtn.Position = UDim2.new(0, X_OFFSET, 0, modeBtn.Position.Y.Offset + modeBtn.Size.Y.Offset + 2)
priorityBtn.Font = Enum.Font.SourceSans
priorityBtn.TextSize = 13
priorityBtn.Text = "Priority: " .. SHIP_PRIORITY_ORDER[priorityIndex]
priorityBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
priorityBtn.TextColor3 = Color3.fromRGB(220,220,220)
priorityBtn.BorderSizePixel = 0
priorityBtn.Parent = screenGui

local bulletBtn = Instance.new("TextButton")
bulletBtn.Name = "BulletTypeBtn"
bulletBtn.Size = UDim2.new(0, UI_WIDTH, 0, 26)
bulletBtn.Position = UDim2.new(0, X_OFFSET, 0, priorityBtn.Position.Y.Offset + priorityBtn.Size.Y.Offset + 2)
bulletBtn.Font = Enum.Font.SourceSans
bulletBtn.TextSize = 13
bulletBtn.Text = "Bullet Type: " .. (mode == "Anti-ship" and bulletTypeName or "N/A")
bulletBtn.BackgroundColor3 = Color3.fromRGB(40,40,40)
bulletBtn.TextColor3 = Color3.fromRGB(220,220,220)
bulletBtn.BorderSizePixel = 0
bulletBtn.Parent = screenGui

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

local draggingBtn = false
local dragInput, dragStart, startTogglePos, startInfoPos, startModePos, startPriorityPos, startBulletPos
toggleBtn.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        draggingBtn = true
        dragStart = input.Position
        startTogglePos = toggleBtn.Position
        startInfoPos = infoFrame.Position
        startModePos = modeBtn.Position
        startPriorityPos = priorityBtn.Position
        startBulletPos = bulletBtn.Position
        input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then draggingBtn = false end end)
    end
end)
toggleBtn.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then dragInput = input end
end)
UIS.InputChanged:Connect(function(input)
    if input == dragInput and draggingBtn and dragStart and startTogglePos then
        local delta = input.Position - dragStart
        toggleBtn.Position = UDim2.new(startTogglePos.X.Scale, startTogglePos.X.Offset + delta.X, startTogglePos.Y.Scale, startTogglePos.Y.Offset + delta.Y)
        infoFrame.Position = UDim2.new(startInfoPos.X.Scale, startInfoPos.X.Offset + delta.X, startInfoPos.Y.Scale, startInfoPos.Y.Offset + delta.Y)
        modeBtn.Position = UDim2.new(startModePos.X.Scale, startModePos.X.Offset + delta.X, startModePos.Y.Scale, startModePos.Y.Offset + delta.Y)
        priorityBtn.Position = UDim2.new(startPriorityPos.X.Scale, startPriorityPos.X.Offset + delta.X, startPriorityPos.Y.Scale, startPriorityPos.Y.Offset + delta.Y)
        bulletBtn.Position = UDim2.new(startBulletPos.X.Scale, startBulletPos.X.Offset + delta.X, startBulletPos.Y.Scale, startBulletPos.Y.Offset + delta.Y)
    end
end)

local warnSound = Instance.new("Sound"); warnSound.Parent = screenGui
warnSound.Name = "AutoLockWarning"; warnSound.SoundId = WARNING_SOUND_ID; warnSound.Volume = 2; warnSound.Looped = false

local predictiveSound = Instance.new("Sound"); predictiveSound.Parent = screenGui
predictiveSound.Name = "AutoLockPredictive"; predictiveSound.SoundId = PREDICTIVE_SOUND_ID; predictiveSound.Volume = PREDICTIVE_VOLUME; predictiveSound.Looped = false

local criticalSound = Instance.new("Sound"); criticalSound.Parent = screenGui
criticalSound.Name = "AutoLockCritical"; criticalSound.SoundId = CRITICAL_SOUND_ID; criticalSound.Volume = CRITICAL_VOLUME; criticalSound.Looped = true

local modeOrder = { "Anti-air", "Anti-ship", "General" }
local function cycleMode()
    local i = 1
    for idx,m in ipairs(modeOrder) do if m == mode then i = idx; break end end
    i = (i % #modeOrder) + 1
    mode = modeOrder[i]
    modeBtn.Text = "Mode: " .. mode
    if mode ~= "Anti-ship" then
        priorityIndex = 1
        priorityBtn.Text = "Priority: " .. SHIP_PRIORITY_ORDER[priorityIndex]
        bulletTypeName = nil
        bulletBtn.Text = "Bullet Type: N/A"
    else
        bulletTypeName = bulletTypeName or "Battleship"
        bulletBtn.Text = "Bullet Type: " .. bulletTypeName
    end
    aiLabel.Text = "Sentry Mode: " .. mode
    if mode == "Anti-ship" then aiLabel.TextColor3 = Color3.fromRGB(255,140,0)
    elseif mode == "Anti-air" then aiLabel.TextColor3 = Color3.fromRGB(0,120,255)
    else aiLabel.TextColor3 = Color3.fromRGB(255,0,0) end
end
modeBtn.MouseButton1Click:Connect(cycleMode)

priorityBtn.MouseButton1Click:Connect(function()
    if mode ~= "Anti-ship" then
        priorityIndex = 1
        priorityBtn.Text = "Priority: N/A"
        return
    end
    priorityIndex = (priorityIndex % #SHIP_PRIORITY_ORDER) + 1
    priorityBtn.Text = "Priority: " .. SHIP_PRIORITY_ORDER[priorityIndex]
end)

bulletBtn.MouseButton1Click:Connect(function()
    if mode ~= "Anti-ship" then
        bulletTypeName = nil
        bulletBtn.Text = "Bullet Type: N/A"
        return
    end
    if bulletTypeName == "Battleship" then bulletTypeName = "Normal" else bulletTypeName = "Battleship" end
    bulletBtn.Text = "Bullet Type: " .. bulletTypeName
end)

local function updateButtonVisual()
    toggleBtn.Text = enabled and "AutoLock: ON" or "AutoLock: OFF"
    indicator.BackgroundColor3 = enabled and Color3.fromRGB(50,200,50) or Color3.fromRGB(200,50,50)
end

-- NEW minimal vehicle info updater (calls only to update the vehicle label each frame)
local function updateVehicleInfoEveryFrame(targetPlayer)
    if not targetPlayer or not targetPlayer.Character then
        pcall(function() vehicleLabel.Text = "Vehicle: N/A | HP: N/A" end)
        return
    end

    local hum = targetPlayer.Character:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart

    if seat then
        local vehicleModel = getVehicleModelFromSeat(seat)
        if vehicleModel then
            local vehicleName = tostring(vehicleModel.Name or "N/A")
            local hpVal = nil

            local hpObj = vehicleModel:FindFirstChild("HP")
            if hpObj and (hpObj:IsA("IntValue") or hpObj:IsA("NumberValue")) then
                hpVal = hpObj.Value
            else
                local ok, attr = pcall(function() return vehicleModel:GetAttribute("HP") end)
                if ok and type(attr) == "number" then
                    hpVal = attr
                end
            end

            pcall(function()
                if hpVal then
                    vehicleLabel.Text = string.format("Vehicle: %s | HP: %d", vehicleName, hpVal)
                else
                    vehicleLabel.Text = string.format("Vehicle: %s | HP: N/A", vehicleName)
                end
            end)
            return
        end
    end

    pcall(function() vehicleLabel.Text = "Vehicle: N/A | HP: N/A" end)
end

local function stopLock()
    if lockConn then lockConn:Disconnect(); lockConn = nil end
    enabled = false
    currentTarget = nil
    updateButtonVisual()
    clearCharHighlight(); clearVehicleHighlights()
    pcall(function() vehicleLabel.Text = "Vehicle: N/A | HP: N/A" end)
    if crosshair then pcall(function() crosshair.ImageTransparency = 0.6; crosshair.ImageColor3 = Color3.new(1,1,1) end) end
    aiLabel.Visible = false; dangerLabel.Visible = false
    pcall(function() player.CameraMode = originalCameraMode or Enum.CameraMode.Classic end)
    cam.CameraType = Enum.CameraType.Custom
    pcall(function() distLabel.Text = "Enemy distance: N/A" end)
    isInDanger = false
    if isInCritical then isInCritical = false; pcall(function() criticalSound:Stop() end) end
    lastPredicting = false; lastPredictTarget = nil
end

local function startLock()
    if lockConn then lockConn:Disconnect() end
    enabled = true; updateButtonVisual()
    if crosshair then pcall(function() crosshair.ImageTransparency = 0.3 end) end
    aiLabel.Visible = true
    aiLabel.Text = "Sentry Mode: " .. mode
    if mode == "Anti-ship" then aiLabel.TextColor3 = Color3.fromRGB(255,140,0)
    elseif mode == "Anti-air" then aiLabel.TextColor3 = Color3.fromRGB(0,120,255)
    else aiLabel.TextColor3 = Color3.fromRGB(255,0,0) end
    originalCameraMode = player.CameraMode or originalCameraMode
    pcall(function() player.CameraMode = Enum.CameraMode.LockFirstPerson end)

    lockConn = RunService.RenderStepped:Connect(function()
        if not player.Character then
            cam.CameraType = Enum.CameraType.Custom
            pcall(function() distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A | HP: N/A"; velocityLabel.Text = "Velocity: N/A" end)
            clearCharHighlight(); clearVehicleHighlights()
            currentTarget = nil
            if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
            aiLabel.Visible = false; dangerLabel.Visible = false
            isInDanger = false; isInCritical = false
            lastPredicting = false; lastPredictTarget = nil
            return
        end

        local head = player.Character:FindFirstChild("Head")
        local origin = head and head.Position or (player.Character:FindFirstChild("HumanoidRootPart") and (player.Character.HumanoidRootPart.Position + Vector3.new(0,1.5,0)))
        if not origin then
            cam.CameraType = Enum.CameraType.Custom
            pcall(function() distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A | HP: N/A"; velocityLabel.Text = "Velocity: N/A" end)
            clearCharHighlight(); clearVehicleHighlights()
            currentTarget = nil
            if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
            aiLabel.Visible = false; dangerLabel.Visible = false
            isInDanger = false; isInCritical = false
            lastPredicting = false; lastPredictTarget = nil
            return
        end

        updatePositionCache(origin)
        local target, distVal
        if mode == "General" then
            target, distVal = nearestEnemyWithVehicleHP(origin)
        elseif mode == "Anti-air" then
            target, distVal = nearestAntiAirTarget(origin)
        else
            target, distVal = nearestAntiShipTarget(origin)
        end
        currentTarget = target

        if currentTarget then
            local vehicleModelForTarget = detectVehicleModelForPlayer(currentTarget)
            if vehicleModelForTarget then
                local dead, hpv = isVehicleDead(vehicleModelForTarget)
                if dead then
                    currentTarget = nil
                    clearCharHighlight(); clearVehicleHighlights()
                    if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
                    aiLabel.Visible = false; dangerLabel.Visible = false
                    isInDanger = false
                    if isInCritical then isInCritical = false; pcall(function() criticalSound:Stop() end) end
                    lastPredicting = false; lastPredictTarget = nil
                    cam.CameraType = Enum.CameraType.Custom
                    pcall(function() distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A | HP: N/A"; velocityLabel.Text = "Velocity: N/A" end)
                    return
                end
            end
        end

        if currentTarget then
            local targetPos = getCharacterHeadPos(currentTarget.Character)
            local hum = currentTarget.Character and currentTarget.Character:FindFirstChildOfClass("Humanoid")
            if targetPos and hum and hum.Health > 0 then
                local dist = (targetPos - origin).Magnitude

                -- Minimal targeted fix: update vehicle info every frame (only updates labels)
                updateVehicleInfoEveryFrame(currentTarget)

                local aimPoint = targetPos
                local cfg = MODE_CONFIG[mode] or MODE_CONFIG["General"]
                local shouldPredict = false

                if dist <= cfg.PREDICTIVE_RANGE then
                    if mode == "Anti-ship" then
                        shouldPredict = true
                    elseif mode == "Anti-air" then
                        local inPlane = select(1, isPlayerInPlane(currentTarget))
                        if inPlane then
                            shouldPredict = true
                        else
                            shouldPredict = (dist <= cfg.PREDICTIVE_RANGE)
                        end
                    else
                        shouldPredict = (dist <= cfg.PREDICTIVE_RANGE)
                    end
                end

                if shouldPredict then
                    if currentTarget ~= lastPredictTarget and dist <= cfg.PREDICTIVE_RANGE then
                        pcall(function() predictiveSound:Stop(); predictiveSound:Play() end)
                    else
                        if not lastPredicting then
                            pcall(function() predictiveSound:Stop(); predictiveSound:Play() end)
                        end
                    end
                end

                local targetVel, fallbackSpeed = getTargetVelocityAndFallbackSpeed(currentTarget)

                if shouldPredict then
                    if mode == "Anti-ship" then
                        local bt = BULLET_TYPES[bulletTypeName] or BULLET_TYPES["Battleship"]
                        local s = bt.Speed
                        local mass = bt.Mass
                        local antiForce = bt.AntiGravityForce
                        local netG = Vector3.new(0, -Workspace.Gravity + (antiForce / mass), 0)
                        local intercept = computeInterceptPointWithGravity(origin, targetPos, targetVel, s, netG, 20)
                        if intercept then aimPoint = intercept else aimPoint = targetPos + targetVel * 0.25 end
                    else
                        local s = cfg.PREDICTIVE_SPEED or 800
                        local intercept = computeInterceptPointNoGravity(origin, targetPos, targetVel, s)
                        if intercept then aimPoint = intercept else aimPoint = targetPos + targetVel * 0.25 end
                    end
                end

                lastPredicting = shouldPredict
                lastPredictTarget = currentTarget

                cam.CameraType = Enum.CameraType.Scriptable
                cam.CFrame = CFrame.lookAt(origin, aimPoint)

                pcall(function() distLabel.Text = string.format("Enemy distance: %.1f studs", dist) end)
                if fallbackSpeed and type(fallbackSpeed) == "number" then
                    pcall(function() velocityLabel.Text = string.format("Velocity: %.1f studs/s", fallbackSpeed) end)
                else
                    pcall(function() velocityLabel.Text = "Velocity: N/A" end)
                end

                setHighlightsIfNeeded(currentTarget, dist, mode)

                if (mode == "Anti-air" or mode == "Anti-ship") and dist < cfg.TIER_ORANGE and enabled then
                    local now = tick()
                    if not isInDanger then
                        isInDanger = true; lastWarningTime = now
                        pcall(function() warnSound:Stop(); warnSound:Play() end)
                    else
                        if now - lastWarningTime >= WARNING_INTERVAL then lastWarningTime = now; pcall(function() warnSound:Stop(); warnSound:Play() end) end
                    end

                    -- ensure danger indicator is shown (added per patch)
                    local _, tier = colorForDistance(dist, mode)
                    pcall(function()
                        dangerLabel.Visible = true
                        if tier == "mid" then
                            dangerLabel.TextColor3 = Color3.fromRGB(255,165,0)
                        elseif tier == "close" then
                            dangerLabel.TextColor3 = Color3.fromRGB(255,0,0)
                        end
                    end)
                else
                    isInDanger = false
                    pcall(function() dangerLabel.Visible = false end)
                end

                if mode == "Anti-air" and cfg.CRITICAL_SOUND and enabled and dist < cfg.TIER_CLOSE then
                    if not isInCritical then isInCritical = true; pcall(function() criticalSound:Stop(); criticalSound:Play() end)
                    else
                        if criticalSound.IsPlaying == false then pcall(function() criticalSound:Play() end) end
                    end
                else
                    if isInCritical then isInCritical = false; pcall(function() criticalSound:Stop() end) end
                end

                return
            else
                currentTarget = nil
                clearCharHighlight(); clearVehicleHighlights()
                if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
                aiLabel.Visible = false; dangerLabel.Visible = false
                isInDanger = false
                if isInCritical then isInCritical = false; pcall(function() criticalSound:Stop() end) end
                lastPredicting = false; lastPredictTarget = nil
            end
        end

        cam.CameraType = Enum.CameraType.Custom
        pcall(function() distLabel.Text = "Enemy distance: N/A"; vehicleLabel.Text = "Vehicle: N/A | HP: N/A"; velocityLabel.Text = "Velocity: N/A" end)
        clearCharHighlight(); clearVehicleHighlights()
        if crosshair then pcall(function() crosshair.ImageColor3 = Color3.new(1,1,1) end) end
        aiLabel.Visible = false; dangerLabel.Visible = false
        isInDanger = false
        if isInCritical then isInCritical = false; pcall(function() criticalSound:Stop() end) end
        lastPredicting = false; lastPredictTarget = nil
    end)
end

toggleBtn.MouseButton1Click:Connect(function() if enabled then stopLock() else startLock() end end)

player.CharacterAdded:Connect(function()
    task.wait(0.05)
    refreshCrosshair()
    aiLabel.Text = "Sentry Mode: " .. mode
    if enabled then pcall(function() player.CameraMode = Enum.CameraMode.LockFirstPerson end); if crosshair then pcall(function() crosshair.ImageTransparency = 0.3 end) end; aiLabel.Visible = true end
end)

Players.PlayerRemoving:Connect(function(rem) if rem == player then stopLock() end end)

refreshCrosshair()
updateButtonVisual()
aiLabel.Text = "Sentry Mode: " .. mode
pcall(function() aiLabel.TextColor3 = (mode == "Anti-ship") and Color3.fromRGB(255,140,0) or ((mode == "Anti-air") and Color3.fromRGB(0,120,255) or Color3.fromRGB(255,0,0)) end)
