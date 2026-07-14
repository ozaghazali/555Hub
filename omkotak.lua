-- ===================================================================
-- [[ ANTI-DOUBLE EXECUTE & CLEANUP SYSTEM ]]
-- ===================================================================
if getgenv().AsuHub_Cleanup then
    pcall(function() getgenv().AsuHub_Cleanup() end)
    task.wait(0.5) 
end

getgenv().AsuHub_Connections = {}
getgenv().AsuHub_LoopsActive = true
getgenv().AsuHub_QEMovementEnabled = true

getgenv().AsuHub_Cleanup = function()
    getgenv().AsuHub_LoopsActive = false
    
    -- 1. Putuskan semua koneksi event
    if getgenv().AsuHub_Connections then
        for _, conn in ipairs(getgenv().AsuHub_Connections) do pcall(function() conn:Disconnect() end) end
    end
    
    -- 2. Matikan Freecam via fungsi bawaan (Natural Off)
    if getgenv().AsuHub_DisableFreecam then 
        pcall(function() getgenv().AsuHub_DisableFreecam() end) 
    end
    
    -- 3. PAKSA RESET KAMERA & KONTROL (Mencegah Bug Nyangkut)
    pcall(function() 
        game:GetService("RunService"):UnbindFromRenderStep("Freecam") 
        game:GetService("ContextActionService"):UnbindAction("FreecamKeyboard")
        game:GetService("ContextActionService"):UnbindAction("FreecamMousePan")
        game:GetService("ContextActionService"):UnbindAction("FreecamMouseWheel")
        
        local cam = game:GetService("Workspace").CurrentCamera
        local localPlayer = game:GetService("Players").LocalPlayer
        if cam then
            cam.CameraType = Enum.CameraType.Custom
            if localPlayer and localPlayer.Character then
                local hum = localPlayer.Character:FindFirstChildOfClass("Humanoid")
                if hum then cam.CameraSubject = hum end
            end
        end
        getgenv().AsuHub_SavedCameraCFrame = nil -- Bersihkan cache posisi kamera
    end)
    
    -- 4. Bersihkan Visual & UI
    if getgenv().AsuHub_CleanupCinematic then pcall(function() getgenv().AsuHub_CleanupCinematic() end) end
    if getgenv().AsuHub_Window then pcall(function() getgenv().AsuHub_Window:Destroy() end); getgenv().AsuHub_Window = nil end
    
    task.wait(0.1)

    local coreGui = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
    if coreGui then
        local targetNames = {"AsuHub_Watermark", "AsuHub_FreecamHUD", "WindUI_Vignette", "WindUI_AsuHub_" .. tostring(game.PlaceId)}
        for _, name in pairs(targetNames) do
            local gui = coreGui:FindFirstChild(name)
            if gui then pcall(function() gui:Destroy() end) end
        end
    end
end

-- ===================================================================
-- [[ INITIALIZATION & SERVICES ]]
-- ===================================================================
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LocalPlayer = Players.LocalPlayer
end

-- ===================================================================
-- [[ LOAD WINDUI ]]
-- ===================================================================
local cloneref = (cloneref or clonereference or function(instance) return instance end)
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))

local WindUI
local ok, result = pcall(function() return require("./src/Init") end)
if ok then
    WindUI = result
else 
    if cloneref(game:GetService("RunService")):IsStudio() then
        WindUI = require(cloneref(ReplicatedStorage:WaitForChild("WindUI"):WaitForChild("Init")))
    else
        WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
    end
end

-- ===================================================================
-- [[ NOTIFICATION SYSTEM ]]
-- ===================================================================
getgenv().AsuHub_DisableNotifications = false -- Variabel global untuk menahan notif

local function Notify(title, content, duration)
    -- Jika fitur disable aktif, hentikan fungsi sebelum notifikasi muncul
    if getgenv().AsuHub_DisableNotifications then return end
    
    WindUI:Notify({
        Title = title,
        Content = content,
        Duration = duration or 3,
        Icon = "solar:bell-bold"
    })
end

