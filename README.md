# roon-nvim

Neovim integration for [roon-rs](https://github.com/shin1ohno/roon-rs)'s `roon` CLI — control a Roon audio system from inside Neovim.

Three surfaces:

- **heirline** player component — live now-playing from `roon watch` (streaming NDJSON)
- **neo-tree** source `roon` — browse Roon's library as a tree, `<CR>` to play
- **telescope** extension `roon` — live search, `<CR>` play-now, `<C-q>` queue, `<C-r>` start-radio

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`)
- `roon` CLI from [roon-rs](https://github.com/shin1ohno/roon-rs) ≥ 0.5.0 on `$PATH`
- A paired Roon Core — run `roon discover` once from a terminal first (also run `roon zone` to pick a default zone)
- `heirline.nvim`, `nvim-neo-tree/neo-tree.nvim`, `nvim-telescope/telescope.nvim`

## Install

### Lazy.nvim

```lua
{
  "shin1ohno/roon-nvim",   -- or: dir = "~/ManagedProjects/roon-nvim" for local dev
  dependencies = {
    "rebelot/heirline.nvim",
    "nvim-neo-tree/neo-tree.nvim",
    "nvim-telescope/telescope.nvim",
  },
  opts = {
    zone = "Qutest",                -- play actions default to this zone
    -- cli  = "roon",               -- override binary location
    -- host = nil, port = nil,      -- override CLI defaults (else uses ~/.config/roon-rs/cli.toml)
    -- watch = { auto_start = true, seek_hz = 1.0 },
  },
  config = function(_, opts)
    require("roon-nvim").setup(opts)
  end,
}
```

### Per-surface wiring

After `setup{}` the core is live (the `roon watch` job starts and `state` is populated), but the three UI surfaces must be wired individually:

#### heirline

Drop the component anywhere in your statusline spec:

```lua
local roon = require("roon-nvim.heirline").component()

require("heirline").setup({
  statusline = {
    -- … your existing sections …
    roon,
  },
})
```

**AstroNvim** users (who drive heirline via `astrocommunity.recipes.heirline-nvchad-statusline` or similar) can extend the existing spec — for example, in `lua/plugins/heirline.lua`:

```lua
return {
  "rebelot/heirline.nvim",
  opts = function(_, opts)
    opts.statusline = opts.statusline or {}
    table.insert(opts.statusline, require("roon-nvim.heirline").component())
    return opts
  end,
}
```

Optional component arguments: `component({ zone = "Kitchen", icons = { playing = "♫" } })`.

#### neo-tree

Add `"roon"` to your existing sources list, then open with `:Neotree roon`:

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    sources = { "filesystem", "buffers", "git_status", "roon" },
    -- optional: show Roon as a tab in the source selector
    source_selector = {
      winbar = true,
      sources = {
        { source = "filesystem" },
        { source = "buffers" },
        { source = "git_status" },
        { source = "roon", display_name = "♪ Roon" },
      },
    },
  },
}
```

Default bindings inside the Roon tree:

| key    | action                                                      |
| ------ | ----------------------------------------------------------- |
| `<CR>` | directory ⇒ expand/collapse; leaf ⇒ play-now                |
| `P`    | play-now on the current node                                |
| `q`    | queue                                                       |
| `r`    | start-radio                                                 |
| `R`    | refresh                                                     |

#### telescope

```lua
require("telescope").load_extension("roon")
-- then: :Telescope roon search
```

| mapping | action      |
| ------- | ----------- |
| `<CR>`  | play-now    |
| `<C-q>` | queue       |
| `<C-r>` | start-radio |

## Local development

During iteration, point Lazy at the local checkout:

```lua
{
  dir = "~/ManagedProjects/roon-nvim",
  dev = true,
  -- same dependencies / opts as above
}
```

## Troubleshooting

- `statusline shows nothing`: confirm the watch job is alive — `:lua print(require("roon-nvim.watch").is_running())`. If false, check `:lua print(require("roon-nvim.config").options.cli)` resolves to a working binary and `roon watch` runs from a shell.
- `play-item returns "no matching action"`: the selected item doesn't have a Play/Queue/Radio action in Roon. Drill one level deeper in neo-tree (to the album's "Play Album" entry) and try again. The error surface includes the list of actual action titles the item offers.
- `empty search results`: try a longer query (< 2 chars are suppressed). Roon's search is weighted toward well-tagged library content.
- `session cursor stuck`: delete `~/.config/roon-rs/sessions/<key>.toml` (neo-tree uses `nvim-neotree`, telescope uses `nvim-telescope`) and retry.

## Architecture

```
┌──────────────────────────┐         ┌──────────────────────────────┐
│    heirline component    │◄────────│  roon-nvim.state (pub/sub)   │
│    (reads on redraw)     │         │    zones / outputs snapshot  │
└──────────────────────────┘         └───────────────▲──────────────┘
                                                     │
┌──────────────────────────┐                         │
│   neo-tree source "roon" │                         │
│   (per-click vim.system) │       ┌─────────────────┴──────────────┐
└──────────────────────────┘       │       roon-nvim.watch          │
                                   │    (long-running jobstart)     │
┌──────────────────────────┐       └────────────────▲───────────────┘
│ telescope ext. "roon"    │                        │
│ (per-keystroke, debounced│                        │
└──────────────────────────┘                        │
             │                                      │
             │          ┌──────────────┐   stream   │
             └────────► │   roon CLI   │◄───────────┘
                        └──────┬───────┘
                               │ MOO+SOOD
                               ▼
                        ┌──────────────┐
                        │  Roon Core   │
                        └──────────────┘
```

## License

Dual MIT / Apache-2.0.
