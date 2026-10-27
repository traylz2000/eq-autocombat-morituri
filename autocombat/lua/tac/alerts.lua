---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- lua/tac/alerts.lua — MoriAC Alerts Plugin
-- ============================================================================
-- Audio / on-screen alerts. Each trigger watches either a chat line (an
-- mq.event pattern, e.g. "#1# has become ENRAGED.") or your own HP / mana
-- dropping below a threshold, and when it fires it:
--   * plays a sound: the built-in alarm (config/moriac_alarm.wav, made by
--     dev/make_alarm_wav.py), a .wav file the trigger names, or /beep,
--   * flashes the alert text at the top of the screen for a few seconds,
--   * echoes it to chat.
--
-- Plugins tick and chat events fire whether MoriAC is running or paused, so
-- alerts work while you play by hand. Per trigger, "When" narrows that to
-- in combat only, or only while MoriAC is running.
--
-- Triggers are saved per character through onSaveSettings. Chat triggers are
-- registered as one mq.event each (MoriacAlert_<n>); any edit re-registers
-- them all on the next tick.
-- ============================================================================

local plugin = {
    id                 = 'alerts',
    name               = 'Alerts',
    version            = '1.1.0',
    author             = 'MoriAC',
    description        = 'Sound and on-screen alerts for chat lines (enrage, rampage, summon, your own text) and for low HP or mana.',
    defaultEnabled     = true,
    tickInterval       = 0.25,
    runOutOfCombatOnly = false,
    hasThread          = false,
}

local KINDS       = { 'chat', 'hp', 'mana' }
local KIND_LABEL  = { chat = 'Chat line', hp = 'My HP below', mana = 'My mana below' }
local WHENS       = { 'always', 'combat', 'running' }
local WHEN_LABEL  = { always = 'Always', combat = 'In combat only', running = 'Only while MoriAC is running' }
local REARM_PCT   = 5      -- HP / mana triggers fire again once back this far above the threshold
local MAX_TRIGGERS = 40

-- Trigger sounds: '' = /beep, ALARM = the built-in alarm, anything else is a
-- .wav file (full path, or relative to the MacroQuest folder).
local ALARM        = 'alarm'
local ALARM_FILE   = 'moriac_alarm.wav'   -- in config/, so the updater ships it
local SOUND_MODES  = { 'alarm', 'beep', 'file' }
local SOUND_LABEL  = { alarm = 'Alarm (loud, built in)', beep = 'Beep (quiet)', file = 'Sound file (.wav)' }
-- Saved settings older than this get the built-in alarm on their default
-- Enrage / Rampage / Summoned triggers (they used to beep).
local SOUND_VERSION = 2

local core  = nil
local mq    = nil
local ImGui = nil

local function defaultTriggers()
    return {
        { name = 'Enrage',   kind = 'chat', pattern = '#1# has become ENRAGED.#*#', enabled = true,  sound = ALARM, when = 'always', cooldown = 5,  flash = true },
        { name = 'Rampage',  kind = 'chat', pattern = '#1# goes on a RAMPAGE!#*#',  enabled = true,  sound = ALARM, when = 'always', cooldown = 10, flash = true },
        { name = 'Summoned', kind = 'chat', pattern = 'You have been summoned!#*#', enabled = true,  sound = ALARM, when = 'always', cooldown = 5,  flash = true },
        { name = 'Tell',     kind = 'chat', pattern = '#1# tells you, #*#',         enabled = false, sound = '', when = 'always', cooldown = 10, flash = false },
        { name = 'Low HP',   kind = 'hp',   threshold = 35,                         enabled = false, sound = '', when = 'always', cooldown = 15, flash = true },
    }
end

-- Persisted through onSaveSettings / onLoadSettings (per character loadout).
local cfg = {
    triggers  = defaultTriggers(),
    muted     = false,     -- no sounds (flash and chat still happen)
    chatEcho  = true,
    flashSec  = 3,
    soundVersion = SOUND_VERSION,
}

-- Session state (never persisted)
local st = {
    registered = {},       -- event names currently registered
    dirty      = true,     -- re-register chat events on the next tick
    lastFire   = {},       -- trigger table -> os.clock() of its last fire
    armed      = {},       -- trigger table -> false while an HP / mana alert is held
    flash      = nil,      -- { text, untilAt }
    selected   = 1,        -- trigger open in the settings editor
    fileMode   = {},       -- trigger table -> true while "Sound file" is picked but no file typed yet
    player     = nil,      -- false: no PlaySound here (not Windows); else { winmm = lib }
}

