local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local cli = require("roon.cli")
local config = require("roon.config")

local M = {}

---`vim.json.decode` maps JSON `null` to `vim.NIL` (userdata), which is truthy
---in Lua and cannot be concatenated. Coerce nullish values to real nil so
---`x or ""` / `and x` / `..` all behave.
local function nilify(v)
  if v == nil or v == vim.NIL then return nil end
  return v
end

local displayer = entry_display.create({
  separator = "  ",
  items = { { width = 40 }, { remaining = true } },
})

-- Map a user-chosen action ("play-now"|"queue"|"start-radio") to the action
-- titles Roon exposes at the leaf of an action_list.
local ACTION_TITLE = {
  ["play-now"] = "Play Now",
  ["queue"] = "Queue",
  ["start-radio"] = "Start Radio",
}

---Roon's search surfaces `list` / `action_list` entries that are not directly
---playable — passing them to `play-item` yields `"no matching action"`.
---Drill up to two levels to locate the concrete `action` leaf matching
---`action`. Returns `item_key, nil` on success, or `nil, err` on failure.
---@param session string
---@param item_key string
---@param hint string|nil
---@param action string
---@return string|nil, string|nil
local function resolve_action_key(session, item_key, hint, action)
  if hint == "action" then
    return item_key, nil
  end
  local leaf_title = ACTION_TITLE[action]
  for _ = 1, 2 do -- cap drill depth to avoid wandering the tree
    local ok, resp = cli.oneshot_sync({
      "browse",
      "--session",
      session,
      "--item-key",
      item_key,
      "--count",
      "20",
    })
    if not ok or not resp or not resp.items then
      return nil, "browse failed"
    end
    -- Direct hit: an `action` child whose title is the requested leaf.
    for _, it in ipairs(resp.items) do
      if it.hint == "action" and it.title == leaf_title then
        return it.item_key, nil
      end
    end
    -- Otherwise drill through the first `action_list` whose title starts
    -- with "Play" ("Play Artist" / "Play Album" / "Play Genre" etc.).
    local next_key
    for _, it in ipairs(resp.items) do
      if it.hint == "action_list" and type(it.title) == "string" and it.title:match("^Play") then
        next_key = it.item_key
        break
      end
    end
    if not next_key then
      return nil, "no playable action under this item"
    end
    item_key = next_key
  end
  return nil, "drill depth exceeded"
end

---Valid picker categories mapped to prompt title + the title of the
---category-drill entry that Roon's cross-category search returns.
local CATEGORIES = {
  search    = { title = "Roon Search",    category = nil },
  artists   = { title = "Roon Artists",   category = "Artists" },
  albums    = { title = "Roon Albums",    category = "Albums" },
  tracks    = { title = "Roon Tracks",    category = "Tracks" },
  composers = { title = "Roon Composers", category = "Composers" },
}

---Run a CLI call once, and retry once on transient MOO/WebSocket errors.
---Roon Core occasionally rejects back-to-back sessions with
---"WebSocket protocol error: Connection reset"; a brief re-attempt almost
---always succeeds.
local function cli_with_retry(args)
  local ok, resp, err = cli.oneshot_sync(args)
  if ok then return resp end
  if type(err) == "string" and (err:find("MOO protocol error") or err:find("Connection reset") or err:find("connection closed")) then
    vim.wait(200)
    local ok2, resp2 = cli.oneshot_sync(args)
    if ok2 then return resp2 end
  end
  return nil
end

---Detect the "stuck session" symptom: Roon Core occasionally locks the
---server-side state for a CLI session in a way that makes every search
---return a single `{"title":"No Results"}` placeholder regardless of input.
---Deleting the on-disk session TOML forces the next CLI invocation to
---register a fresh session with Core, which clears the lock.
---@param resp table|nil
---@return boolean
local function looks_stuck(resp)
  if not resp or type(resp.items) ~= "table" then return false end
  if #resp.items ~= 1 then return false end
  local only = resp.items[1]
  return nilify(only and only.title) == "No Results"
end

---@param session string
local function reset_session_file(session)
  local path = vim.fn.expand("~/.config/roon-rs/sessions/" .. session .. ".toml")
  pcall(os.remove, path)
end

---Run `search` with recovery for both transient MOO errors and the
---stuck-session "No Results" state.
local function search_with_recovery(session, prompt)
  local args = {
    "search", "--session", session, "--input", prompt, "--count", "50",
  }
  local resp = cli_with_retry(args)
  if looks_stuck(resp) then
    reset_session_file(session)
    resp = cli_with_retry(args)
  end
  return resp
