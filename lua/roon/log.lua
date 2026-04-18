---In-memory ring buffer capturing everything roon.nvim sends to vim.notify.
---Exposed via `:RoonLog` so the user can audit what's been firing even after
---the notification toast has disappeared from the screen.
local M = {}

local MAX = 200
local entries = {}

local LEVEL_NAMES = { [0] = "TRACE", [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR", [5] = "OFF" }

---Record a notification. Keeps the most recent MAX entries.
---@param msg string
---@param level integer|nil
---@param ctx string|nil  -- optional call-site label ("watch", "card", ...)
function M.record(msg, level, ctx)
  local lvl = LEVEL_NAMES[level or vim.log.levels.INFO] or tostring(level)
  local ts = os.date("%H:%M:%S")
  table.insert(entries, {
    ts = ts,
    level = lvl,
    ctx = ctx or "-",
    msg = msg,
  })
  if #entries > MAX then
    table.remove(entries, 1)
  end
end

---@return table[]
function M.entries()
  return entries
end

function M.clear()
  entries = {}
end

---Open the log in a scratch buffer. Much easier to scroll than :messages.
function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, string.format("[%s] %-5s %s: %s", e.ts, e.level, e.ctx, e.msg))
  end
  if #lines == 0 then
    lines = { "(no roon.nvim log entries yet)" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, "roon://log")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  -- Jump to the tail.
  vim.api.nvim_win_set_cursor(0, { math.max(1, #lines), 0 })
end

return M
