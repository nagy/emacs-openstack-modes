# AGENTS.md

## Project

`emacs-openstack-modes` — Emacs major modes for displaying OpenStack
resources.  Every OpenStack resource has a unique ID.  The project
starts with one base mode that handles the ID; future resource-specific
modes (servers, volumes, images, networks, …) derive from it and add
their own rendering.  A Swift container has no UUID, so it uses its
name as the ID.

## Files

| File | Purpose |
|---|---|
| `openstack.el` | Entry library and package namesake: requires `openstack-mode`, `openstack-read` and `openstack-resources`, then provides the feature `openstack`. `(use-package openstack ...)` and `:ensure t` load and resolve through it. The optional layers stay out of it. |
| `openstack-mode.el` | Core: base major mode (ID handling, refresh pipeline, renderers), the collection base mode over `tabulated-list-mode`, the `openstack-define-resource` macro, the type registry (`openstack-resource-definitions`, `openstack-resource-types`) |
| `openstack-cli.el` | CLI layer: `openstack-cli-request` (sync) + `openstack-cli-async-request` (async), `openstack-program` defcustom |
| `openstack-api.el` | Native read layer: asynchronous `openstack-api-request` and synchronous `openstack-api-fetch` over Emacs `url.el` (keep-alive, gnutls, chunked decoding), plus cancellation, per-request timeout, JSON parsing and the `openstack-api-error` condition |
| `openstack-read.el` | `RESOURCE list` cache with TTL, `openstack-read-id` prompt completion, `openstack-open-id`, type and name lookups |
| `openstack-resources.el` | The five resource types, one `openstack-define-resource` form each: server, volume, image, network, container |
| `openstack-xref.el` | xref backend: `M-.` on an `openstack-id` property or a UUID, `M-?` over cached list rows, opt-in via `(require 'openstack-xref)` |
| `openstack-url.el` | `openstack:TYPE/ID` URL scheme: registers a `browse-url` handler, opt-in via `(require 'openstack-url)` |
| `openstack-evil.el` | Optional evil bindings: `openstack-evil-mode`, normal and visual state keys for show and list buffers |
| `openstack-mode-tests.el` | ERT tests for the base mode, the collection base mode and the macro/registry (`openstack-mode-tests.el` holds the collection tests and the consistency test) |
| `openstack-cli-tests.el` | ERT tests for the CLI layer (mocked) |
| `openstack-api-tests.el` | ERT tests for the native API layer against a loopback fake cloud (no network, no cloud) |
| `openstack-resource-tests.el` | ERT tests for the five resource show and list modes, one table of fixtures and one test body per check |
| `openstack-list-mode-tests.el` | ERT tests for the collection base mode: table format, widths, sorting, row identity, mode line |
| `openstack-evil-tests.el` | ERT tests for the evil bindings: state keys, motions, global mode, visual ID copy |
| `ol-openstack.el` | Org link type `openstack:` (`TYPE/ID`) with follow, store, complete and Horizon export; enable with `(require 'ol-openstack)` |
| `ol-openstack-tests.el` | ERT tests for the Org link type |
| `openstack-read-tests.el` | ERT tests for the ID completion and the cache |
| `openstack-xref-tests.el` | ERT tests for the xref backend |
| `openstack-url-tests.el` | ERT tests for the `openstack:` URL scheme |
| `mock-openstack` | Fake client emitting canned JSON; demos/tests without a cloud (point `openstack-program` at it) |
| `flake.nix` | Flake (flake-parts) with one `melpaBuild` for the whole repo (all modes ship in the `openstack-mode` package), patches `openstack-program` to the nixpkgs `openstackclient-full` binary, runs ERT; checks: `package` (build + tests), `package-lint`, `checkdoc`, `treefmt`. The builder takes the Emacs to build for and is exported as `lib.openstackPackage`, so a consumer substitutes its own Emacs (`lib.openstackPackage pkgs { emacs = pkgs.emacs31; }`) or calls `.override { emacs = pkgs.emacs31; }` on the package, and `evil` then comes from that Emacs' package set |
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
  -l openstack-cli-tests.el \
  -l openstack-api-tests.el \
  -l openstack-resource-tests.el \
  -l openstack-list-mode-tests.el \
  -l openstack-evil-tests.el \
  -l ol-openstack-tests.el -l openstack-read-tests.el \
  -l openstack-xref-tests.el \
  -f ert-run-tests-batch-and-exit
