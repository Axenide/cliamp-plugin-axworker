local p = plugin.register({
	name = "axworker",
	type = "hook",
	version = "1.0.0",
	description = "Push now-playing metadata to a Cloudflare Worker (or a debug state file)",
})

local worker_url = p:config("worker_url")
local secret = p:config("secret")
local debug = p:config("debug") == true
local debug_file = p:config("debug_file")
local heartbeat = tonumber(p:config("heartbeat")) or 60
local lookup_covers = p:config("lookup_covers") ~= false

local CACHE_KEY = "covers"
local CACHE_MAX = 200
local RETRY_SECS = 5

local home = os.getenv("HOME")
if not debug_file and home then
	debug_file = home .. "/.local/share/cliamp/axworker-state.json"
end

if not debug and not worker_url then
	cliamp.log.warn("no worker_url configured and debug is off; nothing will be sent")
end
if not debug and worker_url and not secret then
	cliamp.log.warn("worker_url set but secret is missing; the worker will reject requests")
end

if debug and debug_file then
	local dir = debug_file:match("^(.*)/[^/]+$")
	if dir then
		pcall(cliamp.fs.mkdir, dir)
	end
end

local cache = cliamp.store.get(CACHE_KEY)
if type(cache) ~= "table" or type(cache.map) ~= "table" or type(cache.order) ~= "table" then
	cache = { order = {}, map = {} }
end

local current = { title = "", artist = "", album = "", coverUrl = "", url = "", path = "", key = "" }
local last_key, last_playing, last_send_ts, last_attempt_ts, last_failed = "", false, 0, 0, false

local function s(value)
	return type(value) == "string" and value or ""
end

local function make_key(title, artist, path)
	return s(title) .. "|" .. s(artist) .. "|" .. s(path)
end

local function set_current(ev)
	current.title = s(ev.title)
	current.artist = s(ev.artist)
	current.album = s(ev.album)
	current.path = s(ev.path)
	current.coverUrl = ""
	current.url = ""
	current.key = make_key(current.title, current.artist, current.path)
end