-- ===================================================================
-- [[ FREECAM MODULE ]]
-- ===================================================================
local FreecamModule = (function()
    local Freecam = {}
    
    local Camera = Workspace.CurrentCamera
    local camConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        local newCam = Workspace.CurrentCamera; if newCam then Camera = newCam end
    end)
    table.insert(getgenv().AsuHub_Connections, camConn)

    local abs, clamp, exp, rad, sign, sqrt, tan = math.abs, math.clamp, math.exp, math.rad, math.sign, math.sqrt, math.tan

    local CinematicTarget = nil; local FreecamRunning = false
    local AllowCharMovement = false; local FollowCharMode = false    
    local EmoteTrackMode = false  
    local LastSubjectPos = nil; local TargetFramingIndex = 1; local NamesHidden = false
    local RatioFrame = nil
    local TargetOffsetX, TargetOffsetY, TargetOffsetZ = 0, 0, 0
    local CustomOffsetX, CustomOffsetY, CustomOffsetZ = 0, 0, 0
    local isOffsetMoving = false

    getgenv().AsuHub_IgnoreOffsetSync = false
    getgenv().AsuHub_SetFreecamOffset = function(x, y, z)
        if getgenv().AsuHub_IgnoreOffsetSync then return end
        if x then TargetOffsetX = x; CustomOffsetX = x end
        if y then TargetOffsetY = y; CustomOffsetY = y end
        if z then TargetOffsetZ = z; CustomOffsetZ = z end
    end
    
    local CustomDoF, DoFEnabled, SavedDoFs = nil, false, {}
    local DoFSettingsCache = { FocusDistance = 20, InFocusRadius = 5, FarIntensity = 0.1, NearIntensity = 0.1 }
    
    local SpeedFrame, SpeedText, SpeedStroke, isPopupShowing, popupHideDelay = nil, nil, nil, false, 0
    local RollFrame, RollText, RollStroke, isRollPopupShowing, rollPopupHideDelay = nil, nil, nil, false, 0
    local DoFFrame, DoFText, DoFStroke, isDoFPopupShowing, dofPopupHideDelay = nil, nil, nil, false, 0
    local SensFrame, SensText, SensStroke, isSensPopupShowing, sensPopupHideDelay = nil, nil, nil, false, 0
    
    local IsAltHeld = false
    local PanModeHoldRightClick = false
    local SpectateIndex = 0 -- Variabel baru untuk fitur pindah pemain (R)

    local FramingModes = {
        {Name = "Pusat (Center)", Offset = CFrame.new(0, 0, 0)}, {Name = "Depan (Front)",  Offset = CFrame.new(0, 0, 2.5)},
        {Name = "Belakang (Back)", Offset = CFrame.new(0, 0, -2.5)}, {Name = "Samping Kiri (Left)", Offset = CFrame.new(2, 0, 0)},
        {Name = "Samping Kanan (Right)", Offset = CFrame.new(-2, 0, 0)}, {Name = "Atas (Up)", Offset = CFrame.new(0, 2, 0)}, {Name = "Bawah (Down)", Offset = CFrame.new(0, -2, 0)}
    }

    local Spring = {}
    Spring.__index = Spring
    function Spring.new(freq, pos) local self = setmetatable({}, Spring); self.f = freq; self.p = pos; self.v = pos * 0; return self end
    function Spring.Update(self, dt, goal)
        local f = self.f * 2 * 3.141592653589793; local p0, v0 = self.p, self.v; local offset = goal - p0; local decay = exp(-f * dt)
        local p1 = goal + (v0 * dt - offset * (f * dt + 1)) * decay; local v1 = (f * dt * (offset * f - v0) + v0) * decay; self.p = p1; self.v = v1; return p1
    end
    function Spring.Reset(self, pos) self.p = pos; self.v = pos * 0 end

    local CameraPos, CameraRot, CameraFov, CameraRoll = Vector3.new(), Vector2.new(), 0, 0
    local VelSpring = Spring.new(0.5, Vector3.new()); local PanSpring = Spring.new(0.5, Vector2.new()); local FovSpring = Spring.new(1.2, 0); local RollSpring = Spring.new(0.75, 0)

    local InputState = {ButtonX=0, ButtonY=0, DPadDown=0, DPadUp=0, ButtonL2=0, ButtonR2=0, Thumbstick1=Vector2.new(), Thumbstick2=Vector2.new()}
    local Keyboard = {W=0, A=0, S=0, D=0, E=0, Q=0, Up=0, Down=0, Left=0, Right=0, LeftShift=0, RightShift=0, LeftControl=0, RightControl=0, C=0, Z=0, Minus=0, Equals=0, LeftBracket=0, RightBracket=0, BackSlash=0, J=0, L=0, I=0, K=0, N=0, M=0}
    local Mouse = {Delta=Vector2.new(), MouseWheel=0}; local MouseSensitivity = Vector2.new(1, 1) * 0.04908738521234052
    local SpeedMultiplier = 1; local PanSpeedMultiplier = 1; local InputHandler = {}

    local function UpdateMouseState()
        if not FreecamRunning then
            UserInputService.MouseIconEnabled = true; UserInputService.MouseBehavior = Enum.MouseBehavior.Default; return
        end
        if IsAltHeld then
            UserInputService.MouseIconEnabled = true; UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        else
            if PanModeHoldRightClick then
                if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
                    UserInputService.MouseIconEnabled = false; UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
                else
                    -- Mouse disembunyikan walau tidak ditahan klik kanan
                    UserInputService.MouseIconEnabled = false; UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end
            else
                UserInputService.MouseIconEnabled = false; UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
            end
        end
    end

    getgenv().AsuHub_SetPanMode = function(state) PanModeHoldRightClick = state; UpdateMouseState() end

    local function SyncUIElement(elementName, value)
        local elements = getgenv().AsuHub_DoFUIElements
        if elements and elements[elementName] then
            getgenv().AsuHub_IgnoreUICallback = true; pcall(function() elements[elementName]:SetValue(value) end); pcall(function() elements[elementName]:Set(value) end); getgenv().AsuHub_IgnoreUICallback = false
        end
    end

    local function TriggerDoFHUD()
        if DoFFrame and CustomDoF then
            DoFText.Text = string.format("📷 DoF | Dist: <b>%.1f</b> | Rad: <b>%.1f</b> | Far: <b>%.2f</b> | Near: <b>%.2f</b>", CustomDoF.FocusDistance, CustomDoF.InFocusRadius, CustomDoF.FarIntensity, CustomDoF.NearIntensity)
            dofPopupHideDelay = 1.0
            if not isDoFPopupShowing then
                isDoFPopupShowing = true
                TweenService:Create(DoFFrame, TweenInfo.new(0.2), {BackgroundTransparency = 0.2}):Play(); TweenService:Create(DoFText, TweenInfo.new(0.2), {TextTransparency = 0}):Play(); TweenService:Create(DoFStroke, TweenInfo.new(0.2), {Transparency = 0.1}):Play()
            end
        end
    end

    function InputHandler.Vel(dt)
        if not AllowCharMovement then
            SpeedMultiplier = clamp(SpeedMultiplier + dt * (Keyboard.Up - Keyboard.Down) * 0.75, 0.01, 4)
            PanSpeedMultiplier = clamp(PanSpeedMultiplier + dt * (Keyboard.Right - Keyboard.Left) * 0.75, 0.1, 5) -- [BARU: Kontrol Sensitivitas Rotasi]
            
            if SpeedFrame then
                if Keyboard.Up == 1 or Keyboard.Down == 1 then
                    SpeedText.Text = "⚡ Speed: <b>" .. math.floor(SpeedMultiplier * 100) .. "%</b>"; popupHideDelay = 1.0 
                    if not isPopupShowing then isPopupShowing = true; TweenService:Create(SpeedFrame, TweenInfo.new(0.2), {BackgroundTransparency = 0.2}):Play(); TweenService:Create(SpeedText, TweenInfo.new(0.2), {TextTransparency = 0}):Play(); TweenService:Create(SpeedStroke, TweenInfo.new(0.2), {Transparency = 0.1}):Play() end
                else
                    if isPopupShowing then popupHideDelay = popupHideDelay - dt; if popupHideDelay <= 0 then isPopupShowing = false; TweenService:Create(SpeedFrame, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play(); TweenService:Create(SpeedText, TweenInfo.new(0.5), {TextTransparency = 1}):Play(); TweenService:Create(SpeedStroke, TweenInfo.new(0.5), {Transparency = 1}):Play() end end
                end
            end
            
            -- [BARU: Pop-up UI untuk Rotasi Speed]
            if SensFrame then
                if Keyboard.Right == 1 or Keyboard.Left == 1 then
                    SensText.Text = "🎯 Sensitivitas: <b>" .. math.floor(PanSpeedMultiplier * 100) .. "%</b>"; sensPopupHideDelay = 1.0
                    if not isSensPopupShowing then isSensPopupShowing = true; TweenService:Create(SensFrame, TweenInfo.new(0.2), {BackgroundTransparency = 0.2}):Play(); TweenService:Create(SensText, TweenInfo.new(0.2), {TextTransparency = 0}):Play(); TweenService:Create(SensStroke, TweenInfo.new(0.2), {Transparency = 0.1}):Play() end
                else
                    if isSensPopupShowing then sensPopupHideDelay = sensPopupHideDelay - dt; if sensPopupHideDelay <= 0 then isSensPopupShowing = false; TweenService:Create(SensFrame, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play(); TweenService:Create(SensText, TweenInfo.new(0.5), {TextTransparency = 1}):Play(); TweenService:Create(SensStroke, TweenInfo.new(0.5), {Transparency = 1}):Play() end end
                end
            end
        end
        local camForward, camBack, camLeft, camRight = 0, 0, 0, 0
        if AllowCharMovement then camForward = Keyboard.Up; camBack = Keyboard.Down; camLeft = Keyboard.Left; camRight = Keyboard.Right else camForward = Keyboard.W; camBack = Keyboard.S; camLeft = Keyboard.A; camRight = Keyboard.D end
        local qeMove = getgenv().AsuHub_QEMovementEnabled and (Keyboard.E - Keyboard.Q) or 0
        local kKeyboard = Vector3.new(camRight - camLeft, qeMove, camBack - camForward)
        local isShiftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        return kKeyboard * (SpeedMultiplier * (isShiftDown and 0.10 or 1))
    end
    
    function InputHandler.Pan(dt) 
        if not IsAltHeld then
            if PanModeHoldRightClick then
                if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then local delta = Mouse.Delta; Mouse.Delta = Vector2.new(); return delta * (MouseSensitivity * PanSpeedMultiplier) end
            else
                local delta = Mouse.Delta; Mouse.Delta = Vector2.new(); return delta * (MouseSensitivity * PanSpeedMultiplier) 
            end
        end
        return Vector2.new()
    end
    
    function InputHandler.Fov(dt) local kMouse = Mouse.MouseWheel * 1; Mouse.MouseWheel = 0; return kMouse end
    function InputHandler.Roll(dt)
        local rollInput = Keyboard.C - Keyboard.Z
        if RollFrame then
            if rollInput ~= 0 then
                RollText.Text = "🔄 Rotasi: <b>" .. math.floor(math.deg(CameraRoll)) .. "°</b>"; rollPopupHideDelay = 1.0 
                if not isRollPopupShowing then isRollPopupShowing = true; TweenService:Create(RollFrame, TweenInfo.new(0.2), {BackgroundTransparency = 0.2}):Play(); TweenService:Create(RollText, TweenInfo.new(0.2), {TextTransparency = 0}):Play(); TweenService:Create(RollStroke, TweenInfo.new(0.2), {Transparency = 0.1}):Play() end
            else
                if isRollPopupShowing then rollPopupHideDelay = rollPopupHideDelay - dt; if rollPopupHideDelay <= 0 then isRollPopupShowing = false; TweenService:Create(RollFrame, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play(); TweenService:Create(RollText, TweenInfo.new(0.5), {TextTransparency = 1}):Play(); TweenService:Create(RollStroke, TweenInfo.new(0.5), {Transparency = 1}):Play() end end
            end
        end
        return rollInput * 0.5 * PanSpeedMultiplier -- [Rotasi C/Z ikut dipercepat/lambat]
    end

    function InputHandler.DoFUpdate(dt)
        if not DoFEnabled or not CustomDoF then return end
        local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
        local isCtrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
        
        local adjRadius = (Keyboard.Equals - Keyboard.Minus) * 50 * dt
        local adjDistance = (Keyboard.Equals - Keyboard.Minus) * 200 * dt
        local adjIntensity = (Keyboard.RightBracket - Keyboard.LeftBracket) * 1 * dt
        local changed = false; local isManualUpdate = false

        if isShift then
            if adjIntensity ~= 0 then CustomDoF.FarIntensity = math.clamp(CustomDoF.FarIntensity + adjIntensity, 0, 1); DoFSettingsCache.FarIntensity = CustomDoF.FarIntensity; changed = true; isManualUpdate = true end
            if adjRadius ~= 0 then CustomDoF.InFocusRadius = math.clamp(CustomDoF.InFocusRadius + adjRadius, 0, 50); DoFSettingsCache.InFocusRadius = CustomDoF.InFocusRadius; changed = true; isManualUpdate = true end
        elseif isCtrl then
            if adjIntensity ~= 0 then CustomDoF.NearIntensity = math.clamp(CustomDoF.NearIntensity + adjIntensity, 0, 1); DoFSettingsCache.NearIntensity = CustomDoF.NearIntensity; changed = true; isManualUpdate = true end
        else
            if adjDistance ~= 0 then 
                if not CinematicTarget then CustomDoF.FocusDistance = math.clamp(CustomDoF.FocusDistance + adjDistance, 0, 500); DoFSettingsCache.FocusDistance = CustomDoF.FocusDistance; changed = true; isManualUpdate = true 
                else Notify("Auto-Focus Aktif", "Jarak fokus sedang dikendalikan otomatis!") end
            end
        end

        if CinematicTarget and CinematicTarget.Parent then
            local targetPos = CinematicTarget.Position
            if CinematicTarget:IsA("Model") and CinematicTarget.PrimaryPart then targetPos = CinematicTarget.PrimaryPart.Position end
            local dist = (CameraPos - targetPos).Magnitude
            if CustomDoF.FocusDistance ~= dist then CustomDoF.FocusDistance = dist; DoFSettingsCache.FocusDistance = dist; changed = true end
        end

        if changed then 
            if isManualUpdate then TriggerDoFHUD() end 
            if tick() - (getgenv().AsuHub_LastDoFUISync or 0) > 0.1 then 
                getgenv().AsuHub_LastDoFUISync = tick()
                SyncUIElement("FocusDistance", CustomDoF.FocusDistance); SyncUIElement("InFocusRadius", CustomDoF.InFocusRadius)
                SyncUIElement("FarIntensity", CustomDoF.FarIntensity); SyncUIElement("NearIntensity", CustomDoF.NearIntensity)
            end
        end

        if not changed and isDoFPopupShowing then
            dofPopupHideDelay = dofPopupHideDelay - dt
            if dofPopupHideDelay <= 0 then
                isDoFPopupShowing = false
                TweenService:Create(DoFFrame, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play(); TweenService:Create(DoFText, TweenInfo.new(0.5), {TextTransparency = 1}):Play(); TweenService:Create(DoFStroke, TweenInfo.new(0.5), {Transparency = 1}):Play()
            end
        end
    end
    
    local function Keypress(_, state, object)
        local key = object.KeyCode
        if key == Enum.KeyCode.BackSlash then if state == Enum.UserInputState.Begin then Freecam.ToggleDoF() end; return Enum.ContextActionResult.Sink end
        if key == Enum.KeyCode.C or key == Enum.KeyCode.Z then Keyboard[key.Name] = state == Enum.UserInputState.Begin and 1 or 0; return Enum.ContextActionResult.Sink end
        if key == Enum.KeyCode.X then if state == Enum.UserInputState.Begin then Freecam.CycleFraming() end; return Enum.ContextActionResult.Sink end
        if key == Enum.KeyCode.Q or key == Enum.KeyCode.E then
            if getgenv().AsuHub_QEMovementEnabled then
                Keyboard[key.Name] = state == Enum.UserInputState.Begin and 1 or 0
                return Enum.ContextActionResult.Sink
            else
                Keyboard[key.Name] = 0
                return Enum.ContextActionResult.Pass
            end
        end
        if Keyboard[key.Name] ~= nil then Keyboard[key.Name] = state == Enum.UserInputState.Begin and 1 or 0 end
        if key == Enum.KeyCode.Space then return Enum.ContextActionResult.Pass end
        if key == Enum.KeyCode.Up or key == Enum.KeyCode.Down or key == Enum.KeyCode.Left or key == Enum.KeyCode.Right then return Enum.ContextActionResult.Sink end
        if key == Enum.KeyCode.W or key == Enum.KeyCode.A or key == Enum.KeyCode.S or key == Enum.KeyCode.D then if AllowCharMovement then return Enum.ContextActionResult.Pass else if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then return Enum.ContextActionResult.Pass end; return Enum.ContextActionResult.Sink end end
        return Enum.ContextActionResult.Sink 
    end
    
    local function MousePan(_, state, object)
        if not IsAltHeld then
            if PanModeHoldRightClick then
                if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then local delta = object.Delta; Mouse.Delta = Vector2.new(-delta.y, -delta.x); return Enum.ContextActionResult.Sink end
            else local delta = object.Delta; Mouse.Delta = Vector2.new(-delta.y, -delta.x); return Enum.ContextActionResult.Sink end
        end
        return Enum.ContextActionResult.Pass
    end
    
    local function MouseWheel(_, state, object) Mouse[object.UserInputType.Name] = -object.Position.z; return Enum.ContextActionResult.Sink end
    
    function InputHandler.BindAll()
        ContextActionService:BindActionAtPriority("FreecamKeyboard", Keypress, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right, Enum.KeyCode.Space, Enum.KeyCode.C, Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.Minus, Enum.KeyCode.Equals, Enum.KeyCode.LeftBracket, Enum.KeyCode.RightBracket, Enum.KeyCode.BackSlash, Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl, Enum.KeyCode.J, Enum.KeyCode.L, Enum.KeyCode.I, Enum.KeyCode.K, Enum.KeyCode.N, Enum.KeyCode.M)
        ContextActionService:BindActionAtPriority("FreecamMousePan", MousePan, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseMovement); ContextActionService:BindActionAtPriority("FreecamMouseWheel", MouseWheel, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
    end
    
    function InputHandler.UnbindAll()
        SpeedMultiplier = 1; PanSpeedMultiplier = 1; for k, v in pairs(InputState) do InputState[k] = v * 0 end; for k, v in pairs(Keyboard) do Keyboard[k] = v * 0 end; for k, v in pairs(Mouse) do Mouse[k] = v * 0 end
        ContextActionService:UnbindAction("FreecamKeyboard"); ContextActionService:UnbindAction("FreecamMousePan"); ContextActionService:UnbindAction("FreecamMouseWheel")
    end
    
    local function UpdateFreecam(dt)
        local dtFov = FovSpring:Update(dt, InputHandler.Fov(dt)); CameraFov = clamp(CameraFov + dtFov * 300 * (dt / (sqrt(0.7002075382097097 / tan((rad(CameraFov / 2)))))), 1, 120)
        local dtRoll = RollSpring:Update(dt, InputHandler.Roll(dt)); CameraRoll = math.clamp(CameraRoll + dtRoll * 1.2 * dt, -math.pi * 2, math.pi * 2)

        local rHue = (tick() * 0.05) % 1; local rColor = Color3.fromHSV(rHue, 1, 1)
        if SpeedStroke then SpeedStroke.Color = rColor end; if RollStroke then RollStroke.Color = rColor end; if DoFStroke then DoFStroke.Color = rColor end; if SensStroke then SensStroke.Color = rColor end

        local useHardLock = (CinematicTarget and CinematicTarget.Parent) and (not FollowCharMode)

        local activeSubject = nil
        local targetToLookAt = CinematicTarget
        local DynamicPlayer = game:GetService("Players").LocalPlayer
        
        if FollowCharMode or EmoteTrackMode then 
            if CinematicTarget and CinematicTarget.Parent then activeSubject = CinematicTarget 
            elseif DynamicPlayer and DynamicPlayer.Character and DynamicPlayer.Character:FindFirstChild("HumanoidRootPart") then activeSubject = DynamicPlayer.Character.HumanoidRootPart end 
        end

        if EmoteTrackMode then
            local function getTorso(subj)
                if not subj then return nil end
                local model = subj:FindFirstAncestorOfClass("Model") or subj.Parent
                if model then return model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("Head") or subj end
                return subj
            end
            if activeSubject then activeSubject = getTorso(activeSubject) end
            if targetToLookAt then targetToLookAt = getTorso(targetToLookAt) end
        end

        if useHardLock then
            local offsetSpeed = 5 
            TargetOffsetX = TargetOffsetX + (Keyboard.L - Keyboard.J) * offsetSpeed * dt
            TargetOffsetZ = TargetOffsetZ + (Keyboard.K - Keyboard.I) * offsetSpeed * dt
            TargetOffsetY = TargetOffsetY + (Keyboard.M - Keyboard.N) * offsetSpeed * dt

            local smoothFactor = 8 * dt
            CustomOffsetX = CustomOffsetX + (TargetOffsetX - CustomOffsetX) * smoothFactor
            CustomOffsetY = CustomOffsetY + (TargetOffsetY - CustomOffsetY) * smoothFactor
            CustomOffsetZ = CustomOffsetZ + (TargetOffsetZ - CustomOffsetZ) * smoothFactor

            if Keyboard.J == 1 or Keyboard.L == 1 or Keyboard.I == 1 or Keyboard.K == 1 or Keyboard.N == 1 or Keyboard.M == 1 then
                isOffsetMoving = true
            else
                if isOffsetMoving then
                    isOffsetMoving = false
                    getgenv().AsuHub_IgnoreOffsetSync = true
                    pcall(function()
                        if getgenv().AsuHub_OffsetXSlider then getgenv().AsuHub_OffsetXSlider:SetValue(math.floor(TargetOffsetX * 10) / 10) end
                        if getgenv().AsuHub_OffsetYSlider then getgenv().AsuHub_OffsetYSlider:SetValue(math.floor(TargetOffsetY * 10) / 10) end
                        if getgenv().AsuHub_OffsetZSlider then getgenv().AsuHub_OffsetZSlider:SetValue(math.floor(TargetOffsetZ * 10) / 10) end
                    end)
                    getgenv().AsuHub_IgnoreOffsetSync = false
                end
            end

            local targetCFrame = targetToLookAt.CFrame * FramingModes[TargetFramingIndex].Offset * CFrame.new(CustomOffsetX, CustomOffsetY, CustomOffsetZ)
            local direction = (targetCFrame.Position - CameraPos).Unit
            CameraRot = Vector2.new(math.asin(direction.Y), math.atan2(-direction.X, -direction.Z))
            PanSpring:Reset(Vector2.new()) 
        else
            local dtPan = PanSpring:Update(dt, InputHandler.Pan(dt)); CameraRot = CameraRot + dtPan * Vector2.new(0.75, 1) * 4 * (dt / (sqrt(0.7002075382097097 / tan((rad(CameraFov / 2)))))); CameraRot = Vector2.new(clamp(CameraRot.x, -1.57, 1.57), CameraRot.y % 6.28)
        end

        if activeSubject then
            local currentSubPos = activeSubject.Position; if LastSubjectPos then CameraPos = CameraPos + (currentSubPos - LastSubjectPos) end
            LastSubjectPos = currentSubPos; local dtVel = VelSpring:Update(dt, InputHandler.Vel(dt))
            CameraPos = CameraPos + (CFrame.fromOrientation(CameraRot.x, CameraRot.y, 0) * CFrame.new(dtVel * Vector3.new(30, 30, 30) * dt)).Position
        else
            LastSubjectPos = nil; local dtVel = VelSpring:Update(dt, InputHandler.Vel(dt))
            CameraPos = (CFrame.new(CameraPos) * CFrame.fromOrientation(CameraRot.x, CameraRot.y, 0) * CFrame.new(dtVel * Vector3.new(30, 30, 30) * dt)).p 
        end

        local finalCFrame
        if useHardLock then 
            finalCFrame = CFrame.lookAt(CameraPos, (targetToLookAt.CFrame * FramingModes[TargetFramingIndex].Offset * CFrame.new(CustomOffsetX, CustomOffsetY, CustomOffsetZ)).Position)
        else 
            finalCFrame = CFrame.new(CameraPos) * CFrame.fromOrientation(CameraRot.x, CameraRot.y, 0) 
        end

        finalCFrame = finalCFrame * CFrame.Angles(0, 0, CameraRoll); Camera.CFrame = finalCFrame; Camera.FieldOfView = CameraFov; Camera.Focus = finalCFrame
        
        InputHandler.DoFUpdate(dt)
    end
    
    local GuiManager, HiddenGuis, CoreGuiState, OldFieldOfView = {}, {}, { Backpack = true, Chat = true, Health = true, PlayerList = true }, 70

    function GuiManager.Push()
        for k in pairs(CoreGuiState) do 
            -- Ambil status UI saat ini
            local currentState = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType[k])
            -- Hanya simpan ke memori jika statusnya nyala (true), sehingga tidak akan pernah tertimpa mati permanen
            if currentState then 
                CoreGuiState[k] = currentState 
            end
            -- Matikan UI untuk mode Freecam
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType[k], false) 
        end
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then for _, gui in pairs(playerGui:GetChildren()) do if gui:IsA("ScreenGui") and gui.Enabled and not (gui.Name == "WindUI") then HiddenGuis[#HiddenGuis + 1] = gui; gui.Enabled = false end end end
        
        OldFieldOfView = Camera.FieldOfView; Camera.FieldOfView = 70; Camera.CameraType = Enum.CameraType.Scriptable
        
        if not SpeedFrame then
            local coreGui = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or LocalPlayer:FindFirstChild("PlayerGui")
            local sg = Instance.new("ScreenGui", coreGui); sg.Name = "AsuHub_FreecamHUD"; sg.IgnoreGuiInset = true
            
            SpeedFrame = Instance.new("Frame", sg); SpeedFrame.Size = UDim2.new(0, 150, 0, 32); SpeedFrame.AnchorPoint = Vector2.new(1, 1); SpeedFrame.Position = UDim2.new(1, -20, 1, -20); SpeedFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15); SpeedFrame.BackgroundTransparency = 1; Instance.new("UICorner", SpeedFrame).CornerRadius = UDim.new(0, 6)
            SpeedStroke = Instance.new("UIStroke", SpeedFrame); SpeedStroke.Thickness = 1.5; SpeedStroke.Transparency = 1; SpeedText = Instance.new("TextLabel", SpeedFrame); SpeedText.Size = UDim2.new(1, 0, 1, 0); SpeedText.BackgroundTransparency = 1; SpeedText.Font = Enum.Font.GothamSemibold; SpeedText.TextSize = 13; SpeedText.TextColor3 = Color3.fromRGB(255, 255, 255); SpeedText.TextTransparency = 1; SpeedText.RichText = true

            RollFrame = Instance.new("Frame", sg); RollFrame.Size = UDim2.new(0, 150, 0, 32); RollFrame.AnchorPoint = Vector2.new(1, 1); RollFrame.Position = UDim2.new(1, -20, 1, -60); RollFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15); RollFrame.BackgroundTransparency = 1; Instance.new("UICorner", RollFrame).CornerRadius = UDim.new(0, 6)
            RollStroke = Instance.new("UIStroke", RollFrame); RollStroke.Thickness = 1.5; RollStroke.Transparency = 1; RollText = Instance.new("TextLabel", RollFrame); RollText.Size = UDim2.new(1, 0, 1, 0); RollText.BackgroundTransparency = 1; RollText.Font = Enum.Font.GothamSemibold; RollText.TextSize = 13; RollText.TextColor3 = Color3.fromRGB(255, 255, 255); RollText.TextTransparency = 1; RollText.RichText = true
            
            DoFFrame = Instance.new("Frame", sg); DoFFrame.Size = UDim2.new(0, 340, 0, 32); DoFFrame.AnchorPoint = Vector2.new(1, 1); DoFFrame.Position = UDim2.new(1, -20, 1, -100); DoFFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15); DoFFrame.BackgroundTransparency = 1; Instance.new("UICorner", DoFFrame).CornerRadius = UDim.new(0, 6)
            DoFStroke = Instance.new("UIStroke", DoFFrame); DoFStroke.Thickness = 1.5; DoFStroke.Transparency = 1; DoFText = Instance.new("TextLabel", DoFFrame); DoFText.Size = UDim2.new(1, 0, 1, 0); DoFText.BackgroundTransparency = 1; DoFText.Font = Enum.Font.GothamSemibold; DoFText.TextSize = 13; DoFText.TextColor3 = Color3.fromRGB(255, 255, 255); DoFText.TextTransparency = 1; DoFText.RichText = true
            
            SensFrame = Instance.new("Frame", sg); SensFrame.Size = UDim2.new(0, 160, 0, 32); SensFrame.AnchorPoint = Vector2.new(1, 1); SensFrame.Position = UDim2.new(1, -20, 1, -140); SensFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15); SensFrame.BackgroundTransparency = 1; Instance.new("UICorner", SensFrame).CornerRadius = UDim.new(0, 6)
            SensStroke = Instance.new("UIStroke", SensFrame); SensStroke.Thickness = 1.5; SensStroke.Transparency = 1; SensText = Instance.new("TextLabel", SensFrame); SensText.Size = UDim2.new(1, 0, 1, 0); SensText.BackgroundTransparency = 1; SensText.Font = Enum.Font.GothamSemibold; SensText.TextSize = 13; SensText.TextColor3 = Color3.fromRGB(255, 255, 255); SensText.TextTransparency = 1; SensText.RichText = true

            RatioFrame = Instance.new("Frame", sg)
            RatioFrame.Name = "RatioOverlaySystem"; RatioFrame.Size = UDim2.new(1, 0, 1, 0); RatioFrame.BackgroundTransparency = 1; RatioFrame.Visible = false; RatioFrame.ZIndex = 1 

            local ratioGuide = Instance.new("Frame", RatioFrame)
            ratioGuide.AnchorPoint = Vector2.new(0.5, 0.5); ratioGuide.Position = UDim2.new(0.5, 0, 0.5, 0); ratioGuide.Size = UDim2.new(1, 0, 1, 0); ratioGuide.BackgroundTransparency = 1 

            local ratioConstraint = Instance.new("UIAspectRatioConstraint", ratioGuide)
            ratioConstraint.AspectRatio = 9.1 / 16; ratioConstraint.DominantAxis = Enum.DominantAxis.Height 

            local leftMask = Instance.new("Frame", RatioFrame)
            leftMask.BackgroundColor3 = Color3.fromRGB(0, 0, 0); leftMask.BackgroundTransparency = 0.6; leftMask.Position = UDim2.new(0, 0, 0, 0); leftMask.ZIndex = 1 

            local rightMask = Instance.new("Frame", RatioFrame)
            rightMask.BackgroundColor3 = Color3.fromRGB(0, 0, 0); rightMask.BackgroundTransparency = 0.6; rightMask.Position = UDim2.new(1, 0, 0, 0); rightMask.AnchorPoint = Vector2.new(1, 0); rightMask.ZIndex = 1

            local function updateMaskDynamicSize()
                if not RatioFrame or not RatioFrame.Visible then return end 
                task.wait(0.01)
                local guideSizeX, sgSizeX = ratioGuide.AbsoluteSize.X, sg.AbsoluteSize.X 
                local marginScale = ((sgSizeX - guideSizeX) / 2) / sgSizeX
                if leftMask then leftMask.Size = UDim2.new(marginScale, 0, 1, 0) end
                if rightMask then rightMask.Size = UDim2.new(marginScale, 0, 1, 0) end
            end
            RatioFrame:GetPropertyChangedSignal("Visible"):Connect(updateMaskDynamicSize)
            ratioGuide:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateMaskDynamicSize)
        end
        isPopupShowing, popupHideDelay, isRollPopupShowing, rollPopupHideDelay, isDoFPopupShowing, dofPopupHideDelay, isSensPopupShowing, sensPopupHideDelay = false, 0, false, 0, false, 0, false, 0
    end
    
    function GuiManager.Pop()
        for k, v in pairs(CoreGuiState) do pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType[k], v) end) end
        for _, gui in pairs(HiddenGuis) do if gui and gui.Parent then pcall(function() gui.Enabled = true end) end end
        HiddenGuis = {}; if OldFieldOfView then Camera.FieldOfView = OldFieldOfView end; Camera.CameraType = Enum.CameraType.Custom
        pcall(function() if SpeedFrame and SpeedFrame.Parent then SpeedFrame.Parent:Destroy() end end)
        SpeedFrame, SpeedText, SpeedStroke, RollFrame, RollText, RollStroke, DoFFrame, DoFText, DoFStroke, SensFrame, SensText, SensStroke = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
    end

    local function RestoreNames()
        if NamesHidden then
            NamesHidden = false
            for _, p in pairs(Players:GetPlayers()) do
                if p.Character then
                    local hum = p.Character:FindFirstChild("Humanoid"); if hum then hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer end
                    for _, v in pairs(p.Character:GetDescendants()) do if (v:IsA("BillboardGui") or v:IsA("SurfaceGui")) then v.Enabled = true end end
                end
            end
        end
    end
    
    function Freecam.ToggleDoF(state)
        if not FreecamRunning then 
            SyncUIElement("Toggle", false) 
            if state == true or state == nil then Notify("Depth of Field", "Gagal! Nyalakan mode Freecam terlebih dahulu.") end
            return 
        end
        
        if state ~= nil then DoFEnabled = state else DoFEnabled = not DoFEnabled end
        SyncUIElement("Toggle", DoFEnabled) 
        
        if DoFEnabled then
            SavedDoFs = {}
            for _, v in pairs(Camera:GetChildren()) do if v:IsA("DepthOfFieldEffect") and v.Enabled then table.insert(SavedDoFs, v); v.Enabled = false end end
            for _, v in pairs(Lighting:GetChildren()) do if v:IsA("DepthOfFieldEffect") and v.Enabled then table.insert(SavedDoFs, v); v.Enabled = false end end
            
            if not CustomDoF then CustomDoF = Instance.new("DepthOfFieldEffect"); CustomDoF.Name = "AsuHub_FreecamDoF"; CustomDoF.Parent = Camera end
            
            CustomDoF.FocusDistance = DoFSettingsCache.FocusDistance; CustomDoF.InFocusRadius = DoFSettingsCache.InFocusRadius
            CustomDoF.FarIntensity = DoFSettingsCache.FarIntensity; CustomDoF.NearIntensity = DoFSettingsCache.NearIntensity
            
            CustomDoF.Enabled = true; Notify("Depth of Field (\\)", "Dinyalakan!")
        else
            if CustomDoF then CustomDoF.Enabled = false end
            for _, v in pairs(SavedDoFs) do if v and v.Parent then v.Enabled = true end end
            SavedDoFs = {}; Notify("Depth of Field (\\)", "Dimatikan!")
        end
    end

    getgenv().AsuHub_SetDoFProperty = function(propertyName, value)
        if getgenv().AsuHub_IgnoreUICallback then return end
        DoFSettingsCache[propertyName] = value
        if CustomDoF then CustomDoF[propertyName] = value; TriggerDoFHUD() end

        -- FIX: Sambungkan nilai baru ke tabel save dan eksekusi penyimpanan
        if propertyName == "FocusDistance" then lastCinematic.FocusDist = value end
        if propertyName == "InFocusRadius" then lastCinematic.FocusRadius = value end
        if propertyName == "FarIntensity" then lastCinematic.BlurFar = value end
        if propertyName == "NearIntensity" then lastCinematic.BlurNear = value end
        
        if not isScriptLoading then saveCinematic() end
    end

    getgenv().AsuHub_ToggleDoF = function(state) Freecam.ToggleDoF(state) end

    local function EnableFreecam()
        FreecamRunning = true 
        
        -- SIMPAN POSISI KAMERA ASLI SEBELUM FREECAM NYALA
        getgenv().AsuHub_SavedCameraCFrame = Camera.CFrame
        
        local currentCFrame = Camera.CFrame; CameraRot, CameraPos, CameraFov = Vector2.new(currentCFrame:toEulerAnglesYXZ()), currentCFrame.p, Camera.FieldOfView
        VelSpring:Reset(Vector3.new()); PanSpring:Reset(Vector2.new()); FovSpring:Reset(0); RollSpring:Reset(0); CameraRoll = 0      
        GuiManager.Push(); RunService:BindToRenderStep("Freecam", Enum.RenderPriority.Camera.Value, UpdateFreecam); InputHandler.BindAll()
        UpdateMouseState()
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then LastSubjectPos = LocalPlayer.Character.HumanoidRootPart.Position end
    end
    
    local function DisableFreecam()
        if DoFEnabled then Freecam.ToggleDoF(false) end 
        FreecamRunning = false 
        RestoreNames(); InputHandler.UnbindAll(); RunService:UnbindFromRenderStep("Freecam"); GuiManager.Pop(); AllowCharMovement = false
        UpdateMouseState()
        pcall(function()
            local cam = Workspace.CurrentCamera
            local DynamicPlayer = game:GetService("Players").LocalPlayer
            
            if DynamicPlayer and DynamicPlayer.Character then
                local hum = DynamicPlayer.Character:FindFirstChild("Humanoid")
                if hum then 
                    cam.CameraSubject = hum 
                end
            end
            
            -- KEMBALIKAN POSISI KAMERA KE TITIK ASAL
            if getgenv().AsuHub_SavedCameraCFrame then
                cam.CFrame = getgenv().AsuHub_SavedCameraCFrame
                getgenv().AsuHub_SavedCameraCFrame = nil
            end

            -- Biarkan sistem bawaan Roblox yang mengatur ulang posisinya
            cam.CameraType = Enum.CameraType.Custom
        end)
    end

    function Freecam.ToggleFreecam(state)
        if state then if not FreecamRunning then EnableFreecam(); ProximityPromptService.Enabled = false end
        else if FreecamRunning then DisableFreecam() end; ProximityPromptService.Enabled = true; CinematicTarget = nil; AllowCharMovement = false; FollowCharMode = false end
    end
    
    -- MENGGUNAKAN GLOBAL OFF YANG NATURAL (FIX PROXIMITY HIDE)
    getgenv().AsuHub_DisableFreecam = function() 
        if FreecamRunning then 
            Freecam.ToggleFreecam(false) 
        end 
    end
    
    function Freecam.ToggleNameTags()
        if not FreecamRunning then return end; NamesHidden = not NamesHidden
        for _, plr in pairs(Players:GetPlayers()) do
            if plr.Character then
                local hum = plr.Character:FindFirstChild("Humanoid"); if hum then hum.DisplayDistanceType = NamesHidden and Enum.HumanoidDisplayDistanceType.None or Enum.HumanoidDisplayDistanceType.Viewer end
                for _, gui in pairs(plr.Character:GetDescendants()) do if gui:IsA("BillboardGui") or gui:IsA("SurfaceGui") then gui.Enabled = not NamesHidden end end
            end
        end
        Notify("Display Name (INSERT)", NamesHidden and "Nama Pemain Disembunyikan!" or "Nama Pemain Ditampilkan!")
    end

    function Freecam.SetTarget(part)
        local finalTarget = part
        if part then 
            local model = part:FindFirstAncestorOfClass("Model")
            if model then local bodyPart = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso") or model:FindFirstChild("Head") or model.PrimaryPart; if bodyPart then finalTarget = bodyPart end end 
        end
        CinematicTarget = finalTarget
        if finalTarget then 
            LastSubjectPos = finalTarget.Position; local targetCFrame = finalTarget.CFrame * FramingModes[TargetFramingIndex].Offset
            local direction = (targetCFrame.Position - CameraPos).Unit; CameraRot = Vector2.new(math.asin(direction.Y), math.atan2(-direction.X, -direction.Z)); PanSpring:Reset(Vector2.new())
            Notify("Target Terkunci", "Mengunci: " .. (finalTarget.Parent and finalTarget.Parent.Name or finalTarget.Name)) 
            if DoFEnabled and CustomDoF then CustomDoF.FocusDistance = (CameraPos - finalTarget.Position).Magnitude end
        else if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then LastSubjectPos = LocalPlayer.Character.HumanoidRootPart.Position end end
    end
    
    function Freecam.ClearTarget() Freecam.SetTarget(nil) end
    function Freecam.ToggleHybrid() if not FreecamRunning then return end; AllowCharMovement = not AllowCharMovement; Notify("Freecam Mode (U)", AllowCharMovement and "Karakter (WASD), Kamera (ARROW)" or "Dimatikan!") end
    function Freecam.ToggleFollow() if not FreecamRunning then return end; FollowCharMode = not FollowCharMode; AllowCharMovement = FollowCharMode; Notify("Follow Mode (Y)", FollowCharMode and "Mengikuti Target" or "Dimatikan!") end
    function Freecam.CycleFraming() if not FreecamRunning then return end; if not CinematicTarget then Notify("Target (X)", "Kunci Target dulu (Alt + Klik Kanan)!"); return end; TargetFramingIndex = TargetFramingIndex + 1; if TargetFramingIndex > #FramingModes then TargetFramingIndex = 1 end; Notify("Posisi Target (X)", "Fokus: " .. FramingModes[TargetFramingIndex].Name) end
    function Freecam.ToggleEmoteTrack() if not FreecamRunning then return end; EmoteTrackMode = not EmoteTrackMode; LastSubjectPos = nil; Notify("Emote Tracker (F)", EmoteTrackMode and "Kamera mengikuti ayunan badan karakter!" or "Dimatikan!") end
    function Freecam.ToggleRatio() if not FreecamRunning then return end; if RatioFrame then RatioFrame.Visible = not RatioFrame.Visible; Notify("Focus Mode 9:16 (End)", RatioFrame.Visible and "Diaktifkan!" or "Dimatikan!") end end

    -- [[ EVENT MOUSE DENGAN CUSTOM RAYCAST & SPECTATE ]]
    local inputConn = UserInputService.InputBegan:Connect(function(input, gp)
        if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
            IsAltHeld = true; UpdateMouseState()
        end
        
        if not FreecamRunning or UserInputService:GetFocusedTextBox() then return end
        
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            if IsAltHeld then 
                local mousePos = UserInputService:GetMouseLocation()
                local ray = Camera:ViewportPointToRay(mousePos.X, mousePos.Y)
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = {} 
                
                local result = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
                if result and result.Instance then Freecam.SetTarget(result.Instance) 
                else local mouse = LocalPlayer:GetMouse(); if mouse.Target then Freecam.SetTarget(mouse.Target) end end
            else UpdateMouseState() end
        end
        
        if input.KeyCode == Enum.KeyCode.B then
            if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then Freecam.SetTarget(LocalPlayer.Character.HumanoidRootPart) end
        end
        
        -- FITUR BARU: Tekan R untuk pindah target pemain lain (Spectate Mode)
        if input.KeyCode == Enum.KeyCode.R then
            local validPlayers = {}
            for _, p in pairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then table.insert(validPlayers, p) end
            end
            
            if #validPlayers > 0 then
                SpectateIndex = SpectateIndex + 1
                if SpectateIndex > #validPlayers then SpectateIndex = 1 end
                Freecam.SetTarget(validPlayers[SpectateIndex].Character.HumanoidRootPart)
            else
                Notify("Spectate Mode", "Tidak ada pemain lain yang bisa dilock.")
            end
        end

        if input.KeyCode == Enum.KeyCode.Insert then Freecam.ToggleNameTags() end; if input.KeyCode == Enum.KeyCode.Delete then Freecam.ClearTarget(); Notify("Target", "Dilepaskan!") end
        if input.KeyCode == Enum.KeyCode.U then Freecam.ToggleHybrid() end; if input.KeyCode == Enum.KeyCode.Y then Freecam.ToggleFollow() end
        if input.KeyCode == Enum.KeyCode.F then Freecam.ToggleEmoteTrack() end; if input.KeyCode == Enum.KeyCode.End then Freecam.ToggleRatio() end
    end)
    table.insert(getgenv().AsuHub_Connections, inputConn)
    
    local inputEndedConn = UserInputService.InputEnded:Connect(function(input, gp)
        if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then IsAltHeld = false; UpdateMouseState() end
        if input.UserInputType == Enum.UserInputType.MouseButton2 then UpdateMouseState() end
    end)
    table.insert(getgenv().AsuHub_Connections, inputEndedConn)
    
    return Freecam
