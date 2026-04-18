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

---@param opts table|nil
function M.search(opts)
  opts = opts or {}
  local session = opts.session or config.options.session.telescope
  local zone = opts.zone or config.options.zone

  pickers
    .new(opts, {
      prompt_title = "Roon Search",
      debounce = 150,
      finder = finders.new_dynamic({
        fn = function(prompt)
          if not prompt or #prompt < 2 then
            return {}
          end
          local ok, resp = cli.oneshot_sync({
            "search",
            "--session",
            session,
            "--input",
            prompt,
            "--count",
            "50",
          })
          if not ok or not resp or not resp.items then
            return {}
          end
          local results = {}
          for _, it in ipairs(resp.items) do
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
        local function fire(action)
          return function()
            local e = action_state.get_selected_entry()
            if not e or not e.value or not e.value.item_key then
              return
            end
            actions.close(prompt_bufnr)
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
