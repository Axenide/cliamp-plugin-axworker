-- Harness: emulate the cliamp plugin sandbox and exercise axworker.lua
local store = {}
local files = {}
local http_calls = {}
local timers = {}

local function log(level) return function(msg) print("[log." .. level .. "] " .. tostring(msg)) end end

local registered
plugin = {
  register = function(def)
    registered = def
    local obj = {}
    function obj:on(event, cb)
      handlers[event] = cb
    end
    function obj:config(key)
      return config_vals[key]
    end
    function obj:command(name, cb)
      commands[name] = cb
    end
    return obj
  end,
}

handlers, commands, config_vals = {}, {}, {}

cliamp = {
  log = { info = log("info"), warn = log("warn"), error = log("error"), debug = log("debug") },
  json = {
    encode = function(t) return json_encode(t) end,
    decode = function(s) return json_decode(s) end,
  },
  fs = {
    write = function(path, content) files[path] = content end,
    read = function(path) return files[path] end,
    mkdir = function() return true end,
  },
  store = {
    set = function(k, v) store[k] = v end,
    get = function(k) return store[k] end,
  },
  http = {
    get = function(url)
      table.insert(http_calls, { method = "GET", url = url })
      local resp = http_stub[url]
      if resp then return resp.body, resp.status end
      return nil, "connection refused"
    end,
    post = function(url, opts)
      table.insert(http_calls, { method = "POST", url = url, opts = opts })
      return '{"ok":true}', 200
    end,
  },
  track = {
    is_live = function() return track_state.is_live end,
  },
  player = {
    state = function() return track_state.status end,
  },
  timer = {
    after = function(sec, fn) table.insert(timers, { sec = sec, fn = fn }) end,
    every = function(sec, fn) table.insert(timers, { sec = sec, fn = fn, every = true }) end,
    cancel = function() end,
  },
}

track_state = { status = "stopped", is_live = false }

