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
    let
      # One package for the whole repo: package-build packages every
      # `*.el' file in the source by default, so the base mode, the
      # CLI layer and each derived show/list mode travel together.
      #
      # It takes the nixpkgs instance and, optionally, another Emacs, so a
      # consumer can substitute the Emacs the package compiles and tests
      # with.  Everything else (melpaBuild, the optional evil layer) comes
      # from that Emacs' package set, so the evil .elc files always match
      # the Emacs that loads them:
      #
      #   (inputs.self.lib.openstackPackage pkgs)
      #   (inputs.self.lib.openstackPackage pkgs { emacs = pkgs.emacs31; })
      #   (inputs.self.packages.${system}.default.override { emacs = pkgs.emacs31; })
      #
      # `makeOverridable' adds the `override' attribute, so the package
      # behaves like a `callPackage' result: `.override { emacs = ...; }'
      # rebuilds it against another Emacs.
      openstackPackage =
        pkgs:
        pkgs.lib.makeOverridable (
          {
            emacs ? pkgs.emacs,
          }:
          let
            lib = pkgs.lib;
            emacsPackages = emacs.pkgs;

            # The package shells out to the python-openstackclient CLI at
            # runtime; bake its store path in so the installed package works
            # without anything on $PATH.
            openstackclient = pkgs.openstackclient-full;

            # The optional openstack-evil.el layer needs evil to compile and
            # test, but the package must not depend on it.  Supply the elisp
            # directory to the build only, never through packageRequires.
            evil = emacsPackages.evil;

            # magit-section is a real dependency of openstack-mode.el, but
            # melpaBuild keeps packageRequires off the load path of its own
            # build and its `-Q' compiles.  A wrapper Emacs on PATH carries
            # every dependency in its EMACSLOADPATH, so the build and the
            # test phase see them.  evil rides along for the optional layer.
            emacsWithDeps = emacsPackages.emacsWithPackages (p: [
              p.magit-section
              p.evil
            ]);
          in
          emacsPackages.melpaBuild {
            # The package name matches its entry library, openstack.el, so
            # `(use-package openstack :ensure t)' resolves the archive
            # package.  The modes themselves keep their `openstack-' prefix.
            pname = "openstack";
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

            # The section library and the optional evil layer reach the
            # build only through this wrapper: melpaBuild ignores
            # packageRequires for its own load path and runs `emacs -Q'.
            preBuild = ''
              export PATH="${emacsWithDeps}/bin:$PATH"
            '';

            # One real dependency, declared for the consumer and for the
            # native-compilation pass of the builder.  evil stays out: it is
            # optional, and a hard dependency would install it for users who
            # never enable the evil layer.
            packageRequires = [ emacsPackages.magit-section ];

            turnCompilationWarningToError = true;

            # The default installPhase compiles the packaged files with
            # `-Q', so preInstall puts the evil elisp directory on
            # EMACSLOADPATH for that compile.  Do not add evil to packageRequires:
            # the dependency is optional for users of the package.
            preInstall = ''
              evil_dir=$(find ${evil}/share/emacs/site-lisp/elpa \
                -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)
              export EMACSLOADPATH="$evil_dir:''${EMACSLOADPATH-}"
            '';

            doCheck = true;
            # The test tree lives in `test/': one file per source unit, named
            # `*-test.el'.  The phase globs that directory, so a new test file
            # needs no flake edit.  `openstack-test-helper.el' holds the shared
            # fixtures and does not match the glob, which keeps the loader a
            # test-only list.  package-build excludes `*-test.el' from the
            # tarball, so the tests never ship.
            checkPhase = ''
              runHook preCheck

              # melpaBuild stages the root-level `*.el' files only, so the test
              # tree comes back from the store before the loader reads it.
              cp -r ${./test} ./test

              # openstack-evil.el is optional and the package declares no
              # dependency on evil, but the gate must still compile and test
              # it.  The check environment supplies the evil elisp directory.
              evil_load_path=$(find ${evil}/share/emacs/site-lisp/elpa \
                -mindepth 1 -maxdepth 1 -type d -name 'evil-*' -print -quit)

              echo '=== byte-compile ==='
              for file in *.el test/*.el; do
                emacs --batch -L . -L test -L "$evil_load_path" \
                  --eval '(setq byte-compile-error-on-warn t)' \
                  -f batch-byte-compile "$file"
              done

              echo '=== ERT tests ==='
              # printf repeats "-l %s" per match.  failglob makes an empty glob
              # a shell error, so the || guard fires even without `set -e'.
              # Restore the default right after: later commands must keep
              # default glob semantics.  The unquoted $test_args is intentional:
              # the words must split into -l <file> pairs, which is safe because
              # test file names never contain spaces.
              shopt -s failglob
              test_args=$(printf -- "-l %s " test/*-test.el) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
              shopt -u failglob
              emacs --batch -L . -L test -L "$evil_load_path" $test_args \
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

                Display buffers color status values, mark fields that
                changed since the last refresh, report state transitions
                through a hook, and poll faster while a status still
                changes.

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
          }
        );
    in
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

      # Expose the builder so a consumer can build the package for its own
      # Emacs without changing this flake.
      flake.lib.openstackPackage = openstackPackage;

      perSystem =
        {
          pkgs,
          ...
        }:
        let
          # The default package: the builder above, instantiated for the
          # nixpkgs instance and the default Emacs of this system.
          package = openstackPackage pkgs { };

          # Shell snippet for the ELPA policy checks: copy the packaged
          # Elisp sources and the test tree into the build directory.  Two
          # lists, because package-lint needs one invocation for the files of
          # the package and one for the secondary files under `test/'.
          lintFiles = ''
            package_files=()
            for file in "$src"/*.el; do
              cp "$file" .
              package_files+=("$(basename "$file")")
            done
            # `src' may be pre-filtered and melpaBuild stages no test tree, so
            # copy it explicitly instead of relying on what the build kept.
            cp -r "$src"/test .
            test_files=(test/*.el)
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
          packages.openstack = package;
          # Former name of the package; kept so existing consumers build.
          packages.openstack-mode = package;
          packages.default = package;

          # `nix flake check' builds the package too, so the check phase
          # (byte-compile with warnings as errors, full ERT suite) gates
          # the whole repo rather than only `nix build'.
          checks.package = package;

          # package-lint: ELPA policy (headers, symbol prefixes,
          # dependency declarations).
          checks.package-lint =
            pkgs.runCommandLocal "openstack-mode-package-lint"
              {
                nativeBuildInputs = [
                  pkgs.writableTmpDirAsHomeHook
                  (pkgs.emacsPackages.emacsWithPackages (p: [
                    p.package-lint
                    p.magit-section
                  ]))
                ];
                src = ./.;
              }
              ''
                ${lintFiles}

                # package-lint assumes online ELPA and wants symbols to carry
                # the file-name prefix (`openstack-mode-', `openstack-cli-'),
                # but the package shares the shorter `openstack-' prefix across
                # both files.  Whitelist it.  The pack above carries
                # magit-section, so package-lint finds the one real dependency
                # installed; emacs itself is special-cased.
                emacs --batch -l package-lint \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`openstack-"))' \
                  -f package-lint-batch-and-exit \
                  "''${package_files[@]}"

                # The test tree joins the gate as secondary files of the main
                # file.  `package-lint-main-file' stops package-lint from
                # treating each test file as its own package and demanding a
                # `Package-Requires' header; the test file names and their
                # test names instead follow the file they exercise, so the
                # prefix rule needs the `ol-openstack-' prefix of the Org link
                # tests as well.  The helper keeps a `provide' form like every
                # other secondary file, so the loader can require it.
                emacs --batch -l package-lint \
                  --eval '(setq package-lint-main-file "openstack.el")' \
                  --eval '(setq package-lint--sane-prefixes (concat package-lint--sane-prefixes "\\|\\`openstack-\\|\\`ol-openstack-"))' \
                  -f package-lint-batch-and-exit \
                  "''${test_files[@]}"

                touch $out
              '';

          # checkdoc: docstring conventions, which byte-compilation cannot
          # check.
          checks.checkdoc =
            pkgs.runCommandLocal "openstack-mode-checkdoc"
              {
                # Emacs writes its user directory under HOME during the
                # run, so HOME must point at a temporary, writable place.
                nativeBuildInputs = [
                  pkgs.writableTmpDirAsHomeHook
                  pkgs.emacs
                ];
                src = ./.;
              }
              ''
                ${lintFiles}

                # checkdoc exits 0 even on findings — gate on non-empty output.
                lint_log=$(emacs --batch -l checkdoc \
                  --eval '(setq checkdoc-arguments-in-order-flag t)' \
                  --eval "(mapc #'checkdoc-file command-line-args-left)" \
                  "''${package_files[@]}" "''${test_files[@]}" 2>&1)
                if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                touch $out
              '';

          devShells.default = pkgs.mkShell {
            # Mirror whatever the package needs at runtime when hacking on
            # it: the external CLI, a real Emacs for interactive testing.
            # Evil comes along for the optional openstack-evil.el layer.
            packages = [
              pkgs.openstackclient-full
              (pkgs.emacsPackages.emacsWithPackages (p: [
                p.evil
                p.magit-section
              ]))
            ];
          };
        };
    };
}
