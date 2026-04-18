local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("telescope.nvim is required for the roon extension")
end

local function picker(default_hierarchy)
  return function(opts)
    opts = opts or {}
    opts.hierarchy = opts.hierarchy or default_hierarchy
    require("roon.telescope").search(opts)
  end
end

return telescope.register_extension({
  exports = {
    search = picker("search"),
    artists = picker("artists"),
    albums = picker("albums"),
    tracks = picker("tracks"),
    composers = picker("composers"),
    genres = picker("genres"),
    playlists = picker("playlists"),
  },
})
