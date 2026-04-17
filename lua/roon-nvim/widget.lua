---Persistent floating-window "Now Playing" widget. Pinned to a screen
---corner and updated in place whenever the watch snapshot mutates, so
---the user always has a glanceable status card — unlike the toast
---variant in card.lua which disappears after a few seconds.
local config = require("roon-nvim.config")
local card = require("roon-nvim.card")
local state = require("roon-nvim.state")

local M = {}

local buf = nil
local win = nil
local visible = false

local POSITIONS = {
  SE = { anchor = "SE", row_from_bottom = 1, col_is_right = true },
  SW = { anchor = "SW", row_from_bottom = 1, col_is_right = false },
  NE = { anchor = "NE", row_from_bottom = nil, col_is_right = true },
  NW = { anchor = "NW", row_from_bottom = nil, col_is_right = false },
}

local function window_config(lines_count, pos_key)
  local opts = config.options.card
  local pos = POSITIONS[pos_key] or POSITIONS.SE
  local width = opts.width or 48
  local height = math.max(lines_count, 1)
  -- A 1-column margin from the edge looks better than pressing against it.
  local margin = 1
  local row
  if pos.row_from_bottom then
    -- vim.o.lines - cmdline(1) - margin so the card sits just above the
    -- statusline/cmdline.
    row = vim.o.lines - vim.o.cmdheight - margin
  else
    row = margin
  end
  local col
  if pos.col_is_right then
    col = vim.o.columns - margin
  else
    col = margin
  end
  return {
    relative = "editor",
    anchor = pos.anchor,
    row = row,
    col = col,
    width = width,
    height = height,
    focusable = false,
    style = "minimal",
    border = "rounded",
    zindex = 50,
    noautocmd = true,
  }
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "roon-card"
  return buf
end

local function render_into_buf(lines, title)
  ensure_buf()
  vim.bo[buf].modifiable = true
  -- Leading blank line acts as a title row: `filler :: title`.
  local display = vim.list_extend({ "  " .. (title or "") }, lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display)
  vim.bo[buf].modifiable = false
end

local function update_win(lines)
  local pos_key = config.options.card.position or "SE"
  local win_cfg = window_config(#lines + 1, pos_key) -- +1 for title line
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, win_cfg)
  else
    win = vim.api.nvim_open_win(buf, false, win_cfg)
    -- Dim the title line for a bit of hierarchy.
    vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  end
end

---Render the widget for the current state. Safe to call repeatedly —
---in-place update, no flicker. No-op if mode != "pinned".
function M.refresh()
  if not visible then
    return
  end
  if config.options.card.mode ~= "pinned" then
    M.close()
    return
  end
  local z = state.primary_zone(config.options.zone)
  if not z then
    render_into_buf({ "(waiting for Roon Core…)" }, "Roon")
  else
    render_into_buf(card.format(z), "Roon — " .. z.display_name)
  end
  update_win(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

function M.open()
  visible = true
  M.refresh()
end

function M.close()
  visible = false
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

function M.toggle()
  if visible and win and vim.api.nvim_win_is_valid(win) then
    M.close()
  else
    M.open()
  end
end

function M.is_open()
  return visible and win and vim.api.nvim_win_is_valid(win) or false
end

---Wire the widget to state changes and nvim resize events.
function M.setup_autos()
  state.subscribe(function()
    if visible then
      vim.schedule(M.refresh)
    end
  end)
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if visible then
        M.refresh()
      end
    end,
    desc = "roon-nvim: reposition card on resize",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.close()
    end,
    desc = "roon-nvim: close card on exit",
  })
end

return M
