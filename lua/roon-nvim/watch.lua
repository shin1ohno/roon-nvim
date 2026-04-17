local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")
local state = require("roon-nvim.state")

local M = {}

local handle = nil
local should_run = false
local backoff_s = nil

local THROTTLE_MS = 250
local last_autocmd_fire = 0

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

local function on_exit(code)
  handle = nil
  state.reset()
  throttled_redraw()
  if should_run then
    vim.notify(
      string.format("roon watch exited (%d); restarting", code),
      code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
    )
    schedule_restart()
  end
end

function M.start()
  if handle and handle.is_alive() then
    return
  end
  should_run = true
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
  desc = "roon-nvim: stop watch job on exit",
})

return M