local function urlencode(value)
	return (value:gsub("[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function cache_set(key, value)
	if cache.map[key] == nil then
		table.insert(cache.order, key)
		while #cache.order > CACHE_MAX do
			cache.map[table.remove(cache.order, 1)] = nil
		end
	end
	cache.map[key] = value
	pcall(cliamp.store.set, CACHE_KEY, cache)
end

local function send(playing)
	local payload = {
		title = current.title,
		artist = current.artist,
		album = current.album,
		coverUrl = current.coverUrl,
		url = current.url,
		playing = playing,
	}

	if debug then
		local ok, err = pcall(cliamp.fs.write, debug_file, cliamp.json.encode(payload) .. "\n")
		if not ok then
			cliamp.log.error("debug write failed: " .. tostring(err))
			return false
		end
		return true
	end

	if not worker_url then
		return false
	end

	local body, status = cliamp.http.post(worker_url .. "/update", {
		json = payload,
		headers = { Authorization = "Bearer " .. (secret or "") },
	})

	if type(status) ~= "number" or status < 200 or status >= 300 then
		cliamp.log.warn("post failed: " .. tostring(status) .. (type(body) == "string" and (" " .. body) or ""))
		return false
	end
	return true
end

local function push(playing, force)
	if current.title == "" and current.artist == "" then
		return
	end

	if not force and playing == last_playing and current.key == last_key then
		return
	end

	local now = os.time()
	if last_failed and now - last_attempt_ts < RETRY_SECS then
		return
	end

	last_attempt_ts = now
	if send(playing) then
		last_key, last_playing, last_send_ts, last_failed = current.key, playing, now, false
	else
		last_failed = true
	end
end

local function apply_cover(key, found)
	if current.key ~= key then
		return
	end
	current.coverUrl = s(found.cover)
	if current.url == "" and s(found.url) ~= "" then
		current.url = found.url
	end
	cliamp.timer.after(0, function()
		if current.key == key then
			push(cliamp.player.state() == "playing", true)
		end
	end)
end

local function youtube_id(path)
	if type(path) ~= "string" then
		return nil
	end
	local patterns = {
		"youtu%.be/([%w%-_]+)",
		"[?&]v=([%w%-_]+)",
		"/shorts/([%w%-_]+)",
		"/embed/([%w%-_]+)",
		"/live/([%w%-_]+)",
	}
	for _, pat in ipairs(patterns) do
		local id = path:match(pat)
		if id and #id >= 11 then
			return id
		end
	end
	return nil
end

local function build_term(artist, album, title)
	local parts = {}
	if artist ~= "" then
		parts[#parts + 1] = artist
	end
	if album ~= "" then
		parts[#parts + 1] = album
	end
	if #parts == 0 and title ~= "" then
		parts[1] = title
	end
	return table.concat(parts, " ")
end

local function lookup_itunes(artist, album, title)
	local term = build_term(artist, album, title)
	if term == "" then
		return nil
	end
	local body, status = cliamp.http.get(
		"https://itunes.apple.com/search?term=" .. urlencode(term) .. "&media=music&entity=song&limit=1")
	if type(body) ~= "string" or status ~= 200 then
		return nil
	end
	local ok, data = pcall(cliamp.json.decode, body)
	local r = ok and type(data) == "table" and data.results and data.results[1]
	if not r or type(r.artworkUrl100) ~= "string" then
		return nil
	end
	return {
		cover = r.artworkUrl100:gsub("100x100bb", "300x300bb"),
		url = type(r.trackViewUrl) == "string" and r.trackViewUrl or "",
	}
end

local function lookup_deezer(artist, album, title)
	local term = build_term(artist, album, title)
	if term == "" then
		return nil
	end
	local body, status = cliamp.http.get("https://api.deezer.com/search?q=" .. urlencode(term) .. "&limit=1")
	if type(body) ~= "string" or status ~= 200 then
		return nil
	end
	local ok, data = pcall(cliamp.json.decode, body)
	local r = ok and type(data) == "table" and data.data and data.data[1]
	if not r or not (type(r.album) == "table" and type(r.album.cover_big) == "string") then
		return nil
	end
	return {
		cover = r.album.cover_big,
		url = type(r.link) == "string" and r.link or "",
	}
end

local function resolve_cover()
	if not lookup_covers then
		return
	end
	local key = current.key
	if key == "||" then
		return
	end

	local yt_id = youtube_id(current.path)
	if yt_id then
		local cache_key = "yt:" .. yt_id
		local cached = cache.map[cache_key]
		if type(cached) == "table" then
			apply_cover(key, cached)
			return
		end

		local video_url = current.path
		if video_url:sub(1, 4) ~= "http" then
			video_url = "https://" .. video_url
		end

		local candidates = {
			"https://i.ytimg.com/vi/" .. yt_id .. "/maxresdefault.jpg",
			"https://i.ytimg.com/vi/" .. yt_id .. "/hq720.jpg",
		}

		local probe
		probe = function(i)
			if current.key ~= key then
				return
			end
			if i <= #candidates then
				local body, status = cliamp.http.get(candidates[i])
				if status == 200 and type(body) == "string" and #body > 0 then
					local found = { cover = candidates[i], url = video_url }
					cache_set(cache_key, found)
					apply_cover(key, found)
					return
				end
				cliamp.timer.after(0, function()
					probe(i + 1)
				end)
				return
			end
			local found = { cover = "https://i.ytimg.com/vi/" .. yt_id .. "/mqdefault.jpg", url = video_url }
			cache_set(cache_key, found)
			apply_cover(key, found)
		end

		cliamp.timer.after(0.1, function()
			probe(1)
		end)
		return
	end

	if cliamp.track.is_live() then
		return
	end

	local artist, album, title = current.artist, current.album, current.title
	if artist == "" or (title == "" and album == "") then
		return
	end

	local term = build_term(artist, album, title)
	local cache_key = "lookup:" .. term:lower()

	local cached = cache.map[cache_key]
	if type(cached) == "table" then
		apply_cover(key, cached)
		return
	end

	cliamp.timer.after(0.2, function()
		if current.key ~= key then
			return
		end
		local found = lookup_itunes(artist, album, title)
		if found then
			cache_set(cache_key, found)
			apply_cover(key, found)
			return
		end
		cliamp.timer.after(0, function()
			if current.key ~= key then
				return
			end
			local alt = lookup_deezer(artist, album, title)
			if alt then
				cache_set(cache_key, alt)
				apply_cover(key, alt)
			end
		end)
	end)
end

p:on("track.change", function(track)
	set_current(track)
	push(true, true)
	resolve_cover()
end)

p:on("playback.state", function(ev)
	local key = make_key(ev.title, ev.artist, ev.path)
	local playing = ev.status == "playing"

	if key ~= current.key then
		set_current(ev)
		push(playing, true)
		if playing then
			resolve_cover()
		end
		return
	end

	if playing ~= last_playing then
		push(playing, true)
	elseif playing and os.time() - last_send_ts >= heartbeat then
		push(true, true)
	end
end)

p:on("playback.stop", function()
	push(false, false)
end)

p:on("app.quit", function()
	pcall(push, false, true)
end)

p:command("status", function()
	return cliamp.json.encode({
		debug = debug,
		target = debug and ("debug file: " .. tostring(debug_file)) or tostring(worker_url),
		track = {
			title = current.title,
			artist = current.artist,
			album = current.album,
			coverUrl = current.coverUrl,
			url = current.url,
		},
		last_sent_playing = last_playing,
		last_sent_at = last_send_ts > 0 and os.date("%Y-%m-%d %H:%M:%S", last_send_ts) or "never",
		cache_entries = #cache.order,
	})
end)
