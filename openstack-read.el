;;; openstack-read.el --- Read OpenStack resource IDs with completion -*- lexical-binding: t; -*-

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

;; Resource IDs are UUIDs, and the display commands of the modes
;; asked for one with a bare prompt.  This library completes the
;; prompt from the rows of `RESOURCE list', which
;; `openstack-data.el' caches for every caller.  This file owns the
;; prompts and the lookups, not the cache.
;;
;; Two more lookups build on the same cache:
;;
;;   openstack-read-type-of-id  - the resource type of an ID
;;   openstack-read-name        - the name of an ID
;;
;; They let a link, an xref jump or a prompt resolve an ID that the
;; user did not choose from a list.
;;
;; Entry points:
;;
;;   openstack-read-id       - read an ID of a known type
;;   openstack-open-id       - display any resource by ID
;;   openstack-read-refresh  - refill the cache
;;
;; Every prompt announces a completion category per resource type
;; and one annotation function, so a completion UI that reads the
;; metadata of the completion table shows the state of a resource
;; beside its ID, and `completion-category-overrides' treats one
;; kind of resource as one kind of object.  The answers go to
;; `openstack-read-id-history'.

;;; Code:

(require 'seq)
(require 'openstack-mode)

(defcustom openstack-read-annotation-fields '("Status" "Size" "Flavor")
  "List row fields that annotate an ID in the completion prompt.
The prompt shows the values of these fields, in this order, next
to the candidate that names the row.  A field that the row does
not hold stays out of the annotation."
  :type '(repeat string)
  :group 'openstack)

(defvar openstack-read-id-history nil
  "History of the OpenStack ID prompts.
Every prompt of `openstack-read-id' shares it, so `M-p' recalls
the ID that the user opened last.")

(defun openstack-read--row-value (row names)
  "Return the value of the first key of ROW that matches NAMES.
NAMES is a list of strings.  The comparison ignores case,
because `RESOURCE list' reports title case keys while `RESOURCE
show' reports lower case ones."
  (declare (side-effect-free t))
  (seq-some (lambda (name)
              (seq-some (lambda (key)
                          (and (stringp key)
                               (string-equal-ignore-case key name)
                               (gethash key row)))
                        (hash-table-keys row)))
            names))

(defun openstack-read--row-id (row)
  "Return the identifier of the list ROW, or nil.
Read the ID field of ROW; a resource without one, such as a Swift
container, uses its Name field."
  (declare (side-effect-free t))
  (when (hash-table-p row)
    (let ((id (openstack-read--row-value row '("ID")))
          (name (openstack-read--row-value row '("Name"))))
      (or (and (stringp id) (not (string-empty-p id)) id)
          (and (stringp name) (not (string-empty-p name)) name)))))

(defun openstack-read--row-name (row)
  "Return the name field of the list ROW, or nil."
  (declare (side-effect-free t))
  (and (hash-table-p row)
       (openstack-read--row-value row '("Name"))))

(defun openstack-read-rows (type)
  "Return the rows of `RESOURCE list' for resource TYPE.
Read the cache of `openstack-data.el' while it stays within
`openstack-resource-cache-ttl' and call the client otherwise."
  (openstack-resource-list-cached type))

(defun openstack-read--choices-with-rows (type)
  "Return completion candidates of resource TYPE as (LABEL . ROW).
The label names the row, and the value keeps the row itself, so
an annotation reads the row that the user sees and no cache
lookup runs per candidate."
  (declare (side-effect-free t))
  (seq-keep (lambda (row)
              (when-let* ((id (openstack-read--row-id row)))
                (let ((name (openstack-read--row-name row)))
                  (cons (if (and (stringp name)
                                 (not (string-empty-p name))
                                 (not (equal name id)))
                            (format "%s (%s)" name id)
                          id)
                        row))))
            (openstack-read-rows type)))

(defun openstack-read-choices (type)
  "Return completion candidates of resource TYPE as (LABEL . ID)."
  (declare (side-effect-free t))
  (mapcar (lambda (choice)
            (cons (car choice)
                  (openstack-read--row-id (cdr choice))))
          (openstack-read--choices-with-rows type)))

(defun openstack-read--category (type)
  "Return the completion category symbol of resource TYPE.
Every type gets its own category, so `completion-category-overrides'
and a completion UI that reads categories treat the servers, the
volumes and the images as different kinds of object."
  (declare (pure t) (side-effect-free t))
  (intern (format "openstack-%s" type)))

(defun openstack-read--annotation (row)
  "Return the annotation string of list ROW, or nil.
The string holds the values of `openstack-read-annotation-fields'
that ROW provides, separated by a comma."
  (declare (side-effect-free t))
  (when (hash-table-p row)
    (let ((values
           (seq-keep
            (lambda (field)
              (let ((value (openstack-read--row-value row (list field))))
                (and (stringp value)
                     (not (string-empty-p value))
                     value)))
            openstack-read-annotation-fields)))
      (when values
        (concat "  " (mapconcat #'identity values ", "))))))

(defun openstack-read--annotation-function (choices)
  "Return a completion annotation function over CHOICES.
CHOICES is a list of (LABEL . ROW) pairs, as
`openstack-read--choices-with-rows' returns.  The function
annotates a candidate with the fields of the row that the choice
keeps."
  (lambda (candidate)
    (when-let* ((row (cdr (assoc candidate choices))))
      (openstack-read--annotation row))))

(defun openstack-read--choices-table (choices type)
  "Return a completion table over CHOICES of resource TYPE.
CHOICES is a list of (LABEL . ROW) pairs.  The table answers the
`metadata' action with an `annotation-function', so every
completion UI shows the state of a resource before the user
chooses it, and with the category of TYPE, so a UI sorts and
annotates one kind of resource as one kind."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata (category . ,(openstack-read--category type))
                   (annotation-function
                    . ,(openstack-read--annotation-function choices)))
      (complete-with-action action choices string predicate))))

;;;###autoload
(defun openstack-read-id (type &optional prompt)
  "Read the ID of an OpenStack resource of TYPE.
PROMPT defaults to a message naming TYPE.  Offer the names of the
cached `RESOURCE list' rows, so the user picks \"web-1 (UUID)\"
instead of a bare UUID.  Annotate each candidate with the fields
of `openstack-read-annotation-fields', and announce the category
`openstack-read--category' names for TYPE, so a completion UI
sorts and annotates the candidates of one type together.  The
prompt keeps its answers in `openstack-read-id-history'.  A raw
ID typed at the prompt wins, and a client failure falls back to a
plain prompt."
  (let* ((prompt (or prompt (format "OpenStack %s ID: " type)))
         (choices (condition-case err
                      (openstack-read--choices-with-rows type)
                    (error
                     (message "%s" (error-message-string err))
                     nil)))
         (answer (completing-read
                  prompt
                  (openstack-read--choices-table choices type)
                  nil nil nil
                  'openstack-read-id-history)))
    (or (when-let* ((row (cdr (assoc answer choices))))
          (openstack-read--row-id row))
        (unless (string-empty-p answer) answer)
        (user-error "No OpenStack %s ID given" type))))

(defun openstack-read-ids (&optional type)
  "Return the cached resource IDs, of TYPE or of every cached type.
Order the result by `openstack-resource-types', so the IDs of a
type stay together."
  (declare (side-effect-free t))
  (let (ids)
    (dolist (one (if type (list type) (mapcar #'car openstack-resource-types))
                 (nreverse ids))
      (dolist (row (openstack-resource-cached-rows one))
        (when-let* ((id (openstack-read--row-id row)))
          (push id ids))))))

(defun openstack-read-name (id)
  "Return the cached name of the resource with ID, or nil.
Search the cache only, so the call never runs the client."
  (declare (side-effect-free t))
  (seq-some (lambda (one)
              (seq-some (lambda (row)
                          (when (equal id (openstack-read--row-id row))
                            (let ((name (openstack-read--row-name row)))
                              (and (stringp name)
                                   (not (string-empty-p name))
                                   name))))
                        (openstack-resource-cached-rows one)))
            (mapcar #'car openstack-resource-types)))

(defun openstack-read-type-of-id (id)
  "Return the resource type of the resource with ID, or nil.
Search the cache first; when no cached row matches, fetch the
list of each type in `openstack-resource-types'.  A client
failure yields nil instead of an error."
  (or (seq-some (lambda (type)
                  (when (seq-some (lambda (row)
                                    (equal id (openstack-read--row-id row)))
                                  (openstack-resource-cached-rows type))
                    type))
                (mapcar #'car openstack-resource-types))
      (seq-some (lambda (type)
                  (when (condition-case nil
                            (seq-some
                             (lambda (row)
                               (equal id (openstack-read--row-id row)))
                             (openstack-read-rows type))
                          (error nil))
                    type))
                (mapcar #'car openstack-resource-types))))

(defun openstack-read--row-values (row)
  "Return the string field values of list ROW."
  (declare (side-effect-free t))
  (when (hash-table-p row)
    (seq-keep (lambda (key)
                (let ((value (gethash key row)))
                  (and (stringp value) value)))
              (hash-table-keys row))))

(defun openstack-read-references (id)
  "Return the cached resources that mention ID in one of their fields.
Return a list of plists with :type, :id and :name, one per row.
Read the cache only: no client call.  A `RESOURCE list' row
holds an ID only for a related resource, such as the image of a
server or the network of a port."
  (declare (side-effect-free t))
  (let (found)
    (dolist (one (mapcar #'car openstack-resource-types) (nreverse found))
      (dolist (row (openstack-resource-cached-rows one))
        (let ((row-id (openstack-read--row-id row)))
          (when (and row-id
                     (not (equal row-id id))
                     (seq-some (lambda (value) (equal value id))
                               (openstack-read--row-values row)))
            (push (list :type one
                        :id row-id
                        :name (openstack-read--row-name row))
                  found)))))))

;;;###autoload
(defun openstack-read-refresh (&optional type)
  "Refill the cache of `RESOURCE list' rows.
With TYPE, refresh only the rows of that type; otherwise refresh
every type in `openstack-resource-types'."
  (interactive)
  (let ((types (if type
                   (list type)
                 (mapcar #'car openstack-resource-types))))
    (openstack-resource-invalidate type)
    (dolist (one types)
      (openstack-resource-list-cached one))
    (message "Refreshed the OpenStack cache of %s"
             (mapconcat #'identity types ", "))))

;;;###autoload
(defun openstack-open-id (id &optional type)
  "Display the OpenStack resource with ID.
TYPE names the resource type of ID.  Without TYPE, resolve it
through `openstack-read-type-of-id', which may run the client.
Interactive use prompts for the type and then for the ID."
  (interactive
   (let* ((type (completing-read "OpenStack resource type: "
                                 (mapcar #'car openstack-resource-types)
                                 nil t))
          (id (openstack-read-id type)))
     (list id type)))
  (let ((type (or type (openstack-read-type-of-id id))))
    (unless type
      (user-error "Unknown OpenStack resource ID: %s" id))
    (funcall (nth 2 (openstack-resource-type type)) id)))

(provide 'openstack-read)
;;; openstack-read.el ends here
