local config = require("roon-nvim.config")
local state = require("roon-nvim.state")

local M = {}

local DEFAULT_BAR_WIDTH = 30

---vim.json.decode turns JSON null into vim.NIL (userdata), not Lua nil.
---Coerce any non-number value to 0 so arithmetic doesn't blow up.
---@param v any
---@return number
local function num(v)
  if type(v) == "number" then
    return v
  end
  return 0
end

local function format_time(s)
  s = math.floor(num(s))
  if s < 0 then
    s = 0
  end
  local m = math.floor(s / 60)
  return string.format("%d:%02d", m, s - m * 60)
end

---Render a unicode progress bar. `●` marker moves along `━` (elapsed) /
---`─` (remaining). Returns the bar plus "m:ss / m:ss".
---@param seek number|nil   seconds elapsed
---@param total number|nil  total seconds
---@param width integer
---@return string
local function format_progress(seek, total, width)
  width = width or DEFAULT_BAR_WIDTH
  seek = num(seek)
  total = num(total)
  local ratio
  if total > 0 then
    ratio = math.min(1.0, math.max(0.0, seek / total))
  else
    ratio = 0
  end
  local pos = math.floor(ratio * (width - 1))
  local bar = string.rep("━", pos) .. "●" .. string.rep("─", width - 1 - pos)
  return string.format("%s  %s / %s", bar, format_time(seek), format_time(total))
end

local function icon_for_state(icons, play_state)
  return icons[play_state] or icons.stopped or "?"
end

---Pick the richest available lines from Roon's now_playing object.
---Roon provides one/two/three line variants. Prefer three, fall back.
---@param np table
---@return string, string|nil, string|nil
local function split_lines(np)
  local three = np.three_line or {}
  local two = np.two_line or {}
  local one = np.one_line or {}
  local title = three.line1 or two.line1 or one.line1
  local line2 = three.line2 or two.line2
  local line3 = three.line3
  return title or "(untitled)", line2, line3
end

---Build the card body as an array of strings (one per line).
---@param zone table
---@return string[]
function M.format(zone)
  local opts = config.options.card
  local icons = opts.icons
  local lines = {}
  local np = zone.now_playing

  if not np then
    table.insert(lines, icon_for_state(icons, zone.state) .. "  " .. zone.display_name)
    table.insert(lines, "(nothing playing)")
    return lines
  end

  local title, line2, line3 = split_lines(np)

  table.insert(lines, icons.track .. "  " .. title)
  if line2 and line2 ~= "" then
    table.insert(lines, icons.artist .. "  " .. line2)
  end
  if line3 and line3 ~= "" then
    table.insert(lines, icons.album .. "  " .. line3)
  end
  table.insert(lines, "")
  table.insert(
    lines,
    string.format(
      "%s  %s",
      icon_for_state(icons, zone.state),
      format_progress(zone.seek_position, np.length, opts.bar_width)
    )
  )
  return lines
end

-- Previous nvim-notify handle, when that backend is active. snacks.nvim
-- doesn't use the return value; it dedupes via the `id` option instead.
local last_handle = nil

---Fire the card as a `vim.notify` message. Routes through whichever
---notifier the user has (nvim-notify / snacks.nvim / default).
---@param opts table|nil -- { zone = "Kitchen" }
function M.show(opts)
  opts = opts or {}
  local z = state.primary_zone(opts.zone or config.options.zone)
  if not z then
    vim.notify("roon: no zone to show", vim.log.levels.WARN, { title = "Roon" })
    return
  end
  local body = table.concat(M.format(z), "\n")
  local notify_opts = {
    title = "Roon — " .. z.display_name,
    timeout = config.options.card.timeout,
    -- snacks.nvim deduplicates by this id; nvim-notify ignores it.
    id = "roon-nvim-card",
  }
  -- nvim-notify expects `replace` to be the HANDLE from a previous notify
  -- call (not a string). Passing the raw id as replace errors. Only set
  -- it when we actually have a handle from the last call.
  if last_handle ~= nil and type(last_handle) ~= "string" then
    notify_opts.replace = last_handle
  end
  local ok, result = pcall(vim.notify, body, vim.log.levels.INFO, notify_opts)
  if ok then
    last_handle = result
  end
end

---Watch the state store for *track* changes (title transitions) and
---auto-show the card. Opt-in via config.options.card.notify_on_change.
---@type table<string, string>|nil
local last_title

function M.enable_track_watcher()
  last_title = {}
  state.subscribe(function()
    if not config.options.card.notify_on_change then
      return
    end
    local target = config.options.zone
    for zid, z in pairs(state.zones) do
      if not target or z.display_name == target then
        local np = z.now_playing
        local current = np and np.one_line and np.one_line.line1 or nil
        if current and current ~= last_title[zid] then
          last_title[zid] = current
          -- Schedule to avoid reentrancy from the subscribe callback.
          vim.schedule(function()
            M.show({ zone = z.display_name })
          end)
        end
      end
    end
  end)
end

return M
