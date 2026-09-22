local MOD_NAME = "RagnaCustomsVote"
local Api = _G.RagnaCustomsApi or _G.RagnaCustoms

local function log(level, message)
    local line = string.format("[%s] [%s] %s", MOD_NAME, tostring(level), tostring(message))
    if type(_G.Ragna) == "table" and type(_G.Ragna.log) == "function" then
        _G.Ragna.log(level, message)
    elseif print then
        print(line .. "\n")
    end
end

local function loadApiDependency()
    if type(Api) == "table"
        and type(Api.getSongVote) == "function"
        and type(Api.upvote) == "function"
        and type(Api.downvote) == "function"
        and type(Api.readInstalledSongId) == "function"
        and type(Api.writeInstalledSongId) == "function"
        and type(Api.discoverInstalledSongId) == "function"
        and type(Api.search) == "function"
        and type(Api.getSong) == "function"
        and type(Api.on) == "function" then
        return Api
    end

    local lastError = nil
    for _, path in ipairs({
        "Mods/RagnaCustomsApi/scripts/ragnacustoms_api.lua",
        "Mods/RagnaCustomsApi/Scripts/ragnacustoms_api.lua",
        "../RagnaCustomsApi/scripts/ragnacustoms_api.lua",
        "../RagnaCustomsApi/Scripts/ragnacustoms_api.lua",
    }) do
        local ok, loaded = pcall(dofile, path)
        if ok and type(loaded) == "table" then
            return loaded
        end
        lastError = loaded
    end
    return nil, lastError
end

Api = loadApiDependency()
if type(Api) ~= "table"
    or type(Api.getSongVote) ~= "function"
    or type(Api.upvote) ~= "function"
    or type(Api.downvote) ~= "function"
    or type(Api.readInstalledSongId) ~= "function"
    or type(Api.writeInstalledSongId) ~= "function"
    or type(Api.discoverInstalledSongId) ~= "function"
    or type(Api.search) ~= "function"
    or type(Api.getSong) ~= "function"
    or type(Api.on) ~= "function" then
    log("error", "RagnaCustomsApi >= 0.3.0 is required")
    return
end

-- The 0.3 API uses its documented catalog transport and numeric song IDs.
Api.configure({ preferApi = true, transport = "varest" })

local state = _G.__ragnaCustomsVoteState or {
    hooksInstalled = false,
    buttonHooksInstalled = false,
    beatmap = nil,
    songId = nil,
    songFolder = nil,
    songMetadata = nil,
    resolutionKey = nil,
    resolutionPending = false,
    custom = nil,
    panelPath = nil,
    mode = nil,
    widgets = nil,
    phase = "hidden",
    currentVote = nil,
    upvotes = 0,
    downvotes = 0,
    customScoresAllowed = nil,
    settingProbeQueued = false,
    createFailedPath = nil,
    error = nil,
    pressed = { up = false, down = false },
    apiEventsInstalled = false,
}
_G.__ragnaCustomsVoteState = state
state.diagnostics = state.diagnostics or {}

local function safeCall(callback, fallback)
    local ok, result = pcall(callback)
    if ok and result ~= nil then
        return result
    end
    return fallback
end

local function unwrap(value)
    if value ~= nil and type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
        local ok, getter = pcall(function()
            return value.get
        end)
        if ok and type(getter) == "function" then
            return safeCall(function()
                return value:get()
            end, value)
        end
    end
    return value
end

local function valid(object)
    if object == nil then
        return false
    end
    return safeCall(function()
        return object:IsValid()
    end, true)
end

local function fullName(object)
    return safeCall(function()
        return object:GetFullName()
    end, tostring(object))
end

local function visible(object)
    return valid(object) and safeCall(function()
        return object:IsVisible()
    end, true)
end

local function asBoolean(value)
    value = unwrap(value)
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    local text = string.lower(tostring(value or ""))
    if text == "true" or text == "1" then return true end
    if text == "false" or text == "0" then return false end
    return nil
end

local function customScoreSendingAllowed()
    if type(FindFirstOf) ~= "function" then return false end
    local gameInstance = safeCall(function() return FindFirstOf("RagnarockGameInstance") end, nil)
    if valid(gameInstance) then
        local result = asBoolean(safeCall(function()
            return gameInstance:GetAllowSendingCustomSongScores()
        end, nil))
        if result ~= nil then return result end
    end
    -- Older builds do not expose the setting. Keep the panel available there.
    return true
end

local RESULT_FLOWS = {
    flat = {
        panelClasses = { "FlatInGameEndPanel_C" },
        buttonClass = "/Game/Flat/Blueprints/UI/InGame/FlatInGameButton.FlatInGameButton_C",
    },
    vr = {
        buttonClass = "/Game/Flat/Blueprints/UI/InGame/FlatInGameButton.FlatInGameButton_C",
    },
}

local function findResultsPanelForFlow(flow)
    for _, className in ipairs(flow.panelClasses) do
        local objects = safeCall(function()
            if type(FindAllOf) == "function" then return FindAllOf(className) end
            return { FindFirstOf(className) }
        end, {})
        for _, object in ipairs(objects or {}) do
            local objectName = fullName(object)
            if valid(object)
                and objectName:find("/Engine/Transient.", 1, true) ~= nil
                and objectName:find("Default__", 1, true) == nil
                and visible(object) then
                return object, objectName
            end
        end
    end
    return nil
end

local function findFlatResultsPanel()
    local panel, name = findResultsPanelForFlow(RESULT_FLOWS.flat)
    if panel ~= nil then return panel, name, "flat" end
    return nil
end

local function findVrResultsPanel()
    if type(FindAllOf) ~= "function" then
        return nil
    end
    -- The visible VR Results board is rendered by one of these live widget
    -- components. Return its UserWidget as the flow anchor; the scoreboard
    -- surface helper performs the component-specific attachment later.
    for _, componentName in ipairs({ ".SongInfoWidget", ".ScoreboardWidget" }) do
        for _, component in ipairs(safeCall(function() return FindAllOf("WidgetComponent") end, {}) or {}) do
            if valid(component) and fullName(component):find(componentName, 1, true) ~= nil then
                local widget = safeCall(function() return component:GetUserWidgetObject() end, nil)
                if valid(widget) then
                    return widget, fullName(widget), "vr"
                end
            end
        end
    end
    return nil
end

local function findActiveResultsPanel()
    if type(FindFirstOf) ~= "function" then
        return nil
    end
    local panel, name, mode = findVrResultsPanel()
    if panel ~= nil then
        return panel, name, mode
    end
    panel, name, mode = findFlatResultsPanel()
    if panel ~= nil then
        return panel, name, mode
    end
    return nil
end

local function rootPath(panelName)
    return tostring(panelName or ""):match("(/Engine/Transient%..-InGameEnd.-_C_%d+)")
        or tostring(panelName or ""):match("(/Engine/Transient%..-EndPanel_C_%d+)")
        or tostring(panelName or "")
end

