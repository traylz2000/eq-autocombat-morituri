---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- lua/tac/update_check.lua — MoriAC Updater Plugin
-- ============================================================================
-- Keeps the MoriAC files (lua/ and config/) in step with the public repo.
--
-- What it compares
--   dev/publish.sh writes update_manifest.txt at the root of the public repo:
--   a version stamp, the newest CHANGELOG section, and one line per shipped
--   file with its size and CRC-32. A check downloads that manifest and
--   compares it with the files on disk, so it never depends on GitHub
--   releases (there are none) and finds every changed file, not just a
--   version number.
--
-- Installing
--   "Update now" downloads only the files that differ, from the same commit
--   of the public repo (raw.githubusercontent.com). Every download must match
--   the manifest's size and CRC-32, or nothing is installed. Then each file is
--   written next to the original as <file>.new, and only once all of them are
--   written is each swapped in, keeping the old copy as <file>.bak. A lock file
--   keeps two boxed characters from installing at once. The running script
--   keeps its loaded copy until /ac restart.
--   config/ingame.cfg is never touched (it is yours to edit).
--
-- How it talks to the internet without hitching the game
--   MoriAC must never spawn a process (curl / PowerShell block eqgame.exe)
--   and has no luarocks socket module. Instead the plugin uses LuaJIT's ffi
--   to drive the WinHttp.WinHttpRequest.5.1 COM object that ships with
--   Windows (and Wine) in *async* mode: Send() returns immediately, the DNS /
--   TLS / transfer runs on WinHTTP's own worker thread, and onTick polls for
--   completion with calls that cannot wait.
--
-- Polling: two stages, neither of which can block the game thread.
--   1. get_Status fails (INCORRECT_HANDLE_STATE) until the response headers
--      are in. It never waits or pumps window messages.
--   2. WaitForResponse(0) then confirms the body is complete, and only after
--      that is ResponseBody read once. Wine's worker thread reallocs the body
--      buffer without holding the lock, so reading earlier would race. Wine
--      also leaves WaitForResponse's out-param untouched once the response is
--      already complete, so it is pre-set to TRUE before every call.
--   ResponseBody (raw bytes) is used rather than ResponseText, which would
--   re-encode the file and break the CRC.
--
-- Everything that can fail (no ffi, COM refused, offline, TLS) degrades to a
-- one-line "update check unavailable" reason on the settings page; the
-- auto-check then stays quiet for the rest of the session.
-- ============================================================================

local plugin = {
    id                 = 'update_check',
    name               = 'Updater',
    version            = '2.1.0',
    author             = 'MoriAC',
    description        = 'Checks the MoriAC GitHub repo for changed files and installs them in place (non-blocking, no external process).',
    defaultEnabled     = true,
    tickInterval       = 0.25,
    runOutOfCombatOnly = false,
    hasThread          = false,
}

local REPO            = 'traylz2000/eq-autocombat-morituri'
local RAW_BASE        = 'https://raw.githubusercontent.com/' .. REPO .. '/main/'
local MANIFEST_URL    = RAW_BASE .. 'update_manifest.txt'
local FILE_BASE       = RAW_BASE .. 'autocombat/'
local REPO_URL        = 'https://github.com/' .. REPO
local USER_AGENT      = 'MoriAC-Updater'
local STARTUP_DELAY_S = 20        -- first automatic check this long after load
local REQUEST_TIMEOUT_S = 30      -- Abort a request that has not completed by then
local RETRY_AFTER_S   = 15 * 60   -- automatic retry spacing after a failed check
local LOCK_STALE_S    = 120       -- an install lock older than this is ignored
local FREQUENCIES     = { 'session', 'daily', 'weekly', 'off' }
local FREQUENCY_LABEL = { session = 'Every session', daily = 'Once a day', weekly = 'Once a week', off = 'Never (manual only)' }
local FREQUENCY_SEC   = { daily = 86400, weekly = 7 * 86400 }
-- Shipped files the updater leaves alone: players edit them.
local KEEP_LOCAL      = { ['config/ingame.cfg'] = true }

local core  = nil
local mq    = nil
local ImGui = nil

-- Persisted through onSaveSettings / onLoadSettings (per character loadout).
local cfg = {
    autoCheck   = true,
    frequency   = 'session',
    popup       = true,       -- open the notice window when an update is found
    skipVersion = nil,        -- "Skip this version": no more notices for this version
    lastCheckAt = nil,        -- os.time() of the last completed check
    lastVersion = nil,        -- manifest version the last successful check returned
}

-- Session state (never persisted)
local st = {
    startedAt      = 0,        -- os.time() at onInit
    nextAutoAt     = nil,      -- os.time() the next automatic check may run
    autoDone       = false,    -- this session's automatic check has run
    unavailable    = nil,      -- reason string when the transport cannot work this session
    phase          = nil,      -- nil | 'manifest' | 'download'
    manual         = false,    -- current check was requested by the user (always report)
    lastError      = nil,
    lastCheckedAt  = nil,      -- os.time() of the last completed check this session
    lastDurationMs = nil,
    result         = nil,      -- { version, date, notes, files, changed }
    dlIndex        = 0,        -- install: index into result.changed being downloaded
    dlBodies       = nil,      -- install: rel path -> downloaded bytes
    installed      = nil,      -- { version, count } after a successful install
    noticeOpen     = false,
    remindLater    = false,    -- popup dismissed for this session
}

local function chat(fmt, ...)
    print(string.format('\ay[MoriAC Update]\ax ' .. fmt, ...))
end

local function saveSettings()
    if core and core.saveLoadout then core.saveLoadout(true) end
end

local function nowMs()
    if mq and mq.gettime then return tonumber(mq.gettime()) end
    return os.clock() * 1000
end

-- ----------------------------------------------------------------------------
-- Pure helpers (exposed on the plugin for the test suite)
-- ----------------------------------------------------------------------------

