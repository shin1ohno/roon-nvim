local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")

local M = {}

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
          return vim.tbl_filter(function(it)
            return it.hint ~= "header" and it.item_key
          end, resp.items)
        end,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = (item.title or "") .. " " .. (item.subtitle or ""),
            display = function()
              return displayer({
                { item.title or "", "TelescopeResultsIdentifier" },
                { item.subtitle or "", "TelescopeResultsComment" },
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