local function findFlatInfoCanvas(panelPath)
    -- Flat has tabs; keep controls in the Info tab hierarchy so they hide
    -- automatically whenever the Results screen switches tabs.
    for _, className in ipairs({ "FlatItem_SongInfoEnd_C", "FlatItem_SongInfoEnd" }) do
        local widgets = safeCall(function()
            if type(FindAllOf) == "function" then return FindAllOf(className) end
            return { FindFirstOf(className) }
        end, {})
        for _, infoWidget in ipairs(widgets or {}) do
            local name = fullName(infoWidget)
            if valid(infoWidget)
                and visible(infoWidget)
                and name:find(tostring(panelPath or ""), 1, true) ~= nil then
                local tree = safeCall(function() return infoWidget.WidgetTree end, nil)
                local root = tree and safeCall(function() return tree.RootWidget end, nil) or nil
                if valid(root) then
                    if not state.diagnostics.songInfoCanvas then
                        state.diagnostics.songInfoCanvas = true
                        log("info", "song info canvas " .. fullName(root))
                    end
                    return root, infoWidget
                end
            end
        end
    end
    if type(FindAllOf) == "function" then
        local candidates = safeCall(function() return FindAllOf("CanvasPanel") end, {})
        for _, candidate in ipairs(candidates or {}) do
            local name = fullName(candidate)
            if valid(candidate)
                and name:find(tostring(panelPath or ""), 1, true) ~= nil
                and name:find("FlatItem_SongInfoEnd.WidgetTree.CanvasPanel_0", 1, true) ~= nil
                and name:find("FlatLeaderboard_C_", 1, true) == nil then
                if visible(candidate) then
                    if not state.diagnostics.songInfoCanvas then
                        state.diagnostics.songInfoCanvas = true
                        log("info", "song info canvas " .. name)
                    end
                    return candidate, nil
                end
            end
        end
    end
    return nil
end

local function findVrStatsComponent()
    if type(FindAllOf) ~= "function" then return nil end
    local best = nil
    local bestScale = -1.0
    for _, component in ipairs(safeCall(function() return FindAllOf("WidgetComponent") end, {}) or {}) do
        local name = fullName(component)
        if valid(component) and name:find(".StatsWidget", 1, true) ~= nil
            and safeCall(function() return component:IsVisible() end, false) then
            local user = safeCall(function() return component:GetUserWidgetObject() end, nil)
            local scale = safeCall(function() return component:K2_GetComponentScale() end, nil)
            local value = tonumber(scale and scale.X) or 0.0
            log("info", "VR StatsWidget candidate=" .. name .. " user=" .. tostring(valid(user)) .. " scale=" .. tostring(value))
            -- The rendered Results Distance surface is StatsPopup. The
            -- larger BP_PlayerStats component is a reflected duplicate and
            -- accepts children without painting them in VR.
            local isRenderedPopup = name:find("BP_StatsPopup_C_", 1, true) ~= nil
            if valid(user) and (isRenderedPopup or value > bestScale) then
                best = component
                bestScale = value
                if isRenderedPopup then break end
            end
        end
    end
    if valid(best) then
        state.statsComponent = best
        state.statsUser = safeCall(function() return best:GetUserWidgetObject() end, nil)
        local tree = valid(state.statsUser) and safeCall(function() return state.statsUser.WidgetTree end, nil) or nil
        state.statsTree = tree
        state.statsRoot = valid(tree) and safeCall(function() return tree.RootWidget end, nil) or nil
        log("info", "VR StatsWidget selected=" .. fullName(best) .. " scale=" .. tostring(bestScale))
    end
    return best
end

local function findVrScoreboardSurface()
    if type(FindAllOf) ~= "function" then return nil, nil, nil end
    for _, component in ipairs(safeCall(function() return FindAllOf("WidgetComponent") end, {}) or {}) do
        local name = fullName(component)
        if valid(component)
            and name:find(".ScoreboardWidget", 1, true) ~= nil
            and safeCall(function() return component:IsVisible() end, false) then
            local user = safeCall(function() return component:GetUserWidgetObject() end, nil)
            local tree = valid(user) and safeCall(function() return user.WidgetTree end, nil) or nil
            local root = valid(tree) and safeCall(function() return tree.RootWidget end, nil) or nil
            if valid(user) and valid(root) then
                -- CanvasPanel_1 is the authored Distance subpanel and is
                -- clipped to the stock stats band.  Use the component root
                -- surface for the mod-owned controls so they can occupy the
                -- unused space beside Distance without moving stock widgets.
                safeCall(function() user:SetVisibility(0) end, nil)
                safeCall(function() user:SetIsEnabled(true) end, nil)
                safeCall(function() root:SetVisibility(0) end, nil)
                safeCall(function() root:SetIsEnabled(true) end, nil)
                -- Set the reflected flags directly.  The setter method
                -- rebuilds the WidgetComponent render target synchronously
                -- on this build and can stall the UE4SS event loop.
                safeCall(function() component:SetPropertyValue("bReceiveHardwareInput", true) end, nil)
                safeCall(function() component:SetPropertyValue("bWindowFocusable", true) end, nil)
                state.scoreboardComponent = component
                state.scoreboardUser = user
                state.scoreboardRoot = root
                log("info", "VR Scoreboard surface selected component=" .. name
                    .. " root=" .. fullName(root))
                return component, user, root
            end
        end
    end
    return nil, nil, nil
end

local function construct(classPath, outer, name)
    if type(StaticFindObject) ~= "function" or type(StaticConstructObject) ~= "function" then
        return nil
    end
    local class = safeCall(function()
        return StaticFindObject(classPath)
    end, nil)
    if class == nil then
        return nil
    end
    local objectName = 0
    if name ~= nil and type(FName) == "function" then
        objectName = safeCall(function()
            return FName(name)
        end, 0)
    end
    return safeCall(function()
        return StaticConstructObject(class, outer, objectName, 0, 0, nil, false, false, nil)
    end, nil)
end

local function setText(widget, value)
    if not valid(widget) then
        return false
    end
    local text = tostring(value or "")
    return safeCall(function()
        widget:SetText(FText(text))
        return true
    end, false)
end

local function addToCanvas(canvas, widget, geometry)
    local slot = safeCall(function()
        return canvas:AddChildToCanvas(widget)
    end, nil)
    if not valid(slot) then
        slot = safeCall(function()
            return canvas:AddChild(widget)
        end, nil)
    end
    if not valid(slot) then
        return false
    end
    local function configure(targetSlot)
        safeCall(function() targetSlot:SetAutoSize(false) end, nil)
        if geometry.anchorRight then
            targetSlot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
        end
        safeCall(function() targetSlot:SetPosition({ X = geometry.x, Y = geometry.y }) end, nil)
        safeCall(function() targetSlot:SetSize({ X = geometry.width, Y = geometry.height }) end, nil)
        safeCall(function() targetSlot:SetZOrder(geometry.z or 9000) end, nil)
    end
    safeCall(function() configure(slot) end, nil)
    -- On this build the returned slot can be a stale wrapper.
    -- The widget's live Slot property is the stable path.
    safeCall(function()
        local liveSlot = widget.Slot
        if valid(liveSlot) then configure(liveSlot) end
    end, nil)
    safeCall(function() widget:SetVisibility(0) end, nil)
    safeCall(function() widget:ForceVolatile(true) end, nil)
    safeCall(function() widget:SetRenderOpacity(1.0) end, nil)
    safeCall(function() widget:InvalidateLayoutAndVolatility() end, nil)
    safeCall(function() widget:SynchronizeProperties() end, nil)
    safeCall(function() canvas:InvalidateLayoutAndVolatility() end, nil)
    return true
end

local function addButtonToCanvas(canvas, widget, geometry)
    local slot = safeCall(function()
        return canvas:AddChildToCanvas(widget)
    end, nil)
    if not valid(slot) then return false end
    safeCall(function()
        slot:SetAutoSize(false)
        slot:SetPosition({ X = geometry.x, Y = geometry.y })
        slot:SetSize({ X = geometry.width, Y = geometry.height })
        slot:SetZOrder(geometry.z or 9000)
    end, nil)
    return true
end

local function findPlayerController(context)
    local controller = nil
    if type(UEHelpers) == "table" and type(UEHelpers.GetPlayerController) == "function" then
        controller = safeCall(function()
            return UEHelpers.GetPlayerController()
        end, nil)
    end
    if not valid(controller) and valid(context) then
        controller = safeCall(function()
            return context:GetOwningPlayer()
        end, nil)
    end
    if valid(controller) then
        return controller
    end
    return nil
