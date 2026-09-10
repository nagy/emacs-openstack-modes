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
| `openstack-cli.el` | CLI layer: `openstack-cli-request` (sync) + `openstack-cli-async-request` (async), `openstack-program` defcustom |
| `openstack-mode-tests.el` | ERT tests for the mode |
| `openstack-cli-tests.el` | ERT tests for the CLI layer (mocked) |
| `flake.nix` | Flake (flake-parts) with `melpaBuild`, patches `openstack-program` to the nixpkgs `openstackclient-full` binary, runs ERT and checkdoc |
| `README.org` | Project README |
| `flake.lock` | Pinned flake inputs |
| `LICENSE` | AGPLv3 |

## Build & test

```sh
nix build          # package; its checkPhase runs the tests
nix flake check    # evaluate/verify all flake outputs
nix fmt            # nixfmt via treefmt
nix develop        # emacs + openstackclient-full
```

The `checkPhase` byte-compiles all `.el` files with warnings as
errors, runs the ERT suite (both test files), and runs checkdoc over
both package files.
The `postPatch` phase substitutes `openstack-program` with the store
path of the nixpkgs `openstackclient-full` package, so the client
works out of the box.

Without Nix:

```sh
emacs --batch -L . -l openstack-mode-tests.el \
  -f ert-run-tests-batch-and-exit
```

## Conventions

- CLI access goes through `openstack-cli.el`: `openstack-cli-request`
  for synchronous calls, `openstack-cli-async-request` for
  asynchronous ones (mirrors the `jsonrpc` library's sync/async
  split).  Derived modes never call `openstack-program` directly.
- `openstack-cli` appends `--format json` automatically; commands
  that produce no output (e.g. `delete`) parse to nil.  Non-zero
  exit or unparseable output signals `openstack-cli-error` (sync) or
  calls `error-fn` (async).
- CLI tests mock at the process level with `cl-letf` on
  `openstack-cli--run` (sync) and `make-process`/
  `set-process-sentinel` (async); they never hit a real OpenStack.
- The `openstack-program` defcustom lives in `openstack-cli.el`
  (the CLI's program), not in the mode file.
  functions return nil unless called with the `errorp` argument.
- Derived modes go in their own file and require
  `openstack-mode`.  Add a package entry per `.el` package
  (one `melpaBuild` per mode) to `flake.nix` when a mode is added.
- Derived modes override rendering by setting the
  `openstack-render-function` defcustom to their own renderer
  (buffer-locally in the mode body, or globally).  Never advise
  private functions like `openstack--render-error`.
- `checkdoc` must pass; docstrings follow the imperative style.
- Interactive entry points carry `;;;###autoload` cookies;
  `openstack-mode-autoloads` / `openstack-cli-autoloads` assert they
  exist.  Add new commands to those tests when adding them to the
  files.
- Tests use `unwind-protect` around temporary buffers.

## TODO

- Derived modes for specific resource types (servers, volumes,
  images, networks, …).
- Commands that run `openstack-program` to fetch real resource data
  (e.g. `openstack server show <id> --format json`) and render it.
