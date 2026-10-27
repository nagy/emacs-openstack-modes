;;; openstack-container.el --- Display OpenStack containers -*- lexical-binding: t; -*-

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

;; This package provides `openstack-container-mode', a mode for
;; displaying containers of the Object Storage service (Swift).  It
;; fetches a container with `openstack container show' through the
;; asynchronous CLI layer (see openstack-cli.el) and renders the
;; container's fields, inheriting the ID handling, refresh pipeline
;; and bookmark support of the base mode.
;;
;; Entry point:
;;
;;   M-x openstack-container-display RET  - display a container by name
;;
;; A Swift container has no UUID: its name is its identifier.  The
;; mode therefore hands the name to the base mode as the resource
;; ID, and `openstack-read-id' completes names from `container
;; list' rows, which carry a Name field and no ID field.
;;
;; The display buffer fills in asynchronously, refreshes itself
;; (see `openstack-refresh-interval') and renders the fields of
;; `openstack-container-fields' first, in that order; all remaining
;; fields follow, sorted by name.
;;
;; Horizon shows a container at "project/containers/NAME", so the
;; mode sets `openstack-id-prefix' and leaves `openstack-url-suffix'
;; empty.
;;
;; The S3 API of Swift is a separate interface on the same service:
;; its access key and secret come from `ec2 credentials' of the
;; Identity service.  This mode does not display them.

;;; Code:

(require 'openstack-mode)
(require 'openstack-read)

(defcustom openstack-container-buffer-name "*OpenStack Container*"
  "Name prefix of the buffer used to display an OpenStack container.
`openstack-container-display' appends the container name, so each
container gets its own buffer; the same name always reuses its
buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-container-fields
  '("container" "bytes_used" "object_count" "storage_policy"
    "read_acl" "write_acl" "account" "sync_to" "sync_key"
    "properties")
  "Fields shown first, in this order, by `openstack-container-mode'.
Fields missing from the container data are skipped; every other
field of `openstack container show' is rendered after them, sorted
by name."
  :type '(repeat string)
  :group 'openstack)

(defun openstack-container--fetch (id success-fn error-fn)
  "Fetch the data of container ID using `openstack-show-fetch'.
ID is the container name.  Run `openstack container show ID' and
call SUCCESS-FN with the parsed JSON, or ERROR-FN with an
`openstack-cli-error' condition.  Return the client process, so
the display machinery can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-container-mode'."
  (openstack-show-fetch "container" id success-fn error-fn))

(defun openstack-container--render (id data)
  "Insert the display of container ID with DATA into the buffer.
DATA is the parsed `openstack container show' JSON, rendered by
`openstack-render-fields' with the field order of
`openstack-container-fields'.  This is the value of
`openstack-render-function' in `openstack-container-mode'."
  (openstack-render-fields "Container" id data openstack-container-fields))

;;;###autoload
(defun openstack-container-display (id)
  "Display the OpenStack container with ID in a dedicated buffer.
ID is the container name.  The buffer is named by
`openstack-container-buffer-name' and put into
`openstack-container-mode', which fetches the container with
`openstack container show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
  (interactive (list (openstack-read-id "container"
                                       "OpenStack container name: ")))
  (let ((openstack-buffer-name openstack-container-buffer-name))
    (openstack-display id #'openstack-container-mode)))

;;;###autoload
(define-derived-mode openstack-container-mode openstack-mode
  "OpenStack Container"
  "Major mode for displaying an OpenStack object storage container.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  The resource ID of the
mode is the container name, because a Swift container has no
UUID.  Fetching and rendering are set buffer-locally to the
container-specific fetcher and renderer; they can be overridden
globally like any other `openstack-mode' buffer.  The dashboard
URL points at the project's container page."
  (setq-local openstack-fetch-function #'openstack-container--fetch)
  (setq-local openstack-render-function #'openstack-container--render)
  (setq-local openstack-id-prefix "project/containers"))

(provide 'openstack-container)
;;; openstack-container.el ends here
