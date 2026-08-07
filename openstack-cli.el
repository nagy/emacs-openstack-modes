;;; openstack-cli.el --- Interface to the OpenStack command line client -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/nagy/emacs-openstack-modes

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides a single interface to the OpenStack command
;; line client, configured by `openstack-program' (the
;; python-openstackclient from nixpkgs, package =openstackclient-full=).
;;
;; The design mirrors the =jsonrpc= library: a synchronous
;; `openstack-cli-request' for callers that want a blocking result,
;; and an asynchronous `openstack-cli-async-request' for callers that
;; do not want to block Emacs.  Both share argument validation,
;; `--format json' handling, and error reporting.
;;
;; The OpenStack client supports `--format json' on essentially every
;; command that produces output: `show', `list', `create', `set' and
;; `delete' (some `delete' variants return no output and therefore
;; have no formatter; those are not JSON commands).  Action commands
;; like `server reboot' or `image save' similarly produce no JSON
;; output, so they are used with `openstack-cli-run' instead.
;;
;; Synchronous usage:
;;
;;   (openstack-cli-request '("server" "show" "some-id"))
;;   => (("id" . "some-id") ("name" . "web-1") ...)
;;
;; Asynchronous usage:
;;
;;   (openstack-cli-async-request
;;    '("server" "list")
;;    :success-fn (lambda (result) ...)
;;    :error-fn (lambda (err) ...))
;;
;; Errors: a non-zero exit or an unparseable response signals a
;; `openstack-cli-error' condition (sync) or calls ERROR-FN (async)
;; with the same condition.  Authentication failures and missing
;; resources are reported this way, with the client's stderr message
;; attached.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)

;;; Customization

