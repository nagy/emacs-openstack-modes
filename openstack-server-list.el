;;; openstack-server-list.el --- List OpenStack servers -*- lexical-binding: t; -*-

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

;; This package provides `openstack-server-list-mode', a mode for
;; listing OpenStack servers.  Unlike the single-resource modes it
;; displays a collection: there is no resource ID, so it sets
;; `openstack-collection' and lets the same refresh pipeline
;; (asynchronous fetch, self-refreshing display buffer) fetch all
;; servers with `openstack server list'.
;;
;; Entry point:
;;
;;   M-x openstack-server-list-display RET  - list all servers
;;
;; The rows render as a padded table.  The columns of
;; `openstack-server-list-fields' come first, in that order; all
;; remaining fields follow, sorted by name.  The buffer refreshes
;; itself through `auto-revert-mode' like every other
;; `openstack-mode' display buffer.

;;; Code:

(require 'openstack-mode)

(defgroup openstack-server-list nil
  "Display OpenStack server lists in Emacs."
  :prefix "openstack-server-list-"
  :group 'openstack)

(defcustom openstack-server-list-buffer-name "*OpenStack Servers*"
  "Name of the buffer listing OpenStack servers.
The list shows all servers, so unlike single-resource buffers
the name carries no ID suffix."
  :type 'string
  :group 'openstack-server-list)

(defcustom openstack-server-list-fields
  '("ID" "Name" "Status" "Host" "Task State"
    "Networks" "Image Name" "Flavor")
  "Columns shown first, in this order, by `openstack-server-list-mode'.
`openstack server list' reports field names in title case (ID,
Name, Status, ...).  Columns missing from the data are skipped;
every remaining field is appended, sorted by name."
  :type '(repeat string)
  :group 'openstack-server-list)

;;; Fetcher and renderer

(defun openstack-server-list--fetch (id success-fn error-fn)
  "Fetch all servers with `openstack server list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  Call SUCCESS-FN with the parsed JSON (a list of
server hash tables), or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-server-list-mode'."
  (openstack-list-fetch "server" id success-fn error-fn))

(defun openstack-server-list--columns (rows)
  "Return the table columns of ROWS in display order.
The fields of `openstack-server-list-fields' present in the data
come first, in that order; every remaining field of ROWS follows,
sorted by name."
  (openstack-list-columns rows openstack-server-list-fields))

(defun openstack-server-list--render (_id data)
  "Insert the table of servers DATA into the current buffer.
DATA is the parsed `openstack server list' JSON, a list of hash
tables.  The columns come from `openstack-server-list--columns',
padded to the widest cell in each column.  This is the value of
`openstack-render-function' in `openstack-server-list-mode'."
  (openstack-list-render "(no servers)" data
                         openstack-server-list-fields))

;;;###autoload
(defun openstack-server-list-display ()
  "Display all OpenStack servers in a dedicated table buffer.
The buffer is named by `openstack-server-list-buffer-name' and
put into `openstack-server-list-mode', which fetches the servers
with `openstack server list' and renders them as a table.  The
fetch is asynchronous: the buffer fills in when the client
delivers data, and keeps itself up to date afterwards."
  (interactive)
  (let ((buf (get-buffer-create openstack-server-list-buffer-name))
        (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-server-list-mode)
      (setq-local openstack-collection t)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(define-derived-mode openstack-server-list-mode openstack-mode
  "OpenStack Servers"
  "Major mode for listing OpenStack servers.
Derives from `openstack-mode' as a collection view: the buffer
has no resource ID (`openstack-collection' is set) and the
ID commands do not apply.  The servers are fetched with
`openstack server list' through the asynchronous CLI layer and
rendered as a padded table; RET or `mouse-2' on a row opens the
server's show buffer (`openstack-server-display')."
  (setq-local openstack-fetch-function #'openstack-server-list--fetch)
  (setq-local openstack-render-function #'openstack-server-list--render)
  (setq-local openstack-id-prefix "compute")
  ;; RET on a row opens the server's show buffer.
  (setq-local openstack-show-command #'openstack-server-display))

(provide 'openstack-server-list)
;;; openstack-server-list.el ends here
