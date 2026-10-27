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
| `openstack-read.el` | `RESOURCE list` cache with TTL, `openstack-read-id` prompt completion, `openstack-open-id`, type and name lookups |
| `openstack-xref.el` | xref backend: `M-.` on an `openstack-id` property or a UUID, opt-in via `(require 'openstack-xref)` |
| `openstack-server.el` | First derived mode: fetches `openstack server show` (async), renders server fields; `openstack-server-display` entry point |
| `openstack-server-list.el` | Collection mode: `openstack server list` as a `tabulated-list-mode` table; `openstack-server-list-display` |
| `openstack-volume.el` | Volume mode: `openstack volume show` via the generic helpers |
| `openstack-image.el` | Image mode: `openstack image show` via the generic helpers |
| `openstack-volume-list.el` | Volume list mode: `openstack volume list` as a `tabulated-list-mode` table; `openstack-volume-list-display` |
| `openstack-image-list.el` | Image list mode: `openstack image list` as a `tabulated-list-mode` table; `openstack-image-list-display` |
| `openstack-network.el` | Network mode: `openstack network show` via the generic helpers; `openstack-network-display` |
| `openstack-network-list.el` | Network list mode: `openstack network list` as a `tabulated-list-mode` table; `openstack-network-list-display` |
| `openstack-list-mode.el` | Collection base mode over `tabulated-list-mode`: generic fetch, table renderer, column widths, typed sorters, row commands, mode line status |
| `openstack-evil.el` | Optional evil bindings: `openstack-evil-mode`, normal and visual state keys for show and list buffers |
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
| `openstack-list-mode-tests.el` | ERT tests for the collection base mode: table format, widths, sorting, row identity, mode line |
| `openstack-evil-tests.el` | ERT tests for the evil bindings: state keys, motions, global mode, visual ID copy |
| `ol-openstack.el` | Org link type `openstack:` (`TYPE/ID`) with follow, store, complete and Horizon export; enable with `(require 'ol-openstack)` |
| `ol-openstack-tests.el` | ERT tests for the Org link type |
| `openstack-read-tests.el` | ERT tests for the ID completion and the cache |
| `openstack-xref-tests.el` | ERT tests for the xref backend |
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
nix develop        # emacs + evil + openstackclient-full
```

The `checkPhase` byte-compiles every `.el` file in the tree with
warnings as errors and runs the ERT suite (all `*-tests.el` files).
No file lists to maintain: the phase globs the source tree, and
`package-build` excludes `*-tests.el` from the package itself.
The phase adds the nixpkgs `evil` elisp directory to the load path,
so `openstack-evil.el` compiles and its tests run; the package
itself does not declare an evil dependency.
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
  -l openstack-list-mode-tests.el \
  -l openstack-evil-tests.el \
  -l ol-openstack-tests.el -l openstack-read-tests.el \
  -l openstack-xref-tests.el \
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
  `openstack-mode`; the list modes require `openstack-list-mode`.
  The repo ships one Emacs package:
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
  `tabulated-list-print` requires an entry as a list `(ID COLS)`:
  a cons of ID and column vector makes it signal a type error.
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
- Collection buffers (lists) have no resource ID:
  `openstack-list-mode` sets the buffer-local `openstack-collection`
  flag, so `openstack--refresh` runs and the fetcher receives nil as
  the ID.  The ID commands user-error on collection buffers.
- The collection base mode derives from `tabulated-list-mode`:
  `openstack-list-mode` is the parent of every `*-list-mode`, which
  only set `openstack-fetch-function`, `openstack-render-function`,
  `openstack-id-prefix`, `openstack-show-command` and
  `openstack-list--noun`.  Do not derive a list mode from
  `openstack-mode` directly, and do not hand-pad a table.
- List modes are thin: a fetch wrapper over `openstack-list-fetch`
  (generic `RESOURCE list` via the async CLI layer) and a render
  wrapper over `openstack-list-render` (placeholder for an empty
  list; column ordering via `openstack-list-columns`), plus display
  command and mode.  `openstack-list-render` sets
  `tabulated-list-format` (widths fitted to the window, typed
  sorters per column, numbers right-aligned) and
  `tabulated-list-entries` (ID plus cell vector), then calls
  `tabulated-list-print`.
- `openstack-render-manages-buffer` tells `openstack--refresh-done`
  that the renderer prints the buffer itself: the pipeline does not
  erase beforehand and does not move point afterwards, because
  `tabulated-list-print` restores point by row ID.  A list row's ID
  is the resource ID, so an update or a re-sort keeps point on the
  same resource.
- The header line holds the tabulated column labels.  A list mode
  must not write it: the row count, the sort state and the last
  fetch error go to the mode line through
  `openstack-list--mode-line`, and list modes bind
  `openstack-error-display-function` to
  `openstack-list--display-error`.  Show modes keep the default
  `openstack--display-error-in-header`.
- `openstack-list-mode-map` builds on `tabulated-list-mode-map`,
  so `n`/`p` move by line and `S` sorts; `openstack-pop` stays a
  show-mode command.  `RET` and `mouse-2` open the row's resource,
  `c` copies the row ID and `w` opens the row's dashboard page.
  The printer adds `openstack-id` and `mouse-face` to the whole
  row, not just the ID cell.
- Column widths depend on the window width, so
  `window-size-change-functions` redraws visible list buffers from
  the cached rows (`openstack-list--redraw`, no new CLI call).
- Navigation: the renderers attach an `openstack-id` text
  property to ID field lines and to whole list rows; RET and
  `mouse-2` (`openstack-display-at-point`) open the resource at
  point with the buffer-local `openstack-show-command`, which list
  modes bind to their resource's display command (default
  `openstack-display`).
- Display buffers refresh themselves: `openstack-mode` and
  `openstack-list-mode` call `openstack--init-display-buffer`, which
  wires `revert-buffer-function`, `buffer-stale-function` and
  `auto-revert-mode` into the async pipeline
  (`openstack--refresh` / `openstack--refresh-done`), throttled by
  `openstack-refresh-interval` and limited to visible buffers
  (`openstack-refresh-visible-only`).  Unchanged data (compared
  structurally via `openstack--data-equal-p`, `equal` fails on hash
  tables) is not re-rendered, keeping point and marks.  A refresh
  requested during a running fetch is served on completion.
  Errors keep the last good content and go to
  `openstack-error-display-function` (header line for show modes,
  mode line for list modes).
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
- The evil layer is optional and lives in `openstack-evil.el`:
  the file requires evil, but `Package-Requires` does not name
  it, so users without evil install nothing.
  `openstack-evil-mode` is a global minor mode with an
  `;;;###autoload` cookie; it enables `openstack-evil-show-mode`
  or `openstack-evil-list-mode` from
  `after-change-major-mode-hook` and scans open buffers.  Do not
  add evil to `packageRequires` in the flake: that turns the
  optional layer into a hard dependency for Nix consumers.  The
  flake `checkPhase` adds the nixpkgs evil elisp directory with
  `-L` instead, and the devShell ships emacs with evil.
