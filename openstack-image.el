;;; openstack-image.el --- Display OpenStack images -*- lexical-binding: t; -*-

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

;; This package provides `openstack-image-mode', a mode for
;; displaying OpenStack disk images.  It fetches an image with
;; `openstack image show' through the asynchronous CLI layer (see
;; openstack-cli.el) and renders the image's fields, inheriting
;; the ID handling, refresh pipeline and bookmark support of the
;; base mode.
;;
;; Entry point:
;;
;;   M-x openstack-image-display RET  - display an image by ID
;;
;; The display buffer fills in asynchronously, refreshes itself
;; (see `openstack-refresh-interval') and renders the fields of
;; `openstack-image-fields' first, in that order; all remaining
;; fields follow, sorted by name.

;;; Code:

(require 'openstack-mode)

(defcustom openstack-image-buffer-name "*OpenStack Image*"
  "Name prefix of the buffer used to display an OpenStack image.
`openstack-image-display' appends the image ID, so each image
gets its own buffer; the same ID always reuses its buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-image-fields
  '("name" "status" "visibility" "disk_format" "container_format"
    "size" "owner" "tags" "created_at" "updated_at")
  "Fields shown first, in this order, by `openstack-image-mode'.
Fields missing from the image data are skipped; every other
field of `openstack image show' is rendered after them, sorted
by name."
  :type '(repeat string)
  :group 'openstack)

(defun openstack-image--fetch (id success-fn error-fn)
  "Fetch the data of image ID using `openstack-show-fetch'.
Run `openstack image show ID' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-image-mode'."
  (openstack-show-fetch "image" id success-fn error-fn))

(defun openstack-image--render (id data)
  "Insert the display of image ID with DATA into the current buffer.
DATA is the parsed `openstack image show' JSON, rendered by
`openstack-render-fields' with the field order of
`openstack-image-fields'.  This is the value of
`openstack-render-function' in `openstack-image-mode'."
  (openstack-render-fields "Image" id data openstack-image-fields))

;;;###autoload
(defun openstack-image-display (id)
  "Display the OpenStack image with ID in a dedicated buffer.
The buffer is named by `openstack-image-buffer-name' and put
into `openstack-image-mode', which fetches the image with
`openstack image show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
  (interactive "sOpenStack image ID: ")
  (let ((openstack-buffer-name openstack-image-buffer-name))
    (openstack-display id #'openstack-image-mode)))

;;;###autoload
(define-derived-mode openstack-image-mode openstack-mode
  "OpenStack Image"
  "Major mode for displaying an OpenStack image resource.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  Fetching and rendering
are set buffer-locally to the image-specific fetcher and
renderer; they can be overridden globally like any other
`openstack-mode' buffer."
  (setq-local openstack-fetch-function #'openstack-image--fetch)
  (setq-local openstack-render-function #'openstack-image--render)
  (setq-local openstack-id-prefix "images"))

(provide 'openstack-image)
;;; openstack-image.el ends here