```

`openstack-evil-tests.el` needs evil on the load path.  Add its
elisp directory with `-L`, or start Emacs from a wrapper that
includes evil.

## Conventions

- CLI access goes through `openstack-cli.el`: `openstack-cli-request`
  for synchronous calls (timing out after `openstack-cli-timeout`
  seconds with `openstack-cli-timeout`, a subclass of
  `openstack-cli-error`), `openstack-cli-async-request` for
  asynchronous ones (mirrors the `jsonrpc` library's sync/async
  split).  Derived modes never call `openstack-program` directly.
  Each call authenticates on its own.  Do not inject OS_TOKEN
  into the client: `clouds.yaml` may select application
  credential auth, whose plugin takes no token argument and
  fails with a TypeError.  A token cache belongs to the native
  API layer, where one POST authenticates the whole session.
- `openstack-cli` appends `--format json` automatically; commands
  that produce no output (e.g. `delete`) parse to nil.  Non-zero
  exit or unparseable output signals `openstack-cli-error` (sync) or
  calls `error-fn` (async).  `openstack-cli-async-request` requires
  both callbacks and signals `user-error' if either is missing or
  is not a function.
- CLI tests mock at the process level with `cl-letf` on
  `openstack-cli--run` (sync) and `make-process`/
  `set-process-sentinel` (async); they never hit a real OpenStack.
- `openstack-api.el` is the native read path in preparation.  It
  does not parse HTTP and does not open sockets itself: Emacs
  `url.el` frames the responses, decodes chunked bodies, follows
  redirects, negotiates TLS and keeps one socket per host open
  between polls (`url-http-open-connections`).  A hand-written HTTP
  parser or socket layer is out of scope; add a helper here only
  when `url.el` lacks it.  The layer adds what `url` lacks: the
  `openstack-api-request` handle, `openstack-api-cancel`, a
  per-request `openstack-api-timeout`, JSON parsing and the
  `openstack-api-error` condition (`openstack-api-timeout` as its
  subclass).  Cancelling closes the socket, because a half-read
  response cannot stay usable; the next request reconnects.
  `openstack-api-tests.el` runs against a loopback fake cloud, so
  the tests stay offline and count accepted connections to check
  the keep-alive promise.  The modes still read through the CLI;
  do not rewire a fetcher until a parity test compares its buffer
  text against the CLI fixture.
