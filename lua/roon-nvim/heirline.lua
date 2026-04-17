local config = require("roon-nvim.config")
local state = require("roon-nvim.state")

local M = {}

local ICONS = {
  playing = "▶",
  paused = "⏸",
  loading = "…",
  stopped = "■",
}

---Returns a heirline component spec for the currently-targeted Roon zone's
---now-playing text. Inserted into the user's statusline as any other spec.
---@param opts table|nil  -- { zone = "Kitchen", icons = {...} }
---@return table
function M.component(opts)
  opts = opts or {}
  local icons = vim.tbl_deep_extend("force", ICONS, opts.icons or {})

  return {
    update = {
      "User",
      pattern = "RoonNvimState",
      callback = vim.schedule_wrap(function()
        vim.cmd("redrawstatus")
      end),
    },
    init = function(self)
      local preferred = opts.zone or config.options.zone
      self.zone = state.primary_zone(preferred)
    end,
    {
      condition = function(self)
        return self.zone ~= nil
      end,
      provider = function(self)
        local z = self.zone
        local icon = icons[z.state] or icons.stopped
        local np = z.now_playing and z.now_playing.one_line and z.now_playing.one_line.line1 or ""
        if np == "" then
          return string.format(" %s %s ", icon, z.display_name)
        end
        return string.format(" %s %s  %s ", icon, z.display_name, np)
      end,
      hl = function(self)
        if self.zone.state == "playing" then
          return { fg = "green" }
        elseif self.zone.state == "paused" then
          return { fg = "yellow" }
        end
        return { fg = "fg" }
      end,
    },
  }
end

return M