end)()

-- ===================================================================
-- [[ CINEMATIC / VISUALS MODULE ]]
-- ===================================================================
local createdVisuals = {}
local atmosphereObj = Lighting:FindFirstChildOfClass("Atmosphere")

if not getgenv().WindUI_OriginalLighting or getgenv().WindUI_OriginalLighting.Time == nil then
    getgenv().WindUI_OriginalLighting = {
        Time = Lighting.ClockTime, Brightness = Lighting.Brightness, FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart, FogColor = Lighting.FogColor,
        AtmosphereDensity = atmosphereObj and atmosphereObj.Density or 0, AtmosphereOffset = atmosphereObj and atmosphereObj.Offset or 0,
        AtmosphereColor = atmosphereObj and atmosphereObj.Color or Color3.new(1, 1, 1), AtmosphereDecay = atmosphereObj and atmosphereObj.Decay or Color3.new(0, 0, 0)
    }
end

local originalLighting = getgenv().WindUI_OriginalLighting
local CINEMATIC_FILE = "WindUICinematicPack.json"

local lastCinematic = {
    Time = math.floor(originalLighting.Time), Brightness = math.floor(originalLighting.Brightness * 20),
    FogThickness = 0, FogColor = originalLighting.FogColor:ToHex(), FocusDist = 50, FocusRadius = 20,
    BlurNear = 0, BlurFar = 0, Saturation = 50, Contrast = 50, Bloom = 0, SunRays = 0, Vignette = 0
}

