;;; openstack-cli-tests.el --- Tests for openstack-cli -*- lexical-binding: t -*-

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

(require 'ert)
(require 'openstack-cli)

;;; Helpers

(defun openstack-cli-test--mock-run (args status stdout)
  "Mock `openstack-cli--run' to return STATUS and STDERR.
ARGS is the argument list; it is validated to be a non-empty
list of strings.  Returns (STATUS . OUTPUT) for the caller."
  (openstack-cli--check-args args)
  (cons status stdout))

(defun openstack-cli-test--with-fixture-program (script fn)
  "Run FN with a fixture executable running SCRIPT as the client.
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

(defmacro openstack-cli-test--with-mock-run (status stdout &rest body)
  "Run BODY with `openstack-cli--run' mocked to return STATUS/STDOUT.
STATUS is the mock exit code, STDOUT the mock stderr text."
  `(cl-letf (((symbol-function 'openstack-cli--run)
              (lambda (args &optional _text)
                (openstack-cli-test--mock-run args ,status ,stdout))))
     ,@body))

(defun openstack-cli-test--wait-until (pred)
  "Wait until PRED returns non-nil, at most 5 seconds.
Accepts process output while waiting, so background client
processes can finish."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

;;; Tests

(ert-deftest openstack-cli-request-json-object ()
  "A successful run parses the JSON output into a hash table."
  (openstack-cli-test--with-mock-run 0 "{\"id\": \"abc\", \"name\": \"web-1\"}"
    (let ((result (openstack-cli-request '("server" "show" "abc"))))
      (should (hash-table-p result))
      (should (equal (gethash "id" result) "abc"))
      (should (equal (gethash "name" result) "web-1")))))

(ert-deftest openstack-cli-request-json-array ()
  "A list command returns a list of hash tables."
  (openstack-cli-test--with-mock-run 0 "[{\"id\": \"a\"}, {\"id\": \"b\"}]"
    (let ((result (openstack-cli-request '("server" "list"))))
      (should (listp result))
      (should (= (length result) 2))
      (should (equal (gethash "id" (car result)) "a")))))

(ert-deftest openstack-cli-request-empty-output-ok ()
  "Empty output with zero exit parses to nil."
  (openstack-cli-test--with-mock-run 0 nil
    (should (null (openstack-cli-request '("server" "delete" "abc"))))))

(ert-deftest openstack-cli-request-nonzero-exit-signals ()
  "A non-zero exit signals `openstack-cli-error' with stderr."
  (openstack-cli-test--with-mock-run 1 "auth failed"
    (should-error (openstack-cli-request '("server" "list"))
                  :type 'openstack-cli-error)))

(ert-deftest openstack-cli-request-invalid-json-signals ()
  "Unparseable output signals `openstack-cli-error'."
  (openstack-cli-test--with-mock-run 0 "not json"
    (should-error (openstack-cli-request '("server" "show" "abc"))
                  :type 'openstack-cli-error)))

(ert-deftest openstack-cli-request-error-data ()
  "The error condition carries :exit-code and :stderr data."
  (openstack-cli-test--with-mock-run 2 "bad cmd"
    (condition-case err
        (openstack-cli-request '("bogus" "cmd"))
      (openstack-cli-error
       (let ((data (cdr err)))
         (should (equal (plist-get data :exit-code) 2))
         (should (equal (plist-get data :stderr) "bad cmd"))
         (should (equal (plist-get data :args) '("bogus" "cmd"))))))))

(ert-deftest openstack-cli-request-check-args ()
  "Empty or non-string ARGS signal `user-error'."
  (should-error (openstack-cli-request nil) :type 'user-error)
  (should-error (openstack-cli-request '("x" 42)) :type 'user-error)
  (should-error (openstack-cli-request '()) :type 'user-error))

(ert-deftest openstack-cli-request-real-process-fresh-output ()
  "Each real-process run parses only its own output.
Regression test for the shared stdout buffer: before the fix,
output accumulated across calls, so a no-output command (delete)
returned the previous command's object instead of nil."
  (openstack-cli-test--with-fixture-program
   "if [ \"$2\" = delete ]; then :; else echo '{\"id\": \"abc\"}'; fi\n"
   (lambda (program)
     (let ((openstack-program program))
       (let ((result (openstack-cli-request '("server" "show" "abc"))))
         (should (hash-table-p result))
         (should (equal (gethash "id" result) "abc")))
       ;; A no-output command must not see the earlier object.
       (should (null (openstack-cli-request '("server" "delete" "abc"))))
       ;; And a later show must still work.
       (should (equal (gethash "id"
                               (openstack-cli-request '("server" "show" "abc")))
                      "abc"))))))

(ert-deftest openstack-cli-request-real-process-reports-stderr ()
  "A real-process failure carries the client's stderr, not stdout.
Regression test for the stderr loss: the destination list form of
`call-process' without a stderr file discarded stderr and the old
code reported stdout as the error's `:stderr'."
  (openstack-cli-test--with-fixture-program
   "echo '{\"id\": \"abc\"}'\necho \"real error text\" >&2\nexit 1\n"
   (lambda (program)
     (let ((openstack-program program))
       (condition-case err
           (openstack-cli-request '("server" "show" "abc"))
         (openstack-cli-error
          (let ((data (cdr err)))
            (should (equal (plist-get data :exit-code) 1))
            (should (equal (plist-get data :stderr)
                           "real error text\n"))
            (should (equal (plist-get data :args)
                           '("server" "show" "abc"))))))))))

(ert-deftest openstack-cli-request-timeout-signals ()
  "A hung client gets killed and signals `openstack-cli-timeout'.
`openstack-cli-timeout' subclasses `openstack-cli-error', so
callers catching the general error also catch the timeout."
  (openstack-cli-test--with-fixture-program
   "exec sleep 5\n"
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-timeout 0.5))
       (condition-case err
           (openstack-cli-request '("server" "list"))
         (openstack-cli-timeout
          (let ((data (cdr err)))
            (should (= (plist-get data :timeout) 0.5))
            (should (equal (plist-get data :args) '("server" "list")))))
         (openstack-cli-error
          (ert-fail "timeout signaled the wrong error subtype")))))))

(ert-deftest openstack-cli-request-timeout-slow-but-fitting-ok ()
  "A client finishing before the deadline still returns its output."
  (openstack-cli-test--with-fixture-program
   "sleep 0.3\necho '{\"id\": \"abc\"}'\n"
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-timeout 5))
       (should (equal (gethash "id"
                               (openstack-cli-request '("server" "show" "abc")))
                      "abc"))))))

(cl-defstruct openstack-cli-test--fake-process
  "Stand-in process record that the CLI sentinel reads."
  status exit-status buffer plist)

(defun openstack-cli-test--run-async (args exit-status output &optional success-fn error-fn stderr text)
  "Run ARGS through `openstack-cli-async-request' with a fake process.
Simulate a process exiting with EXIT-STATUS, writing OUTPUT to its
stdout buffer and STDERR to the shared stderr buffer.  SUCCESS-FN and
ERROR-FN are passed through.

The fake process honors the real :buffer argument, so tests can
assert that the sentinel kills the process buffers."
  (let ((proc-buffer (generate-new-buffer "openstack-cli-")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest plist)
                     (let ((real-buffer (or (plist-get plist :buffer)
                                            proc-buffer)))
                       (with-current-buffer real-buffer
                         (insert output))
                       (when stderr
                         (with-current-buffer (plist-get plist :stderr)
                           (insert stderr)))
                       (make-openstack-cli-test--fake-process
                        :status 'run :exit-status 0 :buffer real-buffer))))
                  ((symbol-function 'process-status)
                   (lambda (proc) (openstack-cli-test--fake-process-status proc)))
                  ((symbol-function 'process-exit-status)
                   (lambda (proc) (openstack-cli-test--fake-process-exit-status proc)))
                  ((symbol-function 'process-buffer)
                   (lambda (proc) (openstack-cli-test--fake-process-buffer proc)))
                  ((symbol-function 'process-get)
                   (lambda (proc prop)
                     (plist-get (openstack-cli-test--fake-process-plist proc)
                                prop)))
                  ((symbol-function 'process-put)
                   (lambda (proc prop value)
                     (setf (openstack-cli-test--fake-process-plist proc)
                           (plist-put (openstack-cli-test--fake-process-plist proc)
                                      prop value))))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (proc sentinel)
                     (setf (openstack-cli-test--fake-process-status proc) 'exit
                           (openstack-cli-test--fake-process-exit-status proc) exit-status)
                     (funcall sentinel proc 'exit))))
          (openstack-cli-async-request
           args
           :success-fn (or success-fn (lambda (_r) nil))
           :error-fn (or error-fn (lambda (_e) nil))
           :text text))
      (when (buffer-live-p proc-buffer)
        (kill-buffer proc-buffer)))))

(ert-deftest openstack-cli-async-request-success ()
  "Async success invokes SUCCESS-FN with the parsed JSON."
  (let ((result nil) (err nil) (called nil))
    (openstack-cli-test--run-async
     '("server" "show" "abc") 0
     "{\"id\": \"abc\", \"name\": \"web-1\"}"
     (lambda (r) (setq called t result r))
     (lambda (e) (setq err e)))
    (should called)
    (should (null err))
    (should (hash-table-p result))
    (should (equal (gethash "id" result) "abc"))))

(ert-deftest openstack-cli-async-request-error ()
  "Async failure invokes ERROR-FN with the condition."
  (let ((err nil) (called nil))
    (openstack-cli-test--run-async
     '("server" "list") 1 "boom"
     (lambda (_r) (setq called t))
     (lambda (e) (setq called t err e)))
    (should called)
    (should (eq (car err) 'openstack-cli-error))))

(ert-deftest openstack-cli-async-request-requires-callbacks ()
  "Omitting or misspelling either callback signals `user-error' early.
Without this check the sentinel would `funcall' nil, surfacing much
later as an unrelated error inside the process sentinel."
  (should-error (openstack-cli-async-request '("server" "list"))
                :type 'user-error)
  (should-error (openstack-cli-async-request '("server" "list")
                                             :success-fn #'ignore)
                :type 'user-error)
  (should-error (openstack-cli-async-request '("server" "list")
                                             :error-fn #'ignore)
                :type 'user-error)
  (should-error (openstack-cli-async-request '("server" "list")
                                             :success-fn "not-a-function"
                                             :error-fn #'ignore)
                :type 'user-error))

(ert-deftest openstack-cli-async-request-buffer-lifecycle ()
  "Async runs leave no stderr accumulation and no process buffers.
Each request gets its own stderr buffer, killed by the sentinel
after the callbacks run; concurrent requests therefore cannot
clobber each other's stderr, and no buffer survives the run."
  (let ((openstack-cli-buffer-name "*openstack-cli-test-stderr*"))
    (unwind-protect
        (progn
          ;; Two failing runs must each report their own stderr.
          (let (reported)
            (openstack-cli-test--run-async
             '("server" "list") 1 "[]"
             nil (lambda (e) (setq reported (plist-get (cdr e) :stderr)))
             "first failure")
            (should (equal reported "first failure")))
          (let (reported)
            (openstack-cli-test--run-async
             '("server" "list") 1 "[]"
             nil (lambda (e) (setq reported (plist-get (cdr e) :stderr)))
             "second failure")
            (should (equal reported "second failure")))
          ;; A successful run leaves no stderr buffer behind either.
          (let (called)
            (openstack-cli-test--run-async
             '("server" "list") 0 "[]"
             (lambda (_r) (setq called t)) (lambda (_e) nil))
            (should called))
          (should-not (seq-some
                       (lambda (b)
                         (string-prefix-p "*openstack-cli-test-stderr"
                                          (buffer-name b)))
                       (buffer-list)))
          (should-not (seq-some (lambda (b) (string-prefix-p "openstack-cli-"
                                                             (buffer-name b)))
                                (buffer-list))))
      (when (get-buffer openstack-cli-buffer-name)
        (kill-buffer openstack-cli-buffer-name)))))

(ert-deftest openstack-cli-autoloads ()
  "Both request entry points carry an autoload cookie."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-cli.el"))
                  (buffer-string))))
    (dolist (entry '("openstack-cli-request" "openstack-cli-request-text"
                     "openstack-cli-async-request"))
      (should (string-match-p
               (format "^;;;###autoload\n(\\(?:defun\\|cl-defun\\) %s\\b"
                       (regexp-quote entry))
               source)))))

(ert-deftest openstack-cli-request-text-keeps-the-output ()
  "A text request returns the client output unchanged."
  (openstack-cli-test--with-mock-run 0 "log line 1\nlog line 2\n"
    (should (equal (openstack-cli-request-text
                    '("console" "log" "show" "srv-1"))
                   "log line 1\nlog line 2\n"))))

(ert-deftest openstack-cli-request-text-reports-an-error ()
  "A failing text request signals `openstack-cli-error'."
  (openstack-cli-test--with-mock-run 1 "boom"
    (should-error (openstack-cli-request-text
                   '("console" "log" "show" "srv-1"))
                  :type 'openstack-cli-error)))

(ert-deftest openstack-cli-text-command-adds-no-formatter ()
  "A text command asks for no `--format'; a JSON one does."
  (should (equal (openstack-cli--command
                  '("console" "log" "show" "srv-1") t)
                 (list openstack-program "console" "log" "show" "srv-1")))
  (should (equal (openstack-cli--command '("server" "show" "srv-1"))
                 (list openstack-program "server" "show" "srv-1"
                       openstack-cli-json-format openstack-cli-json-value))))

(ert-deftest openstack-cli-async-request-text ()
  "The `:text' keyword delivers the plain output."
  (let ((result nil)
        (called nil))
    (openstack-cli-test--run-async
     '("console" "log" "show" "srv-1") 0 "log line\n"
     (lambda (r) (setq called t result r))
     (lambda (_e) nil)
     nil t)
    (should called)
    (should (equal result "log line\n"))))

(provide 'openstack-cli-tests)
;;; openstack-cli-tests.el ends here
