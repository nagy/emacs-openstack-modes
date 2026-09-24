{
  description = "Base major mode for displaying OpenStack resources (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    # Date of the last commit as YYYY-MM-DD, folded into the version
    # string below.  Flake source info gives it as e.g. "20260922133522",
    # so slice out the year, month and day and glue them with hyphens.
    let
      lastModifiedDate = inputs.self.sourceInfo.lastModifiedDate;
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch (and darwin if the deps exist there).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          lib,
          config,
          ...
        }:
        let
          inherit (pkgs.emacsPackages) melpaBuild;
          # The package shells out to the python-openstackclient CLI at
          # runtime; bake its store path in so the installed package works
          # without anything on $PATH.
          openstackclient = pkgs.openstackclient-full;

          # Every Elisp source in the repo, compiled with warnings as
          # errors in the check phase, followed by the full ERT suite.
          # Both packages share one source tree and one gate.
          elispFiles = [
            "openstack-mode.el"
            "openstack-cli.el"
            "openstack-server.el"
            "openstack-server-list.el"
            "openstack-mode-tests.el"
            "openstack-cli-tests.el"
            "openstack-server-tests.el"
            "openstack-server-list-tests.el"
          ];
          elispCheckPhase = ''
            runHook preCheck

            echo '=== byte-compile ==='
            ${lib.concatMapStringsSep "\n" (file: ''
              emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile ${file}
            '') elispFiles}

            echo '=== ERT tests ==='
            emacs --batch -L . \
              -l openstack-mode-tests.el \
              -l openstack-cli-tests.el \
              -l openstack-server-tests.el \
              -l openstack-server-list-tests.el \
              -f ert-run-tests-batch-and-exit

            runHook postCheck
          '';

          # Per-mode packages: one melpaBuild each.  All share the
          # same source tree and the same check gate.
          mkOpenstackPackage =
            {
              pname,
              description,
              longDescription,
            }:
            melpaBuild {
              inherit pname;
              version = "0.1.0-unstable-${commitDate}";

              src = lib.cleanSource ./.;

              packageRequires = [ ];

              # The shared openstack-cli.el shells out to the client;
              # bake its store path in so the default value works.
              postPatch = ''
                substituteInPlace openstack-cli.el \
                  --replace-fail 'openstack-program "openstack"' 'openstack-program "${lib.getExe' openstackclient "openstack"}"'
              '';

              turnCompilationWarningToError = true;

              doCheck = true;
              checkPhase = elispCheckPhase;

              meta = {
                inherit description longDescription;
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/emacs-openstack-modes";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            };
        in
        {
          packages.openstack-mode = mkOpenstackPackage {
            pname = "openstack-mode";
            description = "Base major mode for displaying OpenStack resources";
            longDescription = ''
              Base major mode for displaying OpenStack resources in Emacs
              buffers.  Every OpenStack resource has a unique ID, so this
              mode handles the ID: a buffer-local copy, a command to copy
              it to the kill ring, a dashboard URL command, and a pop-back
              command.  Future resource-specific modes (servers, volumes,
              images, networks, ...) derive from this mode and inherit the
              ID handling.

              The package interfaces with OpenStack through the
              python-openstackclient command line program (nixpkgs package
              openstackclient-full).  The build substitutes the default
              value of openstack-program with the store path of that
              program.
            '';
          };

          packages.openstack-server = mkOpenstackPackage {
            pname = "openstack-server";
            description = "Display OpenStack servers";
            longDescription = ''
              The first resource-specific mode derived from
              openstack-mode.  It fetches a server with
              `openstack server show' through the asynchronous CLI
              layer and renders the server's fields, inheriting the
              ID handling, refresh pipeline and bookmark support of
              the base mode.
            '';
          };

          packages.openstack-server-list = mkOpenstackPackage {
            pname = "openstack-server-list";
            description = "List OpenStack servers";
            longDescription = ''
              A collection view derived from openstack-mode: it
              fetches all servers with `openstack server list'
              through the asynchronous CLI layer and renders them as
              a padded table in a self-refreshing buffer.  The
              buffer has no resource ID (`openstack-collection' is
              set), so the ID commands do not apply.
            '';
          };

          # `nix build` installs every mode of the repo: the base mode
          # package plus one package per derived mode.
          packages.default = pkgs.symlinkJoin {
            name = "emacs-openstack-modes";
            paths = [
              config.packages.openstack-mode
              config.packages.openstack-server
              config.packages.openstack-server-list
            ];
          };

          # Lint gate: checkdoc + package-lint.  They catch what
          # byte-compilation cannot — docstring conventions and ELPA
          # policy (headers, symbol prefixes, dependency declarations).
          checks.lint =
            pkgs.runCommand "openstack-mode-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                ];
                src = config.packages.openstack-mode.src;
              }
              ''
                export HOME=$TMPDIR
                cp "$src"/openstack-mode.el "$src"/openstack-cli.el \
                  "$src"/openstack-server.el "$src"/openstack-server-list.el .

                # package-lint assumes online ELPA and wants symbols to carry
                # the file-name prefix (`openstack-mode-', `openstack-cli-'),
                # but the package shares the shorter `openstack-' prefix across
                # both files.  Whitelist it.  No dependency stubs needed:
                # Package-Requires only names emacs itself, which package-lint
                # special-cases; extra deps would need an `:after' advice on
                # `package-initialize' (it nils `package-alist' on every call).
                emacs --batch -l package-lint \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`openstack-"))' \
                  -f package-lint-batch-and-exit \
                  openstack-mode.el openstack-cli.el openstack-server.el \
                  openstack-server-list.el

                # checkdoc exits 0 even on findings — gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  openstack-mode.el openstack-cli.el openstack-server.el \
                  openstack-server-list.el 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

          # `nix fmt` runs nixfmt via treefmt; keep formatting canonical.
          formatter = treefmt-nix.lib.mkWrapper pkgs {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          devShells.default = pkgs.mkShell {
            # Mirror whatever the package needs at runtime when hacking on
            # it: the external CLI, a real Emacs for interactive testing.
            packages = [
              openstackclient
              pkgs.emacs
            ];
          };
        };
    };
}