if isfile and isfile(CINEMATIC_FILE) then
    local success, data = pcall(function() return readfile(CINEMATIC_FILE) end)
    if success and data then
        pcall(function()
            local decoded = HttpService:JSONDecode(data)
            for k, v in pairs(decoded) do lastCinematic[k] = v end
        end)
    end
end

local function saveCinematic()
    pcall(function() writefile(CINEMATIC_FILE, HttpService:JSONEncode(lastCinematic)) end)
end

local dofSettings = {Dist = lastCinematic.FocusDist, Radius = lastCinematic.FocusRadius, Near = lastCinematic.BlurNear, Far = lastCinematic.BlurFar}
local curSat, curCont = lastCinematic.Saturation, lastCinematic.Contrast
local isScriptLoading = true 

local function CleanupCinematic()
    for _, child in pairs(Lighting:GetChildren()) do if child.Name:match("^WindUI_") then child:Destroy() end end
    if CoreGui:FindFirstChild("WindUI_Vignette") then CoreGui.WindUI_Vignette:Destroy() end
    
    Lighting.ClockTime, Lighting.Brightness = originalLighting.Time, originalLighting.Brightness
    Lighting.FogEnd, Lighting.FogStart, Lighting.FogColor = originalLighting.FogEnd, originalLighting.FogStart, originalLighting.FogColor
    
    local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
    if atmo then
        atmo.Density, atmo.Offset = originalLighting.AtmosphereDensity, originalLighting.AtmosphereOffset
        atmo.Color, atmo.Decay = originalLighting.AtmosphereColor, originalLighting.AtmosphereDecay
    end
