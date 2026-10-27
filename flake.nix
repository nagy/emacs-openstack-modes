{
  description = "Emacs major modes for displaying OpenStack resources";

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
    flake-parts.lib.mkFlake { inherit inputs; } {
      # The treefmt module provides `treefmt' plus the `formatter' output
      # and a `checks.<system>.treefmt' gate for `nix flake check'.
      imports = [ treefmt-nix.flakeModule ];
      # Emacs packages are pure Elisp, but the build bakes in a store
      # path of the OpenStack client, so every output stays tied to one
      # platform.  Linux only: extend the list after a real eval on
      # another system.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          lib,
          ...
        }:
        let
          inherit (pkgs.emacsPackages) melpaBuild;
          # The package shells out to the python-openstackclient CLI at
          # runtime; bake its store path in so the installed package works
          # without anything on $PATH.
          openstackclient = pkgs.openstackclient-full;

          # One package for the whole repo: package-build packages every
          # `*.el' file in the source by default, so the base mode, the
          # CLI layer and each derived show/list mode travel together.
          openstackPackage = melpaBuild {
            pname = "openstack-mode";
            # Nix convention for unreleased packages: <version>-unstable-<date>,
            # the date of the last commit touching the source.  This package
            # has no release yet, so the version stays at 0.  Slice the flake
            # source date (e.g. "20260922133522") into YYYY-MM-DD, with an
            # epoch fallback for sources without git info (e.g. a tarball).
            version =
              let
                d = inputs.self.lastModifiedDate or "19700101000000";
              in
              "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

            src = ./.;

            # The shared openstack-cli.el shells out to the client;
            # bake its store path in so the default value works.
            postPatch = ''
              substituteInPlace openstack-cli.el \
                --replace-fail 'openstack-program "openstack"' 'openstack-program "${lib.getExe' openstackclient "openstack"}"'
            '';

            turnCompilationWarningToError = true;

            doCheck = true;
            # No file lists here: the phase globs the tree, and
            # package-build derives the packaged files from the same
            # sources.  Test files carry the `-tests.el' suffix, which
            # package-build excludes from the tarball and the lint gate
            # excludes from the ELPA policy checks.
            checkPhase = ''
              runHook preCheck

              echo '=== byte-compile ==='
              for file in *.el; do
                emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                  -f batch-byte-compile "$file"
              done

              echo '=== ERT tests ==='
              test_args=()
              for file in *-tests.el; do test_args+=(-l "$file"); done
              emacs --batch -L . "''${test_args[@]}" \
                -f ert-run-tests-batch-and-exit

              runHook postCheck
            '';

            meta = {
              description = "Emacs major modes for displaying OpenStack resources";
              longDescription = ''
                A base major mode for displaying OpenStack resources in
                Emacs buffers, plus derived show and list modes for
                servers, volumes, images and networks.

                Every OpenStack resource has a unique ID, so the base
                mode handles the ID: a buffer-local copy, a command to
                copy it to the kill ring, a dashboard URL command, and a
                pop-back command.  Resource-specific modes derive from it
                and inherit that handling, the asynchronous refresh
                pipeline and the bookmark support.

                Show modes fetch one resource with `openstack server
                show' and friends and render its fields.  List modes
                fetch the whole collection and render it as a padded,
                self-refreshing table.

                An Org link type opens a resource from an openstack:TYPE/ID
                link, stores links from display buffers and exports them as
                dashboard URLs.

                Resource ID prompts complete from a cached `RESOURCE list',
                and an xref backend opens the resource of an ID under point
                with M-. in any buffer.

                The package interfaces with OpenStack through the
                python-openstackclient command line program (nixpkgs
                package openstackclient-full).  The build substitutes the
                default value of openstack-program with the store path of
                that program.
              '';
              license = lib.licenses.agpl3Plus;
              homepage = "https://github.com/nagy/emacs-openstack-modes";
              maintainers = with lib.maintainers; [ nagy ];
              platforms = lib.platforms.unix;
            };
          };

          # Shell snippet for the ELPA policy checks: copy the packaged
          # Elisp sources into the build directory.  Test files carry the
          # `-tests.el' suffix and stay out.
          lintFiles = ''
            export HOME=$TMPDIR
            mode_files=()
            for file in "$src"/*.el; do
              case "$file" in
                *-tests.el) continue ;;
              esac
              cp "$file" .
              mode_files+=("$(basename "$file")")
            done
          '';

        in
        {
          # One canonical formatting config: `nix fmt' runs nixfmt, and
          # `nix flake check' rebuilds the treefmt check.  Never run
          # formatters standalone.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };
          # One package for the whole repo: `nix build' installs the base
          # mode together with every derived mode.
          packages.openstack-mode = openstackPackage;
          packages.default = openstackPackage;

          # `nix flake check' builds the package too, so the check phase
          # (byte-compile with warnings as errors, full ERT suite) gates
          # the whole repo rather than only `nix build'.
          checks.package = openstackPackage;

          # package-lint: ELPA policy (headers, symbol prefixes,
          # dependency declarations).
          checks.package-lint =
            pkgs.runCommandLocal "openstack-mode-package-lint"
              {
                nativeBuildInputs = [
                  (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                ];
                src = openstackPackage.src;
              }
              ''
                ${lintFiles}

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
                  "''${mode_files[@]}"

                touch $out
              '';

          # checkdoc: docstring conventions, which byte-compilation cannot
          # check.
          checks.checkdoc =
            pkgs.runCommandLocal "openstack-mode-checkdoc"
              {
                nativeBuildInputs = [ pkgs.emacs ];
                src = openstackPackage.src;
              }
              ''
                ${lintFiles}

                # checkdoc exits 0 even on findings — gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  "''${mode_files[@]}" 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

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