-- '2026.10.26.1405' / 'v2.15' -> { 2026, 10, 26, 1405 } / { 2, 15 }
local function parseVersion(s)
    s = tostring(s or ''):gsub('^[vV]', '')
    local parts = {}
    for n in s:gmatch('%d+') do parts[#parts + 1] = tonumber(n) end
    return parts
end

-- >0 if a is newer than b, <0 if older, 0 if equal
local function compareVersions(a, b)
    local pa, pb = parseVersion(a), parseVersion(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y and 1 or -1 end
    end
    return 0
end

-- CRC-32 (IEEE, the zlib / PNG one) in plain Lua over LuaJIT's bit library.
-- In game the native ntdll RtlComputeCrc32 is used instead when it passes
-- its self-test; this is the fallback and the reference for the tests.
local CRC_TABLE = nil
local function crc32Lua(s)
    local b = bit
    if not CRC_TABLE then
        CRC_TABLE = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if b.band(c, 1) == 1 then c = b.bxor(b.rshift(c, 1), 0xEDB88320) else c = b.rshift(c, 1) end
            end
            CRC_TABLE[i] = c
        end
    end
    local crc = b.bnot(0)
    for i = 1, #s do
        crc = b.bxor(b.rshift(crc, 8), CRC_TABLE[b.band(b.bxor(crc, s:byte(i)), 0xFF)])
    end
    return b.bnot(crc) % 4294967296
end

-- Only plain relative paths under lua/ or config/ are installable.
local function relPathOk(rel)
    if type(rel) ~= 'string' or rel == '' then return false end
    if rel:find('..', 1, true) or rel:find('\\', 1, true) or rel:find(':', 1, true) or rel:sub(1, 1) == '/' then return false end
    if KEEP_LOCAL[rel] then return false end
    return rel:match('^lua/[%w_%-%./]+$') ~= nil or rel:match('^config/[%w_%-%./]+$') ~= nil
end

-- update_manifest.txt (see dev/publish.sh):
--   version=2026.10.26.1405
--   date=2026-10-26
--   commit=a7db88a
--   file=lua/moriac.lua 1052311 0a1b2c3d
--   note=## 2026-10-26
-- Returns { version, date, commit, files = { {path, size, crc} }, notes } or nil, reason.
local function parseManifest(text)
    if type(text) ~= 'string' or text == '' then return nil, 'empty manifest' end
    local m = { files = {}, noteLines = {} }
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '')
        local k, v = line:match('^(%a+)=(.*)$')
        if k == 'version' then m.version = v
        elseif k == 'date' then m.date = v
        elseif k == 'commit' then m.commit = v
        elseif k == 'note' then m.noteLines[#m.noteLines + 1] = v
        elseif k == 'file' then
            local p, size, crc = v:match('^(%S+)%s+(%d+)%s+(%x%x%x%x%x%x%x%x)$')
            if not p then return nil, 'bad file line: ' .. v end
            m.files[#m.files + 1] = { path = p, size = tonumber(size), crc = tonumber(crc, 16) }
        end
    end
    if not m.version or m.version == '' then return nil, 'manifest has no version' end
    if #m.files == 0 then return nil, 'manifest lists no files' end
    m.notes = table.concat(m.noteLines, '\n')
    m.noteLines = nil
    return m
end

-- Files whose local copy is missing or differs from the manifest.
-- localPathFn(rel) -> path or nil; readFn(path) -> bytes or nil; crcFn(bytes) -> number
local function planChanges(manifest, localPathFn, readFn, crcFn)
    local changed = {}
    for _, f in ipairs(manifest.files) do
        if relPathOk(f.path) then
            local dest = localPathFn(f.path)
            if dest then
                local body = readFn(dest)
                local why = nil
                if not body then why = 'new'
                elseif #body ~= f.size or crcFn(body) ~= f.crc then why = 'changed' end
                if why then changed[#changed + 1] = { path = f.path, dest = dest, size = f.size, crc = f.crc, why = why } end
            end
        end
    end
    return changed
end

-- Write every <dest>.new, then swap each in (old copy -> <dest>.bak).
-- items: { {dest, body, path} }. Returns true, count or false, reason.
local function applyFiles(items)
    for i, it in ipairs(items) do
        local h = io.open(it.dest .. '.new', 'wb')
        local ok = h and h:write(it.body)
        if h then h:close() end
        if not ok then
            for j = 1, i do os.remove(items[j].dest .. '.new') end
            return false, 'could not write ' .. it.dest .. '.new (nothing was changed)'
        end
    end
    for i, it in ipairs(items) do
        local cur = io.open(it.dest, 'rb')
        local existed = cur ~= nil
        if cur then cur:close() end
        if existed then
            os.remove(it.dest .. '.bak')
            local okB, errB = os.rename(it.dest, it.dest .. '.bak')
            if not okB then
                for j = i, #items do os.remove(items[j].dest .. '.new') end
                return false, string.format('could not move %s aside (%s); %d of %d files were updated', it.path or it.dest, tostring(errB), i - 1, #items)
            end
        end
        local okN, errN = os.rename(it.dest .. '.new', it.dest)
        if not okN then
            if existed then os.rename(it.dest .. '.bak', it.dest) end
            for j = i, #items do os.remove(items[j].dest .. '.new') end
            return false, string.format('could not install %s (%s); %d of %d files were updated', it.path or it.dest, tostring(errN), i - 1, #items)
        end
    end
    return true, #items
end

-- Changelog markdown -> a few readable lines for an ImGui text block (strip
-- heading / emphasis markers, cap the length).
local function summarizeNotes(notes, maxLines, maxChars)
    if type(notes) ~= 'string' or notes == '' then return nil end
    local out, n, total = {}, 0, 0
    for line in (notes .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r', ''):gsub('^#+%s*', ''):gsub('%*%*', ''):gsub('`', '')
        if line:match('^%s*%-%-%-%s*$') then break end
        if line:match('%S') then
            n = n + 1
            total = total + #line
            out[#out + 1] = line
            if n >= (maxLines or 12) or total >= (maxChars or 1200) then
                out[#out + 1] = '...'
                break
            end
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, '\n')
end

local function readFile(path)
    local h = io.open(path, 'rb')
    if not h then return nil end
    local s = h:read('*a')
    h:close()
    return s
end

local function localPath(rel)
    local sub = rel:match('^lua/(.+)$')
    if sub then return (mq and mq.luaDir or 'lua') .. '/' .. sub end
    sub = rel:match('^config/(.+)$')
    if sub then return (mq and mq.configDir or 'config') .. '/' .. sub end
    return nil
end

-- ----------------------------------------------------------------------------
-- Transport: LuaJIT ffi -> WinHttp.WinHttpRequest.5.1 (async)
-- ----------------------------------------------------------------------------
local http = {
    ffi      = nil,
    ole32    = nil,
    oleaut32 = nil,
    kernel32 = nil,
    ntdll    = nil,
    iid      = nil,
    ready    = false,
    err      = nil,
    nativeCrc = false,   -- RtlComputeCrc32 passed its self-test
    -- live request
    req      = nil,      -- IWinHttpRequest*
    bstrs    = nil,      -- BSTRs allocated for the live request
    t0       = 0,
    deadline = 0,
    polls    = 0,
    headers  = false,
    code     = nil,
}

local CDEF = [[
typedef long            HRESULT;
typedef long            LONG;
typedef unsigned long   ULONG;
typedef unsigned long   DWORD;
typedef unsigned short  WORD;
typedef unsigned int    UINT;
typedef unsigned short  VARTYPE;
typedef short           VARIANT_BOOL;
typedef wchar_t*        BSTR;
typedef DWORD           LCID;
typedef long            DISPID;

typedef struct { DWORD Data1; WORD Data2; WORD Data3; unsigned char Data4[8]; } GUID;

typedef struct {
    VARTYPE vt;
    WORD    wReserved1, wReserved2, wReserved3;
    union {
        LONG          lVal;
        DWORD         ulVal;
        VARIANT_BOOL  boolVal;
        BSTR          bstrVal;
        void*         byref;
        double        dblVal;
        long long     llVal;
    };
} VARIANT;

typedef struct IWinHttpRequest IWinHttpRequest;
typedef struct {
    HRESULT (__stdcall *QueryInterface)(IWinHttpRequest*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IWinHttpRequest*);
    ULONG   (__stdcall *Release)(IWinHttpRequest*);
    HRESULT (__stdcall *GetTypeInfoCount)(IWinHttpRequest*, UINT*);
    HRESULT (__stdcall *GetTypeInfo)(IWinHttpRequest*, UINT, LCID, void**);
    HRESULT (__stdcall *GetIDsOfNames)(IWinHttpRequest*, const GUID*, wchar_t**, UINT, LCID, DISPID*);
    HRESULT (__stdcall *Invoke)(IWinHttpRequest*, DISPID, const GUID*, LCID, WORD, void*, VARIANT*, void*, UINT*);
    HRESULT (__stdcall *SetProxy)(IWinHttpRequest*, DWORD, VARIANT, VARIANT);
    HRESULT (__stdcall *SetCredentials)(IWinHttpRequest*, BSTR, BSTR, DWORD);
    HRESULT (__stdcall *Open)(IWinHttpRequest*, BSTR, BSTR, VARIANT);
    HRESULT (__stdcall *SetRequestHeader)(IWinHttpRequest*, BSTR, BSTR);
    HRESULT (__stdcall *GetResponseHeader)(IWinHttpRequest*, BSTR, BSTR*);
    HRESULT (__stdcall *GetAllResponseHeaders)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *Send)(IWinHttpRequest*, VARIANT);
    HRESULT (__stdcall *get_Status)(IWinHttpRequest*, LONG*);
    HRESULT (__stdcall *get_StatusText)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *get_ResponseText)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *get_ResponseBody)(IWinHttpRequest*, VARIANT*);
    HRESULT (__stdcall *get_ResponseStream)(IWinHttpRequest*, VARIANT*);
    HRESULT (__stdcall *get_Option)(IWinHttpRequest*, DWORD, VARIANT*);
    HRESULT (__stdcall *put_Option)(IWinHttpRequest*, DWORD, VARIANT);
    HRESULT (__stdcall *WaitForResponse)(IWinHttpRequest*, VARIANT, VARIANT_BOOL*);
    HRESULT (__stdcall *Abort)(IWinHttpRequest*);
    HRESULT (__stdcall *SetTimeouts)(IWinHttpRequest*, LONG, LONG, LONG, LONG);
    HRESULT (__stdcall *SetClientCertificate)(IWinHttpRequest*, BSTR);
    HRESULT (__stdcall *SetAutoLogonPolicy)(IWinHttpRequest*, DWORD);
} IWinHttpRequestVtbl;
struct IWinHttpRequest { const IWinHttpRequestVtbl* lpVtbl; };

HRESULT __stdcall CoInitializeEx(void* reserved, DWORD coinit);
HRESULT __stdcall CLSIDFromProgID(const wchar_t* progId, GUID* clsid);
HRESULT __stdcall CoCreateInstance(const GUID* clsid, void* outer, DWORD ctx, const GUID* iid, void** out);
BSTR    __stdcall SysAllocString(const wchar_t* s);
void    __stdcall SysFreeString(BSTR s);
UINT    __stdcall SysStringLen(BSTR s);
int     __stdcall WideCharToMultiByte(UINT cp, DWORD flags, const wchar_t* src, int srcLen,
                                      char* dst, int dstLen, const char* defChar, int* usedDef);
]]

-- Added with the updater (2.0): raw response bytes and the native CRC. A
-- separate block with its own marker type, so a reload over a state where
-- only the first block was declared still gets these.
local CDEF_V2 = [[
typedef struct { int unused; } MORIAC_UPDATER_V2;
HRESULT __stdcall SafeArrayAccessData(void* psa, void** data);
HRESULT __stdcall SafeArrayUnaccessData(void* psa);
HRESULT __stdcall SafeArrayGetLBound(void* psa, UINT dim, LONG* bound);
HRESULT __stdcall SafeArrayGetUBound(void* psa, UINT dim, LONG* bound);
HRESULT __stdcall VariantClear(VARIANT* v);
DWORD   __stdcall RtlComputeCrc32(DWORD initial, const char* data, int len);
]]

local VT_EMPTY, VT_I4, VT_BOOL          = 0, 3, 11
local VT_ARRAY_UI1                      = 0x2011
local CLSCTX_INPROC_SERVER              = 0x1
local COINIT_APARTMENTTHREADED          = 0x2
local CP_UTF8                           = 65001
local S_OK, S_FALSE                     = 0, 1
local RPC_E_CHANGED_MODE                = -2147417850  -- 0x80010106
local WinHttpRequestOption_SecureProtocols = 9
local SECURE_TLS12_13                   = 0x0800 + 0x2000

local function hex(hr) return string.format('0x%08X', (tonumber(hr) or 0) % 4294967296) end
local function failed(hr) return (tonumber(hr) or -1) < 0 end

-- One-time ffi setup. Returns true, or false + reason. The cdefs are guarded so
-- a plugin reload in the same Lua state does not trip "attempt to redefine".
local function httpSetup()
    if http.ready then return true end
    if http.err then return false, http.err end
    local ok, res = pcall(function()
        local okFfi, ffi = pcall(require, 'ffi')
        if not okFfi then error('LuaJIT ffi is not available in this MacroQuest build') end
        if ffi.os ~= 'Windows' then error('needs the Windows COM runtime (ffi.os = ' .. tostring(ffi.os) .. ')') end
        if not pcall(ffi.typeof, 'IWinHttpRequest') then ffi.cdef(CDEF) end
        if not pcall(ffi.typeof, 'MORIAC_UPDATER_V2') then ffi.cdef(CDEF_V2) end
        if ffi.sizeof('VARIANT') ~= 16 or ffi.sizeof('GUID') ~= 16 then error('unexpected VARIANT/GUID layout') end
        http.ffi      = ffi
        http.ole32    = ffi.load('ole32')
        http.oleaut32 = ffi.load('oleaut32')
        http.kernel32 = ffi.load('kernel32')
        http.iid      = ffi.new('GUID', 0x016fe2ec, 0xb2c8, 0x45f8,
            { 0xb2, 0x3b, 0x39, 0xe5, 0x3a, 0x75, 0x39, 0x6b })   -- IID_IWinHttpRequest
        -- S_OK / S_FALSE / RPC_E_CHANGED_MODE all mean COM is usable on this thread.
        local hr = tonumber(http.ole32.CoInitializeEx(nil, COINIT_APARTMENTTHREADED))
        if hr ~= S_OK and hr ~= S_FALSE and hr ~= RPC_E_CHANGED_MODE then
            error('CoInitializeEx returned ' .. hex(hr))
        end
    end)
    if not ok then
        http.err = tostring(res):gsub('^.-:%d+: ', '')
        return false, http.err
    end
    -- Native CRC-32 when it agrees with the standard check value.
    pcall(function()
        http.ntdll = http.ffi.load('ntdll')
        local s = '123456789'
        http.nativeCrc = (tonumber(http.ntdll.RtlComputeCrc32(0, s, #s)) % 4294967296) == 0xCBF43926
    end)
    http.ready = true
    return true
end

local function crc32(s)
    if http.nativeCrc then
        return tonumber(http.ntdll.RtlComputeCrc32(0, s, #s)) % 4294967296
    end
    return crc32Lua(s)
end

local function wide(s)
    local buf = http.ffi.new('wchar_t[?]', #s + 1)
    for i = 1, #s do buf[i - 1] = s:byte(i) end
    buf[#s] = 0
    return buf
end

local function bstr(s)
    local b = http.oleaut32.SysAllocString(wide(s))
    if b == nil then error('SysAllocString failed') end
    http.bstrs[#http.bstrs + 1] = b
    return b
end

local function variant(vt, field, val)
    local v = http.ffi.new('VARIANT')
    v.vt = vt
    if field then v[field] = val end
    return v
end

-- The response as raw bytes (a VT_ARRAY | VT_UI1 SAFEARRAY).
local function responseBytes(req, vt)
    local ffi, oa = http.ffi, http.oleaut32
    local v = ffi.new('VARIANT[1]')
    local hr = vt.get_ResponseBody(req, v)
    if failed(hr) then error('ResponseBody failed (' .. hex(hr) .. ')') end
    local body = ''
    if v[0].vt == VT_ARRAY_UI1 and v[0].byref ~= nil then
        local psa = v[0].byref
        local lb, ub = ffi.new('LONG[1]'), ffi.new('LONG[1]')
        if not failed(oa.SafeArrayGetLBound(psa, 1, lb)) and not failed(oa.SafeArrayGetUBound(psa, 1, ub)) then
            local n = tonumber(ub[0]) - tonumber(lb[0]) + 1
            local p = ffi.new('void*[1]')
            if n > 0 and not failed(oa.SafeArrayAccessData(psa, p)) then
                body = ffi.string(p[0], n)
                oa.SafeArrayUnaccessData(psa)
            end
        end
    end
    oa.VariantClear(v)
    return body
end

-- Drop the live request: Abort if still in flight, Release, free BSTRs.
local function httpClose(abort)
    if http.req ~= nil then
        local req = http.req
        http.req = nil
        pcall(function()
            if abort then req.lpVtbl.Abort(req) end
            req.lpVtbl.Release(req)
        end)
    end
    if http.bstrs then
        for _, b in ipairs(http.bstrs) do pcall(http.oleaut32.SysFreeString, b) end
    end
    http.bstrs = nil
end

-- Start an async GET. Returns true, or false + reason. Never waits.
local function httpBegin(url)
    local ok, why = httpSetup()
    if not ok then return false, why end
    httpClose(true)
    http.bstrs = {}
    local okRun, res = pcall(function()
        local ffi = http.ffi
        local clsid = ffi.new('GUID')
        local hr = http.ole32.CLSIDFromProgID(wide('WinHttp.WinHttpRequest.5.1'), clsid)
        if failed(hr) then error('WinHttp.WinHttpRequest.5.1 is not registered (' .. hex(hr) .. ')') end
        local out = ffi.new('void*[1]')
        hr = http.ole32.CoCreateInstance(clsid, nil, CLSCTX_INPROC_SERVER, http.iid, out)
        if failed(hr) or out[0] == nil then error('CoCreateInstance failed (' .. hex(hr) .. ')') end
        http.req = ffi.cast('IWinHttpRequest*', out[0])
        local req, vt = http.req, http.req.lpVtbl
        -- resolve / connect / send / receive (ms): bounds the worker, not us
        hr = vt.SetTimeouts(req, 5000, 5000, 5000, 20000)
        if failed(hr) then error('SetTimeouts failed (' .. hex(hr) .. ')') end
        hr = vt.Open(req, bstr('GET'), bstr(url), variant(VT_BOOL, 'boolVal', -1))
        if failed(hr) then error('Open failed (' .. hex(hr) .. ')') end
        hr = vt.SetRequestHeader(req, bstr('User-Agent'), bstr(USER_AGENT))
        if failed(hr) then error('SetRequestHeader failed (' .. hex(hr) .. ')') end
        vt.SetRequestHeader(req, bstr('Cache-Control'), bstr('no-cache'))
        -- TLS 1.2/1.3 explicitly (older Windows defaults exclude 1.2; GitHub
        -- requires it). Wine does not implement the option: ignore the result.
        vt.put_Option(req, WinHttpRequestOption_SecureProtocols, variant(VT_I4, 'lVal', SECURE_TLS12_13))
        hr = vt.Send(req, variant(VT_EMPTY))
        if failed(hr) then error('Send failed (' .. hex(hr) .. ')') end
    end)
    if not okRun then
        httpClose(true)
        return false, tostring(res):gsub('^.-:%d+: ', '')
    end
    http.t0       = nowMs()
    http.deadline = http.t0 + REQUEST_TIMEOUT_S * 1000
    http.polls    = 0
    http.headers  = false
    http.code     = nil
    return true
end

-- One non-blocking poll. Returns 'pending' | 'done', code, body | 'error', reason.
local function httpPoll()
    if http.req == nil then return 'error', 'no request in flight' end
    local ffi = http.ffi
    local req, vt = http.req, http.req.lpVtbl
    http.polls = http.polls + 1
    local status, body = nil, nil
    local okRun, res = pcall(function()
        if not http.headers then
            local s = ffi.new('LONG[1]')
            if not failed(vt.get_Status(req, s)) then
                http.headers = true
                http.code = tonumber(s[0])
            end
        end
        if http.headers then
            local succeeded = ffi.new('VARIANT_BOOL[1]')
            succeeded[0] = -1
            local hr = vt.WaitForResponse(req, variant(VT_I4, 'lVal', 0), succeeded)
            if not failed(hr) and succeeded[0] ~= 0 then
                body = responseBytes(req, vt)
                status = 'done'
            end
        end
    end)
    if not okRun then
        httpClose(true)
        return 'error', tostring(res):gsub('^.-:%d+: ', '')
    end
    if status == 'done' then
        local code = http.code
        httpClose(false)
        return 'done', code, body
    end
    if nowMs() >= http.deadline then
        local why = http.headers
            and string.format('HTTP %s headers arrived but the body never completed', tostring(http.code))
            or 'no response (offline, firewalled, or TLS could not be negotiated)'
        httpClose(true)
        return 'error', why
    end
    return 'pending'
end

-- ----------------------------------------------------------------------------
-- The check and the install
-- ----------------------------------------------------------------------------
local function busy() return st.phase ~= nil end

local function startCheck(manual)
    if busy() then
        if manual then chat('An update check or install is already running.') end
        return false
    end
    if st.unavailable and not manual then return false end
    local ok, why = httpBegin(MANIFEST_URL)
    if not ok then
        st.unavailable = why
        st.lastError = why
        st.lastCheckedAt = os.time()
        if manual then chat('\arUpdate check unavailable\ax: %s', why) end
        if core and core.log then core.log.warn('update_check', 'transport unavailable: %s', tostring(why)) end
        return false
    end
    st.phase = 'manifest'
    st.manual = manual == true
    st.lastError = nil
    if manual then chat('Checking %s for changed files...', REPO) end
    return true
end

local function failPhase(why)
    local wasInstall = st.phase == 'download'
    st.phase = nil
    st.dlBodies = nil
    st.lastError = why
    st.lastCheckedAt = os.time()
    if not wasInstall then st.nextAutoAt = os.time() + RETRY_AFTER_S end
    if st.manual or wasInstall then chat('\ar%s failed\ax: %s', wasInstall and 'Update' or 'Update check', why) end
    if core and core.log then core.log.warn('update_check', '%s failed: %s', wasInstall and 'install' or 'check', tostring(why)) end
end

local function finishManifest(code, body)
    st.phase = nil
    st.lastCheckedAt = os.time()
    st.lastDurationMs = nowMs() - http.t0
    if code ~= 200 then
        st.nextAutoAt = os.time() + RETRY_AFTER_S
        st.lastError = string.format('GitHub answered HTTP %s for the update manifest', tostring(code))
        if st.manual then chat('\ar%s\ax', st.lastError) end
        return
    end
    local m, why = parseManifest(body)
    if not m then
        st.nextAutoAt = os.time() + RETRY_AFTER_S
        st.lastError = 'unreadable update manifest: ' .. tostring(why)
        if st.manual then chat('\ar%s\ax', st.lastError) end
        return
    end
    local okPlan, changed = pcall(planChanges, m, localPath, readFile, crc32)
    if not okPlan then
        st.lastError = 'could not compare local files: ' .. tostring(changed)
        if st.manual then chat('\ar%s\ax', st.lastError) end
        return
    end
    st.result = {
        version = m.version,
        date    = m.date or '',
        commit  = m.commit,
        notes   = summarizeNotes(m.notes, 40, 5000),
        files   = #m.files,
        changed = changed,
    }
    st.lastError = nil
    st.autoDone = true
    cfg.lastCheckAt = os.time()
    cfg.lastVersion = m.version
    saveSettings()

    local r = st.result
    if #changed > 0 then
        local skipped = (cfg.skipVersion == r.version)
        if st.manual or not skipped then
            chat('\agA MoriAC update is available\ax: %s (%s), %d file%s changed. \ay/ac update install\ax to install it.',
                r.version, r.date, #changed, #changed == 1 and '' or 's')
            if skipped and st.manual then chat('  (you chose to skip %s; /ac update unskip to be reminded again)', r.version) end
        end
        if st.manual or (cfg.popup and not skipped and not st.remindLater) then st.noticeOpen = true end
    elseif st.manual then
        chat('Your MoriAC files match the latest version (%s).', r.version)
    end
end

-- Install lock in config/: two boxed characters share one MacroQuest folder.
local function lockPath() return (mq and mq.configDir or 'config') .. '/moriac_update.lock' end

local function takeLock()
    local held = readFile(lockPath())
    local at = held and tonumber(held:match('%d+'))
    if at and (os.time() - at) < LOCK_STALE_S then return false end
    local h = io.open(lockPath(), 'wb')
    if not h then return false end
    h:write(tostring(os.time()))
    h:close()
    return true
end

local function dropLock() os.remove(lockPath()) end

local function startDownload(i)
    local f = st.result.changed[i]
    local ok, why = httpBegin(FILE_BASE .. f.path)
    if not ok then failPhase(why); return end
    st.dlIndex = i
end

local function startInstall()
    if busy() then chat('An update check or install is already running.'); return end
    local r = st.result
    if not r then chat('No update check yet. /ac update to check first.'); return end
    if #r.changed == 0 then chat('Nothing to install: your files match %s.', r.version); return end
    st.phase = 'download'
    st.manual = true
    st.lastError = nil
    st.dlBodies = {}
    chat('Downloading %d file%s for %s...', #r.changed, #r.changed == 1 and '' or 's', r.version)
    startDownload(1)
end

-- One click: check GitHub, then install straight away if anything changed
-- (onTick picks it up when the check finishes). A skipped version is still
-- installed, because the player asked for it.
local function checkAndInstall()
    if busy() then chat('An update check or install is already running.'); return end
    st.unavailable = nil
    if startCheck(true) then st.installAfterCheck = true end
end

local function finishInstall()
    local r = st.result
    local items = {}
    for _, f in ipairs(r.changed) do
        items[#items + 1] = { path = f.path, dest = f.dest, body = st.dlBodies[f.path] }
    end
    st.dlBodies = nil
    if not takeLock() then
        failPhase('another character is installing an update right now. Check again in a minute.')
        return
    end
    local ok, res = applyFiles(items)
    dropLock()
    st.phase = nil
    if not ok then
        st.lastError = res
        chat('\arUpdate failed\ax: %s', res)
        if core and core.log then core.log.warn('update_check', 'install failed: %s', tostring(res)) end
        return
    end
    st.installed = { version = r.version, count = res }
    r.changed = {}
    chat('\agInstalled %s\ax: %d file%s updated (old copies kept as .bak). \ay/ac restart\ax to load it; other characters need /ac restart too.',
        r.version, res, res == 1 and '' or 's')
    if core and core.log then core.log.info('update_check', 'installed %s (%d files)', tostring(r.version), res) end
end

local function onDownloaded(code, body)
    local f = st.result.changed[st.dlIndex]
    if code ~= 200 then
        failPhase(string.format('GitHub answered HTTP %s for %s', tostring(code), f.path))
        return
    end
    if #body ~= f.size or crc32(body) ~= f.crc then
        failPhase(string.format('%s did not match the manifest. GitHub may still be updating its copy; try again in a few minutes.', f.path))
        return
    end
    st.dlBodies[f.path] = body
    if st.dlIndex < #st.result.changed then
        startDownload(st.dlIndex + 1)
    else
        finishInstall()
    end
end

local function frequencyDue()
    if not cfg.autoCheck or cfg.frequency == 'off' then return false end
    local span = FREQUENCY_SEC[cfg.frequency]
    if span and cfg.lastCheckAt and (os.time() - cfg.lastCheckAt) < span then return false end
    return true
end

local function requestRestart()
    if core and core.runtime and core.runtime.restartScript then
        core.runtime.restartScript()
    elseif mq then
        mq.cmd('/ac restart')
    end
end

-- ----------------------------------------------------------------------------
-- UI
-- ----------------------------------------------------------------------------
local function progressText()
    if st.phase == 'manifest' then
        return string.format('Checking... (%.1f s)', (nowMs() - http.t0) / 1000)
    elseif st.phase == 'download' and st.result then
        local f = st.result.changed[st.dlIndex]
        return string.format('Downloading %d of %d: %s', st.dlIndex, #st.result.changed, f and f.path or '?')
    end
    return nil
end

-- Install / restart / skip buttons, shared by the notice and the settings page.
local function drawActions(sfx)
    local r = st.result
    local busyText = progressText()
    if busyText then
        local colors = core.colors or {}
        local WARN = colors.WARN or { 0.95, 0.75, 0.30, 1.0 }
        ImGui.TextColored(WARN[1], WARN[2], WARN[3], WARN[4], busyText)
        return
    end
    if r and #r.changed > 0 then
        if ImGui.Button('Update Now##updInstall' .. sfx, core.px(120), core.px(24)) then startInstall() end
        if ImGui.IsItemHovered() then
            core.setTooltip('Downloads the changed files, checks each one against the manifest, then swaps them in.\nThe old copies are kept as .bak. Restart MoriAC afterwards to load them.')
        end
        ImGui.SameLine()
        if ImGui.Button('Skip This Version##updSkip' .. sfx, core.px(140), core.px(24)) then
            cfg.skipVersion = r.version
            st.noticeOpen = false
            saveSettings()
            chat('Skipping %s. /ac update unskip to be reminded again.', r.version)
        end
        if ImGui.IsItemHovered() then core.setTooltip('No more popups or chat notices for %s. Newer versions still notify.', r.version) end
    elseif st.installed then
        if ImGui.Button('Restart MoriAC##updRestart' .. sfx, core.px(130), core.px(24)) then requestRestart() end
        if ImGui.IsItemHovered() then core.setTooltip('Same as /ac restart: saves, stops and starts MoriAC so the new files load.') end
    end
end

local function drawChangedList(r)
    if #r.changed == 0 then return end
    ImGui.TextDisabled(string.format('%d of %d files changed', #r.changed, r.files or 0))
    if ImGui.BeginChild('##updFiles', 0, core.px(math.min(#r.changed, 5) * 18 + 8), true) then
        for _, f in ipairs(r.changed) do
            ImGui.TextUnformatted(f.path .. (f.why == 'new' and '  (new)' or ''))
        end
    end
    ImGui.EndChild()
end

local function drawNotice()
    local r = st.result
    if not st.noticeOpen or not r then return end
    local colors = core.colors or {}
    local GOOD  = colors.GOOD or { 0.40, 0.85, 0.50, 1.0 }
    local ARC   = colors.ARC or { 0.30, 0.80, 1.00, 1.0 }

    core.pushTheme()
    ImGui.SetNextWindowSize(core.px(480), core.px(380), ImGuiCond.FirstUseEver)
    local flags = 0
    if ImGuiWindowFlags then flags = bit.bor(ImGuiWindowFlags.AlwaysUseWindowPadding) end ---@diagnostic disable-line: deprecated
    core.preBeginWindow('update_check')
    local open, draw = ImGui.Begin('MoriAC Update###TriuneUpdateNotice', true,
        core.windowFlags and core.windowFlags('update_check', flags) or flags)
    if not open then
        st.noticeOpen = false
        st.remindLater = true
        if core.preEndWindow then core.preEndWindow('update_check', false) end
        ImGui.End()
        core.popTheme()
        return
    end
    if not draw then
        if core.preEndWindow then core.preEndWindow('update_check', false) end
        ImGui.End()
        core.popTheme()
        return
    end
    core.postBeginWindow('update_check')

    ImGui.TextColored(ARC[1], ARC[2], ARC[3], ARC[4], 'MORITURI AUTO COMBAT UPDATE')
    ImGui.Separator()
    ImGui.Dummy(0, core.px(4))
    if st.installed then
        ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], string.format('Installed %s (%d files).', st.installed.version, st.installed.count))
        ImGui.TextWrapped('Restart MoriAC to load it. Other characters need /ac restart too.')
    elseif #r.changed > 0 then
        ImGui.Text('A new version is available:')
        ImGui.SameLine()
        ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], r.version)
        if r.date ~= '' then ImGui.TextDisabled('Published ' .. r.date) end
    else
        ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], string.format('Your files match the latest version (%s).', r.version))
    end
    ImGui.Dummy(0, core.px(4))
    drawChangedList(r)

    if r.notes then
        ImGui.TextDisabled('What changed')
        if ImGui.BeginChild('##updNotes', 0, core.px(130), true) then
            ImGui.PushTextWrapPos(0)
            ImGui.TextUnformatted(r.notes)
            ImGui.PopTextWrapPos()
        end
        ImGui.EndChild()
        ImGui.Dummy(0, core.px(4))
    end

    drawActions('n')
    if not busy() then
        ImGui.SameLine()
        if ImGui.Button('Close##updClose', core.px(90), core.px(24)) then
            st.noticeOpen = false
            st.remindLater = true
        end
        if ImGui.IsItemHovered() then core.setTooltip('Closes this notice for the rest of this session. /ac update show opens it again.') end
    end

    if core.preEndWindow then core.preEndWindow('update_check', false) end
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
    st.startedAt = os.time()
    st.nextAutoAt = st.startedAt + STARTUP_DELAY_S
    st.autoDone = false
    st.unavailable = nil
    st.remindLater = false
end

function plugin.onDestroy()
    httpClose(true)
    st.phase = nil
    st.dlBodies = nil
    st.noticeOpen = false
    core = nil
    mq = nil
    ImGui = nil
end

function plugin.onTick()
    if not core then return end
    if st.phase then
        local status, a, b = httpPoll()
        if status == 'done' then
            if st.phase == 'manifest' then
                finishManifest(a, b)
                if st.installAfterCheck then
                    st.installAfterCheck = nil
                    if not st.lastError and st.result and #st.result.changed > 0 then
                        st.noticeOpen = false
                        startInstall()
                    end
                end
            else
                onDownloaded(a, b)
            end
        elseif status == 'error' then
            st.installAfterCheck = nil
            failPhase(a)
        end
        return
    end
    if st.autoDone or st.unavailable then return end
    if st.nextAutoAt and os.time() >= st.nextAutoAt then
        if not frequencyDue() then
            st.autoDone = true
            return
        end
        -- One automatic check per session: autoDone is set only when a check
        -- succeeds (finishManifest); a failure leaves it false so the
        -- RETRY_AFTER_S schedule set by the error path triggers another try.
        startCheck(false)
    end
end

function plugin.onDrawUI()
    if not core then return end
    drawNotice()
end

function plugin.onSaveSettings()
    return {
        autoCheck   = cfg.autoCheck == true,
        frequency   = cfg.frequency,
        popup       = cfg.popup == true,
        skipVersion = cfg.skipVersion,
        lastCheckAt = cfg.lastCheckAt,
        lastVersion = cfg.lastVersion,
    }
end

-- skipTag / lastTag were the release-based checker's keys: GitHub release
-- tags, which this version never sees, so they are dropped.
function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if s.autoCheck ~= nil then cfg.autoCheck = (s.autoCheck == true) end
    if FREQUENCY_LABEL[s.frequency] then cfg.frequency = s.frequency end
    if s.popup ~= nil then cfg.popup = (s.popup == true) end
    cfg.skipVersion = (type(s.skipVersion) == 'string' and s.skipVersion ~= '') and s.skipVersion or nil
    cfg.lastCheckAt = tonumber(s.lastCheckAt)
    cfg.lastVersion = (type(s.lastVersion) == 'string' and s.lastVersion ~= '') and s.lastVersion or nil
end

local function fmtAgo(t)
    if not t then return 'never' end
    local d = os.time() - t
    if d < 60 then return 'just now' end
    if d < 3600 then return string.format('%d min ago', math.floor(d / 60)) end
    if d < 86400 then return string.format('%d h ago', math.floor(d / 3600)) end
    return os.date('%Y-%m-%d %H:%M', t)
end

-- Last check time, errors and what the last check found.
local function drawStatus()
    local colors = core.colors or {}
    local GOOD  = colors.GOOD or { 0.40, 0.85, 0.50, 1.0 }
    local ERR   = colors.ERR or { 0.95, 0.40, 0.40, 1.0 }
    ImGui.Dummy(0, core.px(4))
    ImGui.TextDisabled('Last check: ' .. fmtAgo(st.lastCheckedAt or cfg.lastCheckAt))
    if st.lastDurationMs then
        ImGui.SameLine()
        ImGui.TextDisabled(string.format('(%.0f ms)', st.lastDurationMs))
    end
    if st.unavailable then
        ImGui.TextColored(ERR[1], ERR[2], ERR[3], ERR[4], 'Update check unavailable: ' .. st.unavailable)
    elseif st.lastError then
        ImGui.PushTextWrapPos(0)
        ImGui.TextColored(ERR[1], ERR[2], ERR[3], ERR[4], 'Last error: ' .. st.lastError)
        ImGui.PopTextWrapPos()
    end
    local r = st.result
    if st.installed then
        ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], string.format('Installed %s. Restart MoriAC to load it.', st.installed.version))
    elseif r then
        if #r.changed > 0 then
            ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], string.format('Update available: %s (%d files changed)', r.version, #r.changed))
        else
            ImGui.TextColored(GOOD[1], GOOD[2], GOOD[3], GOOD[4], string.format('Your files match the latest version (%s).', r.version))
        end
    elseif cfg.lastVersion then
        ImGui.TextDisabled('Latest version seen: ' .. cfg.lastVersion)
    end
end

function plugin.onDrawSettings()
    if not core then return end
    local colors = core.colors or {}
    local GOLD  = colors.GOLD or { 1.0, 0.70, 0.54, 1 }
    core.accent(GOLD, 'Updater')
    ImGui.TextDisabled('Source: github.com/' .. REPO .. '  (lua/ and config/; config/ingame.cfg is left alone)')
    ImGui.Dummy(0, core.px(4))

    if not busy() then
        if ImGui.Button('Check and Install##updGet', core.px(150), core.px(28)) then checkAndInstall() end
        if ImGui.IsItemHovered() then
            core.setTooltip('Checks GitHub and, if any MoriAC files changed, downloads and installs them right away.\nRestart MoriAC afterwards to load them. Same as /ac update get.')
        end
        ImGui.SameLine()
        if ImGui.Button('Check Now##updNow', core.px(120), core.px(28)) then
            st.unavailable = nil
            startCheck(true)
        end
        if ImGui.IsItemHovered() then core.setTooltip('Only checks; installing stays your call.') end
        ImGui.SameLine()
        if st.result and ImGui.Button('Show Notice##updShow', core.px(120), core.px(28)) then
            st.noticeOpen = true
        end
    end
    drawActions('s')
    drawStatus()

    ImGui.Dummy(0, core.px(6))
    ImGui.Separator()
    ImGui.Dummy(0, core.px(2))
    local autoVal = ImGui.Checkbox('Check for updates automatically##updAuto', cfg.autoCheck)
    if autoVal ~= cfg.autoCheck then cfg.autoCheck = autoVal; saveSettings() end
    if ImGui.IsItemHovered() then
        core.setTooltip(string.format('Runs one check %d s after MoriAC loads (per character), with the frequency below. Installing is always your call.', STARTUP_DELAY_S))
    end

    local curIdx = 1
    for i, f in ipairs(FREQUENCIES) do if f == cfg.frequency then curIdx = i end end
    local labels = {}
    for i, f in ipairs(FREQUENCIES) do labels[i] = FREQUENCY_LABEL[f] end
    ImGui.SetNextItemWidth(core.px(200))
    local newIdx = ImGui.Combo('Frequency##updFreq', curIdx, labels)
    if newIdx ~= curIdx and FREQUENCIES[newIdx] then cfg.frequency = FREQUENCIES[newIdx]; saveSettings() end

    local popVal = ImGui.Checkbox('Open a popup when an update is found##updPopup', cfg.popup)
    if popVal ~= cfg.popup then cfg.popup = popVal; saveSettings() end
    if ImGui.IsItemHovered() then core.setTooltip('Off: only the chat notice.') end

    if cfg.skipVersion then
        ImGui.TextDisabled('Skipping: ' .. cfg.skipVersion)
        ImGui.SameLine()
        if ImGui.SmallButton('Unskip##updUnskip') then
            cfg.skipVersion = nil
            saveSettings()
        end
    end
end

-- /ac update [now|get|install|show|skip|unskip|auto on|off]
function plugin.onCommand(cmd, args)
    if cmd ~= 'update' and cmd ~= 'checkupdate' and cmd ~= 'updater' then return false end
    local sub = args and args[2] and tostring(args[2]):lower() or 'now'
    if sub == 'now' or sub == 'check' then
        st.unavailable = nil
        startCheck(true)
    elseif sub == 'get' or sub == 'all' then
        checkAndInstall()
    elseif sub == 'install' or sub == 'apply' then
        startInstall()
    elseif sub == 'show' then
        if st.result then st.noticeOpen = true else chat('No check result yet. /ac update to check now.') end
    elseif sub == 'skip' then
        local v = (st.result and st.result.version) or cfg.lastVersion
        if v then
            cfg.skipVersion = v
            st.noticeOpen = false
            saveSettings()
            chat('Skipping %s. /ac update unskip to be reminded again.', v)
        else
            chat('No version known yet to skip.')
        end
    elseif sub == 'unskip' then
        cfg.skipVersion = nil
        saveSettings()
        chat('Version skip cleared.')
    elseif sub == 'auto' then
        local v = args and args[3] and tostring(args[3]):lower() or nil
        if v == 'on' or v == 'off' then
            cfg.autoCheck = (v == 'on')
            saveSettings()
        end
        chat('Automatic update check is %s (%s).', cfg.autoCheck and 'ON' or 'OFF', FREQUENCY_LABEL[cfg.frequency] or cfg.frequency)
    elseif sub == 'link' then
        chat('MoriAC on GitHub: %s', REPO_URL)
    else
        chat('usage: /ac update [now|get|install|show|skip|unskip|auto on|off]')
    end
    return true
end

plugin.help = {
    '  \ag/ac update [now|get|install|show|skip|unskip|auto on|off]\ax - Check GitHub for changed MoriAC files, and install them (non-blocking); get = check and install in one go',
}

-- Exposed for tests
plugin.parseVersion    = parseVersion
plugin.compareVersions = compareVersions
plugin.crc32Lua        = crc32Lua
plugin.relPathOk       = relPathOk
plugin.parseManifest   = parseManifest
plugin.planChanges     = planChanges
plugin.applyFiles      = applyFiles
plugin.summarizeNotes  = summarizeNotes
plugin._cfg            = cfg
plugin._state          = st
plugin.checkAndInstall = checkAndInstall

return plugin
