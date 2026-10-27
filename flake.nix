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
          elispFiles = [
            "openstack-mode.el"
            "openstack-cli.el"
            "openstack-server.el"
            "openstack-server-list.el"
            "openstack-volume.el"
            "openstack-image.el"
            "openstack-volume-list.el"
            "openstack-image-list.el"
            "openstack-mode-tests.el"
            "openstack-cli-tests.el"
            "openstack-server-tests.el"
            "openstack-server-list-tests.el"
            "openstack-volume-tests.el"
            "openstack-image-tests.el"
            "openstack-volume-list-tests.el"
            "openstack-image-list-tests.el"
          ];
          testFiles = [
            "openstack-mode-tests.el"
            "openstack-cli-tests.el"
            "openstack-server-tests.el"
            "openstack-server-list-tests.el"
            "openstack-volume-tests.el"
            "openstack-image-tests.el"
            "openstack-volume-list-tests.el"
            "openstack-image-list-tests.el"
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
              ${lib.concatMapStringsSep "\\\n  " (file: "-l ${file}") testFiles} \
              -f ert-run-tests-batch-and-exit

            runHook postCheck
          '';

          # One package for the whole repo: package-build packages every
          # `*.el' file in the source by default, so the base mode, the
          # CLI layer and each derived show/list mode travel together.
          openstackPackage = melpaBuild {
            pname = "openstack-mode";
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
              description = "Emacs major modes for displaying OpenStack resources";
              longDescription = ''
                A base major mode for displaying OpenStack resources in
                Emacs buffers, plus derived show and list modes for
                servers, volumes and images.

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

          modeFiles = [
            "openstack-mode.el"
            "openstack-cli.el"
            "openstack-server.el"
            "openstack-server-list.el"
            "openstack-volume.el"
            "openstack-image.el"
            "openstack-volume-list.el"
            "openstack-image-list.el"
          ];
        in
        {
          # One package for the whole repo: `nix build' installs the base
          # mode together with every derived mode.
          packages.openstack-mode = openstackPackage;
          packages.default = config.packages.openstack-mode;

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
                cp "$src"/*.el .

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
                  ${lib.escapeShellArgs modeFiles}

                # checkdoc exits 0 even on findings — gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  ${lib.escapeShellArgs modeFiles} 2>&1)
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
