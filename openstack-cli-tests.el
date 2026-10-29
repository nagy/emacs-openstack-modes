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
              (lambda (args)
                (openstack-cli-test--mock-run args ,status ,stdout))))
     ;; Keep the token cache out of these tests: they exercise the
     ;; request mechanics, not authentication.
     (let ((openstack-cli-use-token nil))
       ,@body)))

(defun openstack-cli-test--wait-until (pred)
  "Wait until PREDFN returns non-nil, at most 5 seconds.
Accepts process output while waiting, so background client
processes can finish."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(defconst openstack-cli-test--token-script
  "case \"$1\" in\n    token) echo '{\"id\": \"tok-1\", \"expires\": \"2099-01-01T00:00:00+0000\"}' ;;\n    *) printf '{\"token\": \"%s\"}\\n' \"${OS_TOKEN:-none}\" ;;\nesac\n"
  "Fake client script for the token cache tests.
Answers `token issue' with a far-future token and every other
command with the OS_TOKEN it received, so tests can see which
token (if any) reached the client.")

(defun openstack-cli-test--clean-auth-env (&rest extra)
  "Return `process-environment' without OpenStack auth variables.
EXTRA entries are prepended, so a test can set the auth type it
wants without inheriting the auth type of the test runner."
  (append extra
          (cl-remove-if
           (lambda (entry)
             (string-match-p
              "\\`OS_\\(?:AUTH_TYPE\\|APPLICATION_CREDENTIAL_[A-Z_]*\\|TOKEN\\)="
              entry))
           process-environment)))

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
  status exit-status buffer plist)

(defun openstack-cli-test--run-async (args exit-status output &optional success-fn error-fn stderr)
  "Run ARGS through `openstack-cli-async-request' with a fake process.
Simulate a process exiting with EXIT-STATUS, writing OUTPUT to its
stdout buffer and STDERR to the shared stderr buffer.  SUCCESS-FN and
ERROR-FN are passed through.

The fake process honors the real :buffer argument, so tests can
assert that the sentinel kills the process buffers."
  (let ((proc-buffer (generate-new-buffer "openstack-cli-"))
        ;; Keep the token cache out of these tests: they exercise the
        ;; request mechanics, not authentication.
        (openstack-cli-use-token nil))
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
           :error-fn (or error-fn (lambda (_e) nil))))
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

(ert-deftest openstack-cli-async-token-prefetch-and-reuse ()
  "Requests warm the token cache and later pass the token as OS_TOKEN.
The first request authenticates on its own while the cache fills
in the background; the next one rides on the cached token."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (openstack-cli-test--with-fixture-program
       openstack-cli-test--token-script
       (lambda (program)
         (let ((openstack-program program)
               (openstack-cli-use-token t)
               (first nil)
               (second nil))
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq first (gethash "token" r)))
            :error-fn (lambda (e) (setq first e)))
           (openstack-cli-test--wait-until (lambda () first))
           (should (stringp first))
           ;; The background `token issue' lands asynchronously.
           (openstack-cli-test--wait-until
            (lambda () (openstack-cli--cached-token)))
           (should (equal (openstack-cli--cached-token) "tok-1"))
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq second (gethash "token" r)))
            :error-fn (lambda (e) (setq second e)))
           (openstack-cli-test--wait-until (lambda () second))
           (should (equal second "tok-1")))))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-async-token-retry-on-auth-error ()
  "An authentication failure drops the token and retries once.
A client that rejects the cached token (expired, revoked, or
unsupported environment) must not leave the caller with a failed
request."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (openstack-cli-test--with-fixture-program
       (concat
        "if [ \"$1\" = token ]; then\n"
        "    echo '{\"id\": \"tok-1\", \"expires\": \"2099-01-01T00:00:00+0000\"}'\n"
        "elif [ -n \"$OS_TOKEN\" ]; then\n"
        "    echo 'HTTP 401 Unauthorized' >&2\n"
        "    exit 1\n"
        "else\n"
        "    echo '{\"token\": \"none\"}'\n"
        "fi\n")
       (lambda (program)
         (let ((openstack-program program)
               (openstack-cli-use-token t)
               (result nil))
           ;; Warm and verify the cache first.
           (openstack-cli-async-request
            '("server" "list")
            :success-fn #'ignore :error-fn #'ignore)
           (openstack-cli-test--wait-until
            (lambda () (openstack-cli--cached-token)))
           ;; This call fails once with the token and succeeds on the
           ;; retry without it.
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq result (gethash "token" r)))
            :error-fn (lambda (e) (setq result e)))
           (openstack-cli-test--wait-until (lambda () result))
           (should (equal result "none"))
           (should-not (openstack-cli--cached-token)))))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-token-store-parses-expiry ()
  "The token cache remembers the id and parsed expiry of `token issue'.
An unparseable expiry drops the token instead of caching it: it
would count as permanently stale and churn `token issue' calls
without ever serving one."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (progn
        (let ((result (make-hash-table :test #'equal)))
          (puthash "id" "tok-2" result)
          (puthash "expires" "2099-01-01T00:00:00+0000" result)
          (openstack-cli--token-store result)
          (should (equal (openstack-cli--cached-token) "tok-2")))
        (openstack-cli-token-invalidate)
        (should-not (openstack-cli--cached-token))
        ;; Unparseable expiry: the token is dropped, not cached.
        (let ((result (make-hash-table :test #'equal)))
          (puthash "id" "tok-3" result)
          (puthash "expires" "not-a-date" result)
          (openstack-cli--token-store result)
          (should-not (openstack-cli--cached-token)))
        ;; Garbage output must not error.
        (openstack-cli-token-invalidate)
        (openstack-cli--token-store nil)
        (should-not (openstack-cli--cached-token)))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-use-token-nil-disables-cache ()
  "With `openstack-cli-use-token' nil no token is fetched or used.
