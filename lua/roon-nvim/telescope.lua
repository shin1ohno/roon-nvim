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
            cli.play_item_async(session, e.value.item_key, zone, action)
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
