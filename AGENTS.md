# AGENTS.md

## Project

`emacs-openstack-modes` — Emacs major modes that display OpenStack
resources.

Read `README.org` first.  It holds the usage, the library API, the
design and the build notes.  Every file opens with a `;;; Commentary:`
that states the rules of that file, and the docstring of a function
states its contract.  This file holds only the rules that span files.

## Rules

- Dependencies point down through four layers: transport
  (`openstack-cli.el`, `openstack-api.el`), data (`openstack-data.el`),
  presentation (the renderers) and interaction (the modes).  The data
  layer writes no buffer, reads no buffer-local variable and loads no
  mode library.  `test/openstack-data-test.el` asserts that load rule.
- `openstack.el` is the entry library and the package name.  The
  optional layers (`openstack-xref`, `openstack-url`, `ol-openstack`,
  `openstack-evil`) stay out of it.
- A resource type is one `openstack-define-resource` form in
  `openstack-resources.el`.  Do not hand-write a mode, a display
  command, a fetcher or a field defcustom that the macro can write.
  When the macro lacks a keyword for a new resource, add the keyword
  and teach the data layer to honor it.
- A mode reads and writes resource data through the type-keyed entry
  points of `openstack-data.el`.  Never build a client command from a
  type string in a mode.
- A fetcher receives (ID SUCCESS-FN ERROR-FN), calls exactly one
  callback and returns its process.  Never advise a private function
  such as `openstack--render-error`.
- One command per job.  A command that acts on the resource at point
  reads it through `openstack--object-at-point` and names no mode in
  its `interactive` form.  A command that opens a buffer from any
  context names no mode either.  A command of one view names the modes
  it serves; `test/openstack-mode-test.el` holds the checked list.
- A write command resolves its target through the same helper.  It
  asks for confirmation outside the detail buffer of that resource,
  and it refreshes a live detail buffer of the resource instead of a
  foreign buffer.
- A new interactive entry point needs an `;;;###autoload` cookie.  A
  defvar or defconst that an autoloaded form reads needs one too.  A
  cookie on a plain form such as `add-hook` or `add-to-list` copies
  the form and writes no stub, so the copied form would name a void
  function.  Keep that cookie and add one to the function that the
  form names: the stub loads the library on the first call, and the
  hook or handler entry reaches `xref-backend-functions` or
  `browse-url-default-handlers` before the library loads.
  `test/openstack-mode-test.el` checks every copied form.
- Every face lives in `openstack-mode.el` and inherits a standard face.
- The build compiles with warnings as errors.  Declare a function of
  another file with `declare-function` instead of adding a `require`.
- Put a rule next to the code that must obey it.  Add a note here only
  when the rule spans several files.

## Build and test

```sh
nix build          # the package; the checkPhase runs the suite
nix flake check    # the package plus package-lint, checkdoc and treefmt
nix fmt            # nixfmt
nix develop        # emacs, magit-section, evil, openstackclient-full
```

Run `nix flake check` before a commit.  Run `git add` on a new file
before `nix build`, because a flake copies only tracked files.

`test/*-test.el` is the suite, and `package-build` leaves those files
out of the package.  `test/openstack-test-helper.el` holds the shared
helpers.  For a run without Nix, see `README.org`, "Building".

## TODO

- Native read path in `openstack-api.el`: v3 token auth with catalog
  lookup, an `openstack-read-backend` defcustom (`cli` by default),
  show and list fetchers over the API, a parity test against the CLI
  fixtures, a per-host queue, and the cancellation contract of
  `openstack--kill-pending`.
- Swift objects: `object list` takes a container argument, and an
  object has no ID.  Decide the identity first (a composite row ID or
  a buffer-local container variable).  The answer touches xref, Org
  links, the bookmark handler and the dashboard URLs.
- Dashboard deep links: the compute, volume and image modes still use
  one flat path segment.
- Resource types without a mode: the git-bug tracker holds one ticket
  per missing single-parent type (volume snapshot, volume backup,
  Swift object, domain).  Run `git bug bug` to list them.
- Keep the "Library" section of `README.org` and the public-surface
  tests in step with every new entry point.