(defgroup openstack-cli nil
  "Interface to the OpenStack command line client."
  :prefix "openstack-cli-"
  :group 'openstack)

(defcustom openstack-program "openstack"
  "Path to the OpenStack command line client executable.

This is the python-openstackclient program, normally installed
via Nix as the =openstackclient-full= package.  The Nix build
substitutes this default with the store path of that package."
  :type 'file
  :group 'openstack-cli)

(defcustom openstack-cli-json-format "--format"
  "Option used to request JSON output from `openstack-program'."
  :type 'string
  :group 'openstack-cli)

(defcustom openstack-cli-json-value "json"
  "Value for `openstack-cli-json-format' requesting JSON output."
  :type 'string
  :group 'openstack-cli)

(defcustom openstack-cli-timeout 30
  "Timeout in seconds for synchronous OpenStack CLI calls.
Asynchronous calls do not use a timeout; they wait for the
process to finish and report via their callbacks."
  :type 'number
  :group 'openstack-cli)

(defcustom openstack-cli-buffer-name "*openstack-cli-stderr*"
  "Name of the buffer receiving stderr from `openstack-program'."
  :type 'string
  :group 'openstack-cli)

;;; Internal state

(defvar openstack-cli--process-number 0
  "Counter for naming asynchronous OpenStack CLI processes.")

;;; Conditions

(define-error 'openstack-cli-error "OpenStack CLI error")

;;; Argument validation

(defun openstack-cli--check-args (args)
  "Signal `user-error' unless ARGS is a non-empty list of strings."
  (unless (and (listp args) (consp args) (seq-every-p #'stringp args))
    (user-error "openstack-cli: ARGS must be a non-empty list of strings"))
  args)

;;; Process helpers

(defun openstack-cli--command (args)
  "Return the full command line for OpenStack client ARGS.
The command is `openstack-program' followed by ARGS with
`--format json' inserted at the end (unless ARGS already
contains `--format' or `-f')."
  (let ((prog openstack-program)
        (has-format (seq-some (lambda (a) (member a '("--format" "-f")))
                              args)))
    (if has-format
        (cons prog args)
      (append (list prog) args
              (list openstack-cli-json-format openstack-cli-json-value)))))

(defun openstack-cli--run (args)
  "Run `openstack-program' with ARGS synchronously.
Return (STATUS . STDERR-TEXT) where STATUS is the process exit
code and STDERR-TEXT is the text written to stderr, or nil on
success with empty stderr."
  (let* ((cmd (openstack-cli--command args))
         (stderr-buffer (get-buffer-create openstack-cli-buffer-name))
         (stdout-buffer (get-buffer-create " *openstack-cli-stdout*"))
         (status (apply #'call-process
                        (car cmd) nil (list stdout-buffer nil) nil
                        (cdr cmd))))
    (let ((stdout (with-current-buffer stdout-buffer
                    (buffer-string))))
      (with-current-buffer stderr-buffer
        (let ((err (buffer-string)))
          (when (string-empty-p err)
            (setq err nil))
          (cons status (if (string-empty-p stdout) nil stdout)))))))

;;; Synchronous API

(defun openstack-cli-request (args)
  "Run the OpenStack client synchronously with ARGS, return parsed JSON.
ARGS is a list of command line arguments, e.g.
\\='(\"server\" \"show\" \"some-id\").

The client is run with `--format json', so the output is parsed
with `json-parse-buffer' and returned as a hash table or vector.

If the client exits non-zero, or the output cannot be parsed,
signal an `openstack-cli-error' condition.  The condition data
is a plist with keys `:exit-code' (if any), `:stderr' (the
client's error text, if any) and `:args'."
  (openstack-cli--check-args args)
  (let* ((result (openstack-cli--run args)))
    (if (zerop (car result))
        (let ((output (cdr result)))
          (if (or (null output) (string-empty-p (string-trim output)))
              nil
            (condition-case err
                (with-temp-buffer
                  (insert output)
                  (goto-char (point-min))
                  (json-parse-buffer
                   :object-type 'hash-table
                   :array-type 'list
                   :null-object nil
                   :false-object nil))
              (error
               (signal 'openstack-cli-error
                       (list :args args :stderr nil :reason err))))))
      (signal 'openstack-cli-error
              (list :args args :exit-code (car result)
                    :stderr (cdr result))))))

;;; Asynchronous API

(cl-defun openstack-cli-async-request (args &key success-fn error-fn)
  "Run the OpenStack client asynchronously with ARGS.
ARGS is a list of command line arguments, as in
`openstack-cli-request'.

On success, call SUCCESS-FN with the parsed JSON result (a hash
table or vector).  On failure, call ERROR-FN with an
`openstack-cli-error' condition.

If the process cannot be started at all, signal `user-error'.
Otherwise this function returns immediately; the process runs in
the background and the appropriate callback is invoked when it
finishes."
  (openstack-cli--check-args args)
  (let* ((cmd (openstack-cli--command args))
         (number (cl-incf openstack-cli--process-number))
         (name (format "openstack-cli-%d" number))
         (stderr-buffer (get-buffer-create openstack-cli-buffer-name))
         (proc (make-process
                :name name
                :command cmd
                :connection-type 'pipe
                :stderr stderr-buffer
                :noquery t)))
    (set-process-sentinel
     proc
     (lambda (proc _event)
       (when (eq (process-status proc) 'exit)
         (let* ((code (process-exit-status proc))
                (stderr (with-current-buffer stderr-buffer
                          (let ((s (buffer-string)))
                            (unless (string-empty-p s) s))))
                (output (with-current-buffer (process-buffer proc)
                          (buffer-string))))
           (if (zerop code)
               (condition-case err
                   (funcall success-fn
                            (openstack-cli--parse-json output))
                 (error
                  (funcall error-fn
                           (cons 'openstack-cli-error
                                 (list :args args :stderr stderr
                                       :reason err)))))
             (funcall error-fn
                      (cons 'openstack-cli-error
                            (list :args args :exit-code code
                                  :stderr stderr))))))))
    proc))

(defun openstack-cli--parse-json (text)
  "Parse TEXT as a JSON object or array.
Signal `openstack-cli-error' if TEXT is not valid JSON."
  (condition-case err
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (json-parse-buffer
         :object-type 'hash-table
         :array-type 'list
         :null-object nil
         :false-object nil))
    (error
     (signal 'openstack-cli-error
             (list :reason err)))))

(provide 'openstack-cli)
;;; openstack-cli.el ends here
