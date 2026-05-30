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

-- ─────────────────────────────────────────────────────────────────────────
-- Batteries-included statusline integration
--
-- `component()` above is the SDK-pure factory — consumers that lay out their
-- statusline by hand place it wherever they want. The helpers below own the
-- common "append to heirline + toggle visibility" case so a lazy-loaded
-- consumer doesn't have to reimplement the glue. heirline.nvim's runtime API
-- is required lazily here (pcall-guarded), so this module stays usable by
-- non-heirline callers of `component()`.
-- ─────────────────────────────────────────────────────────────────────────

-- Marks the wrapper component so attach() is idempotent across re-fires.
local STATUSLINE_MARKER = "roon_np"

---Default the visibility flag to hidden on first touch.
local function ensure_visibility()
  if vim.g.roon_statusline_visible == nil then
    vim.g.roon_statusline_visible = false
  end
end

---Append the now-playing component to heirline's live statusline. Idempotent:
---the wrapper carries a `roon_np` marker (via `static`), so repeated calls
---never stack duplicates. Appends at the end so existing components keep their
---ids. The wrapper gates on `vim.g.roon_statusline_visible`, so it renders
---nothing until shown via toggle().
---@param opts table|nil  forwarded to component() (e.g. { zone, icons })
---@return boolean attached  false if heirline isn't available yet
function M.attach(opts)
  local ok, heirline = pcall(require, "heirline")
  if not ok then
    return false
  end
  local sl = heirline.statusline
  if not sl then
    return false
  end
  for _, child in ipairs(sl) do
    if child[STATUSLINE_MARKER] then
      return true -- already attached
    end
  end
  ensure_visibility()
  local wrapper = {
    static = { [STATUSLINE_MARKER] = true },
    condition = function()
      return vim.g.roon_statusline_visible == true
    end,
    M.component(opts),
  }
  local idx = #sl + 1
  sl[idx] = sl:new(wrapper, idx)
  vim.schedule(function()
    vim.cmd("redrawstatus")
  end)
  return true
end

---Flip the now-playing component's visibility. Idempotently attaches first so
---the toggle works even before an explicit attach() (e.g. when wired only to
---:RoonStatuslineToggle).
---@return boolean visible  the new visibility state
function M.toggle()
  M.attach()
  vim.g.roon_statusline_visible = not vim.g.roon_statusline_visible
  vim.cmd("redrawstatus")
  return vim.g.roon_statusline_visible
end

---Set visibility explicitly (attaches first).
---@param visible boolean
function M.set_visible(visible)
  M.attach()
  vim.g.roon_statusline_visible = visible and true or false
  vim.cmd("redrawstatus")
end

return M