end

local function createUserWidget(classPath, context)
    if type(StaticFindObject) ~= "function" then
        return nil
    end
    local library = safeCall(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end, nil)
    local class = safeCall(function()
        return StaticFindObject(classPath)
    end, nil)
    if not valid(library) or not valid(class) then
        return nil
    end
    local owner = findPlayerController(context)
    if not valid(owner) then
        log("error", "cannot create Results button: player controller unavailable")
        return nil
    end
    local widget = safeCall(function()
        return library:Create(owner, class, owner)
    end, nil)
    if not valid(widget) then
        log("error", "failed to create Results button widget class=" .. tostring(classPath))
        return nil
    end
    return widget
end

local function objectPath(object)
    local name = fullName(object)
    return name:match("^[^ ]+ (.+)$") or name
end

local function makeButton(canvas, context, mode, label, geometry)
    local classPath = RESULT_FLOWS[mode].buttonClass
    log("info", "vote button create begin label=" .. tostring(label))
    local root = createUserWidget(classPath, context)
    log("info", "vote button create done label=" .. tostring(label))
    if not valid(root) then
        return nil
    end
    safeCall(function()
        root:SetVisibility(0)
        root:SetRenderOpacity(1.0)
        root:SetIsEnabled(true)
    end, nil)
    local child = safeCall(function() return root:GetPropertyValue("Text_") end, nil)
    local childClass = valid(child) and safeCall(function()
        return child:GetClass():GetFullName()
    end, "unknown") or "nil"
    local childVisible = valid(child) and safeCall(function() return child:IsVisible() end, false) or false
    log("info", "vote button child resolved label=" .. tostring(label)
        .. " valid=" .. tostring(valid(child))
        .. " class=" .. tostring(childClass)
        .. " visible=" .. tostring(childVisible))
    if valid(child) then
        if not setText(child, label) then
            log("error", "failed to label stock Results button label=" .. tostring(label))
        else
            log("info", "stock Results button labeled before attach label=" .. tostring(label))
        end
        safeCall(function()
            child:SetJustification(1) -- ETextJustify::Center
            child:SetHorizontalAlignment(2) -- EHorizontalAlignment::HAlign_Center
            child:SetVerticalAlignment(2) -- EVerticalAlignment::VAlign_Center
            child:SetVisibility(0)
            child:SetRenderOpacity(1.0)
            child:SetIsEnabled(true)
        end, nil)
    end
    local innerButton = safeCall(function() return root:GetPropertyValue("Button_64") end, nil)
    if valid(innerButton) then
        log("info", "vote button inner target property=Button_64 path=" .. objectPath(innerButton))
    end
    safeCall(function()
        root:SetRenderTransformPivot({ X = 0.0, Y = 0.0 })
        -- FlatInGameButton's authored content is approximately 300x70. VR
        -- needs a larger hit target and readable label at the Results board's
        -- world-space scale.
        if mode == "flat" then
            root:SetRenderScale({ X = 0.36, Y = 0.6 })
        else
            root:SetRenderScale({ X = 1.32, Y = 1.58 })
        end
        root:SetRenderOpacity(1.0)
        root:SetRenderTransformTranslation({ X = 0.0, Y = 0.0 })
    end, nil)
    local attached = mode == "flat"
        and addButtonToCanvas(canvas, root, geometry)
        or addToCanvas(canvas, root, geometry)
    if not attached then
        log("error", "failed to attach Results button widget label=" .. tostring(label))
        return nil
    end
    local function slotDescription(widget)
        local slot = valid(widget) and safeCall(function() return widget.Slot end, nil) or nil
        if not valid(slot) then return "invalid-slot" end
        local position = safeCall(function() return slot:GetPosition() end, nil)
        local size = safeCall(function() return slot:GetSize() end, nil)
        return "pos=" .. tostring(position and position.X) .. "," .. tostring(position and position.Y)
            .. " size=" .. tostring(size and size.X) .. "," .. tostring(size and size.Y)
    end
    log("info", "vote button layout root=" .. slotDescription(root)
        .. " inner=" .. slotDescription(innerButton))
    return {
        root = root,
        label = label,
        button = root,
        innerButton = innerButton,
        text = child,
        objectPath = objectPath(root),
    }
end

local function makeFlatButton(canvas, context, label, geometry)
    return makeButton(canvas, context, "flat", label, geometry)
end

local function makeVrButton(canvas, context, label, geometry)
    return makeButton(canvas, context, "vr", label, geometry)
end

local function createVoteButtons(canvas, context, mode, entries)
    local make = mode == "vr" and makeVrButton or makeFlatButton
    local widgets = {}
    for _, entry in ipairs(entries) do
        local widget = make(canvas, context, entry.label, entry.geometry)
        if widget == nil then
            return nil
        end
        widgets[entry.direction] = widget
    end
    return widgets
end

local COLORS = {
    normal = { R = 0.82, G = 0.86, B = 0.92, A = 1.0 },
    up = { R = 0.25, G = 1.0, B = 0.42, A = 1.0 },
    down = { R = 1.0, G = 0.32, B = 0.32, A = 1.0 },
    disabled = { R = 0.52, G = 0.56, B = 0.62, A = 1.0 },
}

local function removeWidgets()
    local widgets = state.widgets
    if widgets ~= nil then
        for _, entry in pairs(widgets) do
            local candidates = type(entry) == "table"
                and { entry.root, entry.button, entry.text, entry.component }
                or { entry }
            for _, widget in ipairs(candidates) do
                if valid(widget) then
                    safeCall(function() widget:RemoveFromParent() end, nil)
                end
            end
        end
    end
    if valid(state.vrOverlayComponent) then
        safeCall(function() state.vrOverlayComponent:DestroyComponent() end, nil)
    end
    state.vrOverlayComponent = nil
    state.widgets = nil
    state.panelPath = nil
    state.loadedSongId = nil
    state.phase = "hidden"
    state.pressed = { up = false, down = false }
end

local function render()
    local widgets = state.widgets
    if widgets == nil then
        return
    end
    local upColor = state.currentVote == "up" and COLORS.up or COLORS.normal
    local downColor = state.currentVote == "down" and COLORS.down or COLORS.normal
    safeCall(function() widgets.up.button:SetColorAndOpacity(upColor) end, nil)
    safeCall(function() widgets.down.button:SetColorAndOpacity(downColor) end, nil)
    local enabled = state.phase == "ready"
    safeCall(function()
        widgets.up.button:SetIsEnabled(enabled)
        widgets.down.button:SetIsEnabled(enabled)
        if valid(widgets.up.innerButton) then widgets.up.innerButton:SetIsEnabled(enabled) end
        if valid(widgets.down.innerButton) then widgets.down.innerButton:SetIsEnabled(enabled) end
    end, nil)
    local status = "Vote for this custom song"
    if state.phase == "loading" then
        status = "Loading votes..."
    elseif state.phase == "submitting" then
        status = "Saving vote..."
    elseif state.phase == "error" then
        status = "Vote unavailable"
    end
    if state.phase ~= "loading" and state.phase ~= "submitting" then
        setText(widgets.up.text, "▲ " .. tostring(state.upvotes or 0))
        setText(widgets.down.text, "▼ " .. tostring(state.downvotes or 0))
    end
    if widgets.status ~= nil then setText(widgets.status.text, status) end
end