end
CleanupCinematic()
getgenv().AsuHub_CleanupCinematic = CleanupCinematic

local function getLightingEffect(className, name)
    local effect = Lighting:FindFirstChild(name)
    if not effect then
        effect = Instance.new(className)
        effect.Name = name; effect.Parent = Lighting; effect.Enabled = false
        table.insert(createdVisuals, effect)
    end
    return effect
end

local function applyDoF()
    local dof = getLightingEffect("DepthOfFieldEffect", "WindUI_DoF")
    if dofSettings.Near > 0 or dofSettings.Far > 0 then
        dof.Enabled, dof.FocusDistance, dof.InFocusRadius = true, dofSettings.Dist, dofSettings.Radius
        dof.NearIntensity, dof.FarIntensity = dofSettings.Near / 100, (dofSettings.Far / 100) * 4   
    else dof.Enabled = false end
end

local function updateColorCorrection()
    local cc = getLightingEffect("ColorCorrectionEffect", "WindUI_CC")
    cc.Enabled, cc.Saturation, cc.Contrast = true, (curSat - 50) / 50, (curCont - 50) / 100 
end

local function updateBloom(val)
    local bloom = getLightingEffect("BloomEffect", "WindUI_Bloom")
    if val > 0 then bloom.Enabled, bloom.Intensity, bloom.Size = true, (val / 100) * 1.5, 24 + ((val/100)*30)
    else bloom.Enabled = false end
end

local function updateSunRays(val)
    local rays = getLightingEffect("SunRaysEffect", "WindUI_SunRays")
    if val > 0 then rays.Enabled, rays.Intensity, rays.Spread = true, (val / 100) * 0.5, (val / 100)
    else rays.Enabled = false end
end

local vignetteLayer, vignetteImage = nil, nil
local function updateVignette(val)
    if not vignetteLayer then 
        if CoreGui:FindFirstChild("WindUI_Vignette") then CoreGui.WindUI_Vignette:Destroy() end
        vignetteLayer = Instance.new("ScreenGui", CoreGui)
        vignetteLayer.Name, vignetteLayer.IgnoreGuiInset = "WindUI_Vignette", true
        vignetteImage = Instance.new("ImageLabel", vignetteLayer)
        vignetteImage.Size, vignetteImage.BackgroundTransparency = UDim2.new(1, 0, 1, 0), 1
        vignetteImage.Image, vignetteImage.ImageColor3, vignetteImage.ZIndex = "rbxassetid://4576475446", Color3.new(0, 0, 0), -1
    end
    if val > 0 then vignetteLayer.Enabled, vignetteImage.ImageTransparency = true, 1 - (val / 100)
    else vignetteLayer.Enabled = false end
end

local safeFogColor = originalLighting.FogColor
pcall(function() safeFogColor = Color3.fromHex(lastCinematic.FogColor) end)

-- ===================================================================
-- [[ CUSTOM THEMES (ASUHUB EDITION) ]]
-- ===================================================================

-- 1. Tema Gelap (Default)
WindUI:AddTheme({
    Name = "AsuHub Dark",
    Accent = Color3.fromHex("#18181b"),
    Background = Color3.fromHex("#101010"),
    Text = Color3.fromHex("#FFFFFF"),
    Placeholder = Color3.fromHex("#7a7a7a"),
    Button = Color3.fromHex("#52525b"),
    Icon = Color3.fromHex("#FFFFFF"),
    Toggle = Color3.fromHex("#33C759"),
    Slider = Color3.fromHex("#0091FF"),
    Checkbox = Color3.fromHex("#0091FF"),
})

-- 2. Tema Terang
WindUI:AddTheme({
    Name = "AsuHub Light",
    Accent = Color3.fromHex("#FFFFFF"),
    Background = Color3.fromHex("#e9e9e9"),
    Text = Color3.fromHex("#000000"),
    Placeholder = Color3.fromHex("#555555"),
    Button = Color3.fromHex("#d4d4d8"),
    Icon = Color3.fromHex("#000000"),
    Toggle = Color3.fromHex("#33C759"),
    Slider = Color3.fromHex("#0091FF"),
    Checkbox = Color3.fromHex("#0091FF"),
})

