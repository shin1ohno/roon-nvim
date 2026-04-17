local M = {}

---@param opts table|nil
function M.setup(opts)
  require("roon-nvim.config").apply(opts or {})
  if require("roon-nvim.config").options.watch.auto_start then
    require("roon-nvim.watch").start()
  end
end

return M
