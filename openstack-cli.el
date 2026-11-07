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
;; have no formatter; those are not JSON commands).  A command that
;; prints plain text, such as `console log show', goes through
;; `openstack-cli-request-text' or the `:text' keyword of
;; `openstack-cli-async-request', which add no formatter and parse
;; nothing.
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
(require 'openstack-error)

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
A synchronous call that has not finished after this many seconds
gets its process killed and signals `openstack-cli-timeout' (a
subclass of `openstack-cli-error').  Asynchronous calls do not
use a timeout; they wait for the process to finish and report
via their callbacks."
  :type 'number
  :group 'openstack-cli)

(defcustom openstack-cli-buffer-name "*openstack-cli-stderr*"
  "Base name of the stderr buffer for each async OpenStack CLI call.
Every asynchronous request gets its own buffer named after this
variable (with a uniqueness suffix when needed); the sentinel
kills the buffer once the callbacks have run, so concurrent
requests cannot clobber each other's stderr."
  :type 'string
  :group 'openstack-cli)

;;; Internal state

(defvar openstack-cli--process-number 0
  "Counter for naming asynchronous OpenStack CLI processes.")

;;; Conditions

(define-error 'openstack-cli-error "OpenStack CLI error"
              'openstack-error)

(define-error 'openstack-cli-timeout "OpenStack CLI call timed out"
              'openstack-cli-error)

;;; Argument validation

(defun openstack-cli--check-args (args)
  "Signal `user-error' unless ARGS is a non-empty list of strings."
  (unless (and (listp args) (consp args) (seq-every-p #'stringp args))
    (user-error "openstack-cli: ARGS must be a non-empty list of strings"))
  args)

(defun openstack-cli--check-callbacks (success-fn error-fn)
  "Signal `user-error' unless SUCCESS-FN and ERROR-FN are functions.
Both callbacks are mandatory: the sentinel would otherwise fail with
`funcall' on nil, far away from the call site that omitted one."
  (dolist (pair `((success-fn . ,success-fn) (error-fn . ,error-fn)))
    (unless (functionp (cdr pair))
      (user-error "openstack-cli: %s must be a function" (car pair)))))

;;; Process helpers

