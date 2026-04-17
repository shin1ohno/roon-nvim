# roon-nvim

Neovim integration for [roon-rs](https://github.com/shin1ohno/roon-rs)'s `roon` CLI. Three surfaces:

- **heirline** player component — live now-playing from `roon watch`
- **neo-tree** source `roon` — browse Roon's library as a tree
- **telescope** extension `roon` — live search + play / queue / start-radio

Works against an already-paired Roon Core (run `roon discover` once from a terminal first).

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`)
- `roon` on `$PATH` (from roon-rs ≥ 0.5.0)
- heirline.nvim, neo-tree.nvim, telescope.nvim

## Install (Lazy.nvim)

```lua
{
  "shin1ohno/roon-nvim",
  dependencies = {
    "rebelot/heirline.nvim",
    "nvim-neo-tree/neo-tree.nvim",
    "nvim-telescope/telescope.nvim",
  },
  opts = {
    zone = "Qutest",   -- default zone for play actions
  },
  config = function(_, opts)
    require("roon-nvim").setup(opts)
  end,
}
```

## License

Dual MIT / Apache-2.0.