local function applyResponse(result)
    if state.widgets == nil then
        return
    end
    if result == nil or result.ok ~= true then
        state.phase = "error"
        state.error = result and result.error or { code = "unknown_error" }
        log("error", "vote response failed code=" .. tostring(state.error.code)
            .. " message=" .. tostring(state.error.message))
        render()
        return
    end
    state.phase = "ready"
    state.error = nil
    state.currentVote = result.state.currentVote
    state.upvotes = result.state.upvotes
    state.downvotes = result.state.downvotes
    log("info", "vote response applied current=" .. tostring(state.currentVote)
        .. " up=" .. tostring(state.upvotes) .. " down=" .. tostring(state.downvotes))
    -- Re-enable the input surface immediately when the request completes;
    -- label repainting is deferred, but click availability must not be.
    render()
    -- VaRest callbacks are not guaranteed to run on the game thread. Queue
    -- all Slate mutations so the attached stock labels can repaint safely.
    local repaint = function()
        log("info", "vote repaint entered widgets=" .. tostring(state.widgets ~= nil))
        if state.widgets == nil then return end
        log("info", "vote repaint state-only current=" .. tostring(state.currentVote)
            .. " up=" .. tostring(state.upvotes) .. " down=" .. tostring(state.downvotes))
        render()
    end
    -- Give the freshly-created Blueprint one rendered tick before touching
    -- its generated TextBlock. Immediate mutation can stall this build.
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(1000, function()
            log("info", "vote repaint executing after widget settle")
            repaint()
        end)
    else
        repaint()
    end
end

local function jsonNumberField(body, name)
    return tonumber(tostring(body or ""):match('"' .. name .. '"%s*:%s*(-?%d+%.?%d*)'))
end

local function jsonStringField(body, name)
    local value = tostring(body or ""):match('"' .. name .. '"%s*:%s*"([^"]*)"')
    if value == nil and tostring(body or ""):match('"' .. name .. '"%s*:%s*null') ~= nil then
        return nil
    end
    return value
end

local function apiVoteResult(responseBody, error)
    if error ~= nil then
        return { ok = false, error = error }
    end
    local body = type(responseBody) == "table" and responseBody.body or responseBody
    local upvotes = jsonNumberField(body, "upvotes")
    local downvotes = jsonNumberField(body, "downvotes")
    if upvotes == nil or downvotes == nil then
        return { ok = false, error = { code = "invalid_response", message = "vote response is missing counts" } }
    end
    local currentVote = jsonStringField(body, "currentVote")
    if currentVote ~= nil and currentVote ~= "up" and currentVote ~= "down" then
        return { ok = false, error = { code = "invalid_response", message = "vote response contains an invalid selection" } }
    end
    return {
        ok = true,
        state = { currentVote = currentVote, upvotes = upvotes, downvotes = downvotes },
    }
end

local function installApiEventHandlers()
    if state.apiEventsInstalled then return end
    state.apiEventsInstalled = true
    Api.on("vote.details.completed", function(payload)
        if payload == nil or tostring(payload.id) ~= tostring(state.songId) then return end
        applyResponse(apiVoteResult(payload.response, nil))
    end)
    Api.on("vote.details.failed", function(payload)
        if payload == nil or tostring(payload.id) ~= tostring(state.songId) then return end
        applyResponse(apiVoteResult(nil, payload.error))
    end)
    Api.on("vote.completed", function(payload)
        if payload == nil or tostring(payload.id) ~= tostring(state.songId) then return end
        applyResponse(apiVoteResult(payload.response, nil))
    end)
    Api.on("vote.failed", function(payload)
        if payload == nil or tostring(payload.id) ~= tostring(state.songId) then return end
        applyResponse(apiVoteResult(nil, payload.error))
    end)
end

local function loadVote()
    state.phase = "loading"
    render()
    installApiEventHandlers()
    local _, err = Api.getSongVote(state.songId)
    if err ~= nil then
        applyResponse(apiVoteResult(nil, { code = "start_failed", message = err }))
    end
end

local function submit(direction)
    if state.phase ~= "ready" then
        return
    end
    local desired = direction
    log("info", "vote submit current=" .. tostring(state.currentVote)
        .. " requested=" .. tostring(direction) .. " desired=" .. tostring(desired))
    state.phase = "submitting"
    render()
    installApiEventHandlers()
    local _, err
    if desired == "up" then
        _, err = Api.upvote(state.songId)
    else
        _, err = Api.downvote(state.songId)
    end
    if err ~= nil then
        applyResponse(apiVoteResult(nil, { code = "start_failed", message = err }))
    end
end

local BUTTON_HANDLER_PATHS = {
    -- The generated Blueprint delegate handlers are retained for builds where
    -- UE4SS dispatches them, while the native UButton callback is the input
    -- path used by the current Flat build.
    native = "/Script/UMG.Button:SlateHandleClicked",
    flat = "/Game/Flat/Blueprints/UI/InGame/FlatInGameButton.FlatInGameButton_C:"
        .. "BndEvt__FlatInGameButton_Button_64_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
    vr = "/Game/VRKeyboards/Blueprints/Keyboards/BasicPointAndClick/WBP_Button_Basic.WBP_Button_Basic_C:"
        .. "BndEvt__Button_0_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
}

local function voteDirectionForClickedButton(...)
    local widgets = state.widgets
    if widgets == nil then
        return nil
    end
    for index = 1, select("#", ...) do
        local clicked = unwrap(select(index, ...))
        if valid(clicked) then
            local clickedPath = objectPath(clicked)
            for _, direction in ipairs({ "up", "down" }) do
                local entry = widgets[direction]
                if entry ~= nil and clickedPath == entry.objectPath then
                    return direction
                end
            end
        end
    end
    return nil
end

local function installButtonHooks()
    if state.buttonHooksInstalled or type(RegisterHook) ~= "function" then
        return
    end
    local installed = false
    local function onButtonPressed(...)
        local arguments = {}
        for index = 1, select("#", ...) do
            local value = unwrap(select(index, ...))
            table.insert(arguments, valid(value) and objectPath(value) or tostring(value))
        end
        log("info", "Results vote button hook invoked args=" .. table.concat(arguments, " | "))
        local direction = voteDirectionForClickedButton(...)
        if direction ~= nil then
            log("info", "Results vote button pressed direction=" .. direction)
            submit(direction)
        end
    end
    for _, handlerPath in pairs(BUTTON_HANDLER_PATHS) do
        local ok, hookError
        if handlerPath == BUTTON_HANDLER_PATHS.native then
            ok, hookError = pcall(RegisterHook, handlerPath, nil, onButtonPressed)
        else
            ok, hookError = pcall(RegisterHook, handlerPath, onButtonPressed)
        end
        log("info", "Results button hook registration path=" .. handlerPath
            .. " ok=" .. tostring(ok)
            .. (hookError ~= nil and " error=" .. tostring(hookError) or ""))
        if ok then
            installed = true
        end
    end
    state.buttonHooksInstalled = installed
    if installed then
        log("info", "installed exact-instance Results vote button hooks")
    else
        log("error", "could not install Results vote button hooks")
    end
end

local function createVrWidgets(panelPath)
    local source, context, targetCanvas = findVrScoreboardSurface()
    if not valid(source) or not valid(context) or not valid(targetCanvas) then
        log("error", "rendered ScoreboardWidget UMG root unavailable for VR vote buttons")
        return false
    end
    local buttons = createVoteButtons(targetCanvas, context, "vr", {
        { direction = "up", label = "▲ 0", geometry = { x = 1195, y = 453, width = 300, height = 78, z = 9000 } },
        { direction = "down", label = "▼ 0", geometry = { x = 1195, y = 542, width = 300, height = 78, z = 9001 } },
    })
    if buttons == nil then
        log("error", "failed to attach VR vote buttons to ScoreboardWidget")
        return false
    end
    state.widgets = { container = nil, status = nil, up = buttons.up, down = buttons.down }
    state.panelPath = panelPath
    state.mode = "vr"
    state.phase = "hidden"
    state.currentVote = nil
    state.upvotes = 0
    state.downvotes = 0
    log("info", "created VR Results vote buttons on ScoreboardWidget root surface")
    installButtonHooks()
    state.loadedSongId = state.songId
    loadVote()
    return true
