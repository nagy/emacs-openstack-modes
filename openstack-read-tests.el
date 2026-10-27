;;; openstack-read-tests.el --- Tests for openstack-read -*- lexical-binding: t; -*-

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
(require 'openstack-read)
(require 'openstack-resources)

(defun openstack-read-test--row (id name)
  "Return a list row hash table with ID and NAME."
  (let ((row (make-hash-table :test 'equal)))
    (puthash "ID" id row)
    (puthash "Name" name row)
    row))

(defun openstack-read-test--named-row (name)
  "Return a list row hash table with NAME and no ID field."
  (let ((row (make-hash-table :test 'equal)))
    (puthash "Name" name row)
    row))

(defmacro openstack-read-test--with-client (calls &rest body)
  "Run BODY with a stubbed CLI client recording calls in CALLS."
  (declare (indent 1))
  `(let ((,calls nil))
     (cl-letf (((symbol-function 'openstack-cli-request)
                (lambda (args)
                  (push args ,calls)
                  (pcase (car args)
                    ("server"
                     (list (openstack-read-test--row "srv-1" "web-1")
                           (openstack-read-test--row "srv-2" "")))
                    ("volume"
                     (list (openstack-read-test--row "vol-1" "data-1")))
                    ("network"
                     (list (openstack-read-test--row "net-1" "provider")))
                    ("container"
                     (list (openstack-read-test--named-row "logs")
                           (openstack-read-test--named-row "backups")))
                    (_ nil)))))
       ,@body)))

;;; Tests

(ert-deftest openstack-read-rows-cache ()
  "The first lookup fetches, the second reads the cache."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (should (equal (length (openstack-read-rows "server")) 2))
      (should (equal (length (openstack-read-rows "server")) 2))
      (should (equal calls '(("server" "list")))))))

(ert-deftest openstack-read-rows-expire ()
  "An entry older than the TTL triggers a new client call."
  (let ((openstack-read--cache nil)
        (openstack-read-cache-ttl 0))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-rows "server")
      (should (equal calls '(("server" "list") ("server" "list")))))))

(ert-deftest openstack-read-rows-keep-forever ()
  "A nil TTL keeps entries even when the clock moves on."
  (let ((openstack-read--cache nil)
        (openstack-read-cache-ttl nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (cl-letf (((symbol-function 'float-time) (lambda () 1e9)))
        (openstack-read-rows "server"))
      (should (equal calls '(("server" "list")))))))

(ert-deftest openstack-read-choices-labels ()
  "Named rows label as \"name (id)\", unnamed rows as the ID."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (should (equal (openstack-read-choices "server")
                     '(("web-1 (srv-1)" . "srv-1")
                       ("srv-2" . "srv-2")))))))

(ert-deftest openstack-read-row-value-ignores-case ()
  "The ID and name lookup accepts title case and lower case keys."
  (let ((row (make-hash-table :test 'equal)))
    (puthash "id" "lower-1" row)
    (puthash "name" "lower-name" row)
    (should (equal (openstack-read--row-id row) "lower-1"))
    (should (equal (openstack-read--row-name row) "lower-name")))
  (should (null (openstack-read--row-id "not a row"))))

(ert-deftest openstack-read-row-id-falls-back-to-name ()
  "A row without an ID field takes its name as the identifier.
A Swift container has a name and no UUID."
  (let ((row (make-hash-table :test 'equal)))
    (puthash "Name" "logs" row)
    (should (equal (openstack-read--row-id row) "logs")))
  (let ((row (make-hash-table :test 'equal)))
    (puthash "Name" "" row)
    (should (null (openstack-read--row-id row)))))

(ert-deftest openstack-read-choices-name-only-rows ()
  "A name-only row labels without a duplicate."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (should (equal (openstack-read-choices "container")
                     '(("logs" . "logs") ("backups" . "backups")))))))

(ert-deftest openstack-read-id-completes ()
  "Picking a candidate returns its ID."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (should (equal collection
                                  '(("web-1 (srv-1)" . "srv-1")
                                    ("srv-2" . "srv-2"))))
                   "web-1 (srv-1)")))
        (should (equal (openstack-read-id "server") "srv-1"))))))

(ert-deftest openstack-read-id-accepts-raw-id ()
  "A typed UUID wins over the candidate list."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "srv-9")))
        (should (equal (openstack-read-id "server") "srv-9"))))))

(ert-deftest openstack-read-id-empty-answer-errors ()
  "An empty answer signals a `user-error'."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "")))
        (should-error (openstack-read-id "server") :type 'user-error)))))

(ert-deftest openstack-read-id-survives-client-failure ()
  "A failing client falls back to a plain prompt."
  (let ((openstack-read--cache nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "no cloud")))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (should (null collection))
                 "srv-1")))
      (should (equal (openstack-read-id "server") "srv-1")))))

(ert-deftest openstack-read-type-of-id ()
  "The type lookup reads the cache before it runs the client."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (should (equal (openstack-read-type-of-id "srv-1") "server"))
      ;; The table order stops at the first type that holds the ID.
      (should (equal calls '(("server" "list"))))
      (should (equal (openstack-read-type-of-id "net-1") "network"))
      (should (equal (length calls) 4))
      ;; A cached hit costs no client call.
      (let ((before (length calls)))
        (should (equal (openstack-read-type-of-id "net-1") "network"))
        (should (equal (length calls) before)))
      (should (null (openstack-read-type-of-id "nope")))
      (should (equal (length calls) 5)))))

(ert-deftest openstack-read-type-of-id-failure-is-nil ()
  "A failing client yields nil from the type lookup."
  (let ((openstack-read--cache nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "no cloud"))))
      (should (null (openstack-read-type-of-id "srv-1"))))))

(ert-deftest openstack-read-name-and-ids ()
  "The name and the ID list come from the cache."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-rows "network")
      (should (equal (openstack-read-name "srv-1") "web-1"))
      (should (null (openstack-read-name "srv-2")))
      (should (equal (openstack-read-ids "server") '("srv-1" "srv-2")))
      (should (equal (openstack-read-ids) '("srv-1" "srv-2" "net-1"))))))

(ert-deftest openstack-read-refresh ()
  "A refresh drops the cached entry and fetches it again."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-rows "network")
      (openstack-read-refresh "server")
      (should (equal (car calls) '("server" "list")))
      (should (equal (length calls) 3))
      (openstack-read-refresh)
      (should (equal (length calls) 8)))))

(ert-deftest openstack-open-id ()
  "A known ID opens the display command of its type."
  (let ((openstack-read--cache nil)
        (seen nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'openstack-network-display)
                 (lambda (id) (setq seen (cons "network" id)) :buffer)))
        (should (eq (openstack-open-id "net-1") :buffer))
        (should (equal seen '("network" . "net-1")))))))

(ert-deftest openstack-open-id-with-type ()
  "An explicit type skips the lookup."
  (let ((openstack-read--cache nil)
        (seen nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "the client must not run")))
              ((symbol-function 'openstack-volume-display)
               (lambda (id) (setq seen id) :buffer)))
      (should (eq (openstack-open-id "vol-1" "volume") :buffer))
      (should (equal seen "vol-1")))))

(ert-deftest openstack-open-id-unknown ()
  "An unknown ID signals a `user-error'."
  (let ((openstack-read--cache nil))
    (openstack-read-test--with-client calls
      (should-error (openstack-open-id "nope") :type 'user-error))))

(ert-deftest openstack-read-display-prompts-use-completion ()
  "Every display command completes the ID of its own type."
  (dolist (entry openstack-resource-types)
    (let* ((type (nth 0 entry))
           (mode (nth 1 entry))
           (command (nth 2 entry))
           (seen nil))
      (cl-letf (((symbol-function 'openstack-read-choices)
                 (lambda (asked)
                   (should (equal asked type))
                   '(("web-1 (res-1)" . "res-1"))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "web-1 (res-1)"))
                ((symbol-function 'openstack-display)
                 (lambda (id mode-arg) (setq seen (cons id mode-arg)))))
        (call-interactively command)
        (should (equal seen (cons "res-1" mode)))))))

(provide 'openstack-read-tests)
;;; openstack-read-tests.el ends here
