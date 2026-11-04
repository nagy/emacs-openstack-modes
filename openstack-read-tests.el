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

(ert-deftest openstack-read-rows-use-the-data-cache ()
  "The prompt rows come from the data cache, one client call."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (should (equal (length (openstack-read-rows "server")) 2))
      (should (equal (length (openstack-read-rows "server")) 2))
      (should (equal calls '(("server" "list")))))))

(ert-deftest openstack-read-refresh-drops-and-refills ()
  "A refresh drops the cached rows and asks the client again."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-refresh "server")
      (should (equal calls '(("server" "list") ("server" "list")))))))

(ert-deftest openstack-read-choices-labels ()
  "Named rows label as \"name (id)\", unnamed rows as the ID."
  (let ((openstack-resource--list-cache nil))
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
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (should (equal (openstack-read-choices "container")
                     '(("logs" . "logs") ("backups" . "backups")))))))

(ert-deftest openstack-read-id-completes ()
  "Picking a candidate returns its ID."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (should (functionp collection))
                   (should (equal (funcall collection "web" nil t)
                                  '("web-1 (srv-1)")))
                   "web-1 (srv-1)")))
        (should (equal (openstack-read-id "server") "srv-1"))))))

(ert-deftest openstack-read-id-accepts-raw-id ()
  "A typed UUID wins over the candidate list."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "srv-9")))
        (should (equal (openstack-read-id "server") "srv-9"))))))

(ert-deftest openstack-read-id-empty-answer-errors ()
  "An empty answer signals a `user-error'."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "")))
        (should-error (openstack-read-id "server") :type 'user-error)))))

(ert-deftest openstack-read-id-survives-client-failure ()
  "A failing client falls back to a plain prompt."
  (let ((openstack-resource--list-cache nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "no cloud")))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (should (functionp collection))
                 (should (null (funcall collection "" nil t)))
                 "srv-1")))
      (should (equal (openstack-read-id "server") "srv-1")))))

(ert-deftest openstack-read-type-of-id ()
  "The type lookup reads the cache before it runs the client."
  (let ((openstack-resource--list-cache nil))
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
      (should (equal (length calls)
                     (length openstack-resource-types))))))

(ert-deftest openstack-read-type-of-id-failure-is-nil ()
  "A failing client yields nil from the type lookup."
  (let ((openstack-resource--list-cache nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "no cloud"))))
      (should (null (openstack-read-type-of-id "srv-1"))))))

