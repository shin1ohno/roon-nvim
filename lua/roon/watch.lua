local cli = require("roon.cli")
local config = require("roon.config")
local state = require("roon.state")

local M = {}

local handle = nil
local should_run = false
local backoff_s = nil

local THROTTLE_MS = 250
local HEALTHY_THRESHOLD_MS = 15000

local last_autocmd_fire = 0
local started_at_ms = 0
-- Tracked for audit via :RoonLog / is_running(); not surfaced as a
-- notification on its own.
local consecutive_failures = 0

---Schedule a throttled `User RoonNvimState` autocmd so heirline and any
---other subscribers redraw. `vim.schedule` because the jobstart callbacks
---run on the libuv loop, and nvim_exec_autocmds must fire on the main loop.
local function throttled_redraw()
  local now = vim.uv.now()
  if now - last_autocmd_fire < THROTTLE_MS then
    return
  end
  last_autocmd_fire = now
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "RoonNvimState" })
  end)
end

local function on_line(ev)
  -- A connection that's survived HEALTHY_THRESHOLD_MS is "healthy" — clear
  -- the failure counter so a later single blip doesn't cross the warn bar.
  if consecutive_failures > 0 and (vim.uv.now() - started_at_ms) > HEALTHY_THRESHOLD_MS then
    consecutive_failures = 0
  end
  state.apply_event(ev)
  throttled_redraw()
end

local function schedule_restart()
  if not should_run then
    return
  end
  local start_s, max_s = config.options.watch.backoff[1], config.options.watch.backoff[2]
  backoff_s = backoff_s and math.min(backoff_s * 2, max_s) or start_s
  vim.defer_fn(function()
    if should_run and (not handle or not handle.is_alive()) then
      M.start()
    end
  end, backoff_s * 1000)
end

local function on_exit(code, stderr_tail)
  handle = nil
  -- Intentionally NOT calling state.reset() here. A reconnect cycle
  -- would otherwise flash the widget to "waiting for Roon Core…"
  -- between every disconnect and the next `initial` snapshot. The new
  -- snapshot overwrites the store atomically when it arrives, so the
  -- stale data in the gap is fine and invisible.
  if not should_run then
    return
  end
  consecutive_failures = consecutive_failures + 1
  -- Clean exits are part of normal operation (Roon Core tears down idle
  -- subscriptions roughly every few seconds on some Core versions).
  -- They are silent; :RoonLog still records the restart count for when
  -- the user wants to audit, and consecutive_failures is reset once the
  -- connection stays alive past HEALTHY_THRESHOLD_MS.
  if code ~= 0 then
    local tail = stderr_tail and stderr_tail ~= "" and ("\n" .. stderr_tail) or ""
    vim.notify(
      string.format("roon watch exited with error (%d)%s", code, tail),
      vim.log.levels.WARN
    )
  end
  schedule_restart()
end

function M.start()
  if handle and handle.is_alive() then
    return
  end
  should_run = true
  started_at_ms = vim.uv.now()
  local seek = tostring(config.options.watch.seek_hz or 1.0)
  handle = cli.stream({ "watch", "--seek-hz", seek }, on_line, on_exit)
  -- Reset backoff on successful start; on_exit re-applies if the process dies.
  backoff_s = nil
end

function M.stop()
  should_run = false
  if handle then
    handle.stop()
    handle = nil
  end
end

function M.is_running()
  return handle and handle.is_alive() or false
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop()
  end,
  desc = "roon.nvim: stop watch job on exit",
})

return M