-- 3. Tema Cotton Candy
WindUI:AddTheme({
    Name = "AsuHub Cotton",
    Accent = Color3.fromHex("#ec4899"),
    Background = Color3.fromHex("#1a0b2e"),
    Text = Color3.fromHex("#fdf2f8"),
    Placeholder = Color3.fromHex("#8a5fd3"),
    Button = Color3.fromHex("#d946ef"),
    Icon = Color3.fromHex("#fdf2f8"),
    Slider = Color3.fromHex("#d946ef"),
})

-- 4. Tema Midnight
WindUI:AddTheme({
    Name = "AsuHub Midnight",
    Accent = Color3.fromHex("#1e3a8a"),
    Background = Color3.fromHex("#0a0f1e"),
    Text = Color3.fromHex("#dbeafe"),
    Placeholder = Color3.fromHex("#2f74d1"),
    Button = Color3.fromHex("#2563eb"),
    Icon = Color3.fromHex("#dbeafe"),
    Slider = Color3.fromHex("#2563eb"),
})

-- 5. Tema Blood (Merah Gelap)
WindUI:AddTheme({
    Name = "AsuHub Blood",
    Accent = Color3.fromHex("#991b1b"),
    Background = Color3.fromHex("#1a0505"),
    Text = Color3.fromHex("#fee2e2"),
    Placeholder = Color3.fromHex("#f87171"),
    Button = Color3.fromHex("#dc2626"),
    Icon = Color3.fromHex("#fee2e2"),
    Slider = Color3.fromHex("#dc2626"),
})

-- 6. Tema Forest (Hijau Alam)
WindUI:AddTheme({
    Name = "AsuHub Forest",
    Accent = Color3.fromHex("#166534"),
    Background = Color3.fromHex("#051f0e"),
    Text = Color3.fromHex("#dcfce7"),
    Placeholder = Color3.fromHex("#4ade80"),
    Button = Color3.fromHex("#15803d"),
    Icon = Color3.fromHex("#dcfce7"),
    Slider = Color3.fromHex("#15803d"),
})

-- 7. Tema Cyberpunk (Kuning Neon & Cyan)
WindUI:AddTheme({
    Name = "AsuHub Cyberpunk",
    Accent = Color3.fromHex("#fde047"),
    Background = Color3.fromHex("#0f172a"),
    Text = Color3.fromHex("#f8fafc"),
    Placeholder = Color3.fromHex("#94a3b8"),
    Button = Color3.fromHex("#06b6d4"),
    Icon = Color3.fromHex("#fde047"),
    Slider = Color3.fromHex("#ec4899"),
})

-- 8. Tema Ocean (Biru Laut)
WindUI:AddTheme({
    Name = "AsuHub Ocean",
    Accent = Color3.fromHex("#0891b2"),
    Background = Color3.fromHex("#082f49"),
    Text = Color3.fromHex("#e0f2fe"),
    Placeholder = Color3.fromHex("#38bdf8"),
    Button = Color3.fromHex("#0284c7"),
    Icon = Color3.fromHex("#e0f2fe"),
    Slider = Color3.fromHex("#0284c7"),
})

-- 9. Tema Gold (Mewah Emas/Hitam)
WindUI:AddTheme({
    Name = "AsuHub Gold",
    Accent = Color3.fromHex("#b45309"),
    Background = Color3.fromHex("#171717"),
    Text = Color3.fromHex("#fef3c7"),
    Placeholder = Color3.fromHex("#fbbf24"),
    Button = Color3.fromHex("#d97706"),
    Icon = Color3.fromHex("#fef3c7"),
    Slider = Color3.fromHex("#f59e0b"),
})

-- 10. Tema Amethyst (Ungu Deep)
WindUI:AddTheme({
    Name = "AsuHub Amethyst",
    Accent = Color3.fromHex("#7e22ce"),
    Background = Color3.fromHex("#2e1065"),
    Text = Color3.fromHex("#f3e8ff"),
    Placeholder = Color3.fromHex("#c084fc"),
    Button = Color3.fromHex("#9333ea"),
    Icon = Color3.fromHex("#f3e8ff"),
    Slider = Color3.fromHex("#a855f7"),
})

-- 11. Tema RGB (Pelangi)
WindUI:AddTheme({
    Name = "AsuHub RGB",
    Accent = Color3.fromHex("#ff0000"),
    Dialog = Color3.fromHex("#161616"),
    Background = Color3.fromHex("#101010"),
    PanelBackground = Color3.fromHex("#FFFFFF"),
    PanelBackgroundTransparency = 0.95, -- <== INI YANG BIKIN BACKGROUND GAMBAR KAMU MUNCUL LAGI
    Text = Color3.fromHex("#ffffff"),
    Placeholder = Color3.fromHex("#7a7a7a"),
    Button = Color3.fromHex("#52525b"),
    Icon = Color3.fromHex("#ff0000"),
    Slider = Color3.fromHex("#ff0000"),
    Toggle = Color3.fromHex("#ff0000"),
    Checkbox = Color3.fromHex("#ff0000"),
})

-- ===================================================================
-- [[ LOOP ANIMASI THEME RGB (CHROMA) - FULL RGB ]]
-- ===================================================================
local chromaHue = 0
task.spawn(function()
    while getgenv().AsuHub_LoopsActive do
        if WindUI:GetCurrentTheme() == "AsuHub RGB" then
            chromaHue = (chromaHue + 0.015) % 1 
            
            -- Warna RGB Terang (Untuk Tombol, Slider, dan Icon)
            local chromaColor = Color3.fromHSV(chromaHue, 1, 1)
            
            -- Warna RGB Gelap (Untuk Background)
            local darkChroma = Color3.fromHSV(chromaHue, 0.8, 0.15) 
            
            WindUI:AddTheme({
                Name = "AsuHub RGB",
                Accent = chromaColor,
                Dialog = darkChroma,          
                Background = darkChroma,      
                PanelBackground = darkChroma, 
                PanelBackgroundTransparency = 0.5,
                Text = Color3.fromHex("#ffffff"), 
                Placeholder = Color3.fromHex("#7a7a7a"),
                Button = Color3.fromHex("#52525b"),
                Icon = chromaColor,           
                Slider = chromaColor,         
                Toggle = chromaColor,         
                Checkbox = chromaColor,       
            })
            
            WindUI:SetTheme("AsuHub RGB")
        end
        task.wait(0.05) 
    end
end)

-- ===================================================================
-- [[ WINDUI SETUP & INTERFACE ]]
-- ===================================================================

local Window = WindUI:CreateWindow({
    Title = "AsuHub | Freecam         ", 
    Icon = "solar:global-bold",
    Folder = "WindUI_AsuHub_" .. tostring(game.PlaceId),
    Size = UDim2.fromOffset(640, 480),
    MinSize = Vector2.new(560, 350),
    MaxSize = Vector2.new(850, 560),
    Theme = "AsuHub Dark",
    HideSearchBar = false,
    NewElements = true, 
    Topbar = {
        Height = 50,
        ButtonsType = "Mac",
    },
    OpenButton = { 
        Title = "Open Camera Hub",
        CornerRadius = UDim.new(1,0),
        StrokeThickness = 3,
        Enabled = true, 
        Draggable = true,
        Scale = 0.5,
        Color = ColorSequence.new(
            Color3.fromHex("#30FF6A"), 
            Color3.fromHex("#e7ff2f")
        )
    },
    User = {
        Enabled = true,
        Anonymous = false,
    },
})

local PremiumTag = Window:Tag({
    Title = "Premium",
    Color = Color3.fromHex("#FF0F7B")
})

-- Rainbow effect
local hue = 0
task.spawn(function()
    while getgenv().AsuHub_LoopsActive do
        hue = (hue + 0.01) % 1
        local color1 = Color3.fromHSV(hue, 1, 0.5) 
        local color2 = Color3.fromHSV((hue + 0.1) % 1, 1, 0.5)

        -- Buat objek gradien baru
        local new_gradient = WindUI:Gradient({
            ["0"]   = { Color = color1, Transparency = 0 },
            ["100"] = { Color = color2, Transparency = 0 },
        }, {
            Rotation = 45,
        })
        
        PremiumTag:SetColor(new_gradient)

        task.wait(0.06)
    end
end)

getgenv().AsuHub_Window = Window
Window:SetToggleKey(Enum.KeyCode.G)

-- Notifikasi Load
Notify("AsuHub", "Script Berhasil Terload!", 5)

-- ===================================================================
-- [[ PREMIUM WATERMARK HUD (FPS, PING, TIME) ]]
-- ===================================================================
-- 1. Bersihkan Watermark Lama
local coreGui = pcall(function() return game:GetService("CoreGui") end) and game:GetService("CoreGui") or game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
if coreGui:FindFirstChild("AsuHub_Watermark") then
    coreGui:FindFirstChild("AsuHub_Watermark"):Destroy()
end

-- 2. Buat GUI Watermark Baru
local WatermarkGui = Instance.new("ScreenGui")
WatermarkGui.Name = "AsuHub_Watermark"
WatermarkGui.Parent = coreGui
WatermarkGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
WatermarkGui.IgnoreGuiInset = true

local Background = Instance.new("Frame")
Background.Parent = WatermarkGui
Background.AnchorPoint = Vector2.new(1, 0)
Background.Position = UDim2.new(1, -15, 0, 15) 
Background.Size = UDim2.new(0, 240, 0, 32) 
Background.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
Background.BackgroundTransparency = 0.2
Background.BorderSizePixel = 0

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 6)
UICorner.Parent = Background

local UIStroke = Instance.new("UIStroke")
UIStroke.Parent = Background
UIStroke.Thickness = 1.5
UIStroke.Transparency = 0.1

local TextLabel = Instance.new("TextLabel")
TextLabel.Parent = Background
TextLabel.Size = UDim2.new(1, 0, 1, 0)
TextLabel.BackgroundTransparency = 1
TextLabel.Font = Enum.Font.GothamSemibold
TextLabel.TextSize = 13
TextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
TextLabel.RichText = true
TextLabel.Text = "<b>AsuHub</b> | -- FPS | -- ms | --:-- --"

-- 3. Logika Update Performa & Rainbow Sinkron
local accumulatedTime = 0
local frameCounter = 0

local cachedFps = "--"
local cachedPing = "--"
local cachedTime = os.date("%I:%M %p")

local watermarkConn = game:GetService("RunService").RenderStepped:Connect(function(deltaTime)
    accumulatedTime = accumulatedTime + deltaTime
    frameCounter = frameCounter + 1
    
    if accumulatedTime >= 0.5 then
        -- Update FPS
        cachedFps = tostring(math.round(frameCounter / accumulatedTime))
        
        -- UPDATE PING
        pcall(function()
            local pingValue = LocalPlayer:GetNetworkPing()
            cachedPing = string.format("%.0f", pingValue * 1000)
        end)
        
        cachedTime = os.date("%I:%M %p")
        
        accumulatedTime = 0
        frameCounter = 0
    end

    local rHue = (tick() * 0.05) % 1 
    local rainbowColor = Color3.fromHSV(rHue, 1, 1)
    UIStroke.Color = rainbowColor 
    
    local r, g, b = math.floor(rainbowColor.R * 255), math.floor(rainbowColor.G * 255), math.floor(rainbowColor.B * 255)
    local hexColor = string.format("#%02X%02X%02X", r, g, b)

    TextLabel.Text = string.format("<font color='%s'><b>AsuHub</b></font>  |  %s FPS  |  %s ms  |  %s", hexColor, cachedFps, cachedPing, cachedTime)
end)
table.insert(getgenv().AsuHub_Connections, watermarkConn)