end

local function createFlatWidgets(panel, panelPath)
    local canvas = findFlatInfoCanvas(panelPath)
    if not valid(canvas) then
        if not state.diagnostics.canvasMissing then
            state.diagnostics.canvasMissing = true
            log("error", "Results panel found but no compatible CanvasPanel was found")
        end
        return false
    end
    local buttonWidth, buttonHeight = 96, 42
    local voteHeight = 112
    local geometry = {
        x = 530,
        y = 17,
        width = 108,
        height = voteHeight,
        anchorRight = true,
    }
    -- Use the UserWidget as the UObject outer; constructing a CanvasPanel with
    -- the live VR CanvasPanel outer can stall UE4SS on this build.
    local widgetOuter = panel
    local container = construct("/Script/UMG.CanvasPanel", widgetOuter)
    log("info", "vote panel construct container begin")
    local containerAttached = valid(container) and addToCanvas(canvas, container, geometry) or false
    if not containerAttached then
        if not state.diagnostics.containerFailed then
            state.diagnostics.containerFailed = true
            log("error", "failed to construct or attach standalone Results vote panel")
        end
        return false
    end
    log("info", "vote panel construct container done")
    log("info", "vote panel construct up begin")
    local buttonContext = panel
    local buttons = createVoteButtons(container, buttonContext, "flat", {
        { direction = "up", label = "▲ 0", geometry = { x = 6, y = 7, width = buttonWidth, height = buttonHeight, z = 2 } },
        { direction = "down", label = "▼ 0", geometry = { x = 6, y = 63, width = buttonWidth, height = buttonHeight, z = 2 } },
    })
    log("info", "vote panel construct up done")
    log("info", "vote panel construct down done")
    if buttons == nil then
        if not state.diagnostics.buttonsFailed then
            state.diagnostics.buttonsFailed = true
            log("error", "failed to construct or attach Results vote buttons")
        end
        safeCall(function() if valid(container) then container:RemoveFromParent() end end, nil)
        return false
    end
    safeCall(function()
        up.button:SetIsEnabled(false)
        down.button:SetIsEnabled(false)
    end, nil)
    state.widgets = {
        container = container,
        status = nil,
        up = buttons.up,
        down = buttons.down,
    }
    state.panelPath = panelPath
    state.mode = "flat"
    state.phase = "hidden"
    state.currentVote = nil
    state.upvotes = 0
    state.downvotes = 0
    log("info", "created standalone flat Results vote panel")
    installButtonHooks()
    state.loadedSongId = state.songId
    loadVote()
    return true
end

local function createWidgets(panel, panelPath, mode)
    if mode == "vr" then
        return createVrWidgets(panelPath)
    end
    if valid(findVrStatsComponent()) then
        return createVrWidgets(panelPath)
    end
    return createFlatWidgets(panel, panelPath)
end

local function extractHash(...)
    for index = 1, select("#", ...) do
        local source = select(index, ...)
        local unwrapped = unwrap(source)
        local direct = safeCall(function()
            return source:get()
        end, nil)
        local values = {
            unwrapped,
            direct,
            safeCall(function()
                return unwrapped:ToString()
            end, nil),
            safeCall(function()
                return direct:ToString()
            end, nil),
            safeCall(function()
                return source:ToString()
            end, nil),
        }
        for valueIndex = 1, 5 do
            local value = values[valueIndex]
            local text = tostring(value or "")
            local decimal = text:match("^(-?%d+)$")
            if decimal ~= nil then
                local numeric = tonumber(decimal)
                if numeric ~= nil and numeric >= -2147483648 and numeric < 0 then
                    numeric = numeric + 4294967296
                end
                if numeric ~= nil and numeric >= 0 and numeric <= 4294967295 and numeric % 1 == 0 then
                    return string.format("%.0f", numeric)
                end
            end
            local hash = text:match("^([0-9a-fA-F][0-9a-fA-F]+)$")
            if hash ~= nil and #hash >= 16 and #hash <= 64 then
                return string.lower(hash)
            end
        end
    end
    return nil
end

local extractBoolean

local function findPlayedSongManager()
    if type(FindFirstOf) ~= "function" then
        return nil
    end
    for _, className in ipairs({ "FlatBeatManager_C", "BeatManager_C", "BeatManager" }) do
        local managers = safeCall(function()
            if type(FindAllOf) == "function" then return FindAllOf(className) end
            return { FindFirstOf(className) }
        end, {})
        for _, manager in ipairs(managers or {}) do
            local managerName = fullName(manager)
            if valid(manager)
                and managerName:find("/Engine/Transient.", 1, true) ~= nil
                and managerName:find("Default__", 1, true) == nil
                and managerName:find("Latency", 1, true) == nil then
                return manager, managerName
            end
        end
    end
    return nil
end

local function extractSongId(value)
    value = unwrap(value)
    if value == nil then return nil end
    local numeric = tonumber(value)
    if numeric ~= nil and numeric > 0 then
        return math.floor(numeric)
    end
    local text = tostring(value):gsub("\\", "/")
    local id = text:match("ragnac://install/(%d+)")
        or text:match("/songs/[^/]+/(%d+)")
        or text:match("/song/(%d+)")
        or text:match("/CustomSongs/(%d+)")
        or text:match("/(%d+)/?$")
        or text:match("[%W_]id[%W_]*(%d+)")
    return id and tonumber(id) or nil
end

local function textValue(value)
    if value == nil then return nil end
    if type(value) == "string" then return value:gsub("^%s+", ""):gsub("%s+$", "") end
    if type(value) == "number" or type(value) == "boolean" then return tostring(value) end
    local valueType = tostring(safeCall(function() return value:type() end, ""))
    if valueType == "RemoteUnrealParam" or valueType == "LocalUnrealParam" then
        local inner = safeCall(function() return value:get() end, nil)
        if inner ~= nil and inner ~= value then return textValue(inner) end
    elseif valueType == "FString" or valueType == "FText" then
        return safeCall(function() return value:ToString() end, nil)
    end
    return nil
end

local function invokeMember(object, name)
    if object == nil or type(object.CallFunction) ~= "function" then return nil end
    local member = safeCall(function() return object[name] end, nil)
    if member == nil and type(StaticFindObject) == "function" then
        local class = safeCall(function() return object:GetClass() end, nil)
        local className = tostring(fullName(class or "")):gsub("^Class ", "")
        if className ~= "" then
            member = safeCall(function()
                return StaticFindObject("Function " .. className .. ":" .. name)
            end, nil)
        end
    end
    if member == nil then return nil end
    local direct = safeCall(function() return member(object) end, nil)
    if direct ~= nil then return direct end
    return safeCall(function() return object:CallFunction(member) end, nil)
end

local function objectValue(object, names)
    if object == nil then return nil end
    for _, name in ipairs(names or {}) do
        local value = safeCall(function()
            if name:sub(1, 1) == "@" then
                return object:GetPropertyValue(name:sub(2))
            end
            local member = object[name]
            if type(member) == "function" then return member(object) end
            if member ~= nil and tostring(fullName(member)):match("^Function ") then
                return invokeMember(object, name)
            end
            return member
        end, nil)
        value = unwrap(value)
        if value ~= nil and type(value) ~= "string" and type(value) ~= "number"
            and type(value) ~= "boolean" and type(value) ~= "function" and valid(value) then
            local name = fullName(value)
            if not name:match("^Function ") then return value end
        end
    end
    return nil
