local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("telescope.nvim is required for the roon extension")
end

return telescope.register_extension({
  exports = {
    search = function(opts)
      require("roon-nvim.telescope").search(opts)
    end,
  },
})