-- 4. Shortcut Dinamis untuk Sembunyikan/Tampilkan HUD Watermark
getgenv().AsuHub_HUDKey = Enum.KeyCode.O -- Keybind Default

local toggleHUDConn = game:GetService("UserInputService").InputBegan:Connect(function(input, gp)
    if gp then return end -- Abaikan jika sedang mengetik di chat
    if input.KeyCode == getgenv().AsuHub_HUDKey then
        Background.Visible = not Background.Visible
    end
end)
table.insert(getgenv().AsuHub_Connections, toggleHUDConn)

-- ==========================================
-- TAB 1: INFORMATION
-- ==========================================
Window:Divider()

local InfoTab = Window:Tab({
    Title = "Information",
    Icon = "solar:info-square-bold",
    IconColor = Color3.fromHex("#74dd11"),
    IconShape = "Square", 
    Border = true,
})

Window:Divider()

local FCInfo = InfoTab:Section({ Title = "Tentang AsuHub", Box = true, BoxBorder = true, Opened = true })
FCInfo:Paragraph({
    Title = "Selamat Datang di AsuHub!",
    Desc = "Script eksklusif yang menyediakan fitur custom kamera (Freecam) dan custom visuals game (Cinematic).\n\n⚠️ Jika ada kendala Laporkan langsung ke Discord dan Tag @Yogurutto",
})

InfoTab:Space()

local FCDiscord = InfoTab:Section({ Title = "Server Discord", Box = true, BoxBorder = true, Opened = true })
FCDiscord:Paragraph({
    Title = "Gabung Discord",
    Desc = "Bergabunglah dengan komunitas kami untuk update dan support.",
    Buttons = {
        {
            Title = "Salin Link Discord",
            Icon = "link",
            Callback = function()
                setclipboard("https://discord.gg/YN2AnEaWrk")
                Notify("Discord", "Link disalin!")
            end
        }
    }
})

InfoTab:Space()

local FCChangelog = InfoTab:Section({ Title = "Changelog", Box = true, BoxBorder = true, Opened = true })

FCChangelog:Paragraph({
    Title = "📢 AsuHub Versi 1.1 (Freecam & Cinematic)",
    Desc = [[
• Menambahkan fitur Emote Tracker (Kamera mengikuti lekuk tubuh).
• Menambahkan fitur Ratio Overlay 9:16 (Fokus Portrait).
• Menambahkan fitur Target Lock Offset (Bisa menggeser kamera saat menge-lock).
• Freecam kini memiliki pengaturan Speed, FOV, dan Roll Kamera yang lebih smooth.
• Menambahkan fitur Spectate Mode (Lock kamera ke pemain lain dengan tombol R).
• Support 11 Custom UI Themes (Termasuk tema AsuHub RGB yang bisa bergerak).
• Menambahkan Live HUD untuk memantau FPS, Ping ms, dan Waktu.]]
})

-- ==========================================
-- TAB 2: FREECAM 
-- ==========================================
local FreecamTab = Window:Tab({
    Title = "Freecam",
    Icon = "solar:videocamera-record-bold",
    IconColor = Color3.fromHex("#EF4F1D"),
    IconShape = "Square",
    Border = true,
})

local FCHotkeys = FreecamTab:Section({ Title = "Hotkey Freecam", Box = true, BoxBorder = true, Opened = true })

FCHotkeys:Paragraph({
    Title = "Daftar Shortcut Freecam",
    Desc = "• (Y) Follow Mode Karakter / Target\n• (U) Mode Berjalan (Karakter Ikut Bergerak)\n• Tahan (C) / (Z) Roll Layar (Putar Kamera)\n• (Alt + Klik Kanan) Kunci Target Kamera\n• (B) Lock Target ke Karakter Sendiri\n• (R) Pindah Lock ke Pemain Lain (Spectate)\n• (X) Ganti Posisi Fokus Target Kamera\n• (INSERT) Menyembunyikan Nama Pemain\n• (DEL) Menghapus Target Kamera",
    TextSize = 14,
})

FreecamTab:Space()

local FCControls = FreecamTab:Section({ Title = "Kontrol Kamera", Box = true, BoxBorder = true, Opened = true })

local FreecamToggleUI = FCControls:Toggle({
    Title = "Aktifkan FreeCam (Shift + P)",
    Desc = "Masuk ke mode kamera bebas.",
    Value = false,
    Callback = function(value) 
        FreecamModule.ToggleFreecam(value)
        if value then Notify("Freecam", "Diaktifkan!") else Notify("Freecam", "Dimatikan!") end
    end
})

FCControls:Toggle({
    Title = "Tahan Klik Kanan Untuk Geser",
    Desc = "Mati = Kursor akan selalu memutar kamera. Nyala = Harus tahan klik kanan (kursor akan tetap disembunyikan).",
    Value = false,
    Callback = function(value) 
        if getgenv().AsuHub_SetPanMode then getgenv().AsuHub_SetPanMode(value) end
    end
})

FCControls:Toggle({
    Title = "Q & E Naik/Turun Kamera",
    Desc = "Matikan fitur ini jika kamu sedang menyetir dan ingin memakai Q & E untuk oper gigi kendaraan.",
    Value = true,
    Callback = function(value) 
        getgenv().AsuHub_QEMovementEnabled = value
        if value then
            Notify("Kamera", "Q & E diaktifkan untuk kamera.")
        else
            Notify("Kendaraan", "Q & E dikembalikan ke kontrol game.")
        end
    end
})

-- Set default keybind untuk tombol kombinasi (awalnya P)
getgenv().AsuHub_FreecamKey = Enum.KeyCode.P 

local toggleConn = UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    
    -- Syarat: Tombol kustom ditekan DAN (Shift Kiri ATAU Shift Kanan ditahan)
    if input.KeyCode == getgenv().AsuHub_FreecamKey and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) then
       FreecamToggleUI:Set(not FreecamToggleUI.Value) 
    end
end)
table.insert(getgenv().AsuHub_Connections, toggleConn)

FCControls:Space()

FCControls:Button({
    Title = "Lepas Target Lock",
    Desc = "Kembali ke kontrol kamera manual.",
    Icon = "solar:forbidden-circle-bold",
    Callback = function() FreecamModule.ClearTarget(); Notify("Info", "Target dilepas. Kembali ke manual.") end
})

-- ==========================================
-- TAB 3: CINEMATIC VISUALS
-- ==========================================
local CinematicTab = Window:Tab({
    Title = "Cinematic",
    Icon = "solar:gallery-bold",
    IconColor = Color3.fromHex("#257AF7"),
    IconShape = "Square",
    Border = true,
})

local OffsetSection = CinematicTab:Section({ Title = "Target Lock Offset (Geser Kamera)", Box = true, BoxBorder = true, Opened = false })
    
OffsetSection:Paragraph({
    Title = "Tips Cinematic",
    Desc = "Gunakan tombol J, L, I, K, N, M untuk menggeser titik fokus secara live, atau gunakan slider di bawah."
})

getgenv().AsuHub_OffsetXSlider = OffsetSection:Slider({
    Title = "Geser Kiri/Kanan (X) [J/L]", Step = 0.1, Value = {Min = -50, Max = 50, Default = 0},
    Callback = function(val) if getgenv().AsuHub_SetFreecamOffset then getgenv().AsuHub_SetFreecamOffset(val, nil, nil) end end
})

getgenv().AsuHub_OffsetYSlider = OffsetSection:Slider({
    Title = "Geser Atas/Bawah (Y) [M/N]", Step = 0.1, Value = {Min = -50, Max = 50, Default = 0},
    Callback = function(val) if getgenv().AsuHub_SetFreecamOffset then getgenv().AsuHub_SetFreecamOffset(nil, val, nil) end end
})

getgenv().AsuHub_OffsetZSlider = OffsetSection:Slider({
    Title = "Geser Maju/Mundur (Z) [I/K]", Step = 0.1, Value = {Min = -50, Max = 50, Default = 0},
    Callback = function(val) if getgenv().AsuHub_SetFreecamOffset then getgenv().AsuHub_SetFreecamOffset(nil, nil, val) end end
})

OffsetSection:Button({
    Title = "Reset Target Offset",
    Color = Color3.fromHex("#dfdfdf"),
    Icon = "solar:refresh-bold",
    Justify = "Center",
    Callback = function()
        if getgenv().AsuHub_SetFreecamOffset then getgenv().AsuHub_SetFreecamOffset(0, 0, 0) end
        getgenv().AsuHub_IgnoreOffsetSync = true
        pcall(function()
            getgenv().AsuHub_OffsetXSlider:SetValue(0)
            getgenv().AsuHub_OffsetYSlider:SetValue(0)
            getgenv().AsuHub_OffsetZSlider:SetValue(0)
        end)
        getgenv().AsuHub_IgnoreOffsetSync = false
        Notify("Target Reset", "Titik fokus kamera dikembalikan ke pusat objek.")
    end
})

CinematicTab:Space()

local CineTimeBox = CinematicTab:Section({ Title = "Waktu & Pencahayaan", Box = true, BoxBorder = true, Opened = false })

local TimeSlider = CineTimeBox:Slider({
    Title = "Time of Day",
    Step = 1,
    Value = {Min = 0, Max = 24, Default = lastCinematic.Time},
    Callback = function(val) 
        if isScriptLoading then return end
        Lighting.ClockTime = val; lastCinematic.Time = val; saveCinematic()
    end,
})

CineTimeBox:Space()

local BrightnessSlider = CineTimeBox:Slider({
    Title = "Kecerahan (Brightness)",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.Brightness},
    Callback = function(val) 
        if isScriptLoading then return end
        Lighting.Brightness = (val/100)*5; lastCinematic.Brightness = val; saveCinematic()
    end,
})

CinematicTab:Space()

local CineFogBox = CinematicTab:Section({ Title = "Kabut (Fog)", Box = true, BoxBorder = true, Opened = false })

local FogThicknessSlider = CineFogBox:Slider({
    Title = "Ketebalan Kabut",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.FogThickness},
    Callback = function(val)
        if isScriptLoading then return end
        local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
        if val == 0 then
            Lighting.FogEnd, Lighting.FogStart = originalLighting.FogEnd, originalLighting.FogStart
            if atmo then atmo.Density, atmo.Offset = originalLighting.AtmosphereDensity, originalLighting.AtmosphereOffset end
        else
            if atmo then atmo.Density, atmo.Offset = (val / 100), 0 
            else Lighting.FogStart = 0; Lighting.FogEnd = 5000 - (val / 100) * 4950 end
        end
        lastCinematic.FogThickness = val; saveCinematic()
    end,
})

CineFogBox:Space()

local FogColorPicker = CineFogBox:Colorpicker({
    Title = "Warna Kabut",
    Default = safeFogColor,
    Callback = function(Value)
        if isScriptLoading then return end
        Lighting.FogColor = Value
        local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
        if atmo then atmo.Color, atmo.Decay = Value, Value end
        lastCinematic.FogColor = Value:ToHex(); saveCinematic()
    end
})

CinematicTab:Space()

-- MENU DEPTH OF FIELD 
getgenv().AsuHub_DoFUIElements = {}

