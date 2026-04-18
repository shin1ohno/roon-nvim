-- Neo-tree requires each source to expose a `components` module (see
-- neo-tree/setup/init.lua:538). Roon does not add renderer components of its
-- own; the item renderer relies on the built-in `name`, `icon`, and `indent`
-- components defined in `neo-tree.sources.common.components`. Re-export that
-- module so `require("neo-tree.sources.roon.components")` succeeds.

return require("neo-tree.sources.common.components")
