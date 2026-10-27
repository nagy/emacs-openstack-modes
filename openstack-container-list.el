;;; openstack-container-list.el --- List OpenStack containers -*- lexical-binding: t; -*-

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

;; This package provides `openstack-container-list-mode', a mode for
;; listing containers of the Object Storage service (Swift).  It
;; derives from `openstack-list-mode', which has no resource ID and
;; lets the same refresh pipeline (asynchronous fetch,
;; self-refreshing display buffer) fetch all containers with
;; `openstack container list'.
;;
;; Entry point:
;;
;;   M-x openstack-container-list-display RET  - list all containers
;;
;; `container list' reports only the container name unless the
;; client runs with `--long', so the fetch passes the options of
;; `openstack-container-list-arguments' and the table shows the
;; byte count and the object count as well.
;;
;; A container has no UUID, so a table row takes the container name
;; as its identity: `tabulated-list-print' keeps point on the same
;; container across refreshes and re-sorts, and RET opens the
;; container's show buffer with `openstack-container-display'.

;;; Code:

(require 'openstack-list-mode)

;; Forward reference: RET on a row calls the container show command.
(declare-function openstack-container-display "openstack-container" (id))

(defgroup openstack-container-list nil
  "Display OpenStack container lists in Emacs."
  :prefix "openstack-container-list-"
  :group 'openstack)

(defcustom openstack-container-list-buffer-name "*OpenStack Containers*"
  "Name of the buffer listing OpenStack containers.
The list shows all containers, so unlike single-resource buffers
the name carries no ID suffix."
  :type 'string
  :group 'openstack-container-list)

(defcustom openstack-container-list-fields '("Name" "Bytes" "Count")
  "Columns shown first, in this order, by `openstack-container-list-mode'.
`openstack container list' reports the title-case fields Name,
Bytes and Count, and the counters only with `--long' (see
`openstack-container-list-arguments').  Columns missing from the
data are skipped; every remaining field is appended, sorted by
name."
  :type '(repeat string)
  :group 'openstack-container-list)

(defcustom openstack-container-list-arguments '("--long")
  "Extra client arguments of `openstack container list'.
The default asks for the byte count and the object count, which
`container list' leaves out otherwise.  Remove \"--long\" to list
the container names only; add \"--all\" to list more than the
client's default page of containers."
  :type '(repeat string)
  :group 'openstack-container-list)

;;; Fetcher and renderer

(defun openstack-container-list--fetch (id success-fn error-fn)
  "Fetch all containers with `openstack container list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  The list runs with the extra arguments of
`openstack-container-list-arguments'.  Call SUCCESS-FN with the
parsed JSON (a list of container hash tables), or ERROR-FN with an
`openstack-cli-error' condition.  Return the client process, so
the display machinery can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-container-list-mode'."
  (openstack-list-fetch "container" id success-fn error-fn
                        openstack-container-list-arguments))

(defun openstack-container-list--columns (rows)
  "Return the table columns of ROWS in display order.
The fields of `openstack-container-list-fields' present in the
data come first, in that order; every remaining field of ROWS
follows, sorted by name."
  (openstack-list-columns rows openstack-container-list-fields))

(defun openstack-container-list--render (_id data)
  "Insert the table of containers DATA into the current buffer.
DATA is the parsed `openstack container list' JSON, a list of hash
tables.  The columns come from
`openstack-container-list-fields', padded to the widest cell in
each column.  This is the value of `openstack-render-function' in
`openstack-container-list-mode'."
  (openstack-list-render "(no containers)" data
                         openstack-container-list-fields))

;;;###autoload
(defun openstack-container-list-display ()
  "Display all OpenStack containers in a dedicated table buffer.
The buffer is named by `openstack-container-list-buffer-name' and
put into `openstack-container-list-mode', which fetches the
containers with `openstack container list' and renders them as a
table.  The fetch is asynchronous: the buffer fills in when the
client delivers data, and keeps itself up to date afterwards."
  (interactive)
  (let ((buf (get-buffer-create openstack-container-list-buffer-name))
        (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-container-list-mode)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(define-derived-mode openstack-container-list-mode openstack-list-mode
  "OpenStack Containers"
  "Major mode for listing OpenStack object storage containers.
Derives from `openstack-list-mode', a `tabulated-list-mode' for
OpenStack collections, so the table has a clickable column header,
per-column sorting and column resizing.  The buffer has no
resource ID and the ID commands do not apply.  A row takes the
container name as its identity, because a Swift container has no
UUID.  The containers are fetched with `openstack container list'
through the asynchronous CLI layer; RET or `mouse-2' on a row
opens the container's show buffer
\(`openstack-container-display')."
  (setq-local openstack-fetch-function #'openstack-container-list--fetch)
  (setq-local openstack-render-function #'openstack-container-list--render)
  (setq-local openstack-id-prefix "project/containers")
  (setq-local openstack-list--noun "containers")
  (setq-local openstack-show-command #'openstack-container-display))

(provide 'openstack-container-list)
;;; openstack-container-list.el ends here
