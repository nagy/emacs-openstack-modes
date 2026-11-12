;;; openstack-test-helper.el --- Shared test helpers -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Helpers that more than one test file needs.  The file name does not
;; match `*-test.el', so the glob loader of the check phase leaves it
;; out and each test file requires it.

;;; Code:

(require 'ert)

;;; Source tree

(defconst openstack-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Directory that holds the package sources.
This file lives in its `test/' subdirectory, so two levels up name
the tree that the tests read a source file from.  Tests must not
resolve a source file against `default-directory', because the
caller chooses that.")

(defun openstack-test--source (file)
  "Return the absolute name of the source FILE.
FILE names one source file of the package, such as
\"openstack-mode.el\"."
  (expand-file-name file openstack-test--source-directory))

;;; Processes

(defun openstack-test--with-fixture-program (script fn)
  "Run SCRIPT as the client and call FN with the fixture name.
SCRIPT is the shell body of a fake `openstack-program'; the script
is made executable and passed to FN as its only argument.  The
fixture is deleted afterwards."
  (let* ((program (make-temp-file "openstack-cli-fixture-" nil nil
                                  (concat "#!/bin/sh\n" script))))
    (unwind-protect
        (progn
          (set-file-modes program #o755)
          (funcall fn program))
      (delete-file program))))

(defun openstack-test--wait-until (pred)
  "Wait until PRED returns non-nil, at most 5 seconds.
Accepts process output while waiting, so background client
processes can finish."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(provide 'openstack-test-helper)
;;; openstack-test-helper.el ends here