(defun openstack-cli--command (args &optional text)
  "Return the full command line for OpenStack client ARGS.
The command is `openstack-program' followed by ARGS.  Unless TEXT,
`--format json' goes at the end unless ARGS already holds
`--format' or `-f'.  A command that prints plain text, such as
`console log show', asks for no formatter."
  (declare (side-effect-free t))
  (let ((prog openstack-program)
        (has-format (seq-some (lambda (a) (member a '("--format" "-f")))
                              args)))
    (if (or text has-format)
        (cons prog args)
      (append (list prog) args
              (list openstack-cli-json-format openstack-cli-json-value)))))

(defun openstack-cli--drain (proc)
  "Wait for PROC to exit, reading the output that is still in flight.
`make-process' starts the stderr pump as a process of its own, so the
client process can exit before the pump has read the client's last
error bytes.  A reader that stops at the exit of the client would then
see an empty stderr buffer.  Wait for PROC until it exits, at most
`openstack-cli-timeout' seconds, and do nothing when PROC is nil or
already dead."
  (when (process-live-p proc)
    (let ((deadline (+ (float-time) openstack-cli-timeout)))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.05)))))

(defun openstack-cli--run (args &optional text)
  "Run `openstack-program' with ARGS synchronously.
TEXT reaches `openstack-cli--command'.
Return (STATUS . OUTPUT) where STATUS is the process exit code.
On success OUTPUT is the process stdout; on a non-zero exit it is
the process stderr instead, because the caller reports that text
as the error's `:stderr' and the stdout of a failed command is
untrustworthy anyway.  Wait at most `openstack-cli-timeout'
seconds; on timeout, kill the process and signal
`openstack-cli-timeout'.  Each call starts from fresh stdout and
stderr buffers, so repeated calls never see earlier output."
  (let* ((cmd (openstack-cli--command args text))
         (stdout-buffer (generate-new-buffer " *openstack-cli*"))
         (stderr-buffer (generate-new-buffer " *openstack-cli-stderr*"))
         (deadline (+ (float-time) openstack-cli-timeout))
         proc
         stderr-proc)
    (unwind-protect
        (progn
          (setq proc (make-process
                      :name "openstack-cli"
                      :command cmd
                      :buffer stdout-buffer
                      :stderr stderr-buffer
                      :connection-type 'pipe
                      :noquery t))
          ;; The default sentinel would insert "Process ... finished"
          ;; into the output buffers, corrupting the captured stdout;
          ;; the stderr pump's default sentinel would also flash a
          ;; message in the echo area.  Polling drives this function,
          ;; so both sentinels do nothing.
          (set-process-sentinel proc #'ignore)
          (setq stderr-proc (get-buffer-process stderr-buffer))
          (when stderr-proc
            (set-process-sentinel stderr-proc #'ignore))
          (while (and (process-live-p proc)
                      (< (float-time) deadline))
            (accept-process-output proc 0.25))
          (cond
           ((process-live-p proc)
            (delete-process proc)
            (signal 'openstack-cli-timeout
                    (list :args args :timeout openstack-cli-timeout)))
           (t
            ;; The stderr pump can still hold the last error bytes when
            ;; the client exits; read them before the buffers are read.
            (openstack-cli--drain stderr-proc)
            (let ((status (process-exit-status proc))
                  (output (with-current-buffer stdout-buffer
                            (buffer-string)))
                  (stderr (with-current-buffer stderr-buffer
                            (buffer-string))))
              (if (zerop status)
                  (cons status output)
                (cons status stderr))))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (kill-buffer stdout-buffer)
      (kill-buffer stderr-buffer))))

;;; Synchronous API

;;;###autoload
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
  (openstack-cli--sync-start args))

(defun openstack-cli--sync-start (args &optional text)
  "Run the OpenStack client with ARGS synchronously, return parsed JSON.
With TEXT the function returns the plain output text instead.
Signal `openstack-cli-error' on a non-zero exit or unparseable
output, as described in `openstack-cli-request'."
  (let* ((result (openstack-cli--run args text)))
    (if (zerop (car result))
        (let ((output (cdr result)))
          (cond (text output)
                ((or (null output) (string-empty-p (string-trim output)))
                 nil)
                (t
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
                            (list :args args :stderr nil :reason err)))))))
      (signal 'openstack-cli-error
              (list :args args :exit-code (car result)
                    :stderr (cdr result))))))

;;;###autoload
(defun openstack-cli-request-text (args)
  "Run the OpenStack client synchronously with ARGS, return its text.
Unlike `openstack-cli-request', the call adds no formatter and
parses nothing, for a command that prints plain text, such as
`console log show'.  Signal `openstack-cli-error' on a non-zero
exit, with the client's stderr in the condition data."
  (openstack-cli--check-args args)
  (openstack-cli--sync-start args t))

;;; Asynchronous API

;;;###autoload
(cl-defun openstack-cli-async-request (args &key success-fn error-fn text)
  "Run the OpenStack client asynchronously with ARGS.
ARGS is a list of command line arguments, as in
`openstack-cli-request'.

On success, call SUCCESS-FN with the parsed JSON result (a hash
table or vector).  On failure, call ERROR-FN with an
`openstack-cli-error' condition.  Both callbacks are required and
must be functions.  With TEXT, the client adds no formatter and
SUCCESS-FN receives the plain output as a string instead.

If the process cannot be started at all, or a callback is missing,
signal `user-error'.
Otherwise this function returns the client process immediately;
the process runs in the background and the appropriate callback is
invoked when it finishes."
  (openstack-cli--check-args args)
  (openstack-cli--check-callbacks success-fn error-fn)
  (openstack-cli--async-start args success-fn error-fn text))

(defun openstack-cli--async-start (args success-fn error-fn &optional text)
  "Run the OpenStack client with ARGS in one background process.
Call SUCCESS-FN with the parsed JSON output, or ERROR-FN with an
`openstack-cli-error' condition, when the process exits; with
TEXT, SUCCESS-FN receives the plain output as a string.  Return
the client process."
  (let* ((cmd (openstack-cli--command args text))
         (number (cl-incf openstack-cli--process-number))
         (name (format "openstack-cli-%d" number))
         ;; Each request gets its own stderr buffer, killed by the
         ;; sentinel once the callbacks have run; concurrent requests
         ;; therefore cannot clobber each other's stderr.
         (stderr-buffer (generate-new-buffer openstack-cli-buffer-name)))
    (let ((proc (condition-case err
                    (make-process
                     :name name
                     :command cmd
                     ;; `make-process' with no :buffer associates no
                     ;; buffer at all, silently discarding the output;
                     ;; give each request its own stdout buffer.
                     :buffer (generate-new-buffer name)
                     :connection-type 'pipe
                     :stderr stderr-buffer
                     :noquery t)
                  (error
                   (kill-buffer stderr-buffer)
                   (signal (car err) (cdr err))))))
      ;; Silence the stderr pump's default sentinel; its "finished"
      ;; message would otherwise clutter the echo area.
      (let ((stderr-proc (get-buffer-process stderr-buffer)))
        (when stderr-proc
          (set-process-sentinel stderr-proc #'ignore)))
      (set-process-sentinel
       proc
       (lambda (proc _event)
         (when (eq (process-status proc) 'exit)
           ;; Run exactly once per process, even if the sentinel is
           ;; invoked again for a later status change.
           (unless (process-get proc 'openstack-cli--handled)
             (process-put proc 'openstack-cli--handled t)
             (openstack-cli--drain (get-buffer-process stderr-buffer))
             (let* ((code (process-exit-status proc))
                    (stderr (with-current-buffer stderr-buffer
                              (let ((s (buffer-string)))
                                (unless (string-empty-p s) s))))
                    (proc-buffer (process-buffer proc))
                    (output (when (buffer-live-p proc-buffer)
                              (with-current-buffer proc-buffer
                                (buffer-string))))
                    (output (or output "")))
               (when (buffer-live-p proc-buffer)
                 (kill-buffer proc-buffer))
               (when (buffer-live-p stderr-buffer)
                 (kill-buffer stderr-buffer))
               (if (zerop code)
                 (condition-case err
                     (funcall success-fn
                              (if text
                                  output
                                (openstack-cli--parse-json output)))
                   (error
                    (funcall error-fn
                             (cons 'openstack-cli-error
                                   (list :args args :stderr stderr
                                         :reason err)))))
               (funcall error-fn
                        (cons 'openstack-cli-error
                              (list :args args :exit-code code
                                    :stderr stderr)))))))))
      proc)))

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
