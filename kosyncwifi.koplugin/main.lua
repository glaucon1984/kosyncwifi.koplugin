--[[--
Progress sync: Wi-Fi on demand.

Companion plugin for KOReader's built-in Progress sync plugin (kosync). It
drives KOSync's push / pull at the moments that matter (book open, book close,
device wake-up, device sleep) and brings Wi-Fi up only for the duration of the
sync, silently, through the same background script KOReader uses for
"Auto restore Wi-Fi". Afterwards Wi-Fi goes off again, unless it was already on
before the sync started.

On sleep the plugin pushes the actual suspend out by a configurable budget so
the push can complete, then lets the device sleep immediately. Kobo's own
suspend path kills Wi-Fi regardless, so a stuck connection can never block
sleep.

KOSync's own "Automatic sync" must stay off (this plugin switches it off when
it finds it on); KOSync still does the actual talking to the server, keeps the
account and the forward/backward prompt settings, and owns the offline queue.

@module koplugin.kosyncwifi
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local DEFAULTS = {
    enabled = true,
    on_open = true,
    on_close = true,
    on_resume = true,
    on_suspend = true,
    wifi_off_after = true,
    -- Seconds we give the Wi-Fi to come up (including DHCP) before giving up.
    -- NetworkMgr's own connectivity check aborts at 45s, so stay below that.
    connect_timeout = 35,
    -- "silent": restore-wifi-async.sh + connectivity check (no UI at all).
    -- "standard": NetworkMgr:enableWifi (non-interactive, shows KOReader's small
    -- "Scanning…" / "Connected to network" messages).
    method = "silent",
    -- Pop-up after a push went out (never for pulls, "in sync" or "ahead").
    notify = true,
    -- Also draw it on the sleep screen after the sleep push (cleared on wake).
    notify_on_sleep_screen = true,
    -- Where the sleep-screen box goes: "bottom", "bottom_left", "bottom_right".
    sleep_box_position = "bottom",
}

-- Extra seconds on top of connect_timeout that the suspend is pushed out by,
-- to leave room for the push itself and the Wi-Fi teardown.
local SUSPEND_MARGIN = 15

local RESTORE_SCRIPT = "restore-wifi-async.sh"

-- The small box near the bottom edge (defined with the sleep-screen code).
local SleepBox

-- ---------------------------------------------------------------------------
-- KOSync access helpers
-- ---------------------------------------------------------------------------

-- Credentials and plugin path, readable without a live KOSync instance (file
-- manager, or after the reader closed). Returns nil when KOSync isn't set up.
local function loadKOSyncCreds()
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    local s = settings:readSetting("settings") or {}
    if not s.username or not s.userkey then
        return nil
    end
    local client_file = package.searchpath("KOSyncClient", package.path)
    if not client_file then
        return nil
    end
    return {
        custom_server = s.custom_server,
        username = s.username,
        userkey = s.userkey,
        path = client_file:gsub("[/\\][^/\\]+$", ""),
    }
end

local function getQueue()
    local ok, KOSyncQueue = pcall(require, "KOSyncQueue")
    if ok then return KOSyncQueue end
end

local function queueCount()
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return 0 end
    local ok, n = pcall(KOSyncQueue.count, KOSyncQueue)
    return ok and n or 0
end