local DoFSection = CinematicTab:Section({ Title = "Depth of Field (Fokus Kamera)", Box = true, BoxBorder = true, Opened = false })

DoFSection:Paragraph({
    Title = "Daftar Shortcut DoF",
    Desc = "• ( \\ ) : Nyala/Mati Custom DoF\n• ( - / = ) : Atur Jarak Fokus Kamera\n• ( Shift + - / = ) : Atur Radius Area Fokus\n• ( Shift + [ / ] ) : Atur Blur Objek Jauh\n• ( Ctrl + [ / ] ) : Atur Blur Objek Dekat"
})

getgenv().AsuHub_DoFUIElements.Toggle = DoFSection:Toggle({
    Title = "Enable Custom DoF ( \\ )",
    Desc = "Hanya bisa diaktifkan saat Freecam menyala.",
    Value = false,
    Callback = function(state)
        if getgenv().AsuHub_IgnoreUICallback then return end
        if getgenv().AsuHub_ToggleDoF then getgenv().AsuHub_ToggleDoF(state) end
    end
})

getgenv().AsuHub_DoFUIElements.FocusDistance = DoFSection:Slider({
    Title = "Focus Distance ( - / = )",
    Desc = "Jarak titik fokus utama.",
    Step = 1,
    Value = { Min = 0, Max = 500, Default = lastCinematic.FocusDist or 20 }, -- FIX
    Callback = function(val)
        if getgenv().AsuHub_IgnoreUICallback then return end
        if getgenv().AsuHub_SetDoFProperty then getgenv().AsuHub_SetDoFProperty("FocusDistance", val) end
    end
})

getgenv().AsuHub_DoFUIElements.InFocusRadius = DoFSection:Slider({
    Title = "In-Focus Radius ( Shift + -/= )",
    Desc = "Lebar area yang tetap tajam di sekitar titik fokus.",
    Step = 1,
    Value = { Min = 0, Max = 50, Default = lastCinematic.FocusRadius or 5 }, -- FIX
    Callback = function(val)
        if getgenv().AsuHub_IgnoreUICallback then return end
        if getgenv().AsuHub_SetDoFProperty then getgenv().AsuHub_SetDoFProperty("InFocusRadius", val) end
    end
})

getgenv().AsuHub_DoFUIElements.FarIntensity = DoFSection:Slider({
    Title = "Far Intensity ( Shift + [ / ] )",
    Desc = "Intensitas buram pada objek jauh (latar belakang).",
    Step = 0.01,
    Value = { Min = 0, Max = 1, Default = lastCinematic.BlurFar or 0.1 }, -- FIX
    Callback = function(val)
        if getgenv().AsuHub_IgnoreUICallback then return end
        if getgenv().AsuHub_SetDoFProperty then getgenv().AsuHub_SetDoFProperty("FarIntensity", val) end
    end
})

getgenv().AsuHub_DoFUIElements.NearIntensity = DoFSection:Slider({
    Title = "Near Intensity ( Ctrl + [ / ] )",
    Desc = "Intensitas buram pada objek dekat (depan kamera).",
    Step = 0.01,
    Value = { Min = 0, Max = 1, Default = lastCinematic.BlurNear or 0.1 }, -- FIX
    Callback = function(val)
        if getgenv().AsuHub_IgnoreUICallback then return end
        if getgenv().AsuHub_SetDoFProperty then getgenv().AsuHub_SetDoFProperty("NearIntensity", val) end
    end
})

CinematicTab:Space()

local CineFXBox = CinematicTab:Section({ Title = "Color Grading & FX", Box = true, BoxBorder = true, Opened = false })

local SaturationSlider = CineFXBox:Slider({
    Title = "Saturasi Warna",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.Saturation},
    Callback = function(val) 
        curSat = val
        if not isScriptLoading then updateColorCorrection(); lastCinematic.Saturation = val; saveCinematic() end
    end,
})

CineFXBox:Space()

local ContrastSlider = CineFXBox:Slider({
    Title = "Kontras",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.Contrast},
    Callback = function(val) 
        curCont = val
        if not isScriptLoading then updateColorCorrection(); lastCinematic.Contrast = val; saveCinematic() end
    end,
})

CineFXBox:Space()

local BloomSlider = CineFXBox:Slider({
    Title = "Bloom (Silau Cahaya)",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.Bloom},
    Callback = function(val) 
        if not isScriptLoading then updateBloom(val); lastCinematic.Bloom = val; saveCinematic() end
    end,
})

CineFXBox:Space()

local RaysSlider = CineFXBox:Slider({
    Title = "Sun Rays (Sinar Matahari)",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.SunRays},
    Callback = function(val) 
        if not isScriptLoading then updateSunRays(val); lastCinematic.SunRays = val; saveCinematic() end
    end,
})

CineFXBox:Space()

local VignetteSlider = CineFXBox:Slider({
    Title = "Vignette (Tepi Gelap)",
    Step = 1,
    Value = {Min = 0, Max = 100, Default = lastCinematic.Vignette},
    Callback = function(val) 
        if not isScriptLoading then updateVignette(val); lastCinematic.Vignette = val; saveCinematic() end
    end,
})

CinematicTab:Space()

local ResetBox = CinematicTab:Section({ Title = "Reset Visual", Box = true, BoxBorder = true, Opened = true })

ResetBox:Button({
    Title = "Reset Semua Efek Visual",
    Color = Color3.fromHex("#dfdfdf"),
    Icon = "solar:refresh-bold",
    Justify = "Center",
    Callback = function()
        CleanupCinematic()
        isScriptLoading = true 
        
        -- Reset tabel lastCinematic ke default
        lastCinematic = {
            Time = math.floor(originalLighting.Time), 
            Brightness = math.floor(originalLighting.Brightness * 20),
            FogThickness = 0, FogColor = originalLighting.FogColor:ToHex(), 
            FocusDist = 20, FocusRadius = 5, BlurNear = 0, BlurFar = 0, 
            Saturation = 50, Contrast = 50, Bloom = 0, SunRays = 0, Vignette = 0
        }

        -- Update UI Slider dengan pcall agar kebal error
        pcall(function() TimeSlider:Set(math.floor(originalLighting.Time)) end)
        pcall(function() BrightnessSlider:Set(math.floor(originalLighting.Brightness * 20)) end)
        pcall(function() FogThicknessSlider:Set(0) end)
        pcall(function() FogColorPicker:Set(originalLighting.FogColor) end)
        pcall(function() SaturationSlider:Set(50) end)
        pcall(function() ContrastSlider:Set(50) end)
        pcall(function() BloomSlider:Set(0) end)
        pcall(function() RaysSlider:Set(0) end)
        pcall(function() VignetteSlider:Set(0) end)
        
        -- Update UI DoF Baru
        pcall(function() getgenv().AsuHub_DoFUIElements.FocusDistance:Set(20) end)
        pcall(function() getgenv().AsuHub_DoFUIElements.InFocusRadius:Set(5) end)
        pcall(function() getgenv().AsuHub_DoFUIElements.FarIntensity:Set(0.1) end)
        pcall(function() getgenv().AsuHub_DoFUIElements.NearIntensity:Set(0.1) end)
        
        -- Hapus file save lama
        pcall(function() if delfile then delfile(CINEMATIC_FILE) end end)
        
        task.wait(0.5)
        isScriptLoading = false
        Notify("Reset", "Semua visual dikembalikan ke Default game.")
    end
})

-- ==========================================
-- TAB 4: SETTINGS
-- ==========================================
Window:Divider()
local SettingsTab = Window:Tab({
    Title = "Settings",
    Icon = "solar:settings-bold",
    IconColor = Color3.fromHex("#a8a8a8"),
    IconShape = "Square",
    Border = true,
})
Window:Divider()

local UISettings = SettingsTab:Section({ Title = "Interface Settings", Box = true, BoxBorder = true, Opened = true })

UISettings:Paragraph({
    Title = "Daftar Shortcut Interface",
    Desc = "• (Shfit + P) : On/Off Freecam AsuHub\n• (G) : Hide/Show UI AsuHub\n• (-) : Hide/Show HUD AsuHub"
})

UISettings:Keybind({
    Title = "Change Freecam Keybind",
    Desc = "Pilih tombol pasangan untuk kombinasi (Shift + [Tombol Pilihanmu]).",
    Value = "P",
    Callback = function(key)
        if Enum.KeyCode[key] then
            getgenv().AsuHub_FreecamKey = Enum.KeyCode[key]
        end
    end
})

UISettings:Keybind({
    Title = "Change GUI Keybind",
    Desc = "Tekan tombol yang diinginkan untuk mengatur shortcut.",
    Value = "G",
    Callback = function(key)
        if Enum.KeyCode[key] then
            Window:SetToggleKey(Enum.KeyCode[key])
        end
    end
})

UISettings:Keybind({
    Title = "Change HUD Keybind",
    Desc = "Tekan tombol untuk menyembunyikan/menampilkan HUD FPS.",
    Value = "Minus",
    Callback = function(key)
        if Enum.KeyCode[key] then
            getgenv().AsuHub_HUDKey = Enum.KeyCode[key]
        end
    end
})

-- List Semua Tema Custom
local customThemes = {
    "AsuHub Dark", 
    "AsuHub Light", 
    "AsuHub Cotton", 
    "AsuHub Midnight",
    "AsuHub Blood",
    "AsuHub Forest",
    "AsuHub Cyberpunk",
    "AsuHub Ocean",
    "AsuHub Gold",
    "AsuHub Amethyst",
    "AsuHub RGB"
}

UISettings:Dropdown({
    Title = "UI Theme",
    Values = customThemes,
    Value = "AsuHub Dark",
    Callback = function(theme)
        WindUI:SetTheme(theme)
        Notify("Theme Applied", "Tema diubah ke: " .. theme, 2)
    end
})

UISettings:Toggle({
    Title = "Disable Notifications (Streamer Mode)",
    Desc = "Mematikan semua notifikasi pop-up. Khusus untuk om kotak si streamer.",
    Value = false,
    Callback = function(value)
        getgenv().AsuHub_DisableNotifications = value
        
        -- Opsi tambahan: Beri tahu pengguna jika notifikasi kembali dinyalakan
        if not value then
            WindUI:Notify({
                Title = "Streamer Mode",
                Content = "Notifikasi kembali diaktifkan!",
                Duration = 3,
                Icon = "solar:bell-bold"
            })
        end
    end
})

-- ==========================================
-- APPLY SAVED VISUALS ON LOAD
-- ==========================================
task.spawn(function()
    task.wait(1.5)
    isScriptLoading = false 
    
    local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
    if lastCinematic.FogThickness > 0 then
        if atmo then atmo.Density = (lastCinematic.FogThickness / 100); atmo.Offset = 0 
        else Lighting.FogStart = 0; Lighting.FogEnd = 5000 - (lastCinematic.FogThickness / 100) * 4950 end
    end
    Lighting.FogColor = safeFogColor
    if atmo then atmo.Color, atmo.Decay = safeFogColor, safeFogColor end
    
    applyDoF()
    updateColorCorrection()
    updateBloom(lastCinematic.Bloom)
    updateSunRays(lastCinematic.SunRays)
    updateVignette(lastCinematic.Vignette)
end)

-- ==========================================
-- AUTO-OPEN FREECAM TAB ON RUN
-- ==========================================
InfoTab:Select()