(ert-deftest openstack-read-name-and-ids ()
  "The name and the ID list come from the cache."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-rows "network")
      (should (equal (openstack-read-name "srv-1") "web-1"))
      (should (null (openstack-read-name "srv-2")))
      (should (equal (openstack-read-ids "server") '("srv-1" "srv-2")))
      (should (equal (openstack-read-ids) '("srv-1" "srv-2" "net-1"))))))

(ert-deftest openstack-read-refresh ()
  "A refresh drops the cached entry and fetches it again."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (openstack-read-rows "server")
      (openstack-read-rows "network")
      (openstack-read-refresh "server")
      (should (equal (car calls) '("server" "list")))
      (should (equal (length calls) 3))
      (openstack-read-refresh)
      (should (equal (length calls)
                     (+ 3 (length openstack-resource-types)))))))

(ert-deftest openstack-open-id ()
  "A known ID opens the display command of its type."
  (let ((openstack-resource--list-cache nil)
        (seen nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'openstack-network-display)
                 (lambda (id) (setq seen (cons "network" id)) :buffer)))
        (should (eq (openstack-open-id "net-1") :buffer))
        (should (equal seen '("network" . "net-1")))))))

(ert-deftest openstack-open-id-with-type ()
  "An explicit type skips the lookup."
  (let ((openstack-resource--list-cache nil)
        (seen nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args) (error "the client must not run")))
              ((symbol-function 'openstack-volume-display)
               (lambda (id) (setq seen id) :buffer)))
      (should (eq (openstack-open-id "vol-1" "volume") :buffer))
      (should (equal seen "vol-1")))))

(ert-deftest openstack-open-id-unknown ()
  "An unknown ID signals a `user-error'."
  (let ((openstack-resource--list-cache nil))
    (openstack-read-test--with-client calls
      (should-error (openstack-open-id "nope") :type 'user-error))))

(ert-deftest openstack-read-display-prompts-use-completion ()
  "Every display command completes the ID of its own type."
  (dolist (entry openstack-resource-types)
    (let* ((type (nth 0 entry))
           (mode (nth 1 entry))
           (command (nth 2 entry))
           (seen nil))
      (cl-letf (((symbol-function 'openstack-read--choices-with-rows)
                 (lambda (asked)
                   (should (equal asked type))
                   (list (cons "web-1 (res-1)"
                               (openstack-read-test--row "res-1" "web-1")))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _collection &rest _) "web-1 (res-1)"))
                ((symbol-function 'openstack-display)
                 (lambda (id mode-arg) (setq seen (cons id mode-arg)))))
        (call-interactively command)
        (should (equal seen (cons "res-1" mode)))))))

(ert-deftest openstack-read-annotation-uses-fields ()
  "The annotation holds the configured row fields that the row has."
  (let ((openstack-read-annotation-fields '("Status" "Size")))
    (let ((row (openstack-read-test--row "srv-1" "web-1")))
      (puthash "Status" "ACTIVE" row)
      (puthash "Size" "20" row)
      (should (equal (openstack-read--annotation row) "  ACTIVE, 20")))
    ;; A row without those fields gets no annotation.
    (should (null (openstack-read--annotation
                   (openstack-read-test--row "srv-2" "web-2"))))))

(ert-deftest openstack-read-choices-table-metadata ()
  "The completion table answers the metadata action.
It names the annotation function of the rows and the category of
the resource type."
  (let* ((choices (list (cons "web-1 (srv-1)"
                               (openstack-read-test--row "srv-1" "web-1"))))
         (table (openstack-read--choices-table choices "server")))
    (let* ((metadata (funcall table "" nil 'metadata))
           (entries (cdr metadata)))
      (should (eq (car metadata) 'metadata))
      (should (functionp (alist-get 'annotation-function entries)))
      (should (eq (alist-get 'category entries) 'openstack-server)))
    (should (equal (funcall table "web" nil t) '("web-1 (srv-1)")))))

(ert-deftest openstack-read-category-names-the-type ()
  "Every resource type gets its own completion category."
  (dolist (entry openstack-resource-types)
    (let ((type (nth 0 entry)))
      (should (eq (openstack-read--category type)
                  (intern (format "openstack-%s" type)))))))

(ert-deftest openstack-read-id-keeps-a-history ()
  "The ID prompt passes its own history symbol to `completing-read'."
  (let ((openstack-resource--list-cache nil)
        (history nil))
    (openstack-read-test--with-client calls
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _collection _predicate _require _initial
                                  hist)
                   (setq history hist)
                   "web-1 (srv-1)")))
        (should (equal (openstack-read-id "server") "srv-1"))
        (should (eq history 'openstack-read-id-history))))))

(ert-deftest openstack-read-id-annotation-needs-no-cache ()
  "A choice keeps its row, so the annotation reads no cache entry.
The prompt annotates every candidate of a long list, and a cache
lookup per candidate would scan every type."
  (let ((openstack-resource--list-cache nil)
        (openstack-read-annotation-fields '("Status"))
        (annotation nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args)
                 (let ((row (openstack-read-test--row "srv-1" "web-1")))
                   (puthash "Status" "ACTIVE" row)
                   (list row))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq annotation
                       (alist-get 'annotation-function
                                  (cdr (funcall collection "" nil 'metadata))))
                 "web-1 (srv-1)")))
      (should (equal (openstack-read-id "server") "srv-1"))
      ;; The annotation still answers after the cache is gone.
      (setq openstack-resource--list-cache nil)
      (should (equal (funcall annotation "web-1 (srv-1)") "  ACTIVE")))))

(ert-deftest openstack-read-id-annotates-candidates ()
  "`openstack-read-id' passes a table that annotates each candidate."
  (let ((openstack-resource--list-cache nil)
        (openstack-read-annotation-fields '("Status"))
        (metadata nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (_args)
                 (let ((row (openstack-read-test--row "srv-1" "web-1")))
                   (puthash "Status" "ACTIVE" row)
                   (list row))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq metadata (funcall collection "" nil 'metadata))
                 "web-1 (srv-1)")))
      (should (equal (openstack-read-id "server") "srv-1"))
      (let ((annotation (alist-get 'annotation-function (cdr metadata))))
        (should (equal (funcall annotation "web-1 (srv-1)")
                       "  ACTIVE"))))))

(ert-deftest openstack-read-references-finds-mentions ()
  "A cached row that names the ID in a field references it."
  (let ((server (openstack-read-test--row "srv-1" "web-1"))
        (image (openstack-read-test--row "img-1" "ubuntu")))
    (puthash "Image ID" "img-1" server)
    (let ((openstack-resource--list-cache
           (list (cons "server" (cons 0 (list server)))
                 (cons "image" (cons 0 (list image))))))
      (should (equal (openstack-read-references "img-1")
                     (list (list :type "server"
                                 :id "srv-1"
                                 :name "web-1"))))
      ;; The row of the resource itself does not count as a reference.
      (should (null (openstack-read-references "srv-1")))
      ;; An unknown ID has no referencing row.
      (should (null (openstack-read-references "nope"))))))

(provide 'openstack-read-tests)
;;; openstack-read-tests.el ends here
