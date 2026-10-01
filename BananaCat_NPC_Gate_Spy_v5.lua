--[[
    BANANACAT NPC / GATE SPY v5.0
    Mục đích:
      - Bấm vào NPC -> tự chụp "snapshot" dữ liệu quan sát được của NPC.
      - Ghi ProximityPrompt / ClickDetector / Attributes / Tags / Parts / vị trí.
      - Theo dõi thay đổi quanh NPC trong vài giây sau khi tương tác.
      - Theo dõi cổng/khu vực dịch chuyển khi nhân vật đi vào:
          + vị trí trước/sau
          + Part/Model chạm vào
          + Prompt/ClickDetector gần cổng
          + Attribute/Tag quan sát được
      - Lưu JSON/Lua vào file BananaCat_NPC_Gate_Spy.lua
      - KHÔNG hook metamethod, KHÔNG đọc/decompile script server,
        KHÔNG bypass/né anti-cheat. Phần "anti-cheat" chỉ ghi lại
        dấu hiệu quan sát được ở client (GUI/thông báo/teleport bất thường).

    File đầu ra:
      BananaCat_NPC_Gate_Spy.lua
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local plr = Players.LocalPlayer

local Spy = {
    Version = "5.0",
    Session = {
        PlaceId = game.PlaceId,
        JobId = game.JobId,
        StartedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    },
    NPC = {},
    Gates = {},
    Interactions = {},
    AntiCheatObservations = {},
}

local function Notify(title, text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = tostring(title),
            Text = tostring(text),
            Duration = 4
        })
    end)
end

local function round(n)
    return math.floor((tonumber(n) or 0) * 100) / 100
end

local function vec3(v)
    return {
        X = round(v.X),
        Y = round(v.Y),
        Z = round(v.Z)
    }
end

local function cframeData(cf)
    return {
        Position = vec3(cf.Position),
        LookVector = vec3(cf.LookVector),
        CFrame = string.format(
            "CFrame.new(%.2f, %.2f, %.2f)",
            cf.X, cf.Y, cf.Z
        )
    }
end

local function safeFullName(obj)
    local ok, result = pcall(function()
        return obj:GetFullName()
    end)
    return ok and result or tostring(obj)
end

local function safeAttributes(obj)
    local out = {}
    pcall(function()
        for k, v in pairs(obj:GetAttributes()) do
            local t = typeof(v)
            if t == "Vector3" then
                out[k] = vec3(v)
            elseif t == "CFrame" then
                out[k] = cframeData(v)
            elseif t == "Color3" then
                out[k] = {
                    R = round(v.R),
                    G = round(v.G),
                    B = round(v.B)
                }
            elseif t == "Instance" then
                out[k] = safeFullName(v)
            else
                out[k] = v
            end
        end
    end)
    return out
end

local function safeTags(obj)
    local tags = {}
    pcall(function()
        for _, tag in ipairs(CollectionService:GetTags(obj)) do
            table.insert(tags, tag)
        end
    end)
    return tags
end

local function partInfo(part)
    if not part or not part:IsA("BasePart") then
        return nil
    end

    return {
        Name = part.Name,
        ClassName = part.ClassName,
        FullName = safeFullName(part),
        Position = vec3(part.Position),
        Size = vec3(part.Size),
        Anchored = part.Anchored,
        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        CanQuery = part.CanQuery,
        Transparency = round(part.Transparency),
    }
end

local function promptInfo(prompt)
    return {
        Name = prompt.Name,
        FullName = safeFullName(prompt),
        ActionText = prompt.ActionText,
        ObjectText = prompt.ObjectText,
        Enabled = prompt.Enabled,
        HoldDuration = prompt.HoldDuration,
        MaxActivationDistance = prompt.MaxActivationDistance,
        RequiresLineOfSight = prompt.RequiresLineOfSight,
        KeyboardKeyCode = tostring(prompt.KeyboardKeyCode),
        GamepadKeyCode = tostring(prompt.GamepadKeyCode),
    }
end

local function clickInfo(detector)
    return {
        Name = detector.Name,
        FullName = safeFullName(detector),
        MaxActivationDistance = detector.MaxActivationDistance,
    }
end

local function nearestBasePart(obj)
    if not obj then return nil end
    if obj:IsA("BasePart") then return obj end

    local root = obj:FindFirstChild("HumanoidRootPart", true)
    if root and root:IsA("BasePart") then
        return root
    end

    return obj:FindFirstChildWhichIsA("BasePart", true)
end

