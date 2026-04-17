local M = {}

---Wrap vim.notify so every message roon-nvim fires is also written to
---the in-memory log, viewable with :RoonLog. Leaves the original
---vim.notify intact for messages from other plugins. Idempotent — a
---second setup() call does not stack another layer of wrapping.
local function install_notify_proxy()
  if M._proxied_notify and vim.notify == M._proxied_notify then
    return
  end
  local log = require("roon-nvim.log")
  local orig = vim.notify
  M._proxied_notify = function(msg, level, opts)
    local title = opts and opts.title or nil
    local ctx = "notify"
    if type(title) == "string" and title:match("^Roon") then
      ctx = "card"
    end
    log.record(tostring(msg), level, ctx)
    return orig(msg, level, opts)
  end
  -- Override globally so cli.lua's stderr notifications also get captured.
  vim.notify = M._proxied_notify
end

local function register_commands()
  local control = require("roon-nvim.control")
  local card = require("roon-nvim.card")
  local widget = require("roon-nvim.widget")
  local log = require("roon-nvim.log")
  local config = require("roon-nvim.config")

  -- `:RoonStatus` adapts to the configured card mode: pinned ⇒ toggle
  -- the floating widget; toast ⇒ fire a one-shot notification; off ⇒ no-op.
  local function status()
    local mode = config.options.card.mode
    if mode == "pinned" then
      widget.toggle()
    elseif mode == "toast" then
      card.show()
    end
  end

  local defs = {
    RoonPlay = control.play,
    RoonPause = control.pause,
    RoonStop = control.stop,
    RoonNext = control.next,
    RoonPrevious = control.previous,
    RoonPlayPause = control.play_pause,
    RoonStatus = status,
    RoonShow = widget.open,
    RoonHide = widget.close,
    RoonToast = function()
      card.show()
    end,
    RoonLog = log.show,
    RoonLogClear = log.clear,
  }
  for name, fn in pairs(defs) do
    vim.api.nvim_create_user_command(name, fn, {})
  end
end

---@param opts table|nil
function M.setup(opts)
  require("roon-nvim.config").apply(opts or {})
  install_notify_proxy()
  register_commands()
  require("roon-nvim.card").enable_track_watcher()
  require("roon-nvim.widget").setup_autos()
  if require("roon-nvim.config").options.watch.auto_start then
    require("roon-nvim.watch").start()
  end
  -- Pinned mode auto-opens the widget so the user sees the card without
  -- having to invoke any command. Toast / off modes stay silent.
  if require("roon-nvim.config").options.card.mode == "pinned" then
    vim.defer_fn(function()
      require("roon-nvim.widget").open()
    end, 500)
  end
end

return M
