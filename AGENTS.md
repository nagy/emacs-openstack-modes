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
| `openstack-server.el` | First derived mode: fetches `openstack server show` (async), renders server fields; `openstack-server-display` entry point |
| `openstack-server-list.el` | Collection mode: `openstack server list` as a padded table; `openstack-server-list-display` |
| `openstack-volume.el` | Volume mode: `openstack volume show` via the generic helpers |
| `openstack-image.el` | Image mode: `openstack image show` via the generic helpers |
| `openstack-volume-list.el` | Volume list mode: `openstack volume list` as a padded table; `openstack-volume-list-display` |
| `openstack-image-list.el` | Image list mode: `openstack image list` as a padded table; `openstack-image-list-display` |
| `openstack-network.el` | Network mode: `openstack network show` via the generic helpers; `openstack-network-display` |
| `openstack-network-list.el` | Network list mode: `openstack network list` as a padded table; `openstack-network-list-display` |
| `openstack-mode-tests.el` | ERT tests for the mode |
| `openstack-cli-tests.el` | ERT tests for the CLI layer (mocked) |
| `openstack-server-tests.el` | ERT tests for the server mode |
| `openstack-server-list-tests.el` | ERT tests for the server list mode |
| `openstack-volume-tests.el` | ERT tests for the volume mode |
| `openstack-image-tests.el` | ERT tests for the image mode |
| `openstack-volume-list-tests.el` | ERT tests for the volume list mode |
| `openstack-image-list-tests.el` | ERT tests for the image list mode |
| `openstack-network-tests.el` | ERT tests for the network mode |
| `openstack-network-list-tests.el` | ERT tests for the network list mode |
| `mock-openstack` | Fake client emitting canned JSON; demos/tests without a cloud (point `openstack-program` at it) |
| `flake.nix` | Flake (flake-parts) with one `melpaBuild` for the whole repo (all modes ship in the `openstack-mode` package), patches `openstack-program` to the nixpkgs `openstackclient-full` binary, runs ERT; checks: `package` (build + tests), `package-lint`, `checkdoc`, `treefmt` |
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

The `checkPhase` byte-compiles every `.el` file in the tree with
warnings as errors and runs the ERT suite (all `*-tests.el` files).
No file lists to maintain: the phase globs the source tree, and
`package-build` excludes `*-tests.el` from the package itself.
`nix flake check` builds `checks.package` (same derivation as
`packages.default`, so the tests run there too), plus three policy
checks: `checks.package-lint` (ELPA headers and prefixes),
`checks.checkdoc` (docstrings) and `checks.<system>.treefmt`
(nixfmt).
The `postPatch` phase substitutes `openstack-program` with the store
path of the nixpkgs `openstackclient-full` package, so the client
works out of the box.

Without Nix:

```sh
emacs --batch -L . -l openstack-mode-tests.el \
  -l openstack-cli-tests.el -l openstack-server-tests.el \
  -l openstack-server-list-tests.el -l openstack-volume-tests.el \
  -l openstack-image-tests.el -l openstack-volume-list-tests.el \
  -l openstack-image-list-tests.el \
  -l openstack-network-tests.el -l openstack-network-list-tests.el \
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
  `openstack-mode`.  The repo ships one Emacs package:
  `packages.openstack-mode` (aliased as `packages.default`) builds
  the whole tree with one `melpaBuild`, because `package-build`
  packages every `*.el` file in the source and no mode carries its
  own version.  Do not add a `melpaBuild` per mode.  The check phase
  and the lint gate glob the tree, so a new mode needs no
  `flake.nix` edit.  Name test files `*-tests.el`: `package-build`
  then leaves them out of the package, and the lint gate skips
  them.  Flakes copy only git-tracked files, so `git add` new files
  before `nix build`.
- Byte-compilation runs with warnings as errors.  When file A calls
  a function defined in file B without requiring B, declare it:
  `(declare-function openstack-server-display "openstack-server" (id))`.
  The list modes and their tests need this for the show entry
  points they bind to `openstack-show-command`.
- Derived modes override fetching and rendering by setting the
  `openstack-fetch-function` and `openstack-render-function`
  defcustoms (buffer-locally in the mode body, or globally).
  `openstack-fetch-function` receives (ID SUCCESS-FN ERROR-FN),
  must eventually call exactly one of them, and returns its
  process object so the mode can cancel it.  Never advise private
  functions like `openstack--render-error`.
- `openstack-display` takes an optional MODE argument (a derived
  mode's symbol); derived-mode entry points such as
  `openstack-server-display` bind their own `openstack-buffer-name`
  and call it, so the refresh starts inside the derived mode.
- Show modes are thin: defcustoms (buffer name, field order), a
  fetch wrapper over `openstack-show-fetch` (generic `RESOURCE
  show ID` via the async CLI layer) and a render wrapper over
  `openstack-render-fields` (header + ordered field table, JSON
  for nested values), plus display command and mode.  Value
  formatting lives in `openstack--format-value`; do not duplicate
  it per mode.  A mode whose Horizon page has trailing segments
  sets `openstack-url-suffix` (e.g. "/detail"); the leading ones
  go into `openstack-id-prefix`.
- Collection buffers (lists) have no resource ID: the entry point
  sets the buffer-local `openstack-collection` flag, so
  `openstack--refresh` runs and the fetcher receives nil as the
  ID.  The ID commands user-error on collection buffers.
- List modes are thin like show modes: a fetch wrapper over
  `openstack-list-fetch` (generic `RESOURCE list` via the async
  CLI layer) and a render wrapper over `openstack-list-render`
  (placeholder for an empty list; column ordering via
  `openstack-list-columns`), plus display command and mode.
- Navigation: the renderers attach an `openstack-id` text
  property to ID field lines and list rows; RET and `mouse-2`
  (`openstack-display-at-point`) open the resource at point with
  the buffer-local `openstack-show-command`, which list modes
  bind to their resource's display command (default
  `openstack-display`).
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
- `checkdoc` and `package-lint` must pass via `checks.checkdoc` and
  `checks.package-lint`; docstrings follow the imperative style.
- Interactive entry points carry `;;;###autoload` cookies;
  `openstack-mode-autoloads` / `openstack-cli-autoloads` assert they
  exist.  Add new commands to those tests when adding them to the
  files.
- Tests use `unwind-protect` around temporary buffers.

## TODO

- Derived modes for more resource types (routers, subnets,
  ports, flavors, hosts, …); servers, volumes, images and
  networks exist.
- Collection modes for more resource types (routers, subnets,
  ports, flavors, hosts, …); server, volume, image and network
  lists exist.
- Dashboard deep links per resource type.  `openstack-id-prefix`
  holds the leading path segments and `openstack-url-suffix` the
  trailing ones (networks use `project/networks` and `/detail`).
  The compute, volume and image modes still use one flat segment.
