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

  ---Parse a numeric argument. Accepts absolute ("37"), relative ("+10",
  ---"-5"), or empty (nil). Returns (value, is_relative).
  local function parse_num(arg)
    if not arg or arg == "" then
      return nil, false
    end
    local rel = arg:sub(1, 1) == "+" or arg:sub(1, 1) == "-"
    local n = tonumber(arg)
    if not n then
      vim.notify("roon: invalid numeric argument: " .. arg, vim.log.levels.ERROR)
      return nil, false
    end
    return n, rel
  end

  local function seek_cmd(opts)
    local n, rel = parse_num(opts.args)
    if not n then
      return
    end
    control.seek(n, rel)
  end

  local function volume_cmd(opts)
    local n, rel = parse_num(opts.args)
    if not n then
      return
    end
    control.volume(n, rel)
  end

  local defs = {
    RoonPlay = { fn = control.play },
    RoonPause = { fn = control.pause },
    RoonStop = { fn = control.stop },
    RoonNext = { fn = control.next },
    RoonPrevious = { fn = control.previous },
    RoonPlayPause = { fn = control.play_pause },
    RoonStatus = { fn = status },
    RoonShow = { fn = widget.open },
    RoonHide = { fn = widget.close },
    RoonToast = { fn = function() card.show() end },
    RoonLog = { fn = log.show },
    RoonLogClear = { fn = log.clear },

    RoonSeek = { fn = seek_cmd, opts = { nargs = 1 } },
    RoonSeekForward = {
      fn = function()
        control.seek(config.options.steps.seek, true)
      end,
    },
    RoonSeekBack = {
      fn = function()
        control.seek(-config.options.steps.seek, true)
      end,
    },

    RoonVolume = { fn = volume_cmd, opts = { nargs = 1 } },
    RoonVolumeUp = {
      fn = function()
        control.volume(config.options.steps.volume, true)
      end,
    },
    RoonVolumeDown = {
      fn = function()
        control.volume(-config.options.steps.volume, true)
      end,
    },

    RoonMute = { fn = function() control.mute(true) end },
    RoonUnmute = { fn = function() control.mute(false) end },
    RoonMuteToggle = { fn = control.mute_toggle },
  }
  for name, def in pairs(defs) do
    vim.api.nvim_create_user_command(name, def.fn, def.opts or {})
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
