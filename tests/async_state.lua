-- Run from the repository root: lua tests/async_state.lua [path/to/Barco_CTRL.qplug]
-- Executes the real plugin with deterministic Q-SYS controls, timers and HTTP
-- callbacks. JSON fixtures are already decoded; wire formats/TLS need hardware.
local source = arg[1] or "Barco_CTRL.qplug"
local function harness(wallCount)
    wallCount = wallCount or 1
    local now, timers, requests = 1000, {}, {}
    local env = setmetatable({ print = function() end }, { __index = _G })
    env.os = { time = function() return now end }
    env.require = function(name)
        assert(name == "rapidjson")
        return {
            decode = function(value)
                assert(type(value) == "table", "invalid JSON fixture")
                return value
            end,
            encode = function(value)
                if type(value) == "string" then return string.format("%q", value) end
                return value
            end
        }
    end
    env.Timer = { New = function()
        local timer = {
            Start = function(self, delay) self.delay = delay; self.next = now + delay end,
            Stop = function(self) self.next = nil end
        }
        timers[#timers + 1] = timer
        return timer
    end }
    env.HttpClient = {}
    for _, method in ipairs({ "Get", "Post", "Put" }) do
        env.HttpClient[method] = function(request)
            request.method = method
            requests[#requests + 1] = request
        end
    end
    assert(loadfile(source, "t", env))()
    env.Properties = { ["#Walls"] = { Value = wallCount } }
    env.Controls = {}
    local function control() return { String = "", Value = 0, Choices = {} } end
    for _, definition in ipairs(env.GetControls(env.Properties)) do
        if definition.Count > 1 then
            env.Controls[definition.Name] = {}
            for index = 1, definition.Count do env.Controls[definition.Name][index] = control() end
        else
            env.Controls[definition.Name] = control()
        end
    end
    assert(loadfile(source, "t", env))()
    local h = { requests = requests }
    function h.control(name, index)
        local c = env.Controls[name]
        return index and wallCount > 1 and c[index] or c
    end
    function h.change(name, value, index)
        local c = h.control(name, index)
        if type(value) == "number" then c.Value = value else c.String = value end
        c.EventHandler(c)
    end
    function h.take(method, suffix)
        for index, request in ipairs(requests) do
            if request.method == method and request.Url:sub(-#suffix) == suffix then
                table.remove(requests, index)
                return request
            end
        end
        error("missing request: " .. method .. " " .. suffix)
    end
    function h.reply(request, body, code)
        request.EventHandler(request, code or 200, body or {}, nil, {})
    end
    function h.advance(seconds)
        local target = now + seconds
        while true do
            local nextTimer
            for _, timer in ipairs(timers) do
                if timer.next and timer.next <= target and (not nextTimer or timer.next < nextTimer.next) then
                    nextTimer = timer
                end
            end
            if not nextTimer then break end
            now = nextTimer.next
            nextTimer.next = now + nextTimer.delay
            nextTimer.EventHandler()
        end
        now = target
    end
    function h.connect(host)
        h.control("ClientID").String = "client"
        h.control("ClientSecret").String = "secret"
        h.change("IP", host or "ctrl-a")
        return h.take("Post", "/token")
    end
    function h.authenticate(request, token)
        h.reply(request, { access_token = token or "ctrl-token", expires_in = 600 })
        return h.take("Get", "/compositions?owner=all"), h.take("Get", "/workplaces?type=Wall")
    end
    function h.loadWalls(request, prefix)
        local data = {}
        for index = 1, wallCount do
            data[index] = {
                name = (prefix or "wall") .. index, id = (prefix or "wall") .. index,
                wallGeometry = { sizePx = { width = 1920, height = 1080 }, grid = { columns = 1, rows = 1 } }
            }
        end
        h.reply(request, { data = data })
    end
    function h.loadCompositions(request, prefix)
        local data = {}
        for _, name in ipairs({ "A", "B", "C" }) do
            data[#data + 1] = { name = name, id = (prefix or "") .. name, size = { width = 1920, height = 1080 } }
        end
        h.reply(request, { data = data })
    end
    function h.ready()
        local compositions, walls = h.authenticate(h.connect())
        h.loadCompositions(compositions)
        h.loadWalls(walls)
    end
    function h.select(name, index) h.change("Compositions", name .. " (1920x1080)", index or 1) end
    function h.manager(index)
        index = index or 1
        h.control("WallManagerAuthKey", index).String = "key-a"
        h.change("WallManagerIP", "manager-a", index)
        return h.take("Post", "/auth/key")
    end
    function h.session(request, sid)
        h.reply(request, { sid = sid or "sid-a", expiresIn = 1800 })
        return h.take("Get", "/wall/brightness"), h.take("Get", "/wall/power")
    end
    return h
end

local passed, failed = 0, 0
local function test(name, run)
    local ok, err = pcall(run)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

test("old discovery cannot replace current walls or compositions", function()
    local h = harness()
    local oldCompositions, oldWalls = h.authenticate(h.connect("ctrl-a"))
    local compositions, walls = h.authenticate(h.connect("ctrl-b"), "token-b")
    h.loadWalls(walls, "new-wall")
    h.loadCompositions(compositions, "new-")
    h.loadWalls(oldWalls, "old-wall")
    h.loadCompositions(oldCompositions, "old-")
    assert(h.control("WallName", 1).String == "new-wall1")
    h.select("A")
    local recall = h.take("Put", "/workplaces/new-wall1/content")
    assert(recall.Url:match("https://ctrl%-b/"))
    assert(recall.Headers.Authorization == "Bearer token-b")
    assert(recall.Data[1].content.id == "new-A")
end)

test("obsolete token replies cannot revive an earlier connection generation", function()
    local h = harness()
    local first = h.connect("ctrl-a")
    local second = h.connect("ctrl-b")
    local compositions, walls = h.authenticate(h.connect("ctrl-a"), "current-token")
    h.loadWalls(walls); h.loadCompositions(compositions)
    h.reply(first, { access_token = "obsolete-token", expires_in = 600 })
    h.reply(second, {}, 401)
    assert(h.control("Status").Value == 0)
    h.select("A")
    assert(h.take("Put", "/content").Headers.Authorization == "Bearer current-token")
    assert(#h.requests == 0)
end)

test("old recall completion cannot unlock current recalls or replay old selections", function()
    local h = harness(); h.ready()
    h.select("A"); local old = h.take("Put", "/content")
    h.select("B")
    local compositions, walls = h.authenticate(h.connect("ctrl-b"))
    h.loadWalls(walls); h.loadCompositions(compositions)
    assert(#h.requests == 0)
    h.select("A"); local current = h.take("Put", "/content")
    h.reply(old, {}, 503)
    assert(h.control("Status").Value == 0)
    h.select("C")
    assert(#h.requests == 0)
    h.reply(current)
    assert(h.take("Put", "/content").Data[1].content.id == "C")
end)

test("failed discovery retries before token renewal and remains non-OK until recovery", function()
    local h = harness()
    local compositions, walls = h.authenticate(h.connect())
    h.reply(walls, {}, 503); h.loadCompositions(compositions)
    assert(h.control("Status").Value ~= 0)
    h.advance(5)
    local retry = h.take("Get", "/workplaces?type=Wall")
    h.loadCompositions(h.take("Get", "/compositions?owner=all"))
    assert(h.control("Status").Value ~= 0)
    h.loadWalls(retry)
    assert(h.control("WallName", 1).String == "wall1" and h.control("Status").Value == 0)
    h.select("A")
    assert(h.take("Put", "/workplaces/wall1/content").Data[1].content.id == "A")
end)

test("malformed discovery also retries without showing a healthy connection", function()
    local h = harness()
    local compositions, walls = h.authenticate(h.connect())
    h.reply(walls, "invalid JSON"); h.loadCompositions(compositions)
    assert(h.control("Status").Value ~= 0)
    h.advance(5)
    h.loadWalls(h.take("Get", "/workplaces?type=Wall"))
    assert(h.control("WallName", 1).String == "wall1")
end)

for _, status in ipairs({ 200, 503 }) do
    test("latest recall follows completion HTTP " .. status .. " independently per wall", function()
        local h = harness(2); h.ready()
        h.select("A", 1); local first = h.take("Put", "/workplaces/wall1/content")
        h.select("B", 1); h.select("C", 1)
        h.select("B", 2)
        assert(h.take("Put", "/workplaces/wall2/content").Data[1].content.id == "B")
        assert(#h.requests == 0)
        h.reply(first, {}, status)
        assert(h.take("Put", "/workplaces/wall1/content").Data[1].content.id == "C")
        assert(#h.requests == 0)
    end)
end

test("recall waits for token renewal rather than losing the selection", function()
    local h = harness(); h.ready()
    h.advance(600)
    local token = h.take("Post", "/token")
    h.select("B")
    for _, request in ipairs(h.requests) do assert(request.method ~= "Put") end
    h.reply(token, { access_token = "renewed", expires_in = 600 })
    local recall = h.take("Put", "/content")
    assert(recall.Data[1].content.id == "B" and recall.Headers.Authorization == "Bearer renewed")
end)

test("manager host and key changes require fresh authentication", function()
    local h = harness(); h.ready()
    h.session(h.manager())
    h.change("WallManagerIP", "manager-b", 1)
    local auth = h.take("Post", "/auth/key")
    assert(auth.Url == "https://manager-b/api/v1/auth/key" and #h.requests == 0)
    assert(auth.Headers.Cookie == nil and auth.Headers.key == nil)
    local brightness, power = h.session(auth, "sid-b")
    assert(brightness.Headers.Cookie == "sid=sid-b" and power.Headers.key == "sid-b")
    h.change("WallManagerAuthKey", "key-b", 1)
    auth = h.take("Post", "/auth/key")
    assert(auth.Data == '{"type":"REST","key":"key-b"}' and #h.requests == 0)
end)

test("authentication retains latest writes and both feedback polls", function()
    local h = harness(); h.ready()
    local auth = h.manager()
    h.change("WallBrightness", 10, 1); h.change("WallBrightness", 90, 1)
    h.change("WallPower", 1, 1)
    assert(#h.requests == 0)
    h.session(auth)
    assert(h.take("Post", "/wall/brightness").Data == '{"brightness":90}')
    assert(h.take("Post", "/wall/power").Data == '{"power":"on"}')
    assert(#h.requests == 0)
end)

test("authentication failure retains writes until the scheduled retry succeeds", function()
    local h = harness(); h.ready()
    local auth = h.manager()
    h.change("WallPower", 1, 1)
    h.reply(auth, {}, 503)
    h.advance(5)
    h.session(h.take("Post", "/auth/key"))
    assert(h.take("Post", "/wall/power").Data == '{"power":"on"}')
end)

test("disabled manager ignores late success and error feedback", function()
    local h = harness(); h.ready()
    local brightness, power = h.session(h.manager())
    h.change("WallManagerIP", "", 1)
    local status = h.control("WallManagerStatus", 1).String
    h.reply(brightness, { brightness = 80 }); h.reply(power, {}, 401)
    assert(h.control("WallManagerStatus", 1).String == status)
    assert(h.control("WallBrightness", 1).Value == 0 and h.control("WallPower", 1).Value == 0)
    h.advance(5)
    assert(#h.requests == 0)
end)

test("old authentication cannot drain writes queued for a new connection", function()
    local h = harness(); h.ready()
    local old = h.manager()
    h.change("WallBrightness", 10, 1)
    h.change("WallManagerIP", "manager-b", 1)
    local current = h.take("Post", "/auth/key")
    h.change("WallBrightness", 90, 1)
    h.reply(old, { sid = "old-sid", expiresIn = 1800 })
    assert(#h.requests == 0)
    h.session(current, "new-sid")
    local write = h.take("Post", "/wall/brightness")
    assert(write.Data == '{"brightness":90}' and write.Headers.key == "new-sid")
    assert(write.Url == "https://manager-b/api/v1/wall/brightness")
end)

test("old session errors cannot invalidate a replacement session", function()
    local h = harness(); h.ready()
    local oldBrightness, oldPower = h.session(h.manager())
    h.change("WallManagerIP", "manager-b", 1)
    local brightness, power = h.session(h.take("Post", "/auth/key"), "new-sid")
    h.reply(brightness, { brightness = 60 }); h.reply(power, { power = "on" })
    h.reply(oldBrightness, { brightness = 20 }); h.reply(oldPower, {}, 403)
    assert(h.control("WallBrightness", 1).Value == 60 and h.control("WallPower", 1).Value == 1)
    assert(h.control("WallManagerStatus", 1).Value == 0)
    h.change("WallPower", 0, 1)
    assert(h.take("Post", "/wall/power").Headers.key == "new-sid")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