-- Snapshot used to tell whether a push ended up in the queue instead.
local function queueSignature()
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return { count = 0 } end
    local ok, q = pcall(KOSyncQueue.load, KOSyncQueue)
    if not ok or type(q) ~= "table" then return { count = 0 } end
    local last = q[#q]
    return { count = #q, last = last and last.queued_at }
end

local function newClient(creds)
    local KOSyncClient = require("KOSyncClient")
    return KOSyncClient:new{
        custom_url = creds.custom_server,
        service_spec = creds.path .. "/api.json",
    }
end

-- Ask the server for a document's progress. Returns "ok", body on success,
-- "none" when the server has nothing (or refused), nil when it couldn't be
-- reached at all.
local function fetchServerProgress(client, creds, document)
    local server_ok, server
    local called = pcall(client.get_progress, client, creds.username, creds.userkey, document,
        function(ok, body) server_ok = ok; server = body end)
    if not called or server_ok == nil then
        return nil
    end
    if server_ok and type(server) == "table" then
        return "ok", server
    end
    return "none"
end

local function samePosition(a_progress, a_percentage, b_progress, b_percentage)
    if a_progress and b_progress and a_progress == b_progress then
        return true
    end
    if a_percentage and b_percentage and math.abs(a_percentage - b_percentage) < 0.00005 then
        return true
    end
    return false
end

-- Decide whether a position read here at `read_at` (0 = nothing was read
-- here) should be pushed over what the server holds. Returns true to push,
-- or false plus a reason.
local function shouldPush(server, our_device_id, progress, percentage, read_at)
    if samePosition(progress, percentage, server.progress, server.percentage) then
        return false, _("in sync")
    end
    if server.device_id ~= our_device_id and server.timestamp then
        if not read_at or read_at == 0 or server.timestamp > read_at then
            return false, T(_("%1 is ahead"), server.device or _("another device"))
        end
    end
    return true
end

-- Send everything in KOSync's offline queue. Self-contained so it can run from
-- a scheduled task after the reader (and its KOSync instance) is gone.
-- A queued position is dropped, not sent, when the server already has it, or
-- when another device has pushed a newer one since this one was read here:
-- the queue must never undo reading done elsewhere in the meantime.
-- Returns sent, dropped; or nil if the queue module is unavailable.
local function drainQueue(creds)
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return nil end
    if KOSyncQueue:count() == 0 then return 0, 0 end
    creds = creds or loadKOSyncCreds()
    if not creds then return 0, 0 end
    local client = newClient(creds)
    local dropped = 0
    local titles = {}
    local sent = KOSyncQueue:drain(function(item)
        -- Items queued by KOSync itself carry no reading time; they come from
        -- a push we had already vetted, so their queue time stands in for it.
        local read_at = item.last_page_turn
        if read_at == nil then read_at = item.queued_at end
        local state, server = fetchServerProgress(client, creds, item.document)
        if state == nil then
            -- Couldn't ask the server: keep the item for later.
            return false
        end
        if state == "ok" then
            local push, reason = shouldPush(server, item.device_id, item.progress, item.percentage, read_at)
            if not push then
                logger.info("KOSyncWiFi: dropping a queued position for", item.document, "-", reason)
                dropped = dropped + 1
                return true
            end
        end
        -- Same success criterion as KOSync:drainQueue (the call went through).
        local ok = pcall(client.update_progress,
            client,
            creds.username,
            creds.userkey,
            item.document,
            item.metadata,
            item.progress,
            item.percentage,
            item.device,
            item.device_id,
            function() end)
        if ok then
            table.insert(titles, item.metadata and item.metadata.title or item.document)
        end
        return ok
    end)
    return sent - dropped, dropped, titles
end

-- "Vestigios" / "Vestigios, Silo (2 books)" for a pop-up about queued sends.
local function titlesText(titles)
    if #titles == 0 then return "" end
    if #titles == 1 then return titles[1] end
    return T(_("%1 (%2 books)"), table.concat(titles, ", "), #titles)
end

-- ---------------------------------------------------------------------------
-- Process helpers (the restore script runs from the onboard partition and
-- other plugins use it too, so we need to see it and, if orphaned, stop it).
-- ---------------------------------------------------------------------------

-- pid of the first process whose command line passes test(cmdline, pid), or nil.
local function findProcess(test)
    local ok, res = pcall(function()
        for pid in lfs.dir("/proc") do
            if pid:match("^%d+$") then
                local f = io.open("/proc/" .. pid .. "/cmdline", "rb")
                if f then
                    local cmdline = f:read("*a") or ""
                    f:close()
                    if test(cmdline, tonumber(pid)) then
                        return tonumber(pid)
                    end
                end
            end
        end
    end)
    if ok then return res end
end

-- Every running process as { pid, cmdline } (arguments NUL-separated).
local function listProcesses()
    local list = {}
    findProcess(function(cmdline, pid) table.insert(list, { pid = pid, cmdline = cmdline }) end)
    return list
end

-- Program name of a command line (argv[0] without its directory).
local function programOf(cmdline)
    return (cmdline:match("^[^%z]*") or ""):match("[^/]*$")
end

-- What changes the radio's state while it runs: KOReader's Wi-Fi scripts,
-- MediaTek's chip loader, module insertion.
local RADIO_SCRIPTS = { "restore-wifi-async.sh", "enable-wifi.sh", "disable-wifi.sh", "obtain-ip.sh" }
local RADIO_PROGRAMS = { wmt_loader = true, insmod = true }

-- The first of those found in `processes`, as text for the log, or nil. With
-- radio_down, Kobo's Bluetooth daemon counts as well (but only if nothing
-- else does): contacted while the radio is not started, it starts it itself.
local function findRadioWork(processes, radio_down)
    local bt_service
    for _, p in ipairs(processes) do
        local program = programOf(p.cmdline)
        local args = p.cmdline:gsub("%z", " ")
        for _, script in ipairs(RADIO_SCRIPTS) do
            if args:find(script, 1, true) then
                return script
            end
        end
        if RADIO_PROGRAMS[program] then
            return program
        end
        if radio_down and program == "mtkbtd" then
            bt_service = program
        end
    end
    return bt_service
end

-- pid of a running restore-wifi-async.sh, or nil.
local function findScript()
    return findProcess(function(cmdline) return cmdline:find(RESTORE_SCRIPT, 1, true) end)
end

-- MediaTek's firmware daemon, by program name (Nickel, the Bluetooth daemon
-- and kobo.koplugin all start it, not necessarily by the same path).
local function isLauncherRunning()
    return findProcess(function(cmdline) return programOf(cmdline) == "wmt_launcher" end) ~= nil
end

local function killScript(pid)
    pid = pid or findScript()
    if pid then
        logger.warn("KOSyncWiFi: stopping " .. RESTORE_SCRIPT .. " (pid " .. pid .. ")")
        os.execute("kill -TERM " .. pid .. " 2>/dev/null")
    end
end

-- ---------------------------------------------------------------------------
-- Link: one shared "bring Wi-Fi up, run work, bring it down" job.
-- Module-level on purpose: the reader and the file manager each get their own
-- plugin instance, and a close-time job must outlive the reader instance.
-- ---------------------------------------------------------------------------

local Link = {
    job = nil,
    last = nil, -- { kind, ok, when, detail }
    shutting_down = false,
    findScript = findScript, -- replaceable for tests
    killScript = killScript,
    isLauncherRunning = isLauncherRunning,
    listProcesses = listProcesses,
}

-- ---------------------------------------------------------------------------
-- Radio start-up (MTK Kobos). When nothing has started MediaTek's radio since
-- boot (see Link.radioState), it is started here the way Nickel does it:
-- first driver module, chip loader (detects the chip, inserts the other
-- modules), firmware daemon, then the chip handshake. Without the first three,
-- the handshake in KOReader's enable-wifi.sh panics the kernel. kobo.koplugin
-- (0.4.1-touch.9 or later) runs the same sequence before Bluetooth.
--
-- It runs as one blocking step on KOReader's UI thread, about 5 s. That is on
-- purpose: kobo.koplugin decides on the same thread whether it has to start
-- the radio itself, so a Bluetooth tap meanwhile is only handled once the
-- radio is up and never leads to a second start-up in parallel. Every
-- external step has a time limit, so a hung one cannot freeze KOReader long.
-- ---------------------------------------------------------------------------

local Radio = {
    MODULES = { "wmt_drv", "wmt_chrdev_wifi", "wmt_cdev_bt", "wlan_drv_gen4m" },
    LOADER = "/usr/bin/wmt_loader",
    LAUNCHER = "/usr/bin/wmt_launcher",
    FIRMWARE_DIR = "/lib/firmware",
    DEBUG_FILE = "/proc/driver/wmt_dbg",
    WIFI_CONTROL = "/dev/wmtWifi",
    -- The handshake of enable-wifi.sh's "wmt" branch; a number is a pause.
    HANDSHAKE = { "0xDB9DB9", "7 9 0", 1, "0xDB9DB9", "7 9 1" },
    MODULE_SETTLE = 0.25,
    LAUNCHER_SETTLE = 3,
    STEP_LIMIT = 10,  -- seconds for one insmod or the chip loader
    WRITE_LIMIT = 5,  -- seconds for one handshake write ("7 9 1" takes ~1.3 s)
    TOTAL_LIMIT = 20, -- seconds for the whole start-up (normally about 5)
    POLL = 0.05,
    STATUS_FILE = "/tmp/kosyncwifi-radio-step",
}

-- ffi/util's sleep() is C's sleep(): whole seconds only.
function Radio.sleep(seconds)
    require("ffi/util").usleep(math.floor(seconds * 1000000))
end

local function shellQuote(s)
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Runs a shell command in its own session (working directory /, off the
-- onboard partition) and waits for it, at most `limit` seconds. Returns true
-- and its exit status, or false if it was still running at the limit; it is
-- then killed together with anything it started.
function Radio.run(command, limit)
    os.remove(Radio.STATUS_FILE)
    local script = command .. "; echo $? >" .. Radio.STATUS_FILE
    local starter = io.popen("cd / && setsid sh -c " .. shellQuote(script) .. " >/dev/null 2>&1 </dev/null & echo $!")
    local pid = starter and tonumber(starter:read("*l") or "")
    if starter then starter:close() end
    if not pid then
        return false
    end
    for _ = 1, math.ceil(limit / Radio.POLL) do
        local f = io.open(Radio.STATUS_FILE, "r")
        if f then
            local status = tonumber(f:read("*l") or "")
            f:close()
            if status then
                return true, status
            end
        end
        Radio.sleep(Radio.POLL)
    end
    os.execute("kill -9 -" .. pid .. " 2>/dev/null")
    return false
end

-- Names of the loaded kernel modules, as a set.
function Radio.loadedModules()
    local loaded = {}
    local f = io.open("/proc/modules", "r")
    if f then
        for line in f:lines() do
            local name = line:match("^(%S+)")
            if name then loaded[name] = true end
        end
        f:close()
    end
    return loaded
end

-- Starts the firmware daemon detached: own session, off the onboard
-- partition, no inherited streams, so it never blocks USB mass storage.
function Radio.startLauncher()
    os.execute(string.format("cd /tmp && setsid %s -p %s >/dev/null 2>&1 </dev/null &",
        Radio.LAUNCHER, Radio.FIRMWARE_DIR))
end

-- The whole start-up, logged step by step. Stops at the first step that
-- fails or runs over its limit, and never reaches the handshake unless all
-- modules are loaded and the firmware daemon runs. Returns true once the
-- radio is up and its Wi-Fi function on.
function Radio.start()
    local started = os.time()
    local dir = "/drivers/" .. (os.getenv("PLATFORM") or "") .. "/mt66xx"
    logger.info("KOSyncWiFi: starting the radio, nothing has since boot")

    -- informational_status: the exit status is only logged, not a failure.
    local function step(what, command, limit, informational_status)
        if os.time() - started > Radio.TOTAL_LIMIT then
            logger.warn("KOSyncWiFi: radio start-up: over", Radio.TOTAL_LIMIT, "s, not running", what)
            return false
        end
        local done, status = Radio.run(command, limit)
        if not done then
            logger.warn("KOSyncWiFi: radio start-up:", what, "still running after", limit, "s, stopped it")
        elseif informational_status then
            logger.info("KOSyncWiFi: radio start-up:", what, "exited with", status)
        elseif status ~= 0 then
            logger.warn("KOSyncWiFi: radio start-up:", what, "exited with", status)
        end
        return done, status
    end
    local function insert(name)
        local done, status = step("insmod " .. name, string.format("insmod %s/%s.ko", dir, name), Radio.STEP_LIMIT)
        Radio.sleep(Radio.MODULE_SETTLE)
        return done and status == 0
    end

    if not Radio.loadedModules()[Radio.MODULES[1]] and not insert(Radio.MODULES[1]) then
        return false
    end
    -- The loader exits with 255 on a Clara BW even when it loaded everything,
    -- so only a time-out stops here; the module list decides below.
    if not step("the chip loader", Radio.LOADER .. " >/dev/null 2>&1", Radio.STEP_LIMIT, true) then
        return false
    end
    for i = 2, #Radio.MODULES do
        if not Radio.loadedModules()[Radio.MODULES[i]] then
            insert(Radio.MODULES[i])
        end
    end
    local loaded = Radio.loadedModules()
    for _, name in ipairs(Radio.MODULES) do
        if not loaded[name] then
            logger.warn("KOSyncWiFi: radio start-up: module", name, "is not loaded, stopping before the handshake")
            return false
        end
    end

    if not Link.isLauncherRunning() then
        Radio.startLauncher()
        Radio.sleep(Radio.LAUNCHER_SETTLE)
        if not Link.isLauncherRunning() then
            logger.warn("KOSyncWiFi: radio start-up: the firmware daemon did not start, stopping before the handshake")
            return false
        end
    end

    for _, value in ipairs(Radio.HANDSHAKE) do
        if type(value) == "number" then
            Radio.sleep(value)
        else
            local written, write_status = step("handshake write " .. value,
                string.format("echo '%s' >%s", value, Radio.DEBUG_FILE), Radio.WRITE_LIMIT)
            if not written or write_status ~= 0 then
                return false
            end
        end
    end
    local on, on_status = step("Wi-Fi function on", "echo 1 >" .. Radio.WIFI_CONTROL, Radio.WRITE_LIMIT)
    if not on or on_status ~= 0 then
        return false
    end
    logger.info("KOSyncWiFi: radio started in about", os.time() - started, "s")
    return true
end

function Link.isUp()
    return NetworkMgr:isWifiOn() and NetworkMgr:isConnected()
end

function Link.setLast(kind, ok, detail)
    Link.last = { kind = kind, ok = ok, when = os.time(), detail = detail }
end

local function restoreWifiWasOn(job)
    NetworkMgr.wifi_was_on = job.prior_wifi_was_on
    G_reader_settings:saveSetting("wifi_was_on", job.prior_wifi_was_on)
end

-- Runs every registered on_connected(ok) then every on_finished(ok).
function Link._complete(job, ok)
    if Link.job == job then
        Link.job = nil
    end
    if job.timeout_task then
        UIManager:unschedule(job.timeout_task)
    end
    UIManager:unschedule(Link._launch)
    UIManager:unschedule(Link._waitReady)

    local keep = false
    if ok then
        for _, entry in ipairs(job.entries) do
            if entry.on_connected then
                local call_ok, res = pcall(entry.on_connected, true)
                if not call_ok then
                    logger.err("KOSyncWiFi: on_connected failed:", res)
                elseif res == true then
                    keep = true
                end
            end
        end
    end

    -- Tear Wi-Fi down if we were the ones who brought it up. A job that only
    -- ever waited started nothing: running disable-wifi.sh then would write to
    -- the radio while the Bluetooth plugin may still be bringing it up.
    if job.we_turned_it_on and job.launched then
        if not ok then
            -- Failed attempt: make sure nothing is left half-up or half-running.
            logger.info("KOSyncWiFi: cleaning up the failed Wi-Fi attempt")
            NetworkMgr:unscheduleConnectivityCheck()
            Link.killScript()
            NetworkMgr:disableWifi()
            restoreWifiWasOn(job)
        elseif not keep and job.settings.wifi_off_after then
            logger.info("KOSyncWiFi: turning Wi-Fi off")
            NetworkMgr:disableWifi()
            -- The connectivity check flags wifi_was_on; keep the user's prior
            -- state so "Auto restore Wi-Fi" / startup restore aren't affected.
            restoreWifiWasOn(job)
        end
    end

    if not ok then
        for _, entry in ipairs(job.entries) do
            if entry.on_connected then
                local call_ok, err = pcall(entry.on_connected, false, job.failure)
                if not call_ok then
                    logger.err("KOSyncWiFi: on_connected failed:", err)
                end
            end
        end
    end
    for _, entry in ipairs(job.entries) do
        if entry.on_finished then
            local call_ok, err = pcall(entry.on_finished, ok)
            if not call_ok then
                logger.err("KOSyncWiFi: on_finished failed:", err)
            end
        end
    end
end

function Link._onTimeout()
    local job = Link.job
    if not job then return end
    logger.warn("KOSyncWiFi: Wi-Fi did not come up within", job.settings.connect_timeout, "s")
    Link._complete(job, false)
end

-- NetworkMgr says "connected" as soon as the interface has *an* address, which
-- includes the IPv6 link-local one that appears before DHCP. Wait until the
-- restore script is done and there is a default route before doing any work.
function Link._waitReady(job)
    if Link.job ~= job then return end
    if Link.findScript() then
        UIManager:scheduleIn(0.5, Link._waitReady, job)
        return
    end
    if not NetworkMgr:isWifiOn() then
        logger.warn("KOSyncWiFi: Wi-Fi went down while connecting")
        Link._complete(job, false)
        return
    end
    if not NetworkMgr:hasDefaultRoute() then
        UIManager:scheduleIn(0.5, Link._waitReady, job)
        return
    end
    logger.info("KOSyncWiFi: Wi-Fi is up after", os.time() - job.started, "s")
    Link._complete(job, true)
end

function Link._onConnected()
    local job = Link.job
    if not job then return end -- stale connectivity callback
    Link._waitReady(job)
end

-- True while the Bluetooth plugin (kobo.koplugin >= 0.4.1-touch.6) has the
-- Wi-Fi function powered for its own chip start-up; it broadcasts
-- BluetoothWifiReleased when it lets go. Only consulted if that module is
-- already loaded, so a disabled plugin is never pulled in.
local function bluetoothHasWifi()
    local kb = package.loaded["src/kobo_bluetooth"]
    return type(kb) == "table" and kb.wifi_borrowed == true
end

-- MTK Kobos (Clara BW / Colour, Libra Colour): KOReader's enable-wifi.sh only
-- inserts the radio modules and runs the chip handshake. It relies on Nickel
-- having run MediaTek's chip detection (wmt_loader) and firmware daemon
-- (wmt_launcher) earlier in the boot. On a boot where Nickel never used Wi-Fi
-- or Bluetooth nothing has, and the handshake panics the kernel (Clara BW,
-- KOReader v2026.07.2). kobo.koplugin (0.4.1-touch.9 or later) starts the
-- radio the way Nickel does when it turns Bluetooth on, and leaves a marker
-- in /tmp. If nobody has, this plugin starts it itself (Radio.start).
local WMT_STACK_READY_MARKER = "/tmp/kobo.koplugin-wmt-stack-ready"
local WMT_BT_DEVICE = "/dev/stpbt"

-- How long Kobo's Bluetooth daemon, seen running while the radio is not
-- started, is given to start it before this plugin does.
local BT_SERVICE_WAIT = 10

local function isMTK()
    return Device.isKobo ~= nil and Device:isKobo() and Device.isMTK ~= nil and Device:isMTK() or false
end

-- "ready", "coming" (the Bluetooth plugin holds the Wi-Fi function or is
-- starting the radio: wait for it) or "missing" (nothing has started the
-- radio since boot). The plugin's own check is used when it is loaded; it is
-- internal to that plugin, so the same rule is applied here when it is not:
-- its marker, or the device node plus a running firmware daemon. The node
-- alone means nothing: it appears as soon as the modules are inserted, before
-- the chip is detected.
function Link.radioState()
    if bluetoothHasWifi() then
        return "coming"
    end
    if not isMTK() then
        return "ready"
    end
    local wmt = package.loaded["src/lib/bluetooth/wmt_power"]
    if type(wmt) == "table" then
        if wmt.bringing_up == true then
            return "coming"
        end
        if type(wmt.isStackLoaded) == "function" then
            local ok, loaded = pcall(wmt.isStackLoaded)
            if ok then
                return loaded and "ready" or "missing"
            end
        end
    end
    if lfs.attributes(WMT_STACK_READY_MARKER, "mode") then
        return "ready"
    end
    if lfs.attributes(WMT_BT_DEVICE, "mode") and Link.isLauncherRunning() then
        return "ready"
    end
    return "missing"
end

-- What else is working on the radio for this job right now (see
-- findRadioWork), or nil. Kobo's Bluetooth daemon only counts while the radio
-- is down, and only for BT_SERVICE_WAIT seconds: if it has not started the
-- radio by then, it is not going to.
function Link.radioWork(job, radio_down)
    local work = findRadioWork(Link.listProcesses(), radio_down)
    if work == "mtkbtd" then
        job.bt_service_seen = job.bt_service_seen or os.time()
        if os.time() - job.bt_service_seen > BT_SERVICE_WAIT then
            return nil
        end
    end
    return work
end

-- Radio.start with a box near the bottom edge saying why KOReader pauses (not
-- on the sleep screen). Returns whether the radio is up.
function Link.startRadio(job)
    local box
    if not Device.screen_saver_mode then
        box = SleepBox:new{ text = _("Starting the radio for progress sync…"), position = job.settings.sleep_box_position }
        UIManager:show(box)
        UIManager:forceRePaint()
    end
    local ok = Radio.start()
    if box then
        UIManager:close(box)
    end
    return ok
end

-- Starts the connection, once nothing else is working on the radio: KOReader's
-- own Wi-Fi scripts ("Auto restore Wi-Fi" at wake, its Wi-Fi menu), MediaTek's
-- loader, the Bluetooth plugin holding the Wi-Fi function (a couple of seconds
-- after a wake, about 13 s on a boot where it starts the radio). If nothing has
-- started the radio since boot and nothing is about to, starts it first.
function Link._launch(job)
    if Link.job ~= job then return end

    if Link.isUp() then
        -- Someone else got us connected in the meantime.
        job.we_turned_it_on = false
        Link._waitReady(job)
        return
    end

    local radio = Link.radioState()
    local other = Link.findScript() and RESTORE_SCRIPT or Link.radioWork(job, radio ~= "ready")
    if other or radio == "coming" then
        other = other or "kobo.koplugin"
        if job.waiting_for ~= other then
            logger.info("KOSyncWiFi: waiting for", other, "to finish with the radio")
            job.waiting_for = other
        end
        UIManager:scheduleIn(1, Link._launch, job)
        return
    end
    if radio == "missing" and not Link.startRadio(job) then
        job.failure = "radio"
        Link._complete(job, false)
        return
    end
    job.launched = true

    local method = job.settings.method
    if method == "silent" and not (Device:hasWifiRestore() and NetworkMgr.restoreWifiAsync) then
        method = "standard"
    end
    logger.info("KOSyncWiFi: bringing Wi-Fi up (" .. method .. ")")

    if method == "silent" then
        if NetworkMgr.pending_connection then
            -- Somebody else is already connecting; just wait for it.
            job.we_turned_it_on = false
        else
            NetworkMgr.pending_connection = true
            UIManager:broadcastEvent(Event:new("NetworkConnecting"))
            NetworkMgr:restoreWifiAsync()
        end
        if NetworkMgr.pending_connectivity_check then
            NetworkMgr:unscheduleConnectivityCheck()
        end
        NetworkMgr:scheduleConnectivityCheck(Link._onConnected)
    else
        local status = NetworkMgr:enableWifi(Link._onConnected, false)
        if status == false then
            Link._complete(job, false)
            return
        elseif status == nil then
            -- EBUSY: a connection attempt by someone else is in flight and our
            -- callback was dropped; poll for it ourselves.
            job.we_turned_it_on = false
            if NetworkMgr.pending_connectivity_check then
                NetworkMgr:unscheduleConnectivityCheck()
            end
            NetworkMgr:scheduleConnectivityCheck(Link._onConnected)
        end
    end
end

-- Request network for some work.
-- on_connected(ok): runs once Wi-Fi is connected (ok=true) or when the attempt
--   failed (ok=false); return true to leave Wi-Fi on afterwards.
-- on_finished(ok): runs after the teardown.
-- Requests made while a job is pending are attached to it.
function Link.request(settings, on_connected, on_finished)
    local entry = { on_connected = on_connected, on_finished = on_finished }

    if Link.job then
        logger.dbg("KOSyncWiFi: attaching to the pending Wi-Fi job")
        table.insert(Link.job.entries, entry)
        return
    end

    local job = {
        entries = { entry },
        we_turned_it_on = true,
        settings = settings,
        started = os.time(),
        prior_wifi_was_on = NetworkMgr.wifi_was_on,
    }

    if Link.isUp() and not Link.findScript() then
        -- Already connected, and not by us: just run the work, leave Wi-Fi alone.
        job.we_turned_it_on = false
        Link._complete(job, true)
        return
    end

    if Link.shutting_down then
        logger.info("KOSyncWiFi: not starting Wi-Fi, KOReader is closing")
        job.we_turned_it_on = false
        Link._complete(job, false)
        return
    end

    Link.job = job
    job.timeout_task = function() Link._onTimeout() end
    UIManager:scheduleIn(settings.connect_timeout, job.timeout_task)
    Link._launch(job)
end

-- KOReader is about to quit (USB storage, power off, reboot, exit, restart):
-- never leave a Wi-Fi script running from the onboard partition.
function Link.shutdown()
    Link.shutting_down = true
    local job = Link.job
    if job then
        logger.info("KOSyncWiFi: aborting the Wi-Fi job, KOReader is closing")
        Link._complete(job, false)
        if not job.launched then
            -- It was waiting for someone else's restore script, which blocks
            -- the USB export just the same.
            Link.killScript()
        end
    end
end

-- ---------------------------------------------------------------------------
-- The plugin
-- ---------------------------------------------------------------------------

local KOSyncWiFi = WidgetContainer:extend{
    name = "kosyncwifi",
    is_doc_only = false,
}
KOSyncWiFi._Link = Link -- for tests
KOSyncWiFi._Radio = Radio

function KOSyncWiFi:init()
    local s = G_reader_settings:readSetting("kosyncwifi") or {}
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    self.settings = s
    G_reader_settings:saveSetting("kosyncwifi", s)

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KOSyncWiFi:saveSettings()
    G_reader_settings:saveSetting("kosyncwifi", self.settings)
end

function KOSyncWiFi:onDispatcherRegisterActions()
    Dispatcher:registerAction("kosyncwifi_sync_now", {
        category = "none",
        event = "KOSyncWiFiSyncNow",
        title = _("Sync now (Progress sync over Wi-Fi)"),
        general = true,
    })
end

-- Generic entry point other plugins can call (SimpleUI's quick-action picker
-- looks for a `launch` method on file-manager plugins): same as "Sync now".
function KOSyncWiFi:launch()
    return self:onKOSyncWiFiSyncNow()
end

function KOSyncWiFi:inReader()
    return self.ui and self.ui.document ~= nil
end

-- Live KOSync instance (reader only), when it is set up.
function KOSyncWiFi:getKOSync()
    local kosync = self.ui and self.ui.kosync
    if kosync and kosync.settings and kosync.settings.username and kosync.settings.userkey then
        return kosync
    end
end

-- Pop-up after a push went out. Independent of any plugin instance so it can
-- be scheduled from a closing reader.
local function showPushed(settings, text)
    if not settings.notify then return end
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function pushedText(summary)
    return T(_("Progress pushed (%1)."), summary)
end

-- Title of the open book, for pop-ups that may be read later, over another book.
function KOSyncWiFi:bookTitle(kosync)
    local meta = kosync and kosync.getMetadata and kosync:getMetadata()
    if meta and meta.title and meta.title ~= "" then return meta.title end
    local props = self.ui and self.ui.doc_props
    if props and props.display_title then return props.display_title end
    return _("this book")
end

-- ---- reading-time tracking --------------------------------------------------
-- KOSync only records page turns while its own automatic sync is on, so we
-- keep our own "last page turned in this book" time, persisted per book, and
-- feed it to KOSync too (its pull logic compares the server's timestamp
-- against it).

local LAST_TURN_KEY = "kosyncwifi_last_page_turn"

function KOSyncWiFi:getLastPageTurn()
    return self.last_page_turn or 0
end

function KOSyncWiFi:onPageUpdate(page)
    if page == nil or not self:inReader() then return end
    if self.last_page == page then return end
    self.last_page = page
    local now = os.time()
    self.last_page_turn = now
    local kosync = self:getKOSync()
    if kosync then
        kosync.last_page_turn_timestamp = now
    end
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(LAST_TURN_KEY, now)
    end
end

-- Push through KOSync, unless the server already has this position or
-- another device has read further since we last turned a page here.
-- Returns ok, summary part.
function KOSyncWiFi:pushNow(interactive)
    local kosync = self:getKOSync()
    if not kosync then return true, nil end
    local digest = kosync:getDocumentDigest()
    local progress, percentage = kosync:getLastProgress(), kosync:getLastPercent()
    local creds = loadKOSyncCreds()
    if digest and creds then
        local state, server = fetchServerProgress(newClient(creds), creds, digest)
        if state == "ok" then
            local push, reason = shouldPush(server, kosync.device_id, progress, percentage, self:getLastPageTurn())
            if not push then
                logger.info("KOSyncWiFi: not pushing:", reason)
                return true, T(_("not pushed: %1"), reason)
            end
        end
    end
    local before = queueSignature()
    -- Our events are the only pushes, so don't let KOSync's 25 s debounce
    -- swallow one.
    kosync.push_timestamp = 0
    kosync:updateProgress(false, interactive)
    local after = queueSignature()
    if after.count > before.count or (after.last and after.last ~= before.last) then
        return false, _("push failed, queued")
    end
    return true, _("pushed")
end

-- Pull through KOSync, unless the server's latest progress is this device's
-- own or already the current position. KOSync's own "coming from this
-- device" check compares the device *name* with the internal model name,
-- which fails as soon as a custom device name is set in its settings; it
-- then offers to "sync forward" to the position this device just pushed.
-- Returns a summary part and whether KOSync put a prompt on screen.
function KOSyncWiFi:pullNow()
    local kosync = self:getKOSync()
    if not kosync then return _("nothing to pull"), false end
    local digest = kosync:getDocumentDigest()
    local creds = loadKOSyncCreds()
    if digest and creds then
        local state, server = fetchServerProgress(newClient(creds), creds, digest)
        if state == "none" then
            return _("nothing on the server"), false
        elseif state == "ok" then
            if server.device_id == kosync.device_id then
                logger.info("KOSyncWiFi: not pulling: latest progress is this device's own")
                return _("latest is ours"), false
            end
            if samePosition(kosync:getLastProgress(), kosync:getLastPercent(), server.progress, server.percentage) then
                logger.info("KOSyncWiFi: not pulling: in sync")
                return _("in sync"), false
            end
        end
    end
    kosync.pull_timestamp = 0
    -- Silent mode keeps the forward/backward prompt instead of jumping
    -- blindly. If it put a prompt on screen, the caller must not cover it.
    local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    kosync:getProgress(false, false)
    local prompted = UIManager.getTopmostVisibleWidget ~= nil and UIManager:getTopmostVisibleWidget() ~= top
    return _("pulled"), prompted
end

-- The sync work itself, run while Wi-Fi is up. Returns a one-line summary,
-- whether everything went through, and whether anything was actually pushed.
function KOSyncWiFi:doSync(opts)
    local parts = {}
    local all_ok = true
    local pushed = false
    local prompt_shown = false
    local sent, dropped, titles = drainQueue()
    if sent and sent > 0 then
        table.insert(parts, T(_("queued sent: %1"), titlesText(titles)))
        pushed = true
    end
    if dropped and dropped > 0 then
        table.insert(parts, T(_("%1 queued dropped"), dropped))
    end
    if queueCount() > 0 then
        all_ok = false
    end
    local kosync = self:getKOSync()
    if kosync and self:inReader() then
        if opts.push then
            -- Always KOSync's silent mode: its interactive mode shows its own
            -- "Progress has been pushed." under ours.
            local ok, part = self:pushNow(false)
            if part then table.insert(parts, part) end
            if not ok then all_ok = false end
            if ok and part == _("pushed") then pushed = true end
        end
        if opts.pull then
            local part, prompted = self:pullNow()
            -- Right after our own push the server's latest is ours: not news.
            if not (pushed and part == _("latest is ours")) then
                table.insert(parts, part)
            end
            if prompted then prompt_shown = true end
        end
    end
    if #parts == 0 then
        return _("nothing to do"), true, false, prompt_shown
    end
    return table.concat(parts, ", "), all_ok, pushed, prompt_shown
end

-- Status-line reason for a sync that got no Wi-Fi (see Radio.start).
local function noWifiText(reason)
    if reason == "radio" then
        return _("radio did not start")
    end
    return _("no Wi-Fi")
end

-- What else can start the radio: the Bluetooth plugin, or Kobo's own
-- software before KOReader starts.
local function radioFailedMessage()
    if package.loaded["src/kobo_bluetooth"] ~= nil then
        return _("Could not start the radio for Wi-Fi. Turn Bluetooth on (that starts it too), then sync again.")
    end
    return _("Could not start the radio for Wi-Fi. Turn Wi-Fi on in Kobo's own software before starting KOReader, then sync again.")
end

-- Bring Wi-Fi up, sync, bring it down.
function KOSyncWiFi:runSync(kind, opts, on_finished)
    logger.info("KOSyncWiFi: sync requested:", kind)
    Link.request(self.settings, function(ok, reason)
        if not ok then
            Link.setLast(kind, false, noWifiText(reason))
            if opts.manual then
                local text = reason == "radio" and radioFailedMessage() or _("Could not connect to Wi-Fi.")
                UIManager:show(InfoMessage:new{ text = text, timeout = reason == "radio" and 6 or 3 })
            end
            return
        end
        local summary, all_ok, pushed, prompt_shown = self:doSync(opts)
        Link.setLast(kind, all_ok, summary)
        logger.info("KOSyncWiFi:", kind, "sync done:", summary)
        if opts.manual then
            -- One summary, and none at all when KOSync's "move to the new
            -- location?" prompt is already on screen.
            if not prompt_shown then
                UIManager:show(InfoMessage:new{ text = T(_("Progress sync: %1"), summary), timeout = 3 })
            end
        elseif pushed then
            showPushed(self.settings, pushedText(summary))
        end
    end, on_finished)
end

-- ---- events ---------------------------------------------------------------

function KOSyncWiFi:onReaderReady()
    if not self.settings.enabled then return end
    local kosync = self:getKOSync()
    if not kosync then return end

    if kosync.settings.auto_sync then
        -- Both of us hooking Suspend/Resume would fight; KOSync's own version
        -- also brings the "Connecting to Wi-Fi…" prompts with it.
        kosync:onKOSyncToggleAutoSync(false)
        UIManager:show(InfoMessage:new{
            text = _("Progress sync's own automatic sync has been switched off. Wi-Fi on demand sync handles it from now on."),
        })
    end

    -- Reading-time tracking for this book.
    self.last_page = self.ui.getCurrentPage and self.ui:getCurrentPage()
    local saved = self.ui.doc_settings and self.ui.doc_settings:readSetting(LAST_TURN_KEY)
    self.last_page_turn = tonumber(saved) or 0
    if (kosync.last_page_turn_timestamp or 0) == 0 then
        kosync.last_page_turn_timestamp = self.last_page_turn
    end

    if self.settings.on_open then
        UIManager:nextTick(function()
            self:runSync("open", { pull = true })
        end)
    end
end

function KOSyncWiFi:onCloseDocument()
    self.suspend_token = nil
    if not self.settings.enabled or not self.settings.on_close then return end
    local kosync = self:getKOSync()
    if not kosync then return end

    if Link.isUp() and not Link.findScript() then
        logger.info("KOSyncWiFi: sync requested: close (online)")
        local ok, part = self:pushNow(false)
        Link.setLast("close", ok, part or _("nothing to do"))
        if ok and part == _("pushed") then
            -- The file manager is about to be shown; put the pop-up above it.
            -- Name the book: if the next one is opened straight away, this
            -- fires above it, after the document load.
            local settings = self.settings
            local text = T(_("Progress pushed: %1."), self:bookTitle(kosync))
            UIManager:scheduleIn(0.5, function() showPushed(settings, text) end)
        end
        return
    end

    if self:getLastPageTurn() == 0 then
        logger.info("KOSyncWiFi: close: no page was turned in this book here, nothing to push")
        return
    end

    -- Offline: queue the position (KOSync's own format, plus the time the
    -- book was last read here), then send the queue in the background once
    -- Wi-Fi is up. Nothing below may touch `self`, the reader is going away.
    local digest = kosync:getDocumentDigest()
    if not digest then return end
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then
        logger.warn("KOSyncWiFi: no KOSyncQueue module, cannot defer the close push")
        return
    end
    KOSyncQueue:push({
        document = digest,
        metadata = kosync:getMetadata(),
        progress = kosync:getLastProgress(),
        percentage = kosync:getLastPercent(),
        device = kosync.settings.kosync_hostname or Device.model,
        device_id = kosync.device_id,
        last_page_turn = self:getLastPageTurn(),
    })
    if Link.shutting_down then
        logger.info("KOSyncWiFi: position queued, KOReader is closing")
        return
    end
    logger.info("KOSyncWiFi: sync requested: close (offline, queued)")

    local creds = loadKOSyncCreds()
    local settings = self.settings
    Link.request(settings, function(up, reason)
        if not up then
            Link.setLast("close", false, reason == "radio" and _("radio did not start, queued") or _("no Wi-Fi, queued"))
            return
        end
        local sent, dropped, titles = drainQueue(creds)
        sent, dropped, titles = sent or 0, dropped or 0, titles or {}
        local summary = sent > 0 and T(_("queued sent: %1"), titlesText(titles)) or T(_("%1 queued sent"), sent)
        if dropped > 0 then
            summary = summary .. ", " .. T(_("%1 queued dropped"), dropped)
        end
        Link.setLast("close", queueCount() == 0, summary)
        logger.info("KOSyncWiFi: close sync done:", summary)
        if sent > 0 then
            showPushed(settings, T(_("Progress pushed: %1 (queued)."), titlesText(titles)))
        end
    end)
end

-- Suspend: we run inside Device:_beforeSuspend(), i.e. after onPowerEvent has
-- already killed Wi-Fi and *before* it schedules the real suspend (15 s).
-- Defer one tick so our rescheduleSuspend wins, then do the work.
function KOSyncWiFi:onSuspend()
    if not self.settings.enabled or not self.settings.on_suspend then return end
    if not Device.rescheduleSuspend then return end
    local has_book = self:inReader() and self:getKOSync() ~= nil
    if not has_book and queueCount() == 0 then return end

    local token = {}
    self.suspend_token = token
    UIManager:nextTick(function()
        if self.suspend_token ~= token or not Device.screen_saver_mode then
            return -- woke up in between
        end
        local budget = self.settings.connect_timeout + SUSPEND_MARGIN
        logger.info("KOSyncWiFi: holding suspend for up to", budget, "s for the sleep sync")
        Device:rescheduleSuspend(budget)

        Link.request(self.settings, function(ok, reason)
            if not ok then
                Link.setLast("sleep", false, noWifiText(reason))
                return
            end
            -- If we were woken up meanwhile, also pull (acts as the wake sync).
            local awake = self.suspend_token ~= token
            local summary, all_ok, pushed = self:doSync({ push = true, pull = awake })
            Link.setLast("sleep", all_ok, summary)
            logger.info("KOSyncWiFi: sleep sync done:", summary)
            if pushed then
                if awake or not Device.screen_saver_mode then
                    showPushed(self.settings, pushedText(summary))
                else
                    self:showOnSleepScreen(T(_("Progress pushed at %1."), os.date("%H:%M")))
                end
            end
        end, function()
            if self.suspend_token == token then
                self.suspend_token = nil
                if Device.screen_saver_mode then
                    logger.info("KOSyncWiFi: releasing suspend")
                    Device:rescheduleSuspend(1)
                end
            end
        end)
    end)
end

-- The box drawn over the sleep screen: a plain square frame, serif text,
-- near the bottom edge. Deliberately not an InfoMessage (no rounded window,
-- no icon, not centred). It has to be modal: UIManager slips non-modal
-- widgets *below* the (modal) screensaver widget. Also used for the notice
-- while the radio is started (Link.startRadio).
SleepBox = WidgetContainer:extend{
    modal = true,
    text = "",
    position = "bottom", -- "bottom" (centred), "bottom_left", "bottom_right"
}

function SleepBox:init()
    local Screen = Device.screen
    local edge = Screen:scaleBySize(18)
    local face = Font:getFace("NotoSerif-Regular.ttf", 15) or Font:getFace("infofont")
    local text_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = Screen:getWidth() - 2 * edge - 2 * Size.padding.large,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.default,
        radius = 0,
        margin = 0,
        padding = Size.padding.default,
        padding_left = Size.padding.large,
        padding_right = Size.padding.large,
        text_widget,
    }
    local size = self.frame:getSize()
    local x
    if self.position == "bottom_left" then
        x = edge
    elseif self.position == "bottom_right" then
        x = Screen:getWidth() - size.w - edge
    else
        x = math.floor((Screen:getWidth() - size.w) / 2)
    end
    local y = Screen:getHeight() - size.h - edge
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1] = self.frame
end

