---Persistent floating-window "Now Playing" widget. Pinned to a screen
---corner and updated in place whenever the watch snapshot mutates, so
---the user always has a glanceable status card — unlike the toast
---variant in card.lua which disappears after a few seconds.
local config = require("roon.config")
local card = require("roon.card")
local state = require("roon.state")
local art = require("roon.art")

local M = {}

local buf = nil
local win = nil
local visible = false

-- Optional art float lifecycle (opt-in via config.options.card.art).
local art_buf = nil
local art_win = nil
local art_placement = nil
local last_image_key = nil
-- Monotonic counter so a fetch that returns stale is rejected by its own
-- callback. Bumped on (a) a newer track fetch superseding an older one and
-- (b) detach_art() — so an in-flight fetch that completes *after* the widget
-- was hidden never resurrects the art float on its own. The invariant we
-- protect: an art window exists only while `visible` is true.
local fetch_seq = 0

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

-- nvim_win_set_config rejects `noautocmd` on existing windows — it only has
-- meaning at window creation via nvim_open_win. Strip it before reconfiguring.
local function config_for_update(cfg)
  local c = vim.deepcopy(cfg)
  c.noautocmd = nil
  return c
end

local function update_win(lines)
  local pos_key = config.options.card.position or "SE"
  local win_cfg = window_config(#lines + 1, pos_key) -- +1 for title line
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config_for_update(win_cfg))
  else
    win = vim.api.nvim_open_win(buf, false, win_cfg)
    -- Dim the title line for a bit of hierarchy.
    vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  end
end

-- ─────────────────────────────────────────────────────────────────────────
-- Album art float
-- ─────────────────────────────────────────────────────────────────────────

---Compute the art window's geometry so it sits adjacent to the main card,
---sharing a vertical edge. `cells` is the square side length.
---@param cells integer
---@return table
local function art_window_config(cells)
  local card_cfg = config.options.card
  local pos_key = card_cfg.position or "SE"
  local pos = POSITIONS[pos_key] or POSITIONS.SE
  local side = card_cfg.art.position or "left"
  local width = card_cfg.width or 48
  local margin = 1

  local row
  if pos.row_from_bottom then
    row = vim.o.lines - vim.o.cmdheight - margin
  else
    row = margin
  end

  -- Anchor matches the card's anchor vertically; horizontally we flip so
  -- the art hugs either side of the card.
  local anchor
  local col
  if side == "left" then
    -- Art's right edge should touch the card's left edge.
    if pos.col_is_right then
      anchor = pos.anchor -- card's SE/NE → art also anchors right, offset by card width.
      col = vim.o.columns - margin - width - 1
    else
      anchor = pos.anchor -- card's SW/NW → art also left-anchored.
      col = margin - cells - 1
    end
  else -- "right"
    if pos.col_is_right then
      anchor = pos.anchor
      col = vim.o.columns - margin + cells + 1
    else
      anchor = pos.anchor
      col = margin + width + 1
    end
  end

  return {
    relative = "editor",
    anchor = anchor,
    row = row,
    col = col,
    width = cells * 2, -- cells are narrower than tall; double columns for near-square.
    height = cells,
    focusable = false,
    style = "minimal",
    border = "rounded",
    zindex = 49, -- just behind the card so the border doesn't double-draw
    noautocmd = true,
  }
end

local function ensure_art_buf(cells)
  if not (art_buf and vim.api.nvim_buf_is_valid(art_buf)) then
    art_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[art_buf].buftype = "nofile"
    vim.bo[art_buf].bufhidden = "hide"
    vim.bo[art_buf].swapfile = false
    vim.bo[art_buf].filetype = "roon-art"
  end
  -- Blank buffer; snacks will lay the image on top via its placement.
  vim.bo[art_buf].modifiable = true
  local line = string.rep(" ", cells * 2)
  local lines = {}
  for _ = 1, cells do
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_lines(art_buf, 0, -1, false, lines)
  vim.bo[art_buf].modifiable = false
  return art_buf
end

local function detach_art()
  -- Supersede any in-flight fetch: its callback checks `seq ~= fetch_seq`
  -- and bails, so a fetch that finishes after this point cannot re-open the
  -- art float while the widget is hidden.
  fetch_seq = fetch_seq + 1
  if art_placement then
    pcall(function()
      art_placement:close()
    end)
    art_placement = nil
  end
  if art_win and vim.api.nvim_win_is_valid(art_win) then
    pcall(vim.api.nvim_win_close, art_win, true)
  end
  art_win = nil
  last_image_key = nil
end

local function attach_art(image_path)
  -- Art is strictly subordinate to the player widget: never paint it while
  -- the widget is hidden. Guards the async fetch callback, which can land
  -- after the user (or VimLeavePre) closed the widget.
  if not visible then
    return
  end
  local cells = config.options.card.art.size or 12
  ensure_art_buf(cells)
  local cfg = art_window_config(cells)
  if art_win and vim.api.nvim_win_is_valid(art_win) then
    vim.api.nvim_win_set_config(art_win, config_for_update(cfg))
  else
    art_win = vim.api.nvim_open_win(art_buf, false, cfg)
    vim.wo[art_win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
  end
  if art_placement then
    pcall(function()
      art_placement:close()
    end)
    art_placement = nil
  end
  local ok, placement = pcall(function()
    return require("snacks.image.placement").new(art_buf, image_path, {
      pos = { 1, 0 },
      auto_resize = true,
      inline = false,
    })
  end)
  if ok then
    art_placement = placement
  end
end

local function maybe_update_art(zone)
  -- Belt-and-suspenders: refresh() already returns early when hidden, but
  -- never let any future caller start an art fetch for a hidden widget.
  if not visible then
    detach_art()
    return
  end
  if not config.options.card.art.enabled then
    if art_win then
      detach_art()
    end
    return
  end
  if not art.supported() then
    return
  end
  local key = zone and zone.now_playing and zone.now_playing.image_key or nil
  if not key or key == "" then
    if art_win then
      detach_art()
    end
    return
  end
  if key == last_image_key and art_placement ~= nil then
    -- Art is already showing this exact image; just reposition if needed.
    local cells = config.options.card.art.size or 12
    if art_win and vim.api.nvim_win_is_valid(art_win) then
      pcall(vim.api.nvim_win_set_config, art_win, config_for_update(art_window_config(cells)))
    end
    return
  end
  last_image_key = key
  fetch_seq = fetch_seq + 1
  local seq = fetch_seq
  local cells = config.options.card.art.size or 12
  art.fetch(key, cells * 20, function(path, err)
    if seq ~= fetch_seq then
      return -- a newer fetch supersedes this result
    end
    if not path then
      return -- silent: just leave the previous art or blank space
    end
    attach_art(path)
  end)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────

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
  maybe_update_art(z)
end

function M.open()
  visible = true
  M.refresh()
end

function M.close()
  visible = false
  detach_art()
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
    desc = "roon.nvim: reposition card on resize",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.close()
    end,
    desc = "roon.nvim: close card on exit",
  })
end

return M