-- Minimal JSON encoder/decoder (test-only, tables are flat)
json_encode = function(t)
  local parts = {}
  for k, v in pairs(t) do
    local val
    if type(v) == "string" then val = '"' .. v .. '"'
    elseif type(v) == "boolean" then val = tostring(v)
    elseif type(v) == "number" then val = tostring(v)
    elseif type(v) == "table" then
      local inner = {}
      for k2, v2 in pairs(v) do
        inner[#inner+1] = '"' .. k2 .. '":' .. (type(v2) == "string" and ('"' .. v2 .. '"') or tostring(v2))
      end
      val = "{" .. table.concat(inner, ",") .. "}"
    else val = "null" end
    parts[#parts+1] = '"' .. k .. '":' .. val
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

json_decode = function(s)
  local pos = 1
  local function skip() pos = s:find("[^ \t\n\r]", pos) or #s + 1 end
  local parse_val
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local nxt = s:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", b = "\b", f = "\f" }
        out[#out+1] = map[nxt] or nxt
        pos = pos + 2
      else
        out[#out+1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parse_val = function()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip()
        local key = parse_string()
        skip()
        assert(s:sub(pos, pos) == ":", "expected :")
        pos = pos + 1
        obj[key] = parse_val()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        assert(d == ",", "expected , or }")
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr+1] = parse_val()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        assert(d == ",", "expected , or ]")
      end
    elseif c == '"' then
      return parse_string()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      assert(num, "bad value at " .. pos)
      pos = pos + #num
      return tonumber(num)
    end
  end
  local v = parse_val()
  return v
end

http_stub = {}

-- Load plugin (config must be set before load, cliamp reads it once)
config_vals = { worker_url = "https://worker.example.com", secret = "sekret", lookup_covers = true }
dofile("axworker.lua")
assert(registered.name == "axworker", "register name")
assert(registered.type == "hook", "register type")
print("== loaded, registered:", registered.name, registered.version)

local function run_timers()
  local ran = 0
  while #timers > 0 do
    local t = table.remove(timers, 1)
    t.fn()
    ran = ran + 1
  end
  return ran
end

local function last_post() return http_calls[#http_calls] end
local function last_file() 
  for path, content in pairs(files) do return path, content end
end

-- 1. track.change (local file) -> send + cover lookup
track_state.status = "playing"
handlers["track.change"]({ title = "Everlong", artist = "Foo Fighters", album = "The Colour and the Shape", path = "/home/me/Music/everlong.mp3", duration = 250 })
assert(last_post().opts.json.playing == true, "playing true on track.change")
assert(last_post().opts.json.title == "Everlong")
print("== track.change sent OK")

-- iTunes stub response (lookup fires on a timer; stub before draining)
http_stub["https://itunes.apple.com/search?term=Foo%20Fighters%20The%20Colour%20and%20the%20Shape&media=music&entity=song&limit=1"] =
  { status = 200, body = '{"results":[{"artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/foo/100x100bb.jpg","trackViewUrl":"https://music.apple.com/x"}]}' }

run_timers() -- fires the 0.2s lookup timer + deferred re-push
assert(#timers == 0, "all timers drained")
local post2 = last_post()
assert(post2.opts.json.coverUrl == "https://is1-ssl.mzstatic.com/image/thumb/foo/300x300bb.jpg", "cover upgraded to 300")
assert(post2.opts.json.url == "https://music.apple.com/x", "url from itunes")
print("== cover resolved via iTunes OK")

-- 2. playback.state ticks: no duplicate sends while playing
http_calls = {}
for i = 1, 3 do
  handlers["playback.state"]({ status = "playing", title = "Everlong", artist = "Foo Fighters", path = "/home/me/Music/everlong.mp3" })
end
assert(#http_calls == 0, "no heartbeat spam: got " .. #http_calls)
print("== no spam while playing OK")

-- 3. pause -> playing=false; play -> true
handlers["playback.state"]({ status = "paused", title = "Everlong", artist = "Foo Fighters", path = "/home/me/Music/everlong.mp3" })
assert(last_post().opts.json.playing == false, "pause sends false")
handlers["playback.state"]({ status = "playing", title = "Everlong", artist = "Foo Fighters", path = "/home/me/Music/everlong.mp3" })
assert(last_post().opts.json.playing == true, "resume sends true")
print("== pause/resume OK")

-- 4. YouTube track: thumbnail derived from ID, no external lookup
http_calls = {}
track_state.is_live = false
handlers["track.change"]({ title = "Some YT Song", artist = "", album = "", path = "https://www.youtube.com/watch?v=dQw4w9WgXcQ", duration = 212, stream = true })
assert(last_post().opts.json.playing == true)
run_timers()
assert(#timers == 0, "no timers for youtube")
assert(#http_calls == 2, "initial send + cover re-push for youtube, got " .. #http_calls)
assert(last_post().opts.json.coverUrl == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "yt thumbnail")
assert(last_post().opts.json.url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "yt url")
print("== youtube cover OK")

-- 5. youtu.be and music.youtube.com variants
local yid = youtube_cover_id_test or nil
-- access via a fresh track.change with another URL form
http_calls = {}
handlers["track.change"]({ title = "YTM", artist = "", path = "https://music.youtube.com/watch?v=abc123def45&list=x" })
run_timers()
assert(last_post().opts.json.coverUrl == "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg", "ytmusic id")
http_calls = {}
handlers["track.change"]({ title = "Shorts", artist = "", path = "https://youtube.com/shorts/abcdefghijk?feat=x" })
run_timers()
assert(last_post().opts.json.coverUrl == "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg", "shorts id")
print("== youtube url variants OK")

-- 6. Live radio: no cover lookup
http_calls = {}
track_state.is_live = true
handlers["track.change"]({ title = "Radio Song", artist = "Station", path = "http://stream.example.com:8000/radio.mp3" })
run_timers()
assert(#http_calls == 1, "no lookup for live streams, got " .. #http_calls)
assert(last_post().opts.json.coverUrl == "", "no cover for radio")
print("== live radio skip OK")

-- 7. iTunes miss -> Deezer fallback
track_state.is_live = false
http_calls = {}
http_stub = {} -- clear; GETs return nil
handlers["track.change"]({ title = "Obscure Song", artist = "Nobody Knows", album = "", path = "/home/me/Music/x.mp3" })
run_timers() -- drains the whole chain: itunes miss -> deezer miss
assert(#timers == 0)
assert(#http_calls == 3, "initial POST + itunes + deezer GETs, got " .. #http_calls)
assert(http_calls[2].url:find("itunes", 1, true), "itunes first")
assert(http_calls[3].url:find("deezer", 1, true), "deezer second")
print("== fallback chain OK (miss = no cover, no crash)")

-- 8. Cache hit: same artist+album again -> no lookups
http_calls = {}
-- re-stub itunes with hit, send a new track, then repeat
http_stub["https://itunes.apple.com/search?term=Cached%20Artist%20Cached%20Album&media=music&entity=song&limit=1"] =
  { status = 200, body = '{"results":[{"artworkUrl100":"https://x/100x100bb.jpg"}]}' }
handlers["track.change"]({ title = "T1", artist = "Cached Artist", album = "Cached Album", path = "/a.mp3" })
run_timers(); run_timers()
local lookups_first = 1
http_calls = {}
handlers["track.change"]({ title = "T2", artist = "Cached Artist", album = "Cached Album", path = "/b.mp3" })
run_timers(); run_timers()
local gets = 0
for _, c in ipairs(http_calls) do if c.method == "GET" then gets = gets + 1 end end
assert(gets == 0, "cache hit avoids lookups, got " .. gets .. " GETs")
assert(last_post().opts.json.coverUrl == "https://x/300x300bb.jpg", "cached cover applied")
print("== cache OK, entries:", select(2, commands["status"]({}) ) or "")
print(commands["status"]({}))

-- 9. playback.stop -> playing=false
handlers["playback.stop"]({})
assert(last_post().opts.json.playing == false, "stop sends false")
print("== stop OK")

-- 10. Track change with no title/artist -> no send
http_calls = {}
handlers["track.change"]({ title = "", artist = "", path = "/x.mp3" })
assert(#http_calls == 0, "empty track not sent")
print("== empty guard OK")

-- 11. Track change via radio metadata update in playback.state
track_state.is_live = true
http_calls = {}
handlers["playback.state"]({ status = "playing", title = "New Radio Song", artist = "Station", path = "http://stream.example.com:8000/radio.mp3" })
assert(last_post().opts.json.title == "New Radio Song", "stream title update")
print("== radio metadata update OK")
print("ALL TESTS PASSED")