function SleepBox:getSize()
    return self.dimen
end

function SleepBox:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SleepBox:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function KOSyncWiFi:showOnSleepScreen(text)
    if not self.settings.notify or not self.settings.notify_on_sleep_screen then return end
    self:clearSleepScreenBox(false)
    self.sleep_box = SleepBox:new{ text = text, position = self.settings.sleep_box_position }
    UIManager:show(self.sleep_box)
    UIManager:forceRePaint()
end

function KOSyncWiFi:clearSleepScreenBox(refresh)
    if not self.sleep_box then return end
    UIManager:close(self.sleep_box)
    self.sleep_box = nil
    if refresh then
        -- Full flash: the box sat on the e-ink panel for a long time.
        UIManager:setDirty(nil, "full")
    end
end

function KOSyncWiFi:onResume()
    self:clearSleepScreenBox(true)
    local suspend_job_pending = self.suspend_token ~= nil and Link.job ~= nil
    self.suspend_token = nil
    if not self.settings.enabled or not self.settings.on_resume then return end
    if suspend_job_pending then
        -- The sleep job is still connecting; its callback will push and pull.
        return
    end
    if self:inReader() then
        if not self:getKOSync() then return end
        UIManager:scheduleIn(1, function()
            self:runSync("wake", { pull = true })
        end)
    elseif queueCount() > 0 then
        UIManager:scheduleIn(1, function()
            self:runSync("wake", {})
        end)
    end
