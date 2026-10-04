# Contributing

## Updating dependencies

When you add, remove, or update a dependency in `build.zig.zon`, run this
command from the repository root to update `build.zig.zon.nix`:

```sh
nix develop --command zon2nix --nix=build.zig.zon.nix build.zig.zon
```

This requires Nix with flakes enabled and network access. Include the
generated file alongside your dependency changes in the same commit.
