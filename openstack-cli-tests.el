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
list of strings.  Returns (STATUS . STDERR) for the caller."
  (openstack-cli--check-args args)
  (cons status stdout))

(defmacro openstack-cli-test--with-mock-run (status stdout &rest body)
  "Run BODY with `openstack-cli--run' mocked to return STATUS/STDOUT.
STATUS is the mock exit code, STDOUT the mock stderr text."
  `(cl-letf (((symbol-function 'openstack-cli--run)
              (lambda (args)
                (openstack-cli-test--mock-run args ,status ,stdout))))
     ,@body))

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

(cl-defstruct openstack-cli-test--fake-process
  status exit-status buffer)

(defun openstack-cli-test--run-async (args exit-status output &optional success-fn error-fn)
  "Run ARGS through `openstack-cli-async-request' with a fake process.
Simulate a process exiting with EXIT-STATUS and writing OUTPUT to
its stdout buffer.  SUCCESS-FN and ERROR-FN are passed through."
  (let ((output-buffer (generate-new-buffer " *openstack-cli-async-out*")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _)
                     (make-openstack-cli-test--fake-process
                      :status 'run :exit-status 0 :buffer output-buffer)))
                  ((symbol-function 'process-status)
                   (lambda (proc) (openstack-cli-test--fake-process-status proc)))
                  ((symbol-function 'process-exit-status)
                   (lambda (proc) (openstack-cli-test--fake-process-exit-status proc)))
                  ((symbol-function 'process-buffer)
                   (lambda (proc) (openstack-cli-test--fake-process-buffer proc)))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (proc sentinel)
                     (with-current-buffer output-buffer (insert output))
                     (setf (openstack-cli-test--fake-process-status proc) 'exit
                           (openstack-cli-test--fake-process-exit-status proc) exit-status)
                     (funcall sentinel proc 'exit))))
          (openstack-cli-async-request
           args
           :success-fn (or success-fn (lambda (_r) nil))
           :error-fn (or error-fn (lambda (_e) nil))))
      (kill-buffer output-buffer))))

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

(provide 'openstack-cli-tests)
;;; openstack-cli-tests.el ends here