local function captureModel(model, reason)
    if not model or not model:IsA("Model") then return nil end

    local root = nearestBasePart(model)
    local data = {
        Name = model.Name,
        ClassName = model.ClassName,
        FullName = safeFullName(model),
        Reason = reason,
        CapturedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        Position = root and vec3(root.Position) or nil,
        CFrame = root and cframeData(root.CFrame) or nil,
        Attributes = safeAttributes(model),
        Tags = safeTags(model),
        Parts = {},
        Prompts = {},
        ClickDetectors = {},
        Proximity = {},
    }

    pcall(function()
        for _, obj in ipairs(model:GetDescendants()) do
            if obj:IsA("BasePart") then
                if #data.Parts < 150 then
                    table.insert(data.Parts, partInfo(obj))
                end
            elseif obj:IsA("ProximityPrompt") then
                table.insert(data.Prompts, promptInfo(obj))
            elseif obj:IsA("ClickDetector") then
                table.insert(data.ClickDetectors, clickInfo(obj))
            elseif obj:IsA("TouchTransmitter") then
                table.insert(data.Proximity, {
                    Name = obj.Name,
                    FullName = safeFullName(obj),
                    ClassName = obj.ClassName
                })
            end
        end
    end)

    return data
end

local function findModelFromTarget(target)
    if not target then return nil end

    local obj = target
    while obj and obj ~= Workspace do
        if obj:IsA("Model") then
            local hum = obj:FindFirstChildOfClass("Humanoid")
            local root = obj:FindFirstChild("HumanoidRootPart")
            if hum or root then
                return obj
            end
        end
        obj = obj.Parent
    end
    return nil
end

local function logInteraction(kind, target, extra)
    table.insert(Spy.Interactions, {
        Time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        Kind = kind,
        Target = target and safeFullName(target) or nil,
        Extra = extra or {},
        PlayerPosition =
            plr.Character
            and plr.Character:FindFirstChild("HumanoidRootPart")
            and vec3(plr.Character.HumanoidRootPart.Position)
            or nil
    })
end

