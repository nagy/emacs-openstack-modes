;;; openstack-volume.el --- Display OpenStack volumes -*- lexical-binding: t; -*-

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

;; This package provides `openstack-volume-mode', a mode for
;; displaying OpenStack block storage volumes.  It fetches a volume
;; with `openstack volume show' through the asynchronous CLI layer
;; (see openstack-cli.el) and renders the volume's fields,
;; inheriting the ID handling, refresh pipeline and bookmark
;; support of the base mode.
;;
;; Entry point:
;;
;;   M-x openstack-volume-display RET  - display a volume by ID
;;
;; The display buffer fills in asynchronously, refreshes itself
;; (see `openstack-refresh-interval') and renders the fields of
;; `openstack-volume-fields' first, in that order; all remaining
;; fields follow, sorted by name.

;;; Code:

(require 'openstack-mode)
(require 'openstack-read)

(defcustom openstack-volume-buffer-name "*OpenStack Volume*"
  "Name prefix of the buffer used to display an OpenStack volume.
`openstack-volume-display' appends the volume ID, so each volume
gets its own buffer; the same ID always reuses its buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-volume-fields
  '("name" "status" "size" "volume_type" "bootable"
    "attachments" "availability_zone"
    "created_at" "updated_at")
  "Fields shown first, in this order, by `openstack-volume-mode'.
Fields missing from the volume data are skipped; every other
field of `openstack volume show' is rendered after them, sorted
by name."
  :type '(repeat string)
  :group 'openstack)

(defun openstack-volume--fetch (id success-fn error-fn)
  "Fetch the data of volume ID using `openstack-show-fetch'.
Run `openstack volume show ID' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-volume-mode'."
  (openstack-show-fetch "volume" id success-fn error-fn))

(defun openstack-volume--render (id data)
  "Insert the display of volume ID with DATA into the current buffer.
DATA is the parsed `openstack volume show' JSON, rendered by
`openstack-render-fields' with the field order of
`openstack-volume-fields'.  This is the value of
`openstack-render-function' in `openstack-volume-mode'."
  (openstack-render-fields "Volume" id data openstack-volume-fields))

;;;###autoload
(defun openstack-volume-display (id)
  "Display the OpenStack volume with ID in a dedicated buffer.
The buffer is named by `openstack-volume-buffer-name' and put
into `openstack-volume-mode', which fetches the volume with
`openstack volume show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
  (interactive (list (openstack-read-id "volume"
                                    "OpenStack volume ID: ")))
  (let ((openstack-buffer-name openstack-volume-buffer-name))
    (openstack-display id #'openstack-volume-mode)))

;;;###autoload
(define-derived-mode openstack-volume-mode openstack-mode
  "OpenStack Volume"
  "Major mode for displaying an OpenStack volume resource.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  Fetching and rendering
are set buffer-locally to the volume-specific fetcher and
renderer; they can be overridden globally like any other
`openstack-mode' buffer."
  (setq-local openstack-fetch-function #'openstack-volume--fetch)
  (setq-local openstack-render-function #'openstack-volume--render)
  (setq-local openstack-id-prefix "volumes"))

(provide 'openstack-volume)
;;; openstack-volume.el ends here