- Evil state maps take precedence over a major mode map, so the
  layer binds every command key through
  `evil-define-minor-mode-key`, one key set per state and local
  minor mode (`openstack-evil-show-keys`,
  `openstack-evil-list-keys`,
  `openstack-evil-list-visual-keys`).  Keep the evil motions
  untouched: show buffers keep `RET`, `q`, `gr`, `p`, `c` and
  `w` because the operators do nothing in a read-only buffer;
  list buffers treat a row as the unit (`n`/`p` move by row,
  `S` sorts, visual `y` copies the IDs of the selected rows).
- Tests use `unwind-protect` around temporary buffers.
- The Org link type lives in `ol-openstack.el` and is opt-in:
  users add `(require 'ol-openstack)` to their init.  Link paths
  are `TYPE/ID`; `openstack-resource-types` (base mode) maps type
  to display mode and display command, so a new derived mode
  needs one entry there.  Do not repeat dashboard URL paths in
  the link code: `openstack-org--dashboard-url` reads
  `openstack-id-prefix` and `openstack-url-suffix` from the mode
  itself.  Org ships with Emacs, so `ol-openstack.el` does not
  declare it in `Package-Requires`; the bare `package-lint`
  environment cannot see builtin packages and rejects the
  declaration.
- `openstack-read.el` owns the `RESOURCE list` cache.  Prompts
  (`openstack-read-id`), type resolution, name lookup and the
  xref completion table all read it; nothing else caches list
  rows.  The cache compares type strings with `equal`, and a
  refresh drops the entry instead of patching it.
- New display commands read their ID with
  `(interactive (list (openstack-read-id TYPE "...")))`; a test
  walks `openstack-resource-types` and calls every display command
  interactively, so give the new mode the same form.
- Status display lives in the renderers, not in the modes:
  `openstack--insert-field` and `openstack-list-render` call
  `openstack--cell-face`, which combines `openstack-status-faces`
  (field names from `openstack-status-fields`, value and name
  compared without case) with `openstack-field-changed`.
  `openstack--refresh-done` binds `openstack--previous-data`
  around the render and then calls the state-change hook; a mode
  that renders its own view must go through the same helpers to
  keep faces, changes and the hook.
- The refresh delay of `openstack--buffer-stale-p` comes from
  `openstack--refresh-delay`: `openstack-refresh-fast-interval`
  while a status in `openstack-transitional-states` shows,
  `openstack-refresh-interval` otherwise.  Keep the normal
  interval as the upper bound.
- `openstack-xref.el` registers its backend through an
  `;;;###autoload` cookie on the `add-hook` form, so `M-.` works
  after package installation without a `require`.  The backend
  claims a buffer only when point holds an identifier, and
  `openstack-read-type-of-id` stays lazy: the text property wins
  over a UUID, and an unknown ID returns nil definitions.

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
