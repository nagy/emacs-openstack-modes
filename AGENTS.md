# AGENTS.md

## Project

`emacs-openstack-modes` — Emacs major modes for displaying OpenStack
resources.  Every OpenStack resource has a unique ID.  The project
starts with one base mode that handles the ID; future resource-specific
modes (servers, volumes, images, networks, …) derive from it and add
their own rendering.

## Files

| File | Purpose |
|---|---|
| `openstack-mode.el` | Base major mode, handles the resource ID |
| `openstack-mode-tests.el` | ERT test suite |
| `default.nix` | Nix build with `melpaBuild` |
| `README.org` | Project README |
| `LICENSE` | AGPLv3 |

## Build & test

```sh
nix-build default.nix
```

The `checkPhase` byte-compiles both `.el` files with warnings as
errors, runs the ERT suite, and runs checkdoc over the package file.

Without Nix:

```sh
emacs --batch -L . -l openstack-mode-tests.el \
  -f ert-run-tests-batch-and-exit
```

## Conventions

- Single base mode `openstack-mode` in one file; tests in a
  separate `-tests.el` file; nothing else yet.
- The resource ID lives in the buffer-local `openstack--id`.
  Derived modes inherit ID handling; they never touch this variable
  directly except via `openstack-set-id`.
- `openstack-display` is the single entry point: it creates
  the display buffer, records the origin buffer, sets the ID, enters
  the mode, and renders the resource.  Derived modes should override
  the rendering part.
- Interactive commands signal `user-error` when no ID is set; helper
  functions return nil unless called with the `errorp` argument.
- Derived modes go in their own file and require
  `openstack-mode`.  Add a new `default.nix`-only package
  entry per mode (one `melpaBuild` per `.el` package) when a mode is
  added.
- `checkdoc` must pass; docstrings follow the imperative style.
- Tests use `unwind-protect` around temporary buffers.

## TODO

- Derived modes for specific resource types (servers, volumes,
  images, networks, …).
