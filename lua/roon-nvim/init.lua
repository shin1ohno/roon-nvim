local M = {}

local function register_commands()
  local control = require("roon-nvim.control")
  local card = require("roon-nvim.card")
  local defs = {
    RoonPlay = control.play,
    RoonPause = control.pause,
    RoonStop = control.stop,
    RoonNext = control.next,
    RoonPrevious = control.previous,
    RoonPlayPause = control.play_pause,
    RoonStatus = function()
      card.show()
    end,
  }
  for name, fn in pairs(defs) do
    vim.api.nvim_create_user_command(name, fn, {})
  end
end

---@param opts table|nil
function M.setup(opts)
  require("roon-nvim.config").apply(opts or {})
  register_commands()
  require("roon-nvim.card").enable_track_watcher()
  if require("roon-nvim.config").options.watch.auto_start then
    require("roon-nvim.watch").start()
  end
end

return M