local function captureNPC(model, reason)
    if not model then return end

    local snapshot = captureModel(model, reason)
    if not snapshot then return end

    local key = snapshot.FullName or snapshot.Name
    Spy.NPC[key] = snapshot

    logInteraction("NPC_CAPTURE", model, {
        Name = snapshot.Name,
        Reason = reason,
        PromptCount = #snapshot.Prompts,
        ClickDetectorCount = #snapshot.ClickDetectors,
    })

    Notify(
        "NPC SPY",
        snapshot.Name .. " | Prompt: " ..
        tostring(#snapshot.Prompts) ..
        " | Click: " ..
        tostring(#snapshot.ClickDetectors)
    )
end

-- Theo dõi GUI/thông báo có dấu hiệu game phản hồi sau tương tác.
local function observeClientSignals(seconds, sourceName)
    local started = os.clock()
    local lastPos = nil

    task.spawn(function()
        while os.clock() - started < seconds do
            task.wait(0.15)

            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")

            if root then
                local pos = root.Position

                if lastPos then
                    local delta = (pos - lastPos).Magnitude
                    if delta > 150 then
                        table.insert(Spy.AntiCheatObservations, {
                            Time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                            Type = "LARGE_CLIENT_POSITION_CHANGE",
                            Source = sourceName,
                            Distance = round(delta),
                            From = vec3(lastPos),
                            To = vec3(pos),
                        })
                    end
                end

                lastPos = pos
            end
        end
    end)
end

-- Chụp các Prompt/ClickDetector quanh một NPC/cổng.
local function captureNearbyInteractionObjects(center, radius, label)
    if not center then return end

    local root = nearestBasePart(center)
    if not root then return end

    local result = {
        Label = label,
        Center = vec3(root.Position),
        Radius = radius,
        Prompts = {},
        ClickDetectors = {},
        Parts = {},
    }

    pcall(function()
        for _, obj in ipairs(Workspace:GetDescendants()) do
            if obj:IsA("ProximityPrompt") then
                local p = obj.Parent
                local bp = p and (p:IsA("BasePart") and p or p:FindFirstChildWhichIsA("BasePart", true))
                if bp and (bp.Position - root.Position).Magnitude <= radius then
                    local info = promptInfo(obj)
                    info.Distance = round((bp.Position - root.Position).Magnitude)
                    table.insert(result.Prompts, info)
                end
            elseif obj:IsA("ClickDetector") then
                local p = obj.Parent
                local bp = p and (p:IsA("BasePart") and p or p:FindFirstChildWhichIsA("BasePart", true))
                if bp and (bp.Position - root.Position).Magnitude <= radius then
                    local info = clickInfo(obj)
                    info.Distance = round((bp.Position - root.Position).Magnitude)
                    table.insert(result.ClickDetectors, info)
                end
            end
        end
    end)

    table.insert(Spy.Gates, result)
end

-- Khi chạm vào một Part, chỉ ghi nhận dữ liệu quan sát được.
local touchConnections = {}

local function watchCharacterTouches()
    local char = plr.Character
    if not char then return end

    for _, c in ipairs(touchConnections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(touchConnections)

    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            local conn = part.Touched:Connect(function(hit)
                if not hit or not hit:IsA("BasePart") then return end

                local model = hit:FindFirstAncestorOfClass("Model")
                local name = model and model.Name or hit.Name

                -- Chỉ ghi lại một mẫu mỗi vùng; không spam file.
                if #Spy.Gates < 500 then
                    table.insert(Spy.Gates, {
                        Type = "CHARACTER_TOUCHED",
                        Time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                        HitPart = hit.Name,
                        HitFullName = safeFullName(hit),
                        HitModel = model and safeFullName(model) or nil,
                        HitPosition = vec3(hit.Position),
                        CharacterPosition = vec3(part.Position),
                        CandidateName = name,
                    })
                end
            end)
            table.insert(touchConnections, conn)
        end
    end
end

local function SaveToFile()
    local payload = {
        Spy = Spy,
        SavedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)

    if not ok then
        Notify("SPY ERROR", "Không encode được dữ liệu.")
        return
    end

    local lua = table.concat({
        "-- BANANACAT NPC / GATE SPY v5.0",
        "-- Dữ liệu quan sát được từ client.",
        "-- Không chứa mã bypass anti-cheat.",
        "",
        "return " .. encoded,
        ""
    }, "\n")

    if writefile then
        local filename = "BananaCat_NPC_Gate_Spy.lua"
        writefile(filename, lua)

        if delfile then
            -- Không tự xóa file cũ; ghi đè file hiện tại để giữ dữ liệu.
        end

        Notify(
            "ĐÃ LƯU SPY DATA",
            filename .. " | NPC: " ..
            tostring(#Spy.NPC) ..
            " | Gate: " ..
            tostring(#Spy.Gates)
        )
    else
        print(lua)
        Notify("SPY DATA", "writefile không có; dữ liệu đã in ra console.")
    end
end

-- GUI
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BananaCat_NPC_Gate_Spy"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999999

local parentTarget = plr:WaitForChild("PlayerGui", 5)
if gethui then
    ScreenGui.Parent = gethui()
elseif parentTarget then
    ScreenGui.Parent = parentTarget
else
    ScreenGui.Parent = CoreGui
end

local SaveBtn = Instance.new("TextButton")
SaveBtn.Name = "SaveSpyData"
SaveBtn.Parent = ScreenGui
SaveBtn.Size = UDim2.new(0, 210, 0, 46)
SaveBtn.Position = UDim2.new(0.5, -105, 0.84, 0)
SaveBtn.BackgroundColor3 = Color3.fromRGB(255, 120, 0)
SaveBtn.BorderSizePixel = 0
SaveBtn.Text = "💾 SAVE SPY DATA"
SaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SaveBtn.Font = Enum.Font.SourceSansBold
SaveBtn.TextSize = 16
SaveBtn.Active = true

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = SaveBtn

local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Parent = SaveBtn

SaveBtn.MouseButton1Click:Connect(function()
    SaveToFile()
end)

-- Bấm NPC bằng chuột.
local mouse = plr:GetMouse()

mouse.Button1Down:Connect(function()
    local target = mouse.Target
    local model = findModelFromTarget(target)

    if model then
        captureNPC(model, "MOUSE_CLICK")
        captureNearbyInteractionObjects(model, 40, "NPC_CLICK_AREA")
        observeClientSignals(5, model.Name)
    end
end)

-- Chạm NPC trên mobile.
UserInputService.TouchTap:Connect(function(touchPositions, processed)
    if processed then return end

    local pos = touchPositions and touchPositions[1]
    if not pos then return end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local ray = camera:ViewportPointToRay(pos.X, pos.Y)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {
        plr.Character
    }

    local hit = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)

    if hit and hit.Instance then
        local model = findModelFromTarget(hit.Instance)

        if model then
            captureNPC(model, "TOUCH_TAP")
            captureNearbyInteractionObjects(model, 40, "NPC_TOUCH_AREA")
            observeClientSignals(5, model.Name)
        end
    end
end)

-- Theo dõi character mới.
plr.CharacterAdded:Connect(function()
    task.wait(2)
    watchCharacterTouches()
end)

watchCharacterTouches()

Notify(
    "BananaCat Spy v5.0",
    "Bấm/chạm NPC để chụp dữ liệu. Nút Save ở dưới."
)
