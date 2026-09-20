-- Run from the repository root: lua tests/async_state.lua [path/to/Barco_CTRL.qplug]
-- Executes the real plugin with deterministic Q-SYS controls, timers and HTTP
-- callbacks. JSON fixtures are already decoded; wire formats/TLS need hardware.
local source = arg[1] or "Barco_CTRL.qplug"
local function harness(wallCount, deskCount)
    deskCount = deskCount or 0
    wallCount = wallCount or 1
    local now, timers, requests = 1000, {}, {}
    local env = setmetatable({ print = function() end }, { __index = _G })
    env.os = { time = function() return now end }
    env.Crypto = { Base64Encode = function(document) return document end }
    env.require = function(name)
        if name == "EzSVG" then
            -- Record drawing primitives so tests can inspect geometry, not pixels.
            return {
                Document = function(width, height)
                    return { width = width, height = height, elements = {},
                        add = function(self, element) table.insert(self.elements, element) end,
                        toString = function(self) return self end }
                end,
                Rect = function(x, y, width, height, rx, ry, style)
                    return { kind = "rect", x = x, y = y, width = width, height = height, style = style }
                end,
                Text = function(text, x, y, style) return { kind = "text", text = text, x = x, y = y } end,
            }
        end
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
            if method == "Get" and request.Url:match("/workplaces/[^/]+/content$") and not env.deferContent then
                request.EventHandler(request, 200, {data={}}, nil)
                return
            end
            requests[#requests + 1] = request
        end
    end
    assert(loadfile(source, "t", env))()
    env.Properties = { ["#Walls"] = { Value = wallCount }, ["#Desks"] = { Value = deskCount } }
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
    local h = { requests = requests, env = env }
    function h.control(name, index)
        local c = env.Controls[name]
        local count = name:match("^Desk") and deskCount or wallCount
        return index and count > 1 and c[index] or c
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
    function h.authenticate(request, token, deferSources)
        h.reply(request, { access_token = token or "ctrl-token", expires_in = 600 })
        if not deferSources then h.reply(h.take("Get", "/sources"), { data = {} }) end
        return h.take("Get", "/compositions?owner=all"), h.take("Get", "/workplaces")
    end
    function h.loadWalls(request, prefix)
        local data = {}
        for index = 1, wallCount do
            data[index] = {
                type = "Wall", name = (prefix or "wall") .. index, id = (prefix or "wall") .. index,
                wallGeometry = { sizePx = { width = 1920, height = 1080 }, grid = { columns = 1, rows = 1 } }
            }
        end
        h.reply(request, { data = data })
        for index = 1, wallCount do
            local name = (prefix or "wall") .. index
            local selector = h.control("WallSelect", index)
            for _, choice in ipairs(selector.Choices) do
                if choice == name .. " [" .. name .. "]" then h.change("WallSelect", choice, index) end
            end
        end
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
    local retry = h.take("Get", "/workplaces")
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
    h.loadWalls(h.take("Get", "/workplaces"))
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

test("mixed workplaces have unique assignments and stale recalls are ignored", function()
    local h = harness(2, 2)
    local compositions, workplaces = h.authenticate(h.connect())
    h.loadCompositions(compositions)
    h.reply(workplaces, { data = {
        {type="Wall", id="w1", name="Wall"}, {type="Wall", id="w2", name="Wall"},
        {type="Desk", id="d1", name="Desk"}, {type="Desk", id="d2", name="Desk"},
        {type="Other", id="other", name="Other"},
    } })
    assert(#h.control("WallSelect", 1).Choices == 3)
    assert(#h.control("DeskSelect", 1).Choices == 3)
    h.change("WallSelect", "Wall [w1]", 1)
    assert(#h.control("WallSelect", 2).Choices == 2)
    h.change("WallSelect", "Wall [w1]", 2)
    assert(h.control("WallSelect", 2).String == "(None)")
    h.change("DeskSelect", "Desk [d1]", 1)
    assert(#h.control("DeskSelect", 2).Choices == 2)
    h.change("Compositions", "A (1920x1080)", 1)
    local old = h.take("Put", "/workplaces/w1/content")
    h.change("Compositions", "B (1920x1080)", 1)
    h.change("WallSelect", "Wall [w2]", 1)
    h.change("Compositions", "C (1920x1080)", 1)
    local current = h.take("Put", "/workplaces/w2/content")
    h.reply(old, {}, 403)
    assert(#h.requests == 0 and h.control("Status").Value == 0)
    h.reply(current)
    h.change("DeskSelect", "(None)", 1)
    assert(#h.control("DeskSelect", 2).Choices == 3)
    assert(h.control("DeskDisplays", 1).String == "")
    assert(h.control("DeskCompositions") == nil)
end)

test("desk-only configuration supports scalar controls and saved selections", function()
    local h = harness(0, 1)
    h.control("DeskSelect").String = "Desk [d1]"
    local compositions, workplaces = h.authenticate(h.connect())
    h.reply(workplaces, { data = {{type="Desk", id="d1", name="Desk",
        deskGeometry={sizeVpx={width=3616,height=1016}},
        displays={
            {connection="HDMI-1",device="san-050-2531106995",geometry={type="vpx",x=0,y=0,width=1808,height=1016}},
            {connection="HDMI-2",device="san-050-2531106995",geometry={type="vpx",x=1808,y=0,width=1808,height=1016}}
        }}} })
    h.loadCompositions(compositions)
    assert(h.control("DeskName").String == "Desk")
    assert(h.control("DeskVpxSize").String == "3616x1016 vpx")
    local displays = h.control("DeskDisplays").String
    assert(displays:find("HDMI-1 | san-050-2531106995", 1, true))
    assert(displays:find("HDMI-2 | san-050-2531106995", 1, true))
    assert(displays:find("1808x1016 vpx at (1808, 0)", 1, true))
    assert(h.control("DeskCompositions") == nil and #h.requests == 0)
    h.change("DeskSelect", "(None)")
    assert(h.control("DeskVpxSize").String == "" and h.control("DeskDisplays").String == "")
end)

test("SVG diagrams preserve desk placement and wall grid counts", function()
    local h = harness(1, 1)
    local compositions, workplaces = h.authenticate(h.connect())
    h.loadCompositions(compositions)
    h.reply(workplaces, {data={
        {type="Wall", id="w", name="Wall", wallGeometry={sizePx={width=3840,height=2160},grid={columns=3,rows=2}}},
        {type="Desk", id="d", name="Desk", deskGeometry={sizeVpx={width=3616,height=1016}}, displays={
            {connection="HDMI<1>&",device="Device",geometry={type="vpx",x=0,y=0,width=1808,height=1016}},
            {connection="HDMI-2",device="Device",geometry={type="vpx",x=1808,y=0,width=1808,height=1016}}
        }}
    }})
    h.change("WallSelect", "Wall [w]")
    h.change("DeskSelect", "Desk [d]")
    local function rectangles(control)
        assert(control.Legend.DrawChrome == false)
        local rects = {}
        for _, element in ipairs(control.Legend.IconData.elements) do
            if element.kind == "rect" then table.insert(rects, element) end
        end
        return rects
    end
    local grid = rectangles(h.control("WallDiagram"))
    assert(#grid == 6 and grid[4].y > grid[1].y and grid[2].x > grid[1].x)
    local displays = rectangles(h.control("DeskDiagram"))
    assert(#displays == 2 and displays[1].y == displays[2].y)
    assert(math.abs(displays[2].x - displays[1].x - displays[1].width) < 0.001)
    assert(math.abs(displays[1].width / displays[1].height - 1808/1016) < 0.001)
    local escaped = false
    for _, element in ipairs(h.control("DeskDiagram").Legend.IconData.elements) do
        if element.text == "HDMI&lt;1&gt;&amp;" then escaped = true end
    end
    assert(escaped)
    h.change("DeskSelect", "(None)")
    assert(#rectangles(h.control("DeskDiagram")) == 0)
    h.change("IP", "another-ctrl")
    assert(#rectangles(h.control("WallDiagram")) == 0)
end)

test("sources preserve classes, streams and capability metadata without controls", function()
    local h = harness()
    h.authenticate(h.connect(), nil, true)
    local request = h.take("Get", "/sources")
    assert(request.Headers.Authorization == "Bearer ctrl-token")
    local records = {
        {id="web", name="barco.com", type="Web", class="Personal", audio={isEnabled=false}, interactivity={isEnabled=true}, streams={{id="stream", name="barco.com"}}, exclusiveMode="NotExclusive"},
        {id="web", name="barco.com", type="Web", class="Common", audio={isEnabled=false}, interactivity={isEnabled=true}, streams={{id="stream", name="barco.com"}}, exclusiveMode="NotExclusive"},
    }
    h.reply(request, {data=records})
    assert(#h.env.sources == 2 and h.env.sources[1].class == "Personal" and h.env.sources[2].class == "Common")
    assert(h.env.sources[1].audio.isEnabled == false and h.env.sources[1].interactivity.isEnabled)
    assert(h.env.sources[1].streams[1].id == "stream" and h.env.sources[1].exclusiveMode == "NotExclusive")
    for name in pairs(h.env.Controls) do assert(not name:lower():find("source")) end
    h.env.funcPollCompositions()
    h.reply(h.take("Get", "/sources"), {data={}})
    assert(#h.env.sources == 0 and h.env.sourcesLoaded and h.env.sourcesError == nil)
end)

test("source failures retain the snapshot and retry without overlapping requests", function()
    local h = harness(); h.ready()
    h.env.funcGetSources()
    local request = h.take("Get", "/sources")
    h.env.funcGetSources()
    assert(#h.requests == 0)
    h.reply(request, {data={{id="encoder",name="Encoder",streams={}}}})
    local snapshot = h.env.sources
    for _, failure in ipairs({{code=503,body={}}, {code=401,body={}}, {code=200,body="bad json"}, {code=200,body={data={bad={}}}}, {code=200,body={data={false}}}}) do
        h.env.funcGetSources()
        h.reply(h.take("Get", "/sources"), failure.body, failure.code)
        assert(h.env.sources == snapshot and h.env.sourcesError ~= nil)
    end
    h.advance(60)
    h.reply(h.take("Get", "/sources"), {data={{id="new",name="New"}}})
    assert(h.env.sources[1].id == "new" and h.env.sourcesError == nil)
end)

test("obsolete source replies cannot restore data or unlock a new request", function()
    local h = harness()
    h.authenticate(h.connect("old"), nil, true)
    local old = h.take("Get", "/sources")
    h.authenticate(h.connect("new"), nil, true)
    local current = h.take("Get", "/sources")
    h.reply(old, {data={{id="old",name="Old"}}})
    assert(#h.env.sources == 0 and h.env.sourcesRequestInProgress)
    h.reply(current, {data={{id="new",name="New"}}})
    assert(h.env.sources[1].id == "new" and not h.env.sourcesRequestInProgress)
    h.change("IP", "")
    assert(#h.env.sources == 0 and not h.env.sourcesLoaded)
end)

local function contentWindow(unit, kind)
    return {id="window", geometry={type=unit,x=0,y=0,width=960,height=540}, fullscreen=false,
        window={title="CCTV <live>",showFrame=false},content={type=kind or "Source",id="source",options={audio={mute=false,volume=100}}}}
end

test("content GET stores full data and draws source and composition overlays", function()
    local h=harness(); h.env.deferContent=true; h.ready()
    local request=h.take("Get", "/workplaces/wall1/content")
    assert(request.Headers.Authorization == "Bearer ctrl-token")
    local source=contentWindow("px")
    local composition=contentWindow("px", "Composition"); composition.geometry.x=960
    h.reply(request,{data={source,composition}})
    assert(h.env.workplaceContentStates[1].data[1].content.options.audio.mute == false)
    local overlays=0
    for _,element in ipairs(h.control("WallDiagram").Legend.IconData.elements) do
        if element.kind=="rect" and element.style.fill_opacity then overlays=overlays+1 end
    end
    assert(overlays==2)
    h.env.funcGetWorkplaceContent(1)
    h.reply(h.take("Get", "/content"), {data={}})
    assert(#h.env.workplaceContentStates[1].data==0)
end)

test("content GET failures retain feedback and late selection replies are ignored", function()
    local h=harness(); h.env.deferContent=true; h.ready()
    local old=h.take("Get", "/content")
    h.env.funcGetWorkplaceContent(1); assert(#h.requests==0)
    h.change("WallSelect", "(None)")
    h.change("WallSelect", "wall1 [wall1]")
    local current=h.take("Get", "/content")
    h.reply(old,{data={contentWindow("px")}})
    assert(h.env.workplaceContentStates[1].inProgress and h.env.workplaceContentStates[1].data==nil)
    h.reply(current,{data={contentWindow("px")}})
    local snapshot=h.env.workplaceContentStates[1].data
    h.env.funcGetWorkplaceContent(1)
    h.reply(h.take("Get", "/content"),{},503)
    assert(h.env.workplaceContentStates[1].data==snapshot and h.env.workplaceContentStates[1].error)
    h.env.funcGetWorkplaceContent(1)
    local stale=h.take("Get", "/content")
    h.change("IP", "other")
    h.reply(stale,{data={contentWindow("px")}})
    assert(h.env.workplaceContentStates[1]==nil)
end)

test("recalls invalidate earlier content GET and refresh after completion", function()
    local h=harness(); h.env.deferContent=true; h.ready()
    local before=h.take("Get", "/content")
    h.select("A"); local write=h.take("Put", "/content")
    h.env.funcGetWorkplaceContent(1); assert(#h.requests==0)
    h.reply(write)
    local after=h.take("Get", "/content")
    h.reply(before,{data={contentWindow("px")}})
    assert(h.env.workplaceContentStates[1].inProgress)
    h.reply(after,{data={contentWindow("px", "Composition")}})
    assert(h.env.workplaceContentStates[1].data[1].content.type=="Composition")
end)

test("desk content uses virtual pixels and polls without composition support", function()
    local h=harness(0,1); h.env.deferContent=true
    local compositions,workplaces=h.authenticate(h.connect())
    h.loadCompositions(compositions)
    h.reply(workplaces,{data={{type="Desk",id="desk",name="Desk",deskGeometry={sizeVpx={width=1920,height=1080}},
        displays={{geometry={type="vpx",x=0,y=0,width=1920,height=1080}}}}}})
    h.change("DeskSelect","Desk [desk]")
    h.reply(h.take("Get", "/workplaces/desk/content"),{data={contentWindow("vpx")}})
    local overlays=0
    for _,element in ipairs(h.control("DeskDiagram").Legend.IconData.elements) do
        if element.kind=="rect" and element.style.fill_opacity then overlays=overlays+1 end
    end
    assert(overlays==1)
    h.advance(60)
    h.reply(h.take("Get", "/workplaces/desk/content"), {data={false}})
    assert(h.env.workplaceContentStates[1].error and #h.env.workplaceContentStates[1].data==1)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
