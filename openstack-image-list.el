;;; openstack-image-list.el --- List OpenStack images -*- lexical-binding: t; -*-

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

;; This package provides `openstack-image-list-mode', a mode for
;; listing OpenStack disk images.  It is a collection view like
;; `openstack-server-list-mode': there is no resource ID, so it sets
;; `openstack-collection' and lets the same refresh pipeline
;; (asynchronous fetch, self-refreshing display buffer) fetch all
;; images with `openstack image list'.
;;
;; Entry point:
;;
;;   M-x openstack-image-list-display RET  - list all images
;;
;; The rows render as a padded table.  The columns of
;; `openstack-image-list-fields' come first, in that order; all
;; remaining fields follow, sorted by name.  The buffer refreshes
;; itself through `auto-revert-mode' like every other
;; `openstack-mode' display buffer.

;;; Code:

(require 'openstack-mode)

(defgroup openstack-image-list nil
  "Display OpenStack image lists in Emacs."
  :prefix "openstack-image-list-"
  :group 'openstack)

(defcustom openstack-image-list-buffer-name "*OpenStack Images*"
  "Name of the buffer listing OpenStack images.
The list shows all images, so unlike single-resource buffers
the name carries no ID suffix."
  :type 'string
  :group 'openstack-image-list)

(defcustom openstack-image-list-fields
  '("ID" "Name" "Status" "Disk Format" "Container Format" "Size")
  "Columns shown first, in this order, by `openstack-image-list-mode'.
`openstack image list' reports field names in title case (ID,
Name, Status, ...).  Columns missing from the data are skipped;
every remaining field is appended, sorted by name."
  :type '(repeat string)
  :group 'openstack-image-list)

;;; Fetcher and renderer

(defun openstack-image-list--fetch (id success-fn error-fn)
  "Fetch all images with `openstack image list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  Call SUCCESS-FN with the parsed JSON (a list of
image hash tables), or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-image-list-mode'."
  (openstack-list-fetch "image" id success-fn error-fn))

(defun openstack-image-list--columns (rows)
  "Return the table columns of ROWS in display order.
The fields of `openstack-image-list-fields' present in the data
come first, in that order; every remaining field of ROWS follows,
sorted by name."
  (openstack-list-columns rows openstack-image-list-fields))

(defun openstack-image-list--render (_id data)
  "Insert the table of images DATA into the current buffer.
DATA is the parsed `openstack image list' JSON, a list of hash
tables.  The columns come from `openstack-image-list-fields',
padded to the widest cell in each column.  This is the value of
`openstack-render-function' in `openstack-image-list-mode'."
  (openstack-list-render "(no images)" data
                         openstack-image-list-fields))

;;;###autoload
(defun openstack-image-list-display ()
  "Display all OpenStack images in a dedicated table buffer.
The buffer is named by `openstack-image-list-buffer-name' and
put into `openstack-image-list-mode', which fetches the images
with `openstack image list' and renders them as a table.  The
fetch is asynchronous: the buffer fills in when the client
delivers data, and keeps itself up to date afterwards."
  (interactive)
  (let ((buf (get-buffer-create openstack-image-list-buffer-name))
        (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-image-list-mode)
      (setq-local openstack-collection t)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(define-derived-mode openstack-image-list-mode openstack-mode
  "OpenStack Images"
  "Major mode for listing OpenStack images.
Derives from `openstack-mode' as a collection view: the buffer
has no resource ID (`openstack-collection' is set) and the
ID commands do not apply.  The images are fetched with
`openstack image list' through the asynchronous CLI layer and
rendered as a padded table; RET or `mouse-2' on a row opens the
image's show buffer (`openstack-image-display')."
  (setq-local openstack-fetch-function #'openstack-image-list--fetch)
  (setq-local openstack-render-function #'openstack-image-list--render)
  (setq-local openstack-id-prefix "images")
  ;; RET on a row opens the image's show buffer.
  (setq-local openstack-show-command #'openstack-image-display))

(provide 'openstack-image-list)
;;; openstack-image-list.el ends here
