---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- lua/tac/timers.lua — MoriAC Timed Commands Plugin
-- ============================================================================
-- Runs a command every N minutes. Ships with Project Morituri's
-- "/say kratos" (the server's buff) every 10 minutes; add your own lines
-- (any slash command; text without a leading / is said with /say).
--
-- Each entry has a "When": always (MoriAC paused too), only while MoriAC is
-- running, or only out of combat. A due entry that is held back (When,
-- casting, dead, zoning) fires as soon as it is allowed instead of waiting a
-- whole interval. "Fire on load" runs it a few seconds after MoriAC starts.
--
-- Entries are saved per character through onSaveSettings.
-- ============================================================================

local plugin = {
    id                 = 'timers',
    name               = 'Timed Commands',
    version            = '1.0.0',
    author             = 'MoriAC',
    description        = 'Runs commands on a timer, e.g. /say kratos every 10 minutes for the Morituri buff.',
    defaultEnabled     = true,
    tickInterval       = 1.0,
    runOutOfCombatOnly = false,
    hasThread          = false,
}

local WHENS       = { 'always', 'running', 'idle' }
local WHEN_LABEL  = { always = 'Always', running = 'Only while MoriAC is running', idle = 'Only out of combat' }
local MAX_ENTRIES = 20
local LOAD_DELAY  = 5      -- seconds after load before a "fire on load" entry runs

local core  = nil
local mq    = nil
local ImGui = nil

local function defaultEntries()
    return {
        { name = 'Kratos buff', command = '/say kratos', minutes = 10, enabled = true, when = 'always', onLoad = true },
    }
end

-- Persisted through onSaveSettings / onLoadSettings (per character loadout).
local cfg = {
    entries = defaultEntries(),
    echo    = true,        -- a chat line each time one runs
}

-- Session state (never persisted)
local st = {
    nextAt   = {},         -- entry table -> os.time() it is next due
    selected = 1,
}

local function saveSettings()
    if core and core.saveLoadout then core.saveLoadout(true) end
end

local function chat(fmt, ...)
    print(string.format('\ay[MoriAC Timers]\ax ' .. fmt, ...))
end

-- ----------------------------------------------------------------------------
-- Pure helpers (exposed for tests)
-- ----------------------------------------------------------------------------
local function sanitizeEntry(e)
    if type(e) ~= 'table' then return nil end
    local function str(v) return type(v) == 'string' and v or '' end
    local when = str(e.when)
    if not WHEN_LABEL[when] then when = 'always' end
    local name = str(e.name)
    if name == '' then name = 'Timer' end
    return {
        name    = name,
        command = str(e.command),
        minutes = math.max(1, math.min(240, math.floor(tonumber(e.minutes) or 10))),
        enabled = e.enabled ~= false,
        when    = when,
        onLoad  = e.onLoad == true,
    }
end

-- "kratos" -> "/say kratos"; "/g hi" stays; blank -> nil.
local function commandLine(text)
    local s = tostring(text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    if s:sub(1, 1) ~= '/' then s = '/say ' .. s end
    return s
end

local function whenAllows(when, inCombat, running)
    if when == 'running' then return running == true end
    if when == 'idle' then return not inCombat end
    return true
end

-- First due time for an entry seen at `now`.
local function firstDue(e, now)
    if e.onLoad then return now + LOAD_DELAY end
    return now + e.minutes * 60
end

local function fmtLeft(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec >= 60 then return string.format('%dm %02ds', math.floor(sec / 60), sec % 60) end
    return string.format('%ds', sec)
end

-- ----------------------------------------------------------------------------
-- Running
-- ----------------------------------------------------------------------------
local function inCombatNow()
    local rt = core and core.runtime
    if rt and rt.isCombat then
        local ok, v = pcall(rt.isCombat)
        return ok and v == true
    end
    return false
end

local function runningNow()
    local c = core and core.ctrl
    return c ~= nil and c.running == true
end

-- Dead, zoning or mid-cast: a command now would be lost or interrupt the cast.
local function blockedNow()
    local blocked = true
    pcall(function()
        local me = mq.TLO.Me
        if not me() or me.Dead() then return end
        if mq.TLO.Zone.ID() == nil then return end
        local casting = me.Casting.ID and me.Casting.ID() or nil
        if casting and casting > 0 then return end
        blocked = false
    end)
    return blocked
end

-- force: the Run Now button / command (skips When, still skips dead / casting)
local function run(e, force)
    local line = commandLine(e.command)
    if not line then return false end
    if not force and not whenAllows(e.when, inCombatNow(), runningNow()) then return false end
    if blockedNow() then return false end
    local ok = pcall(mq.cmd, line)
    if not ok then return false end
    st.nextAt[e] = os.time() + e.minutes * 60
    if cfg.echo then chat('%s: %s (next in %d min)', e.name, line, e.minutes) end
    if core and core.log then pcall(core.log.info, 'timers', 'ran %s', line) end
    return true
end

-- ----------------------------------------------------------------------------
-- Plugin lifecycle
-- ----------------------------------------------------------------------------
function plugin.onInit(coreApi)
    core = coreApi
    mq = core.mq
    ImGui = core.ImGui
    st.nextAt = {}
end

function plugin.onDestroy()
    core = nil
    mq = nil
    ImGui = nil
end

function plugin.onTick()
    if not core then return end
    local now = os.time()
    for _, e in ipairs(cfg.entries) do
        if e.enabled then
            if not st.nextAt[e] then st.nextAt[e] = firstDue(e, now) end
            -- Not run (held back): try again next tick rather than a whole interval later.
            if now >= st.nextAt[e] then run(e, false) end
        end
    end
end

function plugin.onSaveSettings()
    local list = {}
    for i, e in ipairs(cfg.entries) do list[i] = sanitizeEntry(e) end
    return { entries = list, echo = cfg.echo == true }
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if type(s.entries) == 'table' then
        local list = {}
        for _, e in ipairs(s.entries) do
            local clean = sanitizeEntry(e)
            if clean and #list < MAX_ENTRIES then list[#list + 1] = clean end
        end
        cfg.entries = list
    end
    if s.echo ~= nil then cfg.echo = (s.echo == true) end
    st.nextAt = {}
    st.selected = 1
end

-- ----------------------------------------------------------------------------
-- Settings page
-- ----------------------------------------------------------------------------
local function idxOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return 1
end

local function drawEditor(e, i)
    local w = core.px(260)
    core.formLabel('Name')
    ImGui.SetNextItemWidth(w)
    local name = ImGui.InputText('##tmrName', e.name)
    if type(name) == 'string' and name ~= e.name then e.name = name; saveSettings() end

    core.formLabel('Command')
    ImGui.SetNextItemWidth(core.px(340))
    local cmd = ImGui.InputTextWithHint('##tmrCommand', '/say kratos', e.command)
    if type(cmd) == 'string' and cmd ~= e.command then e.command = cmd; saveSettings() end
    if ImGui.IsItemHovered() then
        core.setTooltip('Any slash command. Text without a leading / is said with /say.')
    end

    core.formLabel('Every (minutes)')
    ImGui.SetNextItemWidth(w)
    local m = ImGui.SliderInt('##tmrMinutes', e.minutes or 10, 1, 120)
    if type(m) == 'number' and m ~= e.minutes then
        e.minutes = m
        st.nextAt[e] = nil
        saveSettings()
    end

    core.formLabel('When')
    ImGui.SetNextItemWidth(w)
    local wl = {}
    for k, wh in ipairs(WHENS) do wl[k] = WHEN_LABEL[wh] end
    local wi = ImGui.Combo('##tmrWhen', idxOf(WHENS, e.when), wl)
    if WHENS[wi] and WHENS[wi] ~= e.when then e.when = WHENS[wi]; saveSettings() end
    if ImGui.IsItemHovered() then
        core.setTooltip('A due command that is held back runs as soon as it is allowed.\nIt never runs while you are dead, zoning or casting.')
    end

    local ol = ImGui.Checkbox('Run it when MoriAC loads##tmrOnLoad', e.onLoad)
    if ol ~= e.onLoad then e.onLoad = ol; saveSettings() end
    if ImGui.IsItemHovered() then core.setTooltip(string.format('Runs %d seconds after MoriAC starts, then every interval.', LOAD_DELAY)) end

    if ImGui.Button('Run Now##tmrRun', core.px(80), core.px(22)) then
        if not run(e, true) then chat('%s: could not run it now (no command, dead, zoning or casting).', e.name) end
    end
    if ImGui.IsItemHovered() then core.setTooltip('Runs it now and restarts its timer.') end
    ImGui.SameLine()
    if ImGui.Button('Delete##tmrDelete', core.px(80), core.px(22)) then
        st.nextAt[e] = nil
        table.remove(cfg.entries, i)
        st.selected = math.max(1, math.min(st.selected, #cfg.entries))
        saveSettings()
    end
end

function plugin.onDrawSettings()
    if not core then return end
    local colors = core.colors or {}
    local GOLD = colors.GOLD or { 1.0, 0.70, 0.54, 1 }
    core.accent(GOLD, 'Timed Commands')
    ImGui.TextDisabled('Runs commands on a timer, e.g. /say kratos every 10 minutes. Works while MoriAC is paused too.')
    ImGui.Dummy(0, core.px(4))

    local ec = ImGui.Checkbox('Say in chat when one runs##tmrEcho', cfg.echo)
    if ec ~= cfg.echo then cfg.echo = ec; saveSettings() end

    ImGui.Dummy(0, core.px(4))
    core.cardTitle('Timers')
    local now = os.time()
    for i, e in ipairs(cfg.entries) do
        local en = ImGui.Checkbox('##tmrEn' .. i, e.enabled)
        if en ~= e.enabled then
            e.enabled = en
            st.nextAt[e] = nil
            saveSettings()
        end
        if ImGui.IsItemHovered() then core.setTooltip('On / off') end
        ImGui.SameLine()
        local left = (e.enabled and st.nextAt[e]) and ('next in ' .. fmtLeft(st.nextAt[e] - now)) or (e.enabled and 'waiting' or 'off')
        local _, pressed = ImGui.Selectable(string.format('%s  -  %s every %d min  (%s)##tmrRow%d',
            e.name, e.command, e.minutes, left, i), st.selected == i)
        if pressed then st.selected = i end
    end
    if #cfg.entries < MAX_ENTRIES and ImGui.Button('Add Timer##tmrAdd', core.px(110), core.px(22)) then
        cfg.entries[#cfg.entries + 1] = sanitizeEntry({ name = 'New timer', command = '', minutes = 10 })
        st.selected = #cfg.entries
        saveSettings()
    end
    ImGui.SameLine()
    if ImGui.Button('Add Kratos##tmrKratos', core.px(110), core.px(22)) then
        local have = false
        for _, e in ipairs(cfg.entries) do
            if (commandLine(e.command) or ''):lower() == '/say kratos' then have = true end
        end
        if not have and #cfg.entries < MAX_ENTRIES then
            cfg.entries[#cfg.entries + 1] = defaultEntries()[1]
            st.selected = #cfg.entries
            saveSettings()
        end
    end
    if ImGui.IsItemHovered() then core.setTooltip('Adds back /say kratos every 10 minutes if you deleted it.') end

    local e = cfg.entries[st.selected]
    if e then
        ImGui.Dummy(0, core.px(6))
        core.cardTitle('Edit: ' .. e.name)
        drawEditor(e, st.selected)
    end
end

-- /ac timers [list|now <n>|on <n>|off <n>]
function plugin.onCommand(cmd, args)
    if cmd ~= 'timers' and cmd ~= 'timer' and cmd ~= 'kratos' then return false end
    local sub = args and args[2] and tostring(args[2]):lower() or 'list'
    if cmd == 'kratos' then sub = 'now' end
    local n = tonumber(args and args[3])
    if cmd == 'kratos' then
        for i, e in ipairs(cfg.entries) do
            if (commandLine(e.command) or ''):lower() == '/say kratos' then n = i end
        end
        if not n then
            local ok = pcall(mq.cmd, '/say kratos')
            if ok then chat('/say kratos') end
            return true
        end
    end
    local e = cfg.entries[n or 1]
    if sub == 'now' or sub == 'run' then
        if not e then chat('No timer %s. /ac timers lists them.', tostring(n)) return true end
        if not run(e, true) then chat('%s: could not run it now (dead, zoning or casting).', e.name) end
    elseif sub == 'on' or sub == 'off' then
        if not e then chat('No timer %s. /ac timers lists them.', tostring(n)) return true end
        e.enabled = (sub == 'on')
        st.nextAt[e] = nil
        saveSettings()
        chat('%s %s.', e.name, e.enabled and 'on' or 'off')
    else
        local now = os.time()
        chat('%d timer%s:', #cfg.entries, #cfg.entries == 1 and '' or 's')
        for i, t in ipairs(cfg.entries) do
            chat('  %d. %s %s - %s every %d min%s', i, t.enabled and '\ag[on]\ax' or '\a-w[off]\ax', t.name,
                t.command, t.minutes, (t.enabled and st.nextAt[t]) and (', next in ' .. fmtLeft(st.nextAt[t] - now)) or '')
        end
    end
    return true
end

plugin.help = {
    '  \ag/ac timers [list|now <n>|on <n>|off <n>]\ax - Commands on a timer (default: /say kratos every 10 min)',
    '  \ag/ac kratos\ax - /say kratos now and restart its timer',
}

-- Exposed for tests
plugin.sanitizeEntry  = sanitizeEntry
plugin.commandLine    = commandLine
plugin.whenAllows     = whenAllows
plugin.firstDue       = firstDue
plugin.fmtLeft        = fmtLeft
plugin.defaultEntries = defaultEntries
plugin.run            = run
plugin._cfg           = cfg
plugin._state         = st

return plugin