end

local function relatedSong(object)
    local direct = invokeMember(object, "GetSong")
    if direct ~= nil and type(direct) ~= "function" and valid(direct) then
        return direct
    end
    return objectValue(object, {
        "GetSong", "Song", "m_song", "SongData", "m_songData", "GetSongData",
        "GetSongInfo", "SongInfo", "m_songInfo", "@Song", "@SongData",
    })
end

local function property(object, names)
    if object == nil then return nil end
    for _, name in ipairs(names or {}) do
        local value = safeCall(function()
            if name:sub(1, 1) == "@" then
                return object:GetPropertyValue(name:sub(2))
            end
            local member = object[name]
            if type(member) == "function" then return member(object) end
            if member ~= nil and tostring(fullName(member)):match("^Function ") then
                return invokeMember(object, name)
            end
            return member
        end, nil)
        local text = textValue(value)
        if text ~= nil and text ~= "" and text ~= "None" then return text end
    end
    return nil
end

local function loadedSongFolder(object)
    local candidates = {
        state.liveSongPath,
    }
    if object ~= nil and not state.diagnostics.pathFunctionProbe then
        state.diagnostics.pathFunctionProbe = true
        local getterNames = { "GetPath" }
        for _, getterName in ipairs(getterNames) do
            local raw = safeCall(function() return invokeMember(object, getterName) end, nil)
            local candidate = textValue(raw)
            if candidate ~= nil and candidate ~= "" then
                table.insert(candidates, candidate)
                log("info", "live song path getter=" .. getterName .. " value=" .. candidate)
            end
        end
    end
    for candidateIndex, candidate in ipairs(candidates) do
        local path = type(candidate) == "string" and candidate:gsub("\\", "/"):gsub("/+", "/") or nil
        if (state.diagnostics.pathProbeCount or 0) < 16 then
            state.diagnostics.pathProbeCount = (state.diagnostics.pathProbeCount or 0) + 1
            log("info", "live song path candidate=" .. tostring(candidateIndex) .. "=" .. tostring(path))
        end
        local lower = path and string.lower(path) or ""
        local marker = lower:find("/customsongs/", 1, true) or lower:find("customsongs/", 1, true)
        if marker ~= nil then
            local markerText = lower:sub(marker, marker + #"customsongs/" - 1):find("customsongs/", 1, true) == 1 and "customsongs/" or "/customsongs/"
            local rest = path:sub(marker + #markerText)
            local slash = rest:find("/", 1, true)
            path = slash and path:sub(1, marker + #markerText + slash - 1) or path
            if path:sub(-1) == "/" then path = path:sub(1, -2) end
            if path:lower():match("%.dat$") or path:lower():match("%.json$") then
                path = path:match("^(.+)/[^/]+$")
            end
            if path ~= nil and path ~= "" then return path end
        end
    end
    state.diagnostics.pathProbe = true
    local nested = relatedSong(object)
    if nested ~= nil and nested ~= object then
        return loadedSongFolder(nested)
    end
    return nil
end

local function listProperty(object, names)
    local value = nil
    for _, name in ipairs(names or {}) do
        value = safeCall(function()
            if name:sub(1, 1) == "@" then return object:GetPropertyValue(name:sub(2)) end
            local member = object[name]
            if member ~= nil and tostring(fullName(member)):match("^Function ") then
                return invokeMember(object, name)
            end
            return member
        end, nil)
        if value ~= nil then break end
    end
    local result = {}
    if value ~= nil and type(value) == "table" then
        for _, entry in ipairs(value) do table.insert(result, entry) end
    else
        local forEach = value ~= nil and safeCall(function() return value.ForEach end, nil) or nil
        if type(forEach) ~= "function" then return result end
        safeCall(function() value:ForEach(function(entry) table.insert(result, entry) end) end, nil)
    end
    return result
end

local function songMetadata(song, beatMap)
    if false then
        state.diagnostics.getterProbe = true
        for _, name in ipairs({ "GetPath", "GetName", "GetBand", "GetLevelAuthor", "GetBeatMapsLevels" }) do
            local raw = invokeMember(song, name)
            log("info", "live getter probe name=" .. name .. " raw=" .. tostring(raw)
                .. " type=" .. type(raw) .. " valueType=" .. tostring(safeCall(function() return raw:type() end, nil))
                .. " tostring=" .. tostring(safeCall(function() return raw:ToString() end, nil))
                .. " get=" .. tostring(safeCall(function() return raw:get() end, nil))
                .. " text=" .. tostring(textValue(raw)))
            if type(raw) == "table" then
                for index, entry in ipairs(raw) do
                    if index <= 16 then
                        log("info", "live getter table name=" .. name .. " index=" .. tostring(index)
                            .. " entry=" .. tostring(entry) .. " entryType=" .. type(entry)
                            .. " valueType=" .. tostring(safeCall(function() return entry:type() end, nil))
                            .. " get=" .. tostring(safeCall(function() return entry:get() end, nil))
                            .. " Get=" .. tostring(safeCall(function() return entry:Get() end, nil))
                            .. " text=" .. tostring(textValue(entry)))
                    end
                end
            end
        end
    end
    local metadata = {
        title = property(song, { "GetName", "Title", "@Title", "@Name" })
            or property(beatMap, { "Title", "@Title", "@Name" }),
        artist = property(song, { "GetBand", "Artist", "AuthorName", "@Artist", "@ArtistName", "@AuthorName" })
            or property(beatMap, { "Artist", "AuthorName", "@Artist", "@ArtistName", "@AuthorName" }),
        mapper = property(song, { "GetLevelAuthor", "LevelAuthorName", "Mapper", "@LevelAuthorName", "@Mapper" })
            or property(beatMap, { "LevelAuthorName", "Mapper", "@LevelAuthorName", "@Mapper" }),
        difficulties = listProperty(song, { "GetBeatMapsLevels", "@BeatMaps", "@Levels", "@Difficulties" }),
    }
    local values = listProperty(song, { "GetBeatMapsLevels", "@BeatMaps", "@Levels", "@Difficulties" })
    metadata.difficulties = {}
    for _, map in ipairs(values) do
        local rankObject = objectValue(map, {
            "GetDifficultyRank", "DifficultyRank", "m_difficultyRank", "@DifficultyRank", "@m_difficultyRank",
        })
        local level = property(rankObject, { "GetLevel", "m_level", "Level", "@Level" })
            or property(map, { "GetDifficultyRankLevel", "DifficultyRankLevel", "@DifficultyRankLevel" })
            or property(map, { "GetLevel", "m_level", "Level", "@Level" })
            or safeCall(function() return map:get() end, nil)
            or textValue(map)
        if level ~= nil then table.insert(metadata.difficulties, level) end
    end
    if #metadata.difficulties == 0 and beatMap ~= nil then
        local rankObject = objectValue(beatMap, {
            "GetDifficultyRank", "DifficultyRank", "m_difficultyRank", "@DifficultyRank", "@m_difficultyRank",
        })
        local level = property(rankObject, { "GetLevel", "m_level", "Level", "@Level" })
            or property(beatMap, { "GetDifficultyRankLevel", "DifficultyRankLevel", "@DifficultyRankLevel" })
            or property(beatMap, { "GetLevel", "m_level", "Level", "@Level" })
        if level ~= nil then table.insert(metadata.difficulties, level) end
    end
    return metadata
end

local function probeLiveProperties(object, label, names)
    if object == nil then return end
    for _, name in ipairs(names or {}) do
        local value = safeCall(function() return object:GetPropertyValue(name) end, nil)
        local direct = safeCall(function() return object[name] end, nil)
        if value ~= nil then
            local text = textValue(value)
            log("info", "live property probe object=" .. label .. " name=" .. name
                .. " raw=" .. tostring(value) .. " type=" .. type(value)
                .. " direct=" .. tostring(direct) .. " directType=" .. type(direct)
                .. " text=" .. tostring(text))
        end
    end
    local class = safeCall(function() return object:GetClass() end, nil)
    log("info", "live reflected class object=" .. label .. " class=" .. tostring(class) .. " className=" .. tostring(fullName(class)))
    if class ~= nil then
        local count = 0
        local visited = 0
        while valid(class) and visited < 12 and count < 160 do
            visited = visited + 1
            safeCall(function()
                class:ForEachProperty(function(prop)
                    count = count + 1
                    if count <= 160 then
                        local propName = safeCall(function() return prop:GetFullName() end, nil)
                            or safeCall(function() return prop:GetName() end, nil)
                        local shortName = tostring(propName or ""):match("([^%.:]+)$") or tostring(propName or "")
                        local raw = safeCall(function() return object:GetPropertyValue(shortName) end, nil)
                        local directValue = safeCall(function() return object[shortName] end, nil)
                        log("info", "live reflected property object=" .. label
                            .. " name=" .. tostring(shortName)
                            .. " raw=" .. tostring(raw) .. " rawType=" .. type(raw)
                            .. " direct=" .. tostring(directValue) .. " directType=" .. type(directValue)
                            .. " text=" .. tostring(textValue(raw) or textValue(directValue)))
                    end
                    return false
                end)
            end, nil)
            class = safeCall(function() return class:GetSuperStruct() end, nil)
        end
        log("info", "live reflected property count object=" .. label .. " count=" .. tostring(count))
        local functionCount = 0
        class = safeCall(function() return object:GetClass() end, nil)
        visited = 0
        while valid(class) and visited < 12 and functionCount < 240 do
            visited = visited + 1
            safeCall(function()
                class:ForEachFunction(function(fn)
                    functionCount = functionCount + 1
                    if functionCount <= 240 then
                        log("info", "live reflected function object=" .. label
                            .. " name=" .. tostring(safeCall(function() return fn:GetFullName() end, nil)
                                or safeCall(function() return fn:GetName() end, nil)))
                    end
                end)
            end, nil)
            class = safeCall(function() return class:GetSuperStruct() end, nil)
        end
        log("info", "live reflected function count object=" .. label .. " count=" .. tostring(functionCount))
    end
end

local function resolveCatalogId(folder, metadata, generation)
    if folder == nil or metadata == nil or state.resolutionPending then return end
    state.resolutionPending = true
    local function finish(id, message)
        if generation ~= state.resolutionGeneration then return end
        state.resolutionPending = false
        if id ~= nil then
            state.songId = tonumber(id)
            log("info", message .. " id=" .. tostring(state.songId))
        end
    end
    local cached = type(Api.readInstalledSongId) == "function" and safeCall(function() return Api.readInstalledSongId(folder) end, nil) or nil
    local function discovered(id, err, result)
        if err ~= nil then
            finish(nil, "catalog discovery failed: " .. tostring(err.message or err))
            return
        end
        local status = result and result.status or "resolved"
        local messages = {
            validated = "validated loaded song .id against metadata search",
            replaced = "replaced invalid loaded song .id from metadata search",
            resolved = "resolved loaded song by metadata search and cached",
        }
        finish(id, messages[status] or messages.resolved)
    end
    if type(Api.discoverInstalledSongId) ~= "function" then
        finish(nil, "RagnaCustomsApi does not provide discoverInstalledSongId")
        return
    end
    Api.discoverInstalledSongId(folder, metadata, {
        existingId = cached,
        callback = discovered,
    })
end

local function resolvePlayedSongState(manager)
    if not valid(manager) and not valid(state.liveBeatMap) then
        return false
    end
    local song = valid(manager) and safeCall(function()
        return manager:GetSong()
    end, safeCall(function()
        return manager.m_song
    end, nil)) or state.liveSong or relatedSong(state.liveBeatMap)
    local beatMap = valid(manager) and safeCall(function()
        return manager:GetBeatMap()
    end, safeCall(function()
        return manager.m_beatMap
    end, nil)) or state.liveBeatMap
    log("info", "live song objects manager=" .. tostring(valid(manager) and fullName(manager) or "nil")
        .. " song=" .. tostring(song ~= nil and fullName(song) or "nil")
        .. " beatMap=" .. tostring(beatMap ~= nil and fullName(beatMap) or "nil"))
    -- Capture the live hash before consulting the installed catalog. On the
    -- first Results poll state.beatmap is usually still empty; resolving the
    -- catalog before filling it leaves the one-shot capture marked complete
    -- and prevents the fixture's .id marker from ever being used.
    if beatMap ~= nil and state.beatmap == nil then
        local beatMapHash = safeCall(function() return beatMap:GetHash() end, nil)
        state.beatmap = extractHash(beatMapHash)
    end
    log("info", "song resolution probe beatmap=" .. tostring(state.beatmap)
        .. " beatMap=" .. tostring(beatMap))
    local rawCustom = song and safeCall(function()
        return song:IsCustom()
    end, nil) or nil
    local folderOk, folder = pcall(function()
        return loadedSongFolder(song) or loadedSongFolder(beatMap) or loadedSongFolder(manager)
    end)
    if not folderOk then
        log("warn", "live song folder resolver error=" .. tostring(folder))
        folder = nil
    end
    local metadata = safeCall(function() return songMetadata(song, beatMap) end, {
        title = nil,
        artist = nil,
        mapper = nil,
        difficulties = {},
    })
    if false then
        state.diagnostics.livePropertiesProbed = true
        probeLiveProperties(song, "Song", {
            "Title", "SongTitle", "SongName", "Name", "Artist", "ArtistName", "AuthorName",
            "Mapper", "LevelAuthorName", "SongPath", "FolderPath", "CustomSongPath", "FilePath",
            "m_title", "m_songName", "m_name", "m_artist", "m_authorName", "m_mapper", "m_songPath", "m_folderPath",
        })
        probeLiveProperties(beatMap, "BeatMap", {
            "Title", "SongTitle", "SongName", "Name", "Artist", "ArtistName", "AuthorName",
            "Mapper", "LevelAuthorName", "SongPath", "FolderPath", "CustomSongPath", "FilePath",
            "m_title", "m_songName", "m_name", "m_artist", "m_authorName", "m_mapper", "m_songPath", "m_folderPath",
            "GetLevel", "Difficulty", "DifficultyRank", "GetDifficultyRank", "m_difficultyRank",
        })
    end
    local difficultyText = {}
    for _, difficulty in ipairs(metadata.difficulties or {}) do table.insert(difficultyText, tostring(difficulty)) end
    log("info", "live song metadata folder=" .. tostring(folder)
        .. " title=" .. tostring(metadata.title)
        .. " artist=" .. tostring(metadata.artist)
        .. " mapper=" .. tostring(metadata.mapper)
        .. " difficulties=" .. table.concat(difficultyText, ","))
    local key = tostring(folder or "") .. "|" .. tostring(state.beatmap or "")
    if key ~= state.resolutionKey then
        state.resolutionKey = key
        state.resolutionGeneration = (state.resolutionGeneration or 0) + 1
        state.resolutionPending = false
        state.songId = nil
        state.songFolder = folder
        state.songMetadata = metadata
        resolveCatalogId(folder, metadata, state.resolutionGeneration)
    end
    local custom = extractBoolean(rawCustom)
    if custom ~= nil then
        state.custom = custom
    end
    if state.custom ~= nil and state.beatmap ~= nil and state.songId ~= nil then
        if not state.diagnostics.playedSongResolved then
            state.diagnostics.playedSongResolved = true
            log("info", "resolved played song from BeatManager custom=" .. tostring(state.custom)
                .. " beatmap=" .. state.beatmap .. " songId=" .. tostring(state.songId))
        end
        return true
    end
    -- Resolution continues through the API callbacks. Once the live object has
    -- yielded its folder, do not re-run reflection on every results poll.
    return state.songFolder ~= nil
end

extractBoolean = function(...)
    for index = select("#", ...), 1, -1 do
        local value = unwrap(select(index, ...))
        if type(value) == "boolean" then
            return value
        end
        if type(value) == "number" and (value == 0 or value == 1) then
            return value == 1
        end
    end
    return nil
end

local function installHook(name, pre, post)
    if type(RegisterHook) ~= "function" then
        return false
    end
    local ok
    if post ~= nil then
        ok = pcall(RegisterHook, name, pre, post)
    else
        ok = pcall(RegisterHook, name, pre)
    end
    return ok
end

local function installHooks()
    if state.hooksInstalled then
        return
    end
    state.hooksInstalled = true
    local hashPost = function(...)
        local hash = extractHash(...)
        for index = 1, select("#", ...) do
            local candidate = unwrap(select(index, ...))
            if valid(candidate) and type(candidate) ~= "function" then
                local name = fullName(candidate)
                if name:find("BeatMap", 1, true) ~= nil then
                    state.liveBeatMap = candidate
                elseif name:find("Song", 1, true) ~= nil then
                    state.liveSong = candidate
                end
            end
        end
        if hash ~= nil then
            state.beatmap = hash
        end
    end
    local customPost = function(...)
        local custom = extractBoolean(...)
        if custom ~= nil then
            state.custom = custom
        end
    end
    local owners = { "SongsManager" }
    for _, owner in ipairs(owners) do
        installHook("/Script/Ragnarock." .. owner .. ":GetBeatMapHashFromCompositeId", function() end, hashPost)
        installHook("/Script/Ragnarock." .. owner .. ":IsCustomSong", function() end, customPost)
    end
    installHook("/Script/Ragnarock.BeatMap:GetHash", function() end, hashPost)
    local function captureSongStringHook(label)
        return function(self, ...)
            for index = 1, select("#", ...) do
                local value = select(index, ...)
                local valueType = tostring(safeCall(function() return value:type() end, ""))
                local text = safeCall(function()
                    if valueType == "RemoteUnrealParam" then value = value:get() end
                    if value ~= nil and tostring(safeCall(function() return value:type() end, "")) == "FString" then
                        return value:ToString()
                    end
                    return type(value) == "string" and value or nil
                end, nil)
                if text ~= nil and text ~= "" then
                    local normalizedText = text:gsub("\\", "/")
                    if normalizedText:lower():find("customsongs/", 1, true) then
                        state.liveSongPath = normalizedText
                        log("info", "captured live Song." .. label .. " path=" .. normalizedText)
                    end
                end
            end
        end
    end
    installHook("/Script/Ragnarock.Song:SetPath", function() end, captureSongStringHook("SetPath"))
    installHook("/Script/Ragnarock.Song:Setup", function() end, captureSongStringHook("Setup"))
end

_G.RagnaCustomsVoteSetBeatmapHash = function(hash, isCustom, songId)
    state.beatmap = hash and extractHash(hash) or nil
    state.custom = isCustom == true
end

local function poll()
    if not state.diagnostics.pollStarted then
        state.diagnostics.pollStarted = true
        log("info", "Results UI polling started")
    end
    local panel, panelName, mode = findActiveResultsPanel()
    local manager, managerName = nil, nil
    if panel ~= nil then
        manager, managerName = findPlayedSongManager()
    end
    local liveObjectPath = managerName or (valid(state.liveBeatMap) and fullName(state.liveBeatMap) or nil)
    if panel ~= nil and (manager ~= nil or valid(state.liveBeatMap)) and not state.captureQueued
        and (state.captureManagerPath ~= liveObjectPath or state.captureResolved ~= true) then
        state.captureQueued = true
        local function captureOnGameThread()
            state.captureManagerPath = liveObjectPath
            state.captureResolved = resolvePlayedSongState(manager)
            state.captureQueued = false
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(captureOnGameThread)
        else
            captureOnGameThread()
        end
        return
    end
    -- Reflected GameInstance getters are game-thread calls. Probe the single
    -- stable setting once rather than invoking reflection on every poll.
    if state.customScoresAllowed == nil then
        -- Reflection against GameInstance/SaveGame is a game-thread operation.
        -- Never perform it directly from LoopAsync's worker callback: doing so
        -- can stall the menu while the song selector is constructing its list.
        if not state.settingProbeQueued then
            state.settingProbeQueued = true
            local function probeOnGameThread()
                state.customScoresAllowed = customScoreSendingAllowed()
                state.settingProbeQueued = false
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(probeOnGameThread)
            else
                probeOnGameThread()
            end
        end
        return
    end
    if state.customScoresAllowed ~= state.lastLoggedCustomScoresAllowed then
        state.lastLoggedCustomScoresAllowed = state.customScoresAllowed
        log("info", "custom score sending allowed=" .. tostring(state.customScoresAllowed))
    end
    if panel == nil or state.custom ~= true or state.beatmap == nil
        or state.songId == nil or state.customScoresAllowed ~= true then
        local reason = panel == nil and "no_results_panel"
            or state.custom ~= true and "song_not_custom"
            or state.beatmap == nil and "beatmap_unresolved"
            or state.songId == nil and "song_id_unresolved"
            or "custom_score_sending_disabled"
        if reason ~= state.lastSuppressionReason then
            state.lastSuppressionReason = reason
            log("info", "vote panel suppressed reason=" .. reason)
        end
        if state.widgets ~= nil and panel == nil then
            removeWidgets()
        end
        return
    end
    state.lastSuppressionReason = nil
    if not state.diagnostics.panelFound then
        state.diagnostics.panelFound = true
        log("info", "found active " .. tostring(mode) .. " Results panel")
    end
    local path = rootPath(panelName)
    -- Do not repeatedly allocate/remove widgets after a construction failure:
    -- the Results screen polls every second and that loop can crash the game.
    if state.createFailedPath == path then
        return
    end
    if state.widgets == nil or state.panelPath ~= path or state.loadedSongId ~= state.songId then
        if state.createQueued then
            return
        end
        state.createQueued = true
        local function createOnGameThread()
            if valid(panel) then
                removeWidgets()
                local created = createWidgets(panel, path, mode)
                if not created then
                    state.createFailedPath = path
                else
                    state.createFailedPath = nil
                end
            end
            state.createQueued = false
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(createOnGameThread)
        else
            createOnGameThread()
        end
        return
    end
end

installHooks()
local function protectedPoll()
    local ok, err = pcall(poll)
    if not ok and not state.diagnostics.pollError then
        state.diagnostics.pollError = true
        log("error", "Results UI poll failed: " .. tostring(err))
    end
end
if type(LoopAsync) == "function" then
    LoopAsync(500, protectedPoll)
elseif type(ExecuteWithDelay) == "function" then
    local function delayedPoll()
        protectedPoll()
        ExecuteWithDelay(100, delayedPoll)
    end
    ExecuteWithDelay(100, delayedPoll)
else
    log("error", "UE4SS scheduler unavailable")
end

log("info", "loaded; waiting for a custom-song Results screen")