end

-- kobo.koplugin let go of the Wi-Fi function (and, on a cold boot, finished
-- bringing the radio up): start a waiting job now instead of at its next
-- one-second check. Returning nothing lets other plugins see the event too.
function KOSyncWiFi:onBluetoothWifiReleased()
    local job = Link.job
    if job and not job.launched then
        UIManager:unschedule(Link._launch)
        UIManager:nextTick(Link._launch, job)
    end
end

function KOSyncWiFi:onKOSyncWiFiSyncNow()
    if not self:getKOSync() and not self:inReader() then
        if queueCount() == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing queued; open a book to sync its progress."), timeout = 3 })
            return true
        end
    end
    self:runSync("manual", { push = true, pull = true, manual = true })
    return true
end

-- Broadcast before KOReader quits: Exit / Restart from the menu, power off,
-- reboot, and "Close" right before entering USB mass storage. Returning
-- nothing lets the event continue to the reader itself.
local function markShutdown()
    Link.shutdown()
end
KOSyncWiFi.onExit = markShutdown
KOSyncWiFi.onRestart = markShutdown
KOSyncWiFi.onPowerOff = markShutdown
KOSyncWiFi.onReboot = markShutdown
KOSyncWiFi.onClose = markShutdown

-- ---- menu -----------------------------------------------------------------

