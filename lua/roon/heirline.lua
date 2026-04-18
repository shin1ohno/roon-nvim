local config = require("roon.config")
local state = require("roon.state")

local M = {}

local DEFAULT_ICONS = {
  playing = "▶",
  paused = "⏸",
  loading = "⋯",
  stopped = "■",
}

---Builds a heirline component spec for the currently-targeted Roon zone.
---Uses the `flexible` pattern so the widget gracefully shrinks instead of
---getting truncated when the statusline runs out of space.
---@param opts table|nil  -- { zone = "Kitchen", icons = {...} }
---@return table
function M.component(opts)
  opts = opts or {}
  local icons = vim.tbl_deep_extend("force", DEFAULT_ICONS, opts.icons or {})

  local function pick_zone()
    return state.primary_zone(opts.zone or config.options.zone)
  end

  local function now_playing(z)
    local np = z and z.now_playing
    if not np then
      return nil, nil, nil
    end
    local three = np.three_line or {}
    local two = np.two_line or {}
    local one = np.one_line or {}
    return three.line1 or two.line1 or one.line1, three.line2 or two.line2, three.line3
  end

  return {
    update = {
      "User",
      pattern = "RoonNvimState",
      callback = vim.schedule_wrap(function()
        vim.cmd("redrawstatus")
      end),
    },
    init = function(self)
      self.zone = pick_zone()
    end,
    condition = function(self)
      return self.zone ~= nil
    end,
    hl = function(self)
      if self.zone.state == "playing" then
        return { fg = "green" }
      elseif self.zone.state == "paused" then
        return { fg = "yellow" }
      end
      return { fg = "fg" }
    end,
    -- flexible children: heirline picks the WIDEST that fits.
    -- Order matters — `flexible = N` prioritises smaller N when cramped.
    {
      flexible = 1,

      -- Tier 1: icon + zone + " title — artist"
      {
        provider = function(self)
          local z = self.zone
          local title, artist = now_playing(z)
          local icon = icons[z.state] or icons.stopped
          if not title then
            return string.format(" %s %s ", icon, z.display_name)
          end
          if artist and artist ~= "" then
            return string.format(" %s %s  %s — %s ", icon, z.display_name, title, artist)
          end
          return string.format(" %s %s  %s ", icon, z.display_name, title)
        end,
      },

      -- Tier 2: icon + " title — artist" (drop the zone name)
      {
        provider = function(self)
          local z = self.zone
          local title, artist = now_playing(z)
          local icon = icons[z.state] or icons.stopped
          if not title then
            return string.format(" %s %s ", icon, z.display_name)
          end
          if artist and artist ~= "" then
            return string.format(" %s %s — %s ", icon, title, artist)
          end
          return string.format(" %s %s ", icon, title)
        end,
      },

      -- Tier 3: icon + title
      {
        provider = function(self)
          local z = self.zone
          local title = now_playing(z)
          local icon = icons[z.state] or icons.stopped
          if not title then
            return string.format(" %s %s ", icon, z.display_name)
          end
          return string.format(" %s %s ", icon, title)
        end,
      },

      -- Tier 4: icon only (minimum)
      {
        provider = function(self)
          return " " .. (icons[self.zone.state] or icons.stopped) .. " "
        end,
      },
    },
  }
end

return M