local function saveSettings()
    if core and core.saveLoadout then core.saveLoadout(true) end
end

local function chat(fmt, ...)
    print(string.format('\ay[MoriAC Alert]\ax ' .. fmt, ...))
end

-- ----------------------------------------------------------------------------
-- Pure helpers (exposed on the plugin for the test suite)
-- ----------------------------------------------------------------------------

-- A trigger read from a saved file (or typed in) made safe to use.
local function sanitizeTrigger(t)
    if type(t) ~= 'table' then return nil end
    local kind = KIND_LABEL[t.kind] and t.kind or 'chat'
    local out = {
        name      = (type(t.name) == 'string' and t.name ~= '') and t.name:sub(1, 40) or 'Alert',
        kind      = kind,
        pattern   = type(t.pattern) == 'string' and t.pattern:sub(1, 200) or '',
        threshold = math.max(1, math.min(99, math.floor(tonumber(t.threshold) or 35))),
        enabled   = t.enabled ~= false,
        sound     = type(t.sound) == 'string' and t.sound:sub(1, 200) or '',
        when      = WHEN_LABEL[t.when] and t.when or 'always',
        cooldown  = math.max(0, math.min(300, math.floor(tonumber(t.cooldown) or 5))),
        flash     = t.flash ~= false,
    }
    return out
end

-- Whether the "When" gate lets a trigger fire now.
local function whenAllows(when, inCombat, running)
    if when == 'combat' then return inCombat == true end
    if when == 'running' then return running == true end
    return true
end

-- HP / mana edge detection: fire once on dropping below, re-arm once back
-- REARM_PCT above. Returns fire, newArmed.
local function crossedBelow(pct, threshold, armed)
    if type(pct) ~= 'number' or pct <= 0 then return false, armed end   -- dead / zoning / no data
    if armed ~= false and pct < threshold then return true, false end
    if armed == false and pct >= threshold + REARM_PCT then return false, true end
    return false, armed
end

-- Alert text: the trigger name, plus what the pattern's #1# matched.
local function alertText(trig, arg1)
    if type(arg1) == 'string' and arg1 ~= '' then return trig.name .. ': ' .. arg1 end
    return trig.name
end

-- Which entry of the Sound picker a trigger's sound is.
local function soundMode(sound)
    sound = tostring(sound or '')
    if sound == ALARM then return 'alarm' end
    if sound == '' then return 'beep' end
    return 'file'
end