local function statusText()
    local last = Link.last
    if not last then
        return _("Last sync: none yet")
    end
    local kinds = {
        open = _("open"), close = _("close"), wake = _("wake"), sleep = _("sleep"), manual = _("manual"),
    }
    return T(_("Last sync: %1 at %2, %3"),
        kinds[last.kind] or last.kind,
        os.date("%H:%M", last.when),
        last.ok and last.detail or (_("failed") .. ": " .. last.detail))
end

function KOSyncWiFi:toggleEntry(key, text, help)
    return {
        text = text,
        help_text = help,
        checked_func = function() return self.settings[key] end,
        enabled_func = function() return key == "enabled" or self.settings.enabled end,
        callback = function()
            self.settings[key] = not self.settings[key]
            self:saveSettings()
        end,
    }
end

function KOSyncWiFi:positionEntry(value, text)
    return {
        text = text,
        radio = true,
        checked_func = function() return self.settings.sleep_box_position == value end,
        callback = function()
            self.settings.sleep_box_position = value
            self:saveSettings()
        end,
    }
end

-- KOSync's own toggle, as it is labelled in its menu (same msgid, so the
-- translated texts match too).
local KOSYNC_AUTO_TEXT = _("Automatically keep documents in sync")

function KOSyncWiFi:kosyncAutoSyncOn()
    local kosync = self.ui and self.ui.kosync
    return kosync and kosync.settings and kosync.settings.auto_sync == true
