;;; openstack-data-tests.el --- Tests for openstack-data -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The data layer is the surface that other packages consume, so the
;; tests call it without a buffer, without a mode and without a real
;; cloud.  Every client call is mocked at the CLI layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'openstack-api)
(require 'openstack-data)
(require 'openstack-read)
(require 'openstack-resources)

;;; Helpers

(defun openstack-data-test--row (&rest pairs)
  "Return a hash table holding PAIRS as string keys and values."
  (let ((row (make-hash-table :test 'equal)))
    (while pairs
      (puthash (car pairs) (cadr pairs) row)
      (setq pairs (cddr pairs)))
    row))

;;; Data entry points

(ert-deftest openstack-data-show-runs-client-show ()
  "The show call runs the client command of the type."
  (let ((seen nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (setq seen args) :data)))
      (should (eq (openstack-resource-show "server" "srv-1") :data))
      (should (equal seen '("server" "show" "srv-1"))))))

(ert-deftest openstack-data-show-honors-cli-override ()
  "The show call takes the client command from the definition."
  (let ((seen nil)
        (openstack-resource-definitions
         '(("fake" :type "fake" :cli "fake-client"))))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (setq seen args) :data)))
      (openstack-resource-show "fake" "res-1")
      (should (equal seen '("fake-client" "show" "res-1"))))))

(ert-deftest openstack-data-show-async-calls-async-request ()
  "The async show call passes both callbacks to the CLI layer."
  (let ((seen nil)
        (success nil)
        (failure nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq seen args
                                    success success-fn
                                    failure error-fn)
                              :process))))
      (should (eq (openstack-resource-show-async
                   "server" "srv-1"
                   (lambda (_data) nil) (lambda (_err) nil))
                  :process))
      (should (equal seen '("server" "show" "srv-1")))
      (should (functionp success))
      (should (functionp failure)))))

(ert-deftest openstack-data-list-uses-definition-arguments ()
  "The list call appends the defcustom arguments and the extra ones.
A user customization of `openstack-TYPE-list-arguments' wins, and
EXTRA follows it."
  (let ((seen nil)
        (openstack-container-list-arguments '("--long")))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (setq seen args) :rows)))
      (should (eq (openstack-resource-list "container") :rows))
      (should (equal seen '("container" "list" "--long")))
      (openstack-resource-list "container" '("--prefix" "p"))
      (should (equal seen '("container" "list" "--long" "--prefix" "p")))
      (let ((openstack-container-list-arguments nil))
        (openstack-resource-list "container")
        (should (equal seen '("container" "list")))))))

(ert-deftest openstack-data-list-async-calls-async-request ()
  "The async list call passes the arguments and both callbacks."
  (let ((seen nil)
        (success nil)
        (failure nil)
        (openstack-container-list-arguments '("--long")))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq seen args
                                    success success-fn
                                    failure error-fn)
                              :process))))
      (should (eq (openstack-resource-list-async
                   "container"
                   (lambda (_data) nil) (lambda (_err) nil)
                   '("--all"))
                  :process))
      (should (equal seen '("container" "list" "--long" "--all")))
      (should (functionp success))
      (should (functionp failure)))))

(ert-deftest openstack-data-cancel-kills-a-live-process ()
  "Cancelling a live process deletes it and signals nothing."
  (let ((process (make-process :name "openstack-data-test"
                               :command '("cat")
                               :noquery t)))
    (unwind-protect
        (progn
          (should (process-live-p process))
          (openstack-resource-cancel process)
          (should-not (process-live-p process)))
      (when (process-live-p process) (delete-process process)))
    (should-not (openstack-resource-cancel nil))))

(ert-deftest openstack-data-read-path-honors-definition ()
  "The list cache asks the client with the definition of the type.
A type whose client command differs from the type name, and whose
definition carries list arguments, keeps both."
  (let ((openstack-resource-definitions
         '(("fake" :type "fake" :cli "fake-client"
                    :list-arguments ("--long"))))
        (openstack-resource--list-cache nil)
        (seen nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (setq seen args) nil)))
      (openstack-read-rows "fake")
      (should (equal seen '("fake-client" "list" "--long"))))))

;;; Cache

(ert-deftest openstack-resource-list-cached-fetches-once ()
  "A fresh entry comes back without a client call, FORCE refetches."
  (let ((openstack-resource--list-cache nil)
        (calls nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (push args calls) '(:row))))
      (should (equal (openstack-resource-list-cached "server") '(:row)))
      (should (equal (openstack-resource-list-cached "server") '(:row)))
      (should (equal calls '(("server" "list"))))
      (should (equal (openstack-resource-list-cached "server" t) '(:row)))
      (should (equal calls '(("server" "list") ("server" "list")))))))

(ert-deftest openstack-resource-list-cached-expires ()
  "An entry older than the TTL triggers a new client call."
  (let ((openstack-resource--list-cache nil)
        (openstack-resource-cache-ttl 0)
        (calls 0))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (cl-incf calls) '(:row))))
      (openstack-resource-list-cached "server")
      (openstack-resource-list-cached "server")
      (should (= calls 2)))))

(ert-deftest openstack-resource-list-cached-keeps-forever ()
  "A nil TTL keeps an entry even when the clock moves on."
  (let ((openstack-resource--list-cache nil)
        (openstack-resource-cache-ttl nil)
        (calls 0))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (cl-incf calls) '(:row))))
      (openstack-resource-list-cached "server")
      (cl-letf (((symbol-function 'float-time) (lambda () 1e9)))
        (openstack-resource-list-cached "server"))
      (should (= calls 1)))))

(ert-deftest openstack-resource-cached-rows-never-call ()
  "The cache reader returns an entry without a client call."
  (let ((openstack-resource--list-cache nil)
        (called nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (setq called t) nil)))
      (should (null (openstack-resource-cached-rows "server")))
      (should-not called))))

(ert-deftest openstack-resource-show-cached-fetches-once ()
  "The show cache answers from memory and invalidates one entry."
  (let ((openstack-resource--show-cache nil)
        (calls nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (push args calls) :data)))
      (should (eq (openstack-resource-show-cached "server" "srv-1") :data))
      (should (eq (openstack-resource-show-cached "server" "srv-1") :data))
      (should (equal calls '(("server" "show" "srv-1"))))
      (openstack-resource-invalidate "server" "srv-1")
      (openstack-resource-show-cached "server" "srv-1")
      (should (equal calls '(("server" "show" "srv-1")
                             ("server" "show" "srv-1")))))))

(ert-deftest openstack-resource-invalidate-clears-by-scope ()
  "List, show and whole-cache invalidation stay apart."
  (let ((openstack-resource--list-cache nil)
        (openstack-resource--show-cache nil)
        (calls nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args) (push args calls) :data)))
      (openstack-resource-list-cached "server")
      (openstack-resource-show-cached "server" "srv-1")
      (should (= (length calls) 2))
      ;; A list invalidation keeps the show entry.
      (openstack-resource-invalidate "server")
      (should (null (openstack-resource-cached-rows "server")))
      (openstack-resource-show-cached "server" "srv-1")
      (should (= (length calls) 2))
      ;; A full invalidation drops both.
      (openstack-resource-invalidate)
      (openstack-resource-list-cached "server")
      (openstack-resource-show-cached "server" "srv-1")
      (should (= (length calls) 4)))))

(ert-deftest openstack-resource-fields-reads-the-defcustom ()
  "The field order comes from the generated defcustom when bound."
  (should (equal (openstack-resource-fields "server")
                 openstack-server-fields))
  (let ((openstack-server-fields '("name")))
    (should (equal (openstack-resource-fields "server") '("name"))))
  (should-error (openstack-resource-fields "nope")
                :type 'openstack-resource-error))

(ert-deftest openstack-resource-change-hook-runs ()
  "A changed answer runs the hook, an equal one stays silent."
  (let* ((openstack-resource--list-cache nil)
         (answer '(:row))
         (events nil)
         (openstack-resource-change-functions
          (list (lambda (event) (push event events)))))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) answer)))
      (openstack-resource-list-cached "server")
      (should (= (length events) 1))
      (should (equal (plist-get (car events) :type) "server"))
      (should (eq (plist-get (car events) :kind) 'list))
      (should (eq (plist-get (car events) :event) 'fetched))
      (should (equal (plist-get (car events) :new) '(:row)))
      ;; An equal answer signals nothing.
      (setq events nil)
      (openstack-resource-list-cached "server" t)
      (should (null events))
      ;; A different answer signals once.
      (setq answer '(:other))
      (openstack-resource-list-cached "server" t)
      (should (= (length events) 1))
      (should (equal (plist-get (car events) :old) '(:row)))
      ;; Invalidation reports the value that goes away.
      (setq events nil)
      (openstack-resource-invalidate "server")
      (should (= (length events) 1))
      (should (eq (plist-get (car events) :event) 'invalidated))
      (should (equal (plist-get (car events) :old) '(:other)))
      (should (null (plist-get (car events) :new))))))

(ert-deftest openstack-resource-change-hook-reports-show ()
  "A show fetch reports its type and ID."
  (let* ((openstack-resource--show-cache nil)
         (events nil)
         (openstack-resource-change-functions
          (list (lambda (event) (push event events)))))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) :data)))
      (openstack-resource-show-cached "server" "srv-1")
      (should (= (length events) 1))
      (should (equal (plist-get (car events) :id) "srv-1"))
      (should (eq (plist-get (car events) :kind) 'show))
      (should (eq (plist-get (car events) :new) :data)))))

(ert-deftest openstack-resource-list-fields-reads-the-defcustom ()
  "The list column order comes from the generated defcustom."
  (should (equal (openstack-resource-list-fields "server")
                 openstack-server-list-fields))
  (let ((openstack-server-list-fields '("ID")))
    (should (equal (openstack-resource-list-fields "server") '("ID"))))
  (should-error (openstack-resource-list-fields "nope")
                :type 'openstack-resource-error))

;;; Field access

(ert-deftest openstack-data-field-ignores-case ()
  "A field reads under any key case, absent or non-table data is nil."
  (let ((row (openstack-data-test--row "ID" "id-1" "Name" "web-1"
                                       "Status" "ACTIVE")))
    (should (equal (openstack-resource-field row "id") "id-1"))
    (should (equal (openstack-resource-field row "name") "web-1"))
    (should (equal (openstack-resource-field row "STATUS") "ACTIVE"))
    (should (null (openstack-resource-field row "flavor")))
    (should (null (openstack-resource-field "not a table" "id")))
    (should (null (openstack-resource-field nil "id")))))

(ert-deftest openstack-data-id-and-name ()
  "The accessors read the id and the name of a show hash table."
  (let ((data (openstack-data-test--row "id" "srv-1" "name" "web-1")))
    (should (equal (openstack-resource-id data) "srv-1"))
    (should (equal (openstack-resource-name data) "web-1")))
  (let ((row (openstack-data-test--row "ID" "id-1" "Name" "web-1")))
    (should (equal (openstack-resource-id row) "id-1"))
    (should (equal (openstack-resource-name row) "web-1"))))

;;; Conditions

(ert-deftest openstack-data-unknown-type-signals ()
  "An unknown type signals the documented condition."
  (should-error (openstack-resource-show "nope" "res-1")
                :type 'openstack-resource-error)
  (should-error (openstack-resource-list "nope")
                :type 'openstack-resource-error)
  (should-error (openstack-resource-arguments "nope")
                :type 'openstack-resource-error)
  ;; The subtype stays catchable as the package-wide parent.
  (should-error (openstack-resource-show "nope" "res-1")
                :type 'openstack-error))

(ert-deftest openstack-error-children-derive-from-the-parent ()
  "Every condition of the package derives from `openstack-error'."
  (dolist (child '(openstack-resource-error
                   openstack-cli-error openstack-cli-timeout
                   openstack-api-error openstack-api-timeout))
    (should (memq 'openstack-error (get child 'error-conditions)))))

(ert-deftest openstack-data-transport-error-passes-through ()
  "A client failure reaches the caller as its own condition."
  (cl-letf (((symbol-function 'openstack-cli-request)
             (lambda (_args)
               (signal 'openstack-cli-error (list :reason 'failed)))))
    (should-error (openstack-resource-show "server" "srv-1")
                  :type 'openstack-cli-error)
    (should-error (openstack-resource-show "server" "srv-1")
                  :type 'openstack-error)))

(ert-deftest openstack-data-loads-without-the-modes ()
  "The data layer names no mode or prompt library.
A consumer loads the data entry points alone and pays nothing for
buffers, faces or keymaps."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-data.el"))
                  (buffer-string))))
    (dolist (library '("openstack-mode" "openstack-read"
                       "openstack-resources"))
      (should-not (string-match-p
                   (format "^(require '%s)$" (regexp-quote library))
                   source)))))

(provide 'openstack-data-tests)
;;; openstack-data-tests.el ends here