end

---Fetch the item list to display in the picker for a given prompt.
---For `search` (default) this is the raw cross-category response. For a
---specific category ("artists"/"albums"/...) Roon requires two calls:
---  1. search the cross-category hierarchy to establish the session's list
---  2. drill into the matching category entry ("Artists"/"Albums"/...)
---     whose children are the text-filtered results.
local function fetch_items(session, category, prompt)
  local resp = search_with_recovery(session, prompt)
  if not resp or not resp.items then return nil end
  if not category then return resp.items end
  local category_key
  for _, it in ipairs(resp.items) do
    if nilify(it.title) == category and nilify(it.hint) == "list" then
      category_key = nilify(it.item_key)
      break
    end
  end
  if not category_key then return {} end
  local drilled = cli_with_retry({
    "browse", "--session", session, "--item-key", category_key, "--count", "50",
  })
  if not drilled or not drilled.items then return {} end
  return drilled.items
end

---Open a picker listing the albums that belong to one artist. The artist's
---children are fetched via one browse call rather than a new search, so the
---list is scoped to that artist instead of the global library.
---@param opts table
---@param artist_title string
---@param artist_item_key string
local function open_artist_albums_picker(opts, artist_title, artist_item_key)
  local session = opts.session or config.options.session.telescope
  local zone = opts.zone or config.options.zone

  local drilled = cli_with_retry({
    "browse", "--session", session, "--item-key", artist_item_key, "--count", "100",
  })
  if not drilled or type(drilled.items) ~= "table" then
    vim.notify("roon: could not browse albums for " .. artist_title, vim.log.levels.ERROR)
    return
  end

  local albums = {}
  for _, it in ipairs(drilled.items) do
    -- Roon exposes the artist's albums as `hint = "list"` children; the
    -- "Play Artist" action_list and the occasional action leaf are skipped.
    if nilify(it.hint) == "list" then
      table.insert(albums, {
        item_key = nilify(it.item_key),
        title = nilify(it.title) or "",
        subtitle = nilify(it.subtitle) or "",
      })
    end
  end
  if #albums == 0 then
    vim.notify("roon: no albums listed under " .. artist_title, vim.log.levels.WARN)
    return
  end

  pickers
    .new(opts, {
      prompt_title = "Albums by " .. artist_title,
      finder = finders.new_table({
        results = albums,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = item.title .. " " .. item.subtitle,
            display = function()
              return displayer({
                { item.title, "TelescopeResultsIdentifier" },
                { item.subtitle, "TelescopeResultsComment" },
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = false,
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local e = action_state.get_selected_entry()
          actions.close(bufnr)
          if not e or not e.value or not e.value.item_key then return end
          -- Use play-item with the album's fresh item_key instead of
          -- `roon play --album <title>`. The CLI fuzzy-matches by title
          -- across the whole library, which picks the wrong album when
          -- multiple artists share a title ("21", "Untitled", ...).
          local key, err = resolve_action_key(session, e.value.item_key, "list", "play-now")
          if not key then
            vim.notify("roon: " .. (err or "could not resolve album play action"), vim.log.levels.ERROR)
            return
          end
          cli.play_item_async(session, key, zone, "play-now")
        end)
        return true
      end,
    })
    :find()
end

---Open a static submenu picker listing the things we can do with a selected
---artist. Selecting an action either fires a CLI call (Play / Shuffle /
---Queue / Start Radio) or recurses into another picker (Browse albums).
---@param opts table
---@param artist_title string
---@param artist_item_key string
local function open_artist_submenu(opts, artist_title, artist_item_key)
  local session = opts.session or config.options.session.telescope
  local zone = opts.zone or config.options.zone

  local function with_zone(args)
    if zone and zone ~= "" then
      table.insert(args, "--zone")
      table.insert(args, zone)
    end
    return args
  end

  local function drill_play(action)
    local key, err = resolve_action_key(session, artist_item_key, "list", action)
    if not key then
      vim.notify("roon: " .. (err or "could not resolve " .. action), vim.log.levels.ERROR)
      return
    end
    cli.play_item_async(session, key, zone, action)
  end

  local menu = {
    { label = "▶  Play all tracks", run = function()
      cli.exec_async(with_zone({ "play", "--artist", artist_title }))
    end },
    { label = "🔀 Shuffle all tracks", run = function()
      cli.exec_async(with_zone({ "play", "--artist", artist_title, "--shuffle" }))
    end },
    { label = "📂 Browse albums", run = function()
      open_artist_albums_picker(opts, artist_title, artist_item_key)
    end },
    { label = "➕ Queue all tracks", run = function() drill_play("queue") end },
    { label = "📻 Start Radio", run = function() drill_play("start-radio") end },
  }

  pickers
    .new(opts, {
      prompt_title = artist_title,
      finder = finders.new_table({
        results = menu,
        entry_maker = function(m)
          return { value = m, ordinal = m.label, display = m.label }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = false,
      attach_mappings = function(bufnr)
        actions.select_default:replace(function()
          local e = action_state.get_selected_entry()
          actions.close(bufnr)
          if e and e.value and e.value.run then e.value.run() end
        end)
        return true
      end,
    })
    :find()
end

---@param opts table|nil  {hierarchy="search"|"artists"|"albums"|"tracks"|...}
function M.search(opts)
  opts = opts or {}
  local session = opts.session or config.options.session.telescope
  local zone = opts.zone or config.options.zone
  local picker_kind = opts.hierarchy or "search"
  local cat = CATEGORIES[picker_kind] or CATEGORIES.search

  pickers
    .new(opts, {
      prompt_title = cat.title,
      -- Debounce generously: Roon Core chokes on rapid back-to-back sessions,
      -- so waiting for the user to stop typing costs less than collecting
      -- failed intermediate searches.
      debounce = 400,
      finder = finders.new_dynamic({
        fn = function(prompt)
          if not prompt or #prompt < 2 then
            return {}
          end
          local items = fetch_items(session, cat.category, prompt)
          if not items then
            return {}
          end
          local results = {}
          for _, it in ipairs(items) do
            local hint = nilify(it.hint)
            local item_key = nilify(it.item_key)
            if hint ~= "header" and item_key then
              table.insert(results, {
                item_key = item_key,
                title = nilify(it.title) or "",
                subtitle = nilify(it.subtitle) or "",
                hint = hint,
              })
            end
          end
          return results
        end,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = item.title .. " " .. item.subtitle,
            display = function()
              return displayer({
                { item.title, "TelescopeResultsIdentifier" },
                { item.subtitle, "TelescopeResultsComment" },
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = false,
      attach_mappings = function(prompt_bufnr, map)
        ---Category pickers (Artists / Albums) can play via Roon's
        ---search-and-play CLI shortcut (`roon play -A <artist>` /
        ---`roon play -a <album>`) instead of walking the browse tree.
        ---This is both faster and immune to session-cursor drift when
        ---the picker's finder refetched between display and selection.
        ---Only works for "play-now" — queue / start-radio still need
        ---the action-list drill.
        local function shortcut_play(title)
          if action_state then end -- no-op to keep upvalue captured below
          -- Only use search-and-play for Artists: artist names are
          -- (usually) unique enough that Roon's fuzzy match lands on
          -- the right result. Album titles collide across artists
          -- ("21", "Untitled", ...) and `--album` cannot be scoped to
          -- the artist, so prefer the drill + play-item path for
          -- Albums even though it is slightly slower.
          if cat.category == "Artists" then
            return { "play", "--artist", title }
          end
          return nil
        end

        local function fire(action)
          return function()
            local e = action_state.get_selected_entry()
            if not e or not e.value or not e.value.item_key then
              return
            end
            actions.close(prompt_bufnr)

            -- Artist selection opens a submenu (Play / Shuffle / Browse
            -- albums / Queue / Start Radio) instead of playing directly,
            -- since "play an artist" has more useful modes than just
            -- play-now. Queue / Start Radio shortcuts still fire directly.
            if action == "play-now" and cat.category == "Artists"
              and type(e.value.title) == "string" and e.value.title ~= "" then
              open_artist_submenu(opts or {}, e.value.title, e.value.item_key)
              return
            end

            if action == "play-now" and type(e.value.title) == "string" and e.value.title ~= "" then
              local args = shortcut_play(e.value.title)
              if args then
                if zone and zone ~= "" then
                  table.insert(args, "--zone")
                  table.insert(args, zone)
                end
                cli.exec_async(args)
                return
              end
            end

            local key, err = resolve_action_key(session, e.value.item_key, e.value.hint, action)
            if not key then
              vim.notify("roon: " .. (err or "could not resolve playable action"), vim.log.levels.ERROR)
              return
            end
            cli.play_item_async(session, key, zone, action)
          end
        end
        actions.select_default:replace(fire("play-now"))
        map("i", "<C-q>", fire("queue"))
        map("i", "<C-r>", fire("start-radio"))
        return true
      end,
    })
    :find()
end

return M