end

local BLOCKED_TEXT = _("Wi-Fi on demand sync is off while Progress sync's 'Automatically keep documents in sync' is on. Turn that off to use it.")

function KOSyncWiFi:getSubItems()
    return {
        {
            text_func = function()
                if self:kosyncAutoSyncOn() then
                    return _("Off: turn off 'Automatically keep documents in sync'")
                end
                return statusText()
            end,
            enabled = false,
            separator = true,
        },
        {
            text = _("Enable"),
            -- Greyed out while KOSync's own automatic sync is on; tapping a
            -- greyed item shows its help text, which says why.
            enabled_func = function() return not self:kosyncAutoSyncOn() end,
            help_text_func = function()
                if self:kosyncAutoSyncOn() then
                    return T(_("Turn off '%1' above first: the two cannot run together."), KOSYNC_AUTO_TEXT)
                end
                return _("Run Progress sync automatically and turn Wi-Fi on only for the sync.")
            end,
            checked_func = function() return self.settings.enabled end,
            callback = function()
                self.settings.enabled = not self.settings.enabled
                self:saveSettings()
            end,
        },
        {
            text = _("Sync now"),
            enabled_func = function() return self.settings.enabled end,
            callback = function() self:onKOSyncWiFiSyncNow() end,
            separator = true,
        },
        self:toggleEntry("on_open", _("Pull when opening a book")),
        self:toggleEntry("on_resume", _("Pull on wake-up")),
        self:toggleEntry("on_suspend", _("Push on sleep"),
            _("Keeps the device awake (sleep screen already showing) until the push is done or the time limit is reached.")),
        self:toggleEntry("on_close", _("Push when closing a book")),
        {
            text = _("Turn Wi-Fi off afterwards"),
            help_text = _("Only when the plugin turned it on. Wi-Fi that was already on is left alone."),
            enabled_func = function() return self.settings.enabled end,
            checked_func = function() return self.settings.wifi_off_after end,
            callback = function()
                self.settings.wifi_off_after = not self.settings.wifi_off_after
                self:saveSettings()
            end,
            separator = true,
        },
        {
            text_func = function()
                return T(_("Wi-Fi connection time limit: %1 s"), self.settings.connect_timeout)
            end,
            enabled_func = function() return self.settings.enabled end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    value = self.settings.connect_timeout,
                    value_min = 10,
                    value_max = 40,
                    value_step = 5,
                    default_value = DEFAULTS.connect_timeout,
                    title_text = _("Wi-Fi connection time limit"),
                    info_text = _("How long to wait for Wi-Fi before giving up. On sleep, the device is held awake for this plus 15 seconds at most."),
                    callback = function(spin)
                        self.settings.connect_timeout = spin.value
                        self:saveSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            text = _("Connect silently (background script)"),
            help_text = _("Uses the same background reconnect as 'Auto restore Wi-Fi': no messages on screen. Turn off to use KOReader's normal connection, which shows its usual messages."),
            enabled_func = function() return self.settings.enabled end,
            checked_func = function() return self.settings.method == "silent" end,
            callback = function()
                self.settings.method = self.settings.method == "silent" and "standard" or "silent"
                self:saveSettings()
            end,
        },
        self:toggleEntry("notify", _("Pop-up after a push"),
            _("Shown when progress actually went to the server: on close, on sleep, or from the queue. Nothing for pulls, 'in sync' or when another device is ahead.")),
        {
            text = _("Also on the sleep screen"),
            help_text = _("After the sleep push, a small box with the time is drawn over the sleep screen and removed on wake-up."),
            enabled_func = function() return self.settings.enabled and self.settings.notify end,
            checked_func = function() return self.settings.notify_on_sleep_screen end,
            callback = function()
                self.settings.notify_on_sleep_screen = not self.settings.notify_on_sleep_screen
                self:saveSettings()
            end,
        },
        {
            text = _("Sleep screen box position"),
            enabled_func = function() return self.settings.enabled and self.settings.notify and self.settings.notify_on_sleep_screen end,
            sub_item_table = {
                self:positionEntry("bottom", _("Bottom, centred")),
                self:positionEntry("bottom_left", _("Bottom left corner")),
                self:positionEntry("bottom_right", _("Bottom right corner")),
            },
        },
    }
