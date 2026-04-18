local config = require("roon.config")

local M = {}

---Build the argv for a roon subcommand. Prepends global flags
---(--host/--port) only if the user supplied them in setup().
---@param args string[]   -- { "browse", "--session", "s", ... }
---@return string[]
local function argv(args)
  local opts = config.options
  local out = { opts.cli or "roon" }
  if opts.host then
    table.insert(out, "--host")
    table.insert(out, opts.host)
  end
  if opts.port then
    table.insert(out, "--port")
    table.insert(out, tostring(opts.port))
  end
  for _, a in ipairs(args) do
    table.insert(out, a)
  end
  return out
end

---Blocking one-shot CLI call. Returns (ok, parsed_json, err_string).
---Use only from sync contexts (e.g. telescope dynamic finder, neo-tree navigate).
---@param args string[]
---@return boolean ok
---@return table|nil parsed
---@return string|nil err
function M.oneshot_sync(args)
  local result = vim.system(argv(args), { text = true }):wait()
  if result.code ~= 0 then
    return false, nil, (result.stderr ~= "" and result.stderr) or ("exit " .. tostring(result.code))
  end
  local ok, parsed = pcall(vim.json.decode, result.stdout or "")
  if not ok then
    return false, nil, "json parse: " .. tostring(parsed)
  end
  return true, parsed, nil
end

---Detect transient MOO/WebSocket errors from stderr that typically succeed
---on a short re-attempt.
local function is_transient_err(err)
  if type(err) ~= "string" then return false end
  return err:find("MOO protocol error") ~= nil
    or err:find("Connection reset") ~= nil
    or err:find("connection closed") ~= nil
    or err:find("registry handshake") ~= nil
end

---Fire-and-forget CLI invocation whose stdout is NOT JSON (e.g. play, pause,
---next, previous). Retries once on transient MOO/connection errors, then
---reports failures via vim.notify.
---@param args string[]
function M.exec_async(args)
  local function run(attempt)
    vim.system(argv(args), { text = true }, function(result)
      if result.code == 0 then return end
      local err = (result.stderr ~= "" and result.stderr) or ("exit " .. tostring(result.code))
      if attempt == 1 and is_transient_err(err) then
        vim.defer_fn(function() run(2) end, 300)
        return
      end
      vim.schedule(function()
        vim.notify("roon " .. (args[1] or "?") .. " failed: " .. err, vim.log.levels.ERROR)
      end)
    end)
  end
  run(1)
end

---Async one-shot. Callback runs on main loop via vim.schedule. Retries once
---on transient MOO/connection errors before delivering failure to `cb`.
---@param args string[]
---@param cb fun(ok: boolean, parsed: table|nil, err: string|nil)
function M.oneshot_async(args, cb)
  local function run(attempt)
    vim.system(argv(args), { text = true }, function(result)
      if result.code ~= 0 then
        local err = (result.stderr ~= "" and result.stderr) or ("exit " .. tostring(result.code))
        if attempt == 1 and is_transient_err(err) then
          vim.defer_fn(function() run(2) end, 300)
          return
        end
        vim.schedule(function() cb(false, nil, err) end)
        return
      end
      local ok, parsed = pcall(vim.json.decode, result.stdout or "")
      if not ok then
        vim.schedule(function() cb(false, nil, "json parse: " .. tostring(parsed)) end)
        return
      end
      vim.schedule(function() cb(true, parsed, nil) end)
    end)
  end
  run(1)
end

---Start a long-running job whose stdout is NDJSON.
---Returns a handle { stop = fn, is_alive = fn }. `on_line(parsed)` fires per
---decoded JSON object; malformed lines are skipped silently. Stderr is
---collected into a bounded tail and handed to `on_exit` — it is NEVER
---surfaced as its own notification, since roon-cli's tracing writes warn!
---lines there during normal operation (empty frame hints, reconnects) and
---we do not want them promoted to user-visible toasts.
---@param args string[]
---@param on_line fun(parsed: table)
---@param on_exit fun(code: integer, stderr_tail: string)|nil
---@return table handle
function M.stream(args, on_line, on_exit)
  local buf = ""
  local err_buf = {}
  local ERR_TAIL_LINES = 20
  local alive = true

  local function flush(data)
    if not data then
      return
    end
    buf = buf .. table.concat(data, "\n")
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        local ok, parsed = pcall(vim.json.decode, line)
        if ok and parsed then
          on_line(parsed)
        end
      end
    end
  end

  local function capture_stderr(data)
    if not data then
      return
    end
    for _, line in ipairs(data) do
      if line ~= "" then
        table.insert(err_buf, line)
        if #err_buf > ERR_TAIL_LINES then
          table.remove(err_buf, 1)
        end
      end
    end
  end

  local job = vim.fn.jobstart(argv(args), {
    stdout_buffered = false,
    on_stdout = function(_, data)
      flush(data)
    end,
    on_stderr = function(_, data)
      capture_stderr(data)
    end,
    on_exit = function(_, code)
      alive = false
      if on_exit then
        local tail = table.concat(err_buf, "\n")
        vim.schedule(function()
          on_exit(code, tail)
        end)
      end
    end,
  })

  if job <= 0 then
    alive = false
  end

  return {
    stop = function()
      if alive then
        vim.fn.jobstop(job)
      end
    end,
    is_alive = function()
      return alive
    end,
  }
end

---Fire-and-forget play-item helper used by all three surfaces.
---@param session string
---@param item_key string
---@param zone string|nil
---@param action string  -- "play-now"|"queue"|"start-radio"|"auto"
function M.play_item_async(session, item_key, zone, action)
  local args = { "play-item", "--session", session, "--item-key", item_key, "--action", action }
  if zone and zone ~= "" then
    table.insert(args, "--zone")
    table.insert(args, zone)
  end
  M.oneshot_async(args, function(ok, parsed, err)
    if ok and parsed and parsed.ok then
      local title = (parsed.played and parsed.played.title) or action
      vim.notify("roon: " .. title)
    elseif ok and parsed and parsed.error then
      vim.notify(
        "roon: " .. parsed.error .. " (available: " .. table.concat(parsed.available or {}, ", ") .. ")",
        vim.log.levels.ERROR
      )
    else
      vim.notify("roon: play-item failed — " .. (err or "unknown"), vim.log.levels.ERROR)
    end
  end)
end

return M
