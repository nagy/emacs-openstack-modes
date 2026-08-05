{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

melpaBuild {
  pname = "openstack-mode";
  version = "0.1.0";
  src = lib.cleanSource ./.;

  packageRequires = [ ];

  turnCompilationWarningToError = true;

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    echo '=== byte-compile ==='
    emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile openstack-mode.el
    emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile openstack-mode-tests.el

    echo '=== ERT tests ==='
    emacs --batch -L . \
      -l openstack-mode-tests.el \
      -f ert-run-tests-batch-and-exit

    echo '=== checkdoc ==='
    emacs --batch -L . \
      -l checkdoc \
      --eval "(setq checkdoc-arguments-in-order-flag t)" \
      --eval "(mapc #'checkdoc-file command-line-args-left)" \
      openstack-mode.el

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
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/emacs-openstack-modes";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}
