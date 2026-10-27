;;; openstack-network-list.el --- List OpenStack networks -*- lexical-binding: t; -*-

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

;; This package provides `openstack-network-list-mode', a mode for
;; listing OpenStack networks.  It derives from
;; `openstack-list-mode', which has no resource ID and lets the same
;; refresh pipeline (asynchronous fetch, self-refreshing display
;; buffer) fetch all
;; networks with `openstack network list'.
;;
;; Entry point:
;;
;;   M-x openstack-network-list-display RET  - list all networks
;;
;; The rows render as a `tabulated-list-mode' table.  The columns of
;; `openstack-network-list-fields' come first, in that order; all
;; remaining fields follow, sorted by name.  The buffer refreshes
;; itself through `auto-revert-mode' like every other
;; `openstack-mode' display buffer.

;;; Code:

(require 'openstack-list-mode)

;; Forward reference: RET on a row calls the network show command.
(declare-function openstack-network-display "openstack-network" (id))

(defgroup openstack-network-list nil
  "Display OpenStack network lists in Emacs."
  :prefix "openstack-network-list-"
  :group 'openstack)

(defcustom openstack-network-list-buffer-name "*OpenStack Networks*"
  "Name of the buffer listing OpenStack networks.
The list shows all networks, so unlike single-resource buffers
the name carries no ID suffix."
  :type 'string
  :group 'openstack-network-list)

(defcustom openstack-network-list-fields
  '("ID" "Name" "Status" "Subnets" "Shared" "Router External")
  "Columns shown first, in this order, by `openstack-network-list-mode'.
Columns missing from the data are skipped; every remaining field
is appended, sorted by name."
  :type '(repeat string)
  :group 'openstack-network-list)

;;; Fetcher and renderer

(defun openstack-network-list--fetch (id success-fn error-fn)
  "Fetch all networks with `openstack network list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  Call SUCCESS-FN with the parsed JSON (a list of
network hash tables), or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-network-list-mode'."
  (openstack-list-fetch "network" id success-fn error-fn))

(defun openstack-network-list--columns (rows)
  "Return the table columns of ROWS in display order.
The fields of `openstack-network-list-fields' present in the data
come first, in that order; every remaining field of ROWS follows,
sorted by name."
  (openstack-list-columns rows openstack-network-list-fields))

(defun openstack-network-list--render (_id data)
  "Insert the table of networks DATA into the current buffer.
DATA is the parsed `openstack network list' JSON, a list of hash
tables.  The columns come from `openstack-network-list-fields',
padded to the widest cell in each column.  This is the value of
`openstack-render-function' in `openstack-network-list-mode'."
  (openstack-list-render "(no networks)" data
                         openstack-network-list-fields))

;;;###autoload
(defun openstack-network-list-display ()
  "Display all OpenStack networks in a dedicated table buffer.
The buffer is named by `openstack-network-list-buffer-name' and
put into `openstack-network-list-mode', which fetches the
networks with `openstack network list' and renders them as a
table.  The fetch is asynchronous: the buffer fills in when the
client delivers data, and keeps itself up to date afterwards."
  (interactive)
  (let ((buf (get-buffer-create openstack-network-list-buffer-name))
        (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-network-list-mode)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(define-derived-mode openstack-network-list-mode openstack-list-mode
  "OpenStack Networks"
  "Major mode for listing OpenStack networks.
Derives from `openstack-list-mode', a `tabulated-list-mode'
for OpenStack collections, so the table has a clickable column
header, per-column sorting and column resizing.  The buffer has
no resource ID and the ID commands do not apply.  The networks
are fetched with `openstack network list' through the
asynchronous CLI layer; RET or `mouse-2' on a row opens the
network's show buffer (`openstack-network-display')."
  (setq-local openstack-fetch-function #'openstack-network-list--fetch)
  (setq-local openstack-render-function #'openstack-network-list--render)
  (setq-local openstack-id-prefix "project/networks")
  ;; RET on a row opens the network's show buffer.
  (setq-local openstack-list--noun "networks")
  ;; The row command `w' opens the network detail page.
  (setq-local openstack-url-suffix "/detail")
  (setq-local openstack-show-command #'openstack-network-display))

(provide 'openstack-network-list)
;;; openstack-network-list.el ends here
