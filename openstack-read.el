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
;; prompt from the rows of `RESOURCE list': every resource type in
;; `openstack-resource-types' gets an entry in a cache, refreshed
;; when it outlives `openstack-read-cache-ttl'.
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

;;; Code:

(require 'seq)
(require 'openstack-mode)

(defcustom openstack-read-cache-ttl 300
  "Seconds a cached `RESOURCE list' result stays valid.
Every completion, link and xref lookup reads the cache; an entry
older than this many seconds triggers a new client call.  Set it
to nil to keep entries forever, or run `openstack-read-refresh'
to refill them by hand."
  :type '(choice (number :tag "Seconds") (const :tag "Never expire" nil))
  :group 'openstack)

(defvar openstack-read--cache nil
  "Alist of resource type to a plist of :time and :rows.")

(defun openstack-read--entry-rows (entry)
  "Return the rows of cache ENTRY."
  (plist-get (cdr entry) :rows))

(defun openstack-read--entry-fresh-p (entry)
  "Return non-nil when cache ENTRY is still valid."
  (or (null openstack-read-cache-ttl)
      (< (- (float-time) (plist-get (cdr entry) :time))
         openstack-read-cache-ttl)))

(defun openstack-read--row-value (row names)
  "Return the value of the first key of ROW that matches NAMES.
NAMES is a list of strings.  The comparison ignores case,
because `RESOURCE list' reports title case keys while `RESOURCE
show' reports lower case ones."
  (seq-some (lambda (name)
              (seq-some (lambda (key)
                          (and (stringp key)
                               (string-equal-ignore-case key name)
                               (gethash key row)))
                        (hash-table-keys row)))
            names))

(defun openstack-read--row-id (row)
  "Return the ID field of the list ROW, or nil."
  (and (hash-table-p row)
       (openstack-read--row-value row '("ID"))))

(defun openstack-read--row-name (row)
  "Return the name field of the list ROW, or nil."
  (and (hash-table-p row)
       (openstack-read--row-value row '("Name"))))

(defun openstack-read--store (type rows)
  "Store the cache entry of resource TYPE with ROWS."
  (let ((entry (list :time (float-time) :rows rows))
        (cell (assoc type openstack-read--cache)))
    (if cell
        (setcdr cell entry)
      (push (cons type entry) openstack-read--cache))))

(defun openstack-read--fetch-rows (type)
  "Fetch and cache the list rows of resource TYPE."
  (let ((rows (openstack-cli-request (list type "list"))))
    (setq rows (and (listp rows) rows))
    (openstack-read--store type rows)
    rows))

(defun openstack-read-rows (type)
  "Return the rows of `RESOURCE list' for resource TYPE.
Read the cache while it stays within `openstack-read-cache-ttl'
and call the client otherwise."
  (let ((entry (assoc type openstack-read--cache)))
    (if (and entry (openstack-read--entry-fresh-p entry))
        (openstack-read--entry-rows entry)
      (openstack-read--fetch-rows type))))

(defun openstack-read-choices (type)
  "Return completion candidates of resource TYPE as (LABEL . ID)."
  (seq-keep (lambda (row)
              (when-let* ((id (openstack-read--row-id row)))
                (let ((name (openstack-read--row-name row)))
                  (cons (if (and (stringp name)
                                 (not (string-empty-p name)))
                            (format "%s (%s)" name id)
                          id)
                        id))))
            (openstack-read-rows type)))

;;;###autoload
(defun openstack-read-id (type &optional prompt)
  "Read the ID of an OpenStack resource of TYPE.
PROMPT defaults to a message naming TYPE.  Offer the names of the
cached `RESOURCE list' rows, so the user picks \"web-1 (UUID)\"
instead of a bare UUID.  A raw ID typed at the prompt wins, and a
client failure falls back to a plain prompt."
  (let* ((prompt (or prompt (format "OpenStack %s ID: " type)))
         (choices (condition-case err
                      (openstack-read-choices type)
                    (error
                     (message "%s" (error-message-string err))
                     nil)))
         (answer (completing-read prompt choices nil nil)))
    (or (cdr (assoc answer choices))
        (unless (string-empty-p answer) answer)
        (user-error "No OpenStack %s ID given" type))))

(defun openstack-read-ids (&optional type)
  "Return the cached resource IDs, of TYPE or of every cached type.
Order the result by `openstack-resource-types', so the IDs of a
type stay together."
  (let (ids)
    (dolist (one (if type (list type) (mapcar #'car openstack-resource-types))
                 (nreverse ids))
      (let ((entry (assoc one openstack-read--cache)))
        (dolist (row (openstack-read--entry-rows entry))
          (when-let* ((id (openstack-read--row-id row)))
            (push id ids)))))))

(defun openstack-read-name (id)
  "Return the cached name of the resource with ID, or nil.
Search the cache only, so the call never runs the client."
  (seq-some (lambda (entry)
              (seq-some (lambda (row)
                          (when (equal id (openstack-read--row-id row))
                            (let ((name (openstack-read--row-name row)))
                              (and (stringp name)
                                   (not (string-empty-p name))
                                   name))))
                        (openstack-read--entry-rows entry)))
            openstack-read--cache))

(defun openstack-read-type-of-id (id)
  "Return the resource type of the resource with ID, or nil.
Search the cache first; when no cached row matches, fetch the
list of each type in `openstack-resource-types'.  A client
failure yields nil instead of an error."
  (or (seq-some (lambda (entry)
                  (when (seq-some (lambda (row)
                                    (equal id (openstack-read--row-id row)))
                                  (openstack-read--entry-rows entry))
                    (car entry)))
                openstack-read--cache)
      (seq-some (lambda (type)
                  (when (condition-case nil
                            (seq-some
                             (lambda (row)
                               (equal id (openstack-read--row-id row)))
                             (openstack-read-rows type))
                          (error nil))
                    type))
                (mapcar #'car openstack-resource-types))))

;;;###autoload
(defun openstack-read-refresh (&optional type)
  "Refill the cache of `RESOURCE list' rows.
With TYPE, refresh only the rows of that type; otherwise refresh
every type in `openstack-resource-types'."
  (interactive)
  (let ((types (if type
                   (list type)
                 (mapcar #'car openstack-resource-types))))
    (if type
        (setq openstack-read--cache
              (seq-remove (lambda (entry) (equal type (car entry)))
                          openstack-read--cache))
      (setq openstack-read--cache nil))
    (dolist (one types)
      (openstack-read-rows one))
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