-- The .wav file to play for a sound, or nil for /beep.
-- configDir: MacroQuest's config folder; mqRoot: the MacroQuest folder.
local function soundFilePath(sound, configDir, mqRoot)
    sound = tostring(sound or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('^"(.*)"$', '%1')
    local path
    if sound == '' then return nil end
    if sound == ALARM then
        if type(configDir) ~= 'string' or configDir == '' then return nil end
        path = configDir .. '/' .. ALARM_FILE
    elseif sound:match('^%a:[/\\]') or sound:match('^[/\\][/\\]') then
        path = sound                                  -- C:\... or \\server\...
    else
        if type(mqRoot) ~= 'string' or mqRoot == '' then return nil end
        path = mqRoot .. '/' .. sound
    end
    return path
end

-- Windows' PlaySound (winmm) through LuaJIT's ffi: async, so it never holds
-- up the game, and louder and longer than /beep. Loaded on first use; false
-- when there is no such thing here (not Windows, no ffi).
local SND_ASYNC, SND_NODEFAULT, SND_FILENAME = 0x0001, 0x0002, 0x00020000
local function loadPlayer()
    if st.player ~= nil then return st.player end
    st.player = false
    pcall(function()
        local ffi = require('ffi')
        if ffi.os ~= 'Windows' then return end
        if not pcall(ffi.typeof, 'MORIAC_ALERTS_PLAYSOUND') then
            ffi.cdef([[
                typedef int MORIAC_ALERTS_PLAYSOUND;
                int __stdcall PlaySoundA(const char* pszSound, void* hmod, unsigned int fdwSound);
            ]])
        end
        st.player = { winmm = ffi.load('winmm') }
    end)
    return st.player
end

-- Plays a trigger's sound: its .wav through PlaySound, else /beep (also the
-- fallback when the file is missing or PlaySound isn't available).
local function playSound(sound)
    local path = nil
    pcall(function()
        local root = nil
        pcall(function() root = mq.TLO.MacroQuest.Path() end)
        path = soundFilePath(sound, core and core.configDir or (mq and mq.configDir), root)
    end)
    if path then
        local f = io.open(path, 'rb')
        if f then f:close() else path = nil end
    end
    if path then
        local p = loadPlayer()
        if p then
            st.playing = path:gsub('/', '\\')   -- kept referenced while it plays
            local ok, played = pcall(function()
                return p.winmm.PlaySoundA(st.playing, nil, SND_ASYNC + SND_NODEFAULT + SND_FILENAME) ~= 0
            end)
            if ok and played then return 'played' end
        end
    end
    if mq then pcall(mq.cmd, '/beep') end
    return 'beep'
end

-- ----------------------------------------------------------------------------
-- Firing
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

-- force: the Test button (skips the When gate and the cooldown)
local function fire(trig, arg1, force)
    if not force then
        if not trig.enabled then return false end
        if not whenAllows(trig.when, inCombatNow(), runningNow()) then return false end
        local last = st.lastFire[trig]
        if last and (os.clock() - last) < (trig.cooldown or 0) then return false end
    end
    st.lastFire[trig] = os.clock()
    local text = alertText(trig, arg1)
    if not cfg.muted then playSound(trig.sound) end
    if trig.flash then st.flash = { text = text, untilAt = os.clock() + (cfg.flashSec or 3) } end
    if cfg.chatEcho then chat('\ar%s\ax', text) end
    if core and core.log then pcall(core.log.info, 'alerts', 'fired: %s', text) end
    return true
end

-- ----------------------------------------------------------------------------
-- Chat events
-- ----------------------------------------------------------------------------
local function unregisterAll()
    if mq and mq.unevent then
        for _, name in ipairs(st.registered) do pcall(mq.unevent, name) end
    end
    st.registered = {}
end

local function registerAll()
    unregisterAll()
    st.dirty = false
    if not (mq and mq.event) then return end
    for i, trig in ipairs(cfg.triggers) do
        if trig.kind == 'chat' and trig.enabled and trig.pattern ~= '' then
            local name = 'MoriacAlert_' .. i
            if mq.unevent then pcall(mq.unevent, name) end
            local ok = pcall(mq.event, name, trig.pattern, function(_, a1) fire(trig, a1) end)
            if ok then st.registered[#st.registered + 1] = name end
        end
    end
end

local function markDirty()
    st.dirty = true
    saveSettings()
end

-- ----------------------------------------------------------------------------
-- Flash overlay
-- ----------------------------------------------------------------------------
local function drawFlash()
    local f = st.flash
    if not f then return end
    if os.clock() >= f.untilAt then st.flash = nil; return end
    local screenW, screenH = 0, 0
    pcall(function()
        local io = ImGui.GetIO()
        screenW, screenH = io.DisplaySize.x, io.DisplaySize.y
    end)
    if screenW <= 0 or screenH <= 0 then return end
    local scale = 1.8
    local okW, tw = pcall(ImGui.CalcTextSize, f.text)
    local w = ((okW and type(tw) == 'number') and tw or #f.text * 7) * scale + core.px(32)
    local colors = core.colors or {}
    local ERR = colors.ERR or { 0.95, 0.40, 0.40, 1.0 }

    core.pushTheme()
    ImGui.SetNextWindowPos((screenW - w) / 2, screenH * 0.18, ImGuiCond.Always)
    local flags = bit.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoResize, ImGuiWindowFlags.NoMove,
        ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoInputs, ImGuiWindowFlags.NoSavedSettings,
        ImGuiWindowFlags.NoFocusOnAppearing, ImGuiWindowFlags.AlwaysAutoResize)
    local _, show = ImGui.Begin('MoriAC Alert###moriacAlertFlash', true, flags)
    if show then
        pcall(ImGui.SetWindowFontScale, scale)
        ImGui.TextColored(ERR[1], ERR[2], ERR[3], ERR[4], f.text)
        pcall(ImGui.SetWindowFontScale, 1.0)
    end
    ImGui.End()
    core.popTheme()
end

-- ----------------------------------------------------------------------------
-- Plugin lifecycle
-- ----------------------------------------------------------------------------
function plugin.onInit(coreApi)
    core = coreApi
    mq = core.mq
    ImGui = core.ImGui
    st.dirty = true
end

function plugin.onDestroy()
    unregisterAll()
    st.flash = nil
    core = nil
    mq = nil
    ImGui = nil
end

local function readPct(kind)
    local v = nil
    pcall(function()
        if kind == 'hp' then v = mq.TLO.Me.PctHPs() else v = mq.TLO.Me.PctMana() end
    end)
    return tonumber(v)
end

function plugin.onTick()
    if not core then return end
    if st.dirty then registerAll() end
    for _, trig in ipairs(cfg.triggers) do
        if trig.enabled and (trig.kind == 'hp' or trig.kind == 'mana') then
            local hit, armed = crossedBelow(readPct(trig.kind), trig.threshold, st.armed[trig])
            st.armed[trig] = armed
            if hit then fire(trig, string.format('%d%%', readPct(trig.kind) or 0)) end
        end
    end
end

function plugin.onDrawUI()
    if not core then return end
    drawFlash()
end

function plugin.onSaveSettings()
    local list = {}
    for i, t in ipairs(cfg.triggers) do list[i] = sanitizeTrigger(t) end
    return {
        triggers = list,
        muted    = cfg.muted == true,
        chatEcho = cfg.chatEcho == true,
        flashSec = cfg.flashSec,
        soundVersion = SOUND_VERSION,
    }
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if type(s.triggers) == 'table' then
        local list = {}
        for _, t in ipairs(s.triggers) do
            local clean = sanitizeTrigger(t)
            if clean and #list < MAX_TRIGGERS then list[#list + 1] = clean end
        end
        cfg.triggers = list
        -- Before 1.1.0 every default trigger beeped: move the loud defaults
        -- to the built-in alarm unless the player picked a sound of their own.
        if (tonumber(s.soundVersion) or 1) < SOUND_VERSION then
            local loud = {}
            for _, d in ipairs(defaultTriggers()) do
                if d.sound == ALARM then loud[d.pattern] = true end
            end
            for _, t in ipairs(list) do
                if t.sound == '' and t.kind == 'chat' and loud[t.pattern] then t.sound = ALARM end
            end
        end
    end
    if s.muted ~= nil then cfg.muted = (s.muted == true) end
    if s.chatEcho ~= nil then cfg.chatEcho = (s.chatEcho == true) end
    cfg.flashSec = math.max(1, math.min(10, math.floor(tonumber(s.flashSec) or cfg.flashSec or 3)))
    st.lastFire, st.armed = {}, {}
    st.selected = 1
    st.dirty = true
end

-- ----------------------------------------------------------------------------
-- Settings page
-- ----------------------------------------------------------------------------
local function idxOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return 1
end

local function drawEditor(trig, i)
    local w = core.px(260)
    core.formLabel('Name')
    ImGui.SetNextItemWidth(w)
    local name = ImGui.InputText('##alrName', trig.name)
    if type(name) == 'string' and name ~= trig.name then trig.name = name; saveSettings() end

    core.formLabel('Type')
    ImGui.SetNextItemWidth(w)
    local labels = {}
    for k, kind in ipairs(KINDS) do labels[k] = KIND_LABEL[kind] end
    local ki = ImGui.Combo('##alrKind', idxOf(KINDS, trig.kind), labels)
    if KINDS[ki] and KINDS[ki] ~= trig.kind then trig.kind = KINDS[ki]; markDirty() end

    if trig.kind == 'chat' then
        core.formLabel('Chat line')
        ImGui.SetNextItemWidth(core.px(340))
        local pat = ImGui.InputText('##alrPattern', trig.pattern)
        if type(pat) == 'string' and pat ~= trig.pattern then trig.pattern = pat; markDirty() end
        if ImGui.IsItemHovered() then
            core.setTooltip('The text to watch for, as an MQ event pattern.\n#*# matches anything; #1# matches anything and shows it in the alert\n(e.g. "#1# has become ENRAGED.#*#" shows the mob name).')
        end
    else
        core.formLabel('Below %')
        ImGui.SetNextItemWidth(w)
        local th = ImGui.SliderInt('##alrThreshold', trig.threshold or 35, 1, 99)
        if type(th) == 'number' and th ~= trig.threshold then trig.threshold = th; saveSettings() end
        if ImGui.IsItemHovered() then core.setTooltip(string.format('Fires once when it drops below this, and again only after it is back %d%% above it.', REARM_PCT)) end
    end

    core.formLabel('Sound')
    ImGui.SetNextItemWidth(w)
    local mode = st.fileMode[trig] and 'file' or soundMode(trig.sound)
    local sl = {}
    for k, sm in ipairs(SOUND_MODES) do sl[k] = SOUND_LABEL[sm] end
    local si = ImGui.Combo('##alrSoundMode', idxOf(SOUND_MODES, mode), sl)
    local picked = SOUND_MODES[si]
    if picked and picked ~= mode then
        st.fileMode[trig] = (picked == 'file') or nil
        if picked == 'alarm' then trig.sound = ALARM
        elseif picked == 'beep' or trig.sound == ALARM then trig.sound = '' end
        saveSettings()
        mode = picked
    end
    if ImGui.IsItemHovered() then
        core.setTooltip('Alarm: three loud rising whoops (config/moriac_alarm.wav).\nBeep: the quiet /beep.\nSound file: any .wav you pick.')
    end
    if mode == 'file' then
        core.formLabel('File')
        ImGui.SetNextItemWidth(core.px(340))
        local cur = (trig.sound == ALARM) and '' or trig.sound
        local snd = ImGui.InputTextWithHint('##alrSound', 'e.g. C:\\Sounds\\horn.wav', cur)
        if type(snd) == 'string' and snd ~= cur then trig.sound = snd; saveSettings() end
        if ImGui.IsItemHovered() then
            core.setTooltip('A .wav file: a full path, or a path from your MacroQuest folder.\nIf it can\'t be played, the alert beeps instead.')
        end
    end

    core.formLabel('When')
    ImGui.SetNextItemWidth(w)
    local wl = {}
    for k, wh in ipairs(WHENS) do wl[k] = WHEN_LABEL[wh] end
    local wi = ImGui.Combo('##alrWhen', idxOf(WHENS, trig.when), wl)
    if WHENS[wi] and WHENS[wi] ~= trig.when then trig.when = WHENS[wi]; saveSettings() end

    core.formLabel('Cooldown (s)')
    ImGui.SetNextItemWidth(w)
    local cd = ImGui.SliderInt('##alrCooldown', trig.cooldown or 5, 0, 120)
    if type(cd) == 'number' and cd ~= trig.cooldown then trig.cooldown = cd; saveSettings() end
    if ImGui.IsItemHovered() then core.setTooltip('After firing, the trigger stays quiet this long so a burst of lines makes one alert.') end

    local fl = ImGui.Checkbox('Flash it on screen##alrFlash', trig.flash)
    if fl ~= trig.flash then trig.flash = fl; saveSettings() end

    if ImGui.Button('Test##alrTest', core.px(80), core.px(22)) then fire(trig, trig.kind == 'chat' and 'a test mob' or '30%', true) end
    if ImGui.IsItemHovered() then core.setTooltip('Plays this alert now, ignoring When and the cooldown.') end
    ImGui.SameLine()
    if ImGui.Button('Delete##alrDelete', core.px(80), core.px(22)) then
        table.remove(cfg.triggers, i)
        st.selected = math.max(1, math.min(st.selected, #cfg.triggers))
        markDirty()
    end
end

function plugin.onDrawSettings()
    if not core then return end
    local colors = core.colors or {}
    local GOLD = colors.GOLD or { 1.0, 0.70, 0.54, 1 }
    core.accent(GOLD, 'Alerts')
    ImGui.TextDisabled('Sounds and on-screen alerts for chat lines and low HP / mana. They work while MoriAC is paused too.')
    ImGui.Dummy(0, core.px(4))

    local m = ImGui.Checkbox('Mute sounds##alrMute', cfg.muted)
    if m ~= cfg.muted then cfg.muted = m; saveSettings() end
    if ImGui.IsItemHovered() then core.setTooltip('Alerts still flash and show in chat. Also /ac alerts mute | unmute.') end
    ImGui.SameLine()
    local ce = ImGui.Checkbox('Echo to chat##alrEcho', cfg.chatEcho)
    if ce ~= cfg.chatEcho then cfg.chatEcho = ce; saveSettings() end
    core.formLabel('Flash for (s)')
    ImGui.SetNextItemWidth(core.px(200))
    local fs = ImGui.SliderInt('##alrFlashSec', cfg.flashSec or 3, 1, 10)
    if type(fs) == 'number' and fs ~= cfg.flashSec then cfg.flashSec = fs; saveSettings() end

    ImGui.Dummy(0, core.px(4))
    core.cardTitle('Triggers')
    for i, trig in ipairs(cfg.triggers) do
        local en = ImGui.Checkbox('##alrEn' .. i, trig.enabled)
        if en ~= trig.enabled then trig.enabled = en; markDirty() end
        if ImGui.IsItemHovered() then core.setTooltip('On / off') end
        ImGui.SameLine()
        local desc = trig.kind == 'chat' and trig.pattern or string.format('%s %d%%', KIND_LABEL[trig.kind], trig.threshold or 0)
        local _, pressed = ImGui.Selectable(string.format('%s  -  %s##alrRow%d', trig.name, desc, i), st.selected == i)
        if pressed then st.selected = i end
    end
    if #cfg.triggers < MAX_TRIGGERS and ImGui.Button('Add Trigger##alrAdd', core.px(110), core.px(22)) then
        cfg.triggers[#cfg.triggers + 1] = sanitizeTrigger({ name = 'New alert', kind = 'chat', pattern = '', sound = ALARM })
        st.selected = #cfg.triggers
        markDirty()
    end
    ImGui.SameLine()
    if ImGui.Button('Add Missing Defaults##alrDefaults', core.px(160), core.px(22)) then
        local have = {}
        for _, t in ipairs(cfg.triggers) do have[t.name] = true end
        for _, d in ipairs(defaultTriggers()) do
            if not have[d.name] and #cfg.triggers < MAX_TRIGGERS then cfg.triggers[#cfg.triggers + 1] = d end
        end
        markDirty()
    end
    if ImGui.IsItemHovered() then core.setTooltip('Adds back any of Enrage, Rampage, Summoned, Tell and Low HP you deleted.') end

    local trig = cfg.triggers[st.selected]
    if trig then
        ImGui.Dummy(0, core.px(6))
        core.cardTitle('Edit: ' .. trig.name)
        drawEditor(trig, st.selected)
    end
end

-- /ac alerts [list|mute|unmute|test <n>]
function plugin.onCommand(cmd, args)
    if cmd ~= 'alerts' and cmd ~= 'alert' then return false end
    local sub = args and args[2] and tostring(args[2]):lower() or 'list'
    if sub == 'mute' or sub == 'unmute' then
        cfg.muted = (sub == 'mute')
        saveSettings()
        chat('Alert sounds %s.', cfg.muted and 'muted' or 'on')
    elseif sub == 'test' then
        local n = tonumber(args and args[3]) or 1
        local trig = cfg.triggers[n]
        if trig then fire(trig, 'a test mob', true) else chat('No trigger %s. /ac alerts lists them.', tostring(n)) end
    else
        chat('%d trigger%s%s:', #cfg.triggers, #cfg.triggers == 1 and '' or 's', cfg.muted and ' (sounds muted)' or '')
        for i, t in ipairs(cfg.triggers) do
            chat('  %d. %s %s - %s', i, t.enabled and '\ag[on]\ax' or '\a-w[off]\ax', t.name,
                t.kind == 'chat' and t.pattern or string.format('%s %d%%', KIND_LABEL[t.kind], t.threshold or 0))
        end
    end
    return true
end

plugin.help = {
    '  \ag/ac alerts [list|mute|unmute|test <n>]\ax - Sound / on-screen alerts (enrage, rampage, summon, low HP, your own chat lines)',
}

-- Exposed for tests
plugin.sanitizeTrigger = sanitizeTrigger
plugin.whenAllows      = whenAllows
plugin.crossedBelow    = crossedBelow
plugin.alertText       = alertText
plugin.soundMode       = soundMode
plugin.soundFilePath   = soundFilePath
plugin.playSound       = playSound
plugin.defaultTriggers = defaultTriggers
plugin.fire            = fire
plugin._cfg            = cfg
plugin._state          = st

return plugin
