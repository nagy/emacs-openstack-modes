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
        in
        {
          packages.openstack-mode = melpaBuild {
            pname = "openstack-mode";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>,
            # where the date is the last commit touching the source.
            version = "0.1.0-unstable-2026-08-07";

            src = lib.cleanSource ./.;

            # Elisp dependencies from the Package-Requires header that
            # already exist in nixpkgs.
            packageRequires = [ ];

            # Rewrite the default executable path to the Nix store path.
            # Interpolating the derivation bakes the store path in;
            # `lib.getExe'` picks the exact binary name inside the package.
            postPatch = ''
              substituteInPlace openstack-cli.el \
                --replace-fail 'openstack-program "openstack"' 'openstack-program "${lib.getExe' openstackclient "openstack"}"'
            '';

            # Byte-compilation warnings fail the build. Keep it on: it is
            # the cheapest lint the package will ever get.
            turnCompilationWarningToError = true;

            doCheck = true;

            # `nix build` gates the package on the ERT suite plus checkdoc,
            # so a broken rendering or a stale docstring never reaches $out.
            checkPhase = ''
              runHook preCheck

              echo '=== byte-compile ==='
              emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile openstack-mode.el
              emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile openstack-cli.el
              emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile openstack-mode-tests.el

              echo '=== ERT tests ==='
              emacs --batch -L . \
                -l openstack-mode-tests.el \
                -l openstack-cli-tests.el \
                -f ert-run-tests-batch-and-exit

              echo '=== checkdoc ==='
              emacs --batch -L . \
                -l checkdoc \
                --eval "(setq checkdoc-arguments-in-order-flag t)" \
                --eval "(mapc #'checkdoc-file command-line-args-left)" \
                openstack-mode.el openstack-cli.el

              runHook postCheck
            '';

            meta = {
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
              # Read the license from the file header — Elisp packages
              # conventionally declare it after ";;; Code:".
              license = lib.licenses.agpl3Plus;
              homepage = "https://github.com/nagy/emacs-openstack-modes";
              maintainers = with lib.maintainers; [ nagy ];
              platforms = lib.platforms.unix;
            };
          };

          packages.default = config.packages.openstack-mode;

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
