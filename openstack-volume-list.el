;;; openstack-volume-list.el --- List OpenStack volumes -*- lexical-binding: t; -*-

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

;; This package provides `openstack-volume-list-mode', a mode for
;; listing OpenStack block storage volumes.  It is a collection view
;; like `openstack-server-list-mode': there is no resource ID, so it
;; sets `openstack-collection' and lets the same refresh pipeline
;; (asynchronous fetch, self-refreshing display buffer) fetch all
;; volumes with `openstack volume list'.
;;
;; Entry point:
;;
;;   M-x openstack-volume-list-display RET  - list all volumes
;;
;; The rows render as a padded table.  The columns of
;; `openstack-volume-list-fields' come first, in that order; all
;; remaining fields follow, sorted by name.  The buffer refreshes
;; itself through `auto-revert-mode' like every other
;; `openstack-mode' display buffer.

;;; Code:

(require 'openstack-mode)

(defgroup openstack-volume-list nil
  "Display OpenStack volume lists in Emacs."
  :prefix "openstack-volume-list-"
  :group 'openstack)

(defcustom openstack-volume-list-buffer-name "*OpenStack Volumes*"
  "Name of the buffer listing OpenStack volumes.
The list shows all volumes, so unlike single-resource buffers
the name carries no ID suffix."
  :type 'string
  :group 'openstack-volume-list)

(defcustom openstack-volume-list-fields
  '("ID" "Name" "Status" "Size" "Volume Type" "Attached to")
  "Columns shown first, in this order, by `openstack-volume-list-mode'.
`openstack volume list' reports field names in title case (ID,
Name, Status, ...).  Columns missing from the data are skipped;
every remaining field is appended, sorted by name."
  :type '(repeat string)
  :group 'openstack-volume-list)

;;; Fetcher and renderer

(defun openstack-volume-list--fetch (id success-fn error-fn)
  "Fetch all volumes with `openstack volume list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  Call SUCCESS-FN with the parsed JSON (a list of
volume hash tables), or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-volume-list-mode'."
  (openstack-list-fetch "volume" id success-fn error-fn))

(defun openstack-volume-list--columns (rows)
  "Return the table columns of ROWS in display order.
The fields of `openstack-volume-list-fields' present in the data
come first, in that order; every remaining field of ROWS follows,
sorted by name."
  (openstack-list-columns rows openstack-volume-list-fields))

(defun openstack-volume-list--render (_id data)
  "Insert the table of volumes DATA into the current buffer.
DATA is the parsed `openstack volume list' JSON, a list of hash
tables.  The columns come from `openstack-volume-list-fields',
padded to the widest cell in each column.  This is the value of
`openstack-render-function' in `openstack-volume-list-mode'."
  (openstack-list-render "(no volumes)" data
                         openstack-volume-list-fields))

;;;###autoload
(defun openstack-volume-list-display ()
  "Display all OpenStack volumes in a dedicated table buffer.
The buffer is named by `openstack-volume-list-buffer-name' and
put into `openstack-volume-list-mode', which fetches the volumes
with `openstack volume list' and renders them as a table.  The
fetch is asynchronous: the buffer fills in when the client
delivers data, and keeps itself up to date afterwards."
  (interactive)
  (let ((buf (get-buffer-create openstack-volume-list-buffer-name))
        (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-volume-list-mode)
      (setq-local openstack-collection t)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(define-derived-mode openstack-volume-list-mode openstack-mode
  "OpenStack Volumes"
  "Major mode for listing OpenStack volumes.
Derives from `openstack-mode' as a collection view: the buffer
has no resource ID (`openstack-collection' is set) and the
ID commands do not apply.  The volumes are fetched with
`openstack volume list' through the asynchronous CLI layer and
rendered as a padded table; RET or `mouse-2' on a row opens the
volume's show buffer (`openstack-volume-display')."
  (setq-local openstack-fetch-function #'openstack-volume-list--fetch)
  (setq-local openstack-render-function #'openstack-volume-list--render)
  (setq-local openstack-id-prefix "volumes")
  ;; RET on a row opens the volume's show buffer.
  (setq-local openstack-show-command #'openstack-volume-display))

(provide 'openstack-volume-list)
;;; openstack-volume-list.el ends here