The client then authenticates on every call, exactly as before
the token cache existed."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (openstack-cli-test--with-fixture-program
       openstack-cli-test--token-script
       (lambda (program)
         (let ((openstack-program program)
               (openstack-cli-use-token nil)
               (result nil))
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq result (gethash "token" r)))
            :error-fn (lambda (e) (setq result e)))
           (openstack-cli-test--wait-until (lambda () result))
           (should (equal result "none"))
           (should-not (openstack-cli--cached-token)))))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-application-credential-auth-p-detection ()
  "Application credential auth comes from the environment.
`OS_AUTH_TYPE' wins when set; otherwise an application credential
variable implies the type."
  (dolist (type '("v3applicationcredential" "v3ApplicationCredential"))
    (let ((process-environment
           (openstack-cli-test--clean-auth-env
            (concat "OS_AUTH_TYPE=" type))))
      (should (openstack-cli--application-credential-auth-p))))
  (let ((process-environment
         (openstack-cli-test--clean-auth-env "OS_AUTH_TYPE=v3password")))
    (should-not (openstack-cli--application-credential-auth-p)))
  (dolist (variable '("OS_APPLICATION_CREDENTIAL_ID"
                      "OS_APPLICATION_CREDENTIAL_NAME"
                      "OS_APPLICATION_CREDENTIAL_SECRET"))
    (let ((process-environment
           (openstack-cli-test--clean-auth-env
            (concat variable "=cred"))))
      (should (openstack-cli--application-credential-auth-p))))
  (let ((process-environment
         (openstack-cli-test--clean-auth-env
          "OS_APPLICATION_CREDENTIAL_ID=")))
    (should-not (openstack-cli--application-credential-auth-p))))

(ert-deftest openstack-cli-token-skipped-for-application-credentials ()
  "No OS_TOKEN goes out under application credential auth.
The client rejects a token argument for that auth type, so the
cache must neither inject one nor fetch a fresh one.  Password
auth keeps the token."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (openstack-cli-test--with-fixture-program
       openstack-cli-test--token-script
       (lambda (program)
         ;; Seed the cache with a usable token.
         (let ((stored (make-hash-table :test #'equal)))
           (puthash "id" "tok-1" stored)
           (puthash "expires" "2099-01-01T00:00:00+0000" stored)
           (openstack-cli--token-store stored))
         (let ((openstack-program program)
               (openstack-cli-use-token t)
               (process-environment
                (openstack-cli-test--clean-auth-env
                 "OS_AUTH_TYPE=v3applicationcredential"))
               (result nil))
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq result (gethash "token" r)))
            :error-fn (lambda (e) (setq result e)))
           (openstack-cli-test--wait-until (lambda () result))
           (should (equal result "none"))
           (should (equal (gethash "token"
                                   (openstack-cli-request '("server" "list")))
                          "none")))
         ;; Password auth still receives the cached token.
         (let ((openstack-program program)
               (openstack-cli-use-token t)
               (process-environment
                (openstack-cli-test--clean-auth-env
                 "OS_AUTH_TYPE=v3password"))
               (result nil))
           (openstack-cli-async-request
            '("server" "list")
            :success-fn (lambda (r) (setq result (gethash "token" r)))
            :error-fn (lambda (e) (setq result e)))
           (openstack-cli-test--wait-until (lambda () result))
           (should (equal result "tok-1")))))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-request-token-retry-on-auth-error ()
  "A sync call that fails on a stale cached token retries once without it.
The sync path must self-heal exactly like the async one."
  (openstack-cli-token-invalidate)
  (unwind-protect
      (openstack-cli-test--with-fixture-program
       (concat
        "if [ -n \"$OS_TOKEN\" ]; then\n"
        "    echo 'HTTP 401 Unauthorized' >&2\n"
        "    exit 1\n"
        "else\n"
        "    echo '{\"token\": \"none\"}'\n"
        "fi\n")
       (lambda (program)
         (let ((openstack-program program)
               (openstack-cli-use-token t))
           ;; Seed the cache with a token the fixture rejects.
           (let ((result (make-hash-table :test #'equal)))
             (puthash "id" "tok-1" result)
             (puthash "expires" "2099-01-01T00:00:00+0000" result)
             (openstack-cli--token-store result))
           (should (equal (gethash "token"
                                   (openstack-cli-request '("server" "list")))
                          "none"))
           (should-not (openstack-cli--cached-token)))))
    (openstack-cli-token-invalidate)))

(ert-deftest openstack-cli-autoloads ()
  "Both request entry points carry an autoload cookie."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-cli.el"))
                  (buffer-string))))
    (dolist (entry '("openstack-cli-request" "openstack-cli-async-request"))
      (should (string-match-p
               (format "^;;;###autoload\n(\\(?:defun\\|cl-defun\\) %s\\b"
                       (regexp-quote entry))
               source)))))

(provide 'openstack-cli-tests)
;;; openstack-cli-tests.el ends here