- The `openstack-program` defcustom lives in `openstack-cli.el`
  (the CLI's program), not in the mode file.
  functions return nil unless called with the `errorp` argument.
- The resource types live in `openstack-resources.el`, one
  `(openstack-define-resource "TYPE" ...)` form each; the macro in
  `openstack-mode.el` writes the show mode, the list mode, their
  display commands, fetchers, renderers and defcustoms from that
  form.  The type string appears once per resource.  Do not
  hand-write `openstack-*-mode`, `openstack-*-display`,
  `openstack-*-fetch` or the `*-fields` defcustoms again: derive
  them through the macro, and add a keyword when the macro lacks
  what a new resource needs.  A new resource that the client serves
  differently gets a new keyword, not a hand-written mode.
  `:value-formatters` (an alist of show field name to formatter
  function) changes the display text of one show field, as the
  image `size` does through `openstack--format-size`; the list
  mode ignores it, so a numeric column keeps its typed sort.
- `openstack-define-resource` registers the type in
  `openstack-resource-definitions`, the registry, and appends its
  entry to `openstack-resource-types`, which the ID prompts, the
  Org links and the xref backend read.  The table therefore starts
  empty and fills in the order of the forms in
  `openstack-resources.el`.  `openstack-mode.el` ends with
  `;;;###autoload (require 'openstack-resources)`, so the autoload
  generator copies that form into the package autoloads and the
  installed package fills the registry at startup.  The macro writes
  its commands, so no cookie can precede them in the source;
  `openstack-mode-tests.el` asserts the autoloaded require instead,
  and its registry tests check that every definition, its generated
  symbols and its table entry agree.
- The repo ships one Emacs package: `packages.openstack`
  (`packages.default` points at the same derivation, and
  `packages.openstack-mode` stays as the former name) builds
  the whole tree with one `melpaBuild`, because `package-build`
  packages every `*.el` file in the source and no mode carries its
  own version.  Do not add a `melpaBuild` per mode.  The check phase
  and the lint gate glob the tree, so a new mode needs no
  `flake.nix` edit.  Name test files `*-tests.el`: `package-build`
  then leaves them out of the package, and the lint gate skips
  them.  Flakes copy only git-tracked files, so `git add` new files
  before `nix build`.
- The package name matches its entry library: `pname = "openstack"`
  in the flake, `openstack.el` in the source.  `use-package SYMBOL`
  expands to `(require SYMBOL)`, and `:ensure t` looks up the
  package named by SYMBOL, so the two names must agree.  Users
  therefore configure the whole package through
  `(use-package openstack :config ...)` and reach every defcustom
  in the `openstack` group.  Do not point users at an internal
  library such as `openstack-resources` as the entry point, and do
  not require `openstack.el` from another package file (that
  creates a load cycle through `openstack-resources`).
- The entry library loads the display path only: `openstack-mode`,
  `openstack-read` and `openstack-resources`.  The optional layers
  keep their own libraries (`openstack-xref`, `openstack-url`,
  `ol-openstack`, `openstack-evil`), because they change global
  state (xref hooks, `browse-url` handlers) or add a dependency
  (evil).  `openstack-mode` stays a valid feature, so requiring it
  loads the base mode without the resource types.
  `openstack-mode.el` keeps its
  `;;;###autoload (require 'openstack-resources)` form, so the
  generated autoloads fill the registry at startup even for a user
  who never requires the entry library.
  `openstack-mode-tests.el` checks the entry library through
  `openstack-entry-library`.
- Byte-compilation runs with warnings as errors.  When file A calls
  a function defined in file B without requiring B, declare it:
  `(declare-function openstack-server-display "openstack-server" (id))`.
  The list mode tests need this for the show entry points they
  bind to `openstack-show-command`.
  `tabulated-list-print` requires an entry as a list `(ID COLS)`:
  a cons of ID and column vector makes it signal a type error.
- The resource show and list tests live in one table, not one file
  per resource: `openstack-resource-tests.el` holds
  `openstack-resource-test--fixtures` (the client answers and the
  expected texts of each type) and defines every check once through
  `openstack-resource-test--def-type-tests`, which expands one
  `openstack-TYPE-SUFFIX` test per fixture.  A new resource type
  needs a fixture entry, not a new test file; the
  `openstack-resource-tests-cover-registry` test fails until the
  fixture table lists it in registry order.  Because the symbol
  names of a type are built at runtime, the tests call the modes and
  fetchers with `funcall` and compare `openstack-fetch-function`
  and friends with interned symbols.
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
- Show modes build on `openstack-show-fetch` (generic `RESOURCE
  show ID` via the async CLI layer) and `openstack-render-fields`
  (header + ordered field table, JSON for nested values).  Value
  formatting lives in `openstack--format-value`; do not duplicate
  it per mode.  A list of plain values, such as the `subnets` of a
  network or the `tags` of an image, prints as comma-separated
  text (`subnet-1, subnet-2`); a list that holds records stays
  JSON.  The field renderer collects every row first and
  pads each name after its colon to the longest name, so all
  values start at one column (`openstack--insert-field' takes the
  width); a mode that renders fields by hand must align them the
  same way or the detail buffers disagree.  A hash-table
  `properties` value (Glance image properties, Swift container
  properties) prints last as an indented `key: value` block,
  sorted by key, through `openstack--insert-properties`; do not
  JSON-encode it.  A `locations` list of hash tables (the Glance
  image locations, which the client flattens into `properties')
  prints as an indented block of records, sorted by key, through
  `openstack--insert-records`, also when it appears as a
  `properties` entry.  A mode whose Horizon page has trailing
  segments sets `openstack-url-suffix` (e.g. "/detail"); the
  leading ones go into `openstack-id-prefix`.  Both come from the
  macro call (`:id-prefix`, `:url-suffix`).
- Collection buffers (lists) have no resource ID:
  `openstack-list-mode` sets the buffer-local `openstack-collection`
  flag, so `openstack--refresh` runs and the fetcher receives nil as
  the ID.  The ID commands user-error on collection buffers.
- The collection base mode derives from `tabulated-list-mode`:
  `openstack-list-mode` is the parent of every `*-list-mode`.  The
  macro sets `openstack-fetch-function`, `openstack-render-function`,
  `openstack-id-prefix`, `openstack-url-suffix`,
  `openstack-show-command` and `openstack-list--noun` for a list
  mode.  Do not derive a list mode from `openstack-mode` directly,
  and do not hand-pad a table.
- List modes build on `openstack-list-fetch` (generic `RESOURCE
  list` via the async CLI layer) and `openstack-list-render`
  (placeholder for an empty list; column ordering via
  `openstack-list-columns`).  `openstack-list-render` sets
  `tabulated-list-format` (widths fitted to the window, typed
  sorters per column, numbers right-aligned) and
  `tabulated-list-entries` (ID plus cell vector), then calls
  `tabulated-list-print`.  `openstack-list-fetch` takes an optional
  ARGS list appended to `RESOURCE list`; the macro passes the
  `:list-arguments` of the definition, so a collection whose list
  needs a client option stays a thin wrapper
  (`openstack-container-list-arguments` defaults to `--long`).
  The buffer-local `openstack-list--prefix-arguments` follows ARGS;
  the generated list display command sets it from its prefix
  argument through `:list-prefix-arguments` of the definition
  (only the image definition sets `--all`).  Do not add a second
  prefix level: the display commands take one universal argument.
- A resource with no UUID takes its name as the ID.
  `openstack-read--row-id` and `openstack-list--row-id` fall back to
  the `Name` field of a list row, and a row without either field
  keeps the positional `row-N` identity.  Swift containers work
  this way (`openstack-container-mode` uses the container name as
  `openstack--id`).  Do not invent a prefixed or composite ID for
  such a resource, and do not repeat the name as a `name (id)`
  completion label.
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
  `openstack-display`).  `openstack-display-at-point` reads the
  property only: a bare UUID in a log line stays `M-.` territory.
- `openstack-mode` also registers the `openstack-id` thing:
  `openstack-id-thing` (property first, then a UUID under point)
  and `openstack-id-bounds` (the property run, or the UUID bounds)
  go on the symbol plist under `thing-at-point` and
  `bounds-of-thing-at-point`.  `openstack--init-display-buffer`
  adds a buffer-local `thing-at-point-provider-alist` entry that
  maps `uuid` to `openstack-id-thing`, because a narrow table
  truncates the ID text and keeps the full ID in the property.
  `openstack-xref.el` reads `(thing-at-point 'openstack-id t)` and
  keeps only the type lookup and the fresh-property check.  A
  custom THING gets no `forward-op`: the region comes from a text
  property, so a scan for it has no meaning.
- `imenu` reads the renderers, not the modes own bookkeeping:
  `openstack--insert-field` adds an `openstack-field` text property
  to every field name, and `openstack--imenu-index` collects those
  lines.  `openstack-list--imenu-index` collects the rows from
  their `openstack-id` property and names each row by its name
  field and ID.  Both modes set `imenu-create-index-function`, so
  `consult-imenu` and `which-function-mode` work without further
  wiring.  Do not key the show index on the `face` property:
  font-lock may replace it.
- `openstack-read-id` passes `openstack-read--choices-table` to
  `completing-read`, not the raw alist: the table answers the
  `metadata` action with an `annotation-function` built by
  `openstack-read--annotation-function` over the choices.  The
  annotation holds the values of
  `openstack-read-annotation-fields` that the row has.  Keep the
  `(LABEL . ID)` alist for the answer lookup.
- `openstack-dashboard-url` builds every dashboard URL.  The Org
  export and the `openstack:` URL handler in `openstack-url.el`
  call it, so a resource type names its path segments once.  The
  handler takes `TYPE/ID` or an ID alone and passes a nil TYPE to
  `openstack-open-id` for the ID-alone form.
- `xref-backend-references` warms the cache through
  `openstack-read-type-of-id` and then reads
  `openstack-read-references`, which scans the cached list rows for
  a field equal to the ID and skips the row of the resource itself.
  The scan never fetches show data, so it reports only the direct
  relations a list row names (image, network, flavor).  Keep the
  cache read inside `openstack-read.el`; do not reach into
  `openstack-read--cache` from the backend.
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
- The JSON view is a read-only second buffer over the last fetch:
  `openstack-json-view` (=J= in both mode maps) pretty prints
  `openstack--last-data` through `openstack-json-mode`, which
  derives from `js-json-mode`.  It shares the buffer: the source
  buffer keeps it in `openstack--json-buffer` and the JSON buffer
  keeps the source in `openstack-json--source`, so a second call
  switches instead of recreating, and `openstack--refresh-done`
  calls `openstack-json--redraw` after a render.  The name is the
  source name plus " JSON", so it needs no registry.  Do not fetch
  again from the JSON buffer; `gr` renders the cached data.
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
  files.  A defconst or defvar that an autoloaded form reads needs
  its own `;;;###autoload` cookie: the generated autoload file holds
  the copied form only, so the variable otherwise stays void when
  the autoloads load (`openstack-url-regexp`).
- The evil layer is optional and lives in `openstack-evil.el`:
  the file requires evil 1.14 or later, but `Package-Requires`
  does not name it, so users without evil install nothing.
  `package.el` compiles every file during install, so an install
  without evil prints one `Cannot open load file: evil` line and
  still succeeds.  `openstack-evil-mode` is a global minor mode
  with an `;;;###autoload` cookie; it enables
  `openstack-evil-show-mode` or `openstack-evil-list-mode` from
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
  untouched: show buffers keep `RET`, `<mouse-2>`, `q`, `gr`,
  `p`, `c` and `w` because the operators do nothing in a
  read-only buffer; list buffers treat a row as the unit
  (`<mouse-2>` opens, `c` or `Y` copies, `S` sorts, `j`/`k`
  move, `n`/`N` repeat the search, visual `y` copies the IDs of
  the selected rows and leaves visual state).
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
- Every face of the package inherits a standard one and lives in
  `openstack-mode.el`: `openstack-status-ok`, `openstack-status-off`,
  `openstack-status-pending`, `openstack-status-error`,
  `openstack-field-changed`, `openstack-field-name` (inherits
  `font-lock-variable-name-face`), `openstack-date` (inherits
  `org-date`), `openstack-id` (inherits `marginalia-number`) and
  `openstack-error` (inherits `error`).  Do not
  apply a font-lock or message face directly: then a user who
  restyles the OpenStack buffers changes code buffers or every
  message as well.
- The resource ID takes `openstack-id`: `openstack-render-fields`
  propertizes its `ID' header line with it, and
  `openstack--cell-face` adds it when the field name is `id'
  (show) or `ID' (list), so the `id' field row and the `ID'
  column share the face.  A reference to another resource, such
  as `image_id', keeps the default face; the face marks the
  identity of the displayed resource only.  The name-as-ID
  resource (Swift containers) keeps its `Name' column unfaced.
- Date fields take `openstack-date`: `openstack--cell-face` adds it
  when the field name matches `openstack-date-fields` (a space in a
  list column matches an underscore in a show field).  Both
  renderers go through that function, so a new date field needs one
  entry there, not a per-mode change.  `openstack-date-fields` set
  to nil disables the face.
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

- Native read path (`openstack-api.el`).  The request layer and its
  offline tests exist; the CLI still serves every fetch.  Next:
  v3 token auth with catalog lookup (the session keeps the token
  in Emacs, so it needs no CLI token cache), a
  `openstack-read-backend` defcustom (`cli` default), show and
  list fetchers over the API,
  a parity test that compares buffer text against the CLI fixtures,
  a per-host queue, and the request-object cancellation contract
  in `openstack--kill-pending` once parity passes.
- Derived modes for more resource types (routers, subnets,
  ports, flavors, hosts, …); servers, volumes, images,
  networks and containers exist.
- Collection modes for more resource types (routers, subnets,
  ports, flavors, hosts, …); server, volume, image, network and
  container lists exist.
- Objects of the Object Storage service.  `object list` needs a
  container argument and an object has no ID at all (its identity
  is container plus name), so decide the identity scheme first:
  a composite row ID or a buffer-local container variable.  That
  choice touches xref, Org links, the bookmark handler and the
  dashboard URLs.
- Dashboard deep links per resource type.  `openstack-id-prefix`
  holds the leading path segments and `openstack-url-suffix` the
  trailing ones (networks use `project/networks` and `/detail`).
  The compute, volume and image modes still use one flat segment.
