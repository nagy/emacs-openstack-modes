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
| `mock-openstack` | Fake client emitting canned JSON; demos/tests without a cloud (point `openstack-program` at it) |
| `flake.nix` | Flake (flake-parts) with `melpaBuild`, patches `openstack-program` to the nixpkgs `openstackclient-full` binary, runs ERT; `checks.lint` runs checkdoc + package-lint |
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
errors and runs the ERT suite (both test files).
Linting lives in `checks.lint` (`nix flake check` builds it):
`package-lint` plus a `checkdoc` gate over both package files.
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
  for synchronous calls (timing out after `openstack-cli-timeout`
  seconds with `openstack-cli-timeout`, a subclass of
  `openstack-cli-error`), `openstack-cli-async-request` for
  asynchronous ones (mirrors the `jsonrpc` library's sync/async
  split).  Derived modes never call `openstack-program` directly.
  Calls pass a token warmed by async calls into the cache
  (`openstack-cli-use-token`) via `OS_TOKEN`; an authentication
  failure retries once without the token.
- `openstack-cli` appends `--format json` automatically; commands
  that produce no output (e.g. `delete`) parse to nil.  Non-zero
  exit or unparseable output signals `openstack-cli-error` (sync) or
  calls `error-fn` (async).  `openstack-cli-async-request` requires
  both callbacks and signals `user-error' if either is missing or
  is not a function.
- CLI tests mock at the process level with `cl-letf` on
  `openstack-cli--run` (sync) and `make-process`/
  `set-process-sentinel` (async); they never hit a real OpenStack.
- The `openstack-program` defcustom lives in `openstack-cli.el`
  (the CLI's program), not in the mode file.
  functions return nil unless called with the `errorp` argument.
- Derived modes go in their own file and require
  `openstack-mode`.  Add a package entry per `.el` package
  (one `melpaBuild` per mode) to `flake.nix` when a mode is added.
- Derived modes override fetching and rendering by setting the
  `openstack-fetch-function` and `openstack-render-function`
  defcustoms (buffer-locally in the mode body, or globally).
  `openstack-fetch-function` receives (ID SUCCESS-FN ERROR-FN),
  must eventually call exactly one of them, and returns its
  process object so the mode can cancel it.  Never advise private
  functions like `openstack--render-error`.
- Display buffers refresh themselves: `openstack-mode` wires
  `revert-buffer-function`, `buffer-stale-function` and
  `auto-revert-mode` into the async pipeline
  (`openstack--refresh` / `openstack--refresh-done`), throttled by
  `openstack-refresh-interval` and limited to visible buffers
  (`openstack-refresh-visible-only`).  Unchanged data (compared
  structurally via `openstack--data-equal-p`, `equal` fails on hash
  tables) is not re-rendered, keeping point and marks.  A refresh
  requested during a running fetch is served on completion.
  Errors keep the last good content and go to the header line.
- Mode-switch rules: `openstack--id`, `openstack--origin-buffer`
  and `openstack--pending` are `permanent-local` (entering a mode
  cancels any in-flight fetch via `openstack--kill-pending`);
  `openstack--last-data`, `openstack--rendered`,
  `openstack--last-fetch-time`, `openstack--last-error` and
  `openstack--fetch-marker` deliberately are not, so a new mode's
  renderer draws its own view.
- `checkdoc` and `package-lint` must pass via `checks.lint`;
  docstrings follow the imperative style.
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