end

-- In the reader, the entry goes inside KOSync's own "Progress sync" menu,
-- right after its automatic-sync items, and KOSync's toggle is greyed out
-- while this plugin is enabled (its help text explains). In the file manager
-- KOSync has no menu, so the entry stays under Tools.
function KOSyncWiFi:addToMainMenu(menu_items)
    local entry = {
        text = _("Wi-Fi on demand sync"),
        -- Built when opened, so we can explain a fully greyed-out menu with a
        -- pop-up. The same function is also called by menu search and by the
        -- menu's position restore, where a pop-up would be wrong: only show it
        -- when we were reached from a tap (TouchMenu:onMenuSelect).
        sub_item_table_func = function()
            if self:kosyncAutoSyncOn() and debug.traceback():find("onMenuSelect", 1, true) then
                UIManager:show(InfoMessage:new{ text = BLOCKED_TEXT })
            end
            return self:getSubItems()
        end,
    }

    local ps = menu_items.progress_sync
    local items = ps and ps.sub_item_table
    if items then
        local auto_idx
        for i, item in ipairs(items) do
            if item.text == KOSYNC_AUTO_TEXT then
                auto_idx = i
                break
            end
        end
        if auto_idx then
            local auto_item = items[auto_idx]
            local original_help = auto_item.help_text
            auto_item.enabled_func = function() return not self.settings.enabled end
            auto_item.help_text = nil
            auto_item.help_text_func = function()
                if self.settings.enabled then
                    return _("Turn off 'Wi-Fi on demand sync' below first: the two cannot run together.")
                end
                return original_help
            end
            -- Slot in after the pages-before-update item that belongs to it,
            -- taking over its separator.
            local at = auto_idx + 1
            local pages_item = items[at]
            if pages_item and pages_item.text_func and pages_item.separator then
                pages_item.separator = nil
                at = at + 1
            end
            entry.separator = true
            table.insert(items, at, entry)
        else
            table.insert(items, entry)
        end
        return
    end

    entry.text = _("Progress sync: Wi-Fi on demand")
    entry.sorting_hint = "tools"
    menu_items.kosyncwifi = entry
end

return KOSyncWiFi

