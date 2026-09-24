;;; openstack-server.el --- Display OpenStack servers -*- lexical-binding: t; -*-

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

;; This package provides `openstack-server-mode', the first
;; resource-specific mode derived from `openstack-mode'.  It
;; fetches a server with `openstack server show' through the
;; asynchronous CLI layer (see openstack-cli.el) and renders the
;; server's fields, inheriting the ID handling, refresh pipeline
;; and bookmark support of the base mode.
;;
;; Entry point:
;;
;;   M-x openstack-server-display RET  - display a server by ID
;;
;; The display buffer fills in asynchronously, refreshes itself
;; (see `openstack-refresh-interval') and renders the fields of
;; `openstack-server-fields' first, in that order; all remaining
;; fields follow, sorted by name.

;;; Code:

(require 'json)
(require 'openstack-mode)

(defcustom openstack-server-buffer-name "*OpenStack Server*"
  "Name prefix of the buffer used to display an OpenStack server.
`openstack-server-display' appends the server ID, so each server
gets its own buffer; the same ID always reuses its buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-server-fields
  '("name" "status" "host_status" "vm_state"
    "OS-EXT-AZ:availability_zone" "project_id"
    "flavor" "addresses" "image"
    "created_at" "updated_at")
  "Fields shown first, in this order, by `openstack-server-mode'.
Fields missing from the server data are skipped; every other
field of `openstack server show' is rendered after them, sorted
by name."
  :type '(repeat string)
  :group 'openstack)

;;; Fetcher and renderer

(defun openstack-server--fetch (id success-fn error-fn)
  "Fetch the data of server ID with `openstack-cli-async-request'.
Run `openstack server show ID' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-server-mode'."
  (openstack-cli-async-request
   (list "server" "show" id)
   :success-fn success-fn
   :error-fn error-fn))

(defun openstack-server--format-value (value)
  "Return the display text of one server field VALUE.
Strings and numbers are shown as they are; booleans, lists,
hash tables and anything else fall back to their JSON encoding."
  (cond
   ((null value) "-")
   ((stringp value) (if (string-empty-p value) "-" value))
   ((numberp value) (number-to-string value))
   ((eq value t) "true")
   (t (json-encode value))))

(defun openstack-server--insert-field (field value)
  "Insert one FIELD of a server with its VALUE into the buffer."
  (insert (propertize field 'face 'font-lock-variable-name-face)
          ": " (openstack-server--format-value value) "\n"))

(defun openstack-server--render (id data)
  "Insert the display of server ID with DATA into the current buffer.
DATA is the parsed `openstack server show' JSON.  The fields of
`openstack-server-fields' that the server data contains come
first, in that order; every remaining field follows, sorted by
name.  This is the value of `openstack-render-function' in
`openstack-server-mode'."
  (insert (format "Server: %s\nID: %s\n\n"
                  (or (and (hash-table-p data) (gethash "name" data))
                      id)
                  id))
  (when (hash-table-p data)
    (let ((unshown (make-hash-table :test #'equal)))
      (maphash (lambda (key _value) (puthash key t unshown)) data)
      (dolist (field openstack-server-fields)
        (remhash field unshown)
        (let ((value (gethash field data)))
          (when value
            (openstack-server--insert-field field value))))
      (let ((fields nil))
        (maphash (lambda (key _value) (push key fields)) unshown)
        (dolist (field (sort fields #'string<))
          (openstack-server--insert-field
           field (gethash field data)))))))

;;;###autoload
(defun openstack-server-display (id)
  "Display the OpenStack server with ID in a dedicated buffer.
The buffer is named by `openstack-server-buffer-name' and put
into `openstack-server-mode', which fetches the server with
`openstack server show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
  (interactive "sOpenStack server ID: ")
  (let ((openstack-buffer-name openstack-server-buffer-name))
    (openstack-display id #'openstack-server-mode)))

;;;###autoload
(define-derived-mode openstack-server-mode openstack-mode
  "OpenStack Server"
  "Major mode for displaying an OpenStack server resource.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  Fetching and rendering
are set buffer-locally to the server-specific fetcher and
renderer; they can be overridden globally like any other
`openstack-mode' buffer."
  (setq-local openstack-fetch-function #'openstack-server--fetch)
  (setq-local openstack-render-function #'openstack-server--render)
  (setq-local openstack-id-prefix "compute"))

(provide 'openstack-server)
;;; openstack-server.el ends here
