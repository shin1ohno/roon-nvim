local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")

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
          if cat.category == "Artists" then
            return { "play", "--artist", title }
          elseif cat.category == "Albums" then
            return { "play", "--album", title }
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
