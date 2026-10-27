;;; openstack-network.el --- Display OpenStack networks -*- lexical-binding: t; -*-

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

;; This package provides `openstack-network-mode', a mode for
;; displaying OpenStack networks of the Networking service.  It
;; fetches a network with `openstack network show' through the
;; asynchronous CLI layer (see openstack-cli.el) and renders the
;; network's fields, inheriting the ID handling, refresh pipeline
;; and bookmark support of the base mode.
;;
;; Entry point:
;;
;;   M-x openstack-network-display RET  - display a network by ID
;;
;; The display buffer fills in asynchronously, refreshes itself
;; (see `openstack-refresh-interval') and renders the fields of
;; `openstack-network-fields' first, in that order; all remaining
;; fields follow, sorted by name.
;;
;; Horizon shows a network at "project/networks/ID/detail", so the
;; mode sets `openstack-id-prefix' and `openstack-url-suffix'
;; instead of the single path segment the compute modes use.

;;; Code:

(require 'openstack-mode)
(require 'openstack-read)

(defcustom openstack-network-buffer-name "*OpenStack Network*"
  "Name prefix of the buffer used to display an OpenStack network.
`openstack-network-display' appends the network ID, so each
network gets its own buffer; the same ID always reuses its
buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-network-fields
  '("name" "status" "admin_state_up" "shared" "router:external"
    "subnets" "project_id"
    "provider:network_type" "provider:physical_network"
    "provider:segmentation_id" "mtu"
    "created_at" "updated_at")
  "Fields shown first, in this order, by `openstack-network-mode'.
Fields missing from the network data are skipped; every other
field of `openstack network show' is rendered after them, sorted
by name."
  :type '(repeat string)
  :group 'openstack)

(defun openstack-network--fetch (id success-fn error-fn)
  "Fetch the data of network ID using `openstack-show-fetch'.
Run `openstack network show ID' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  This is the value of
`openstack-fetch-function' in `openstack-network-mode'."
  (openstack-show-fetch "network" id success-fn error-fn))

(defun openstack-network--render (id data)
  "Insert the display of network ID with DATA into the current buffer.
DATA is the parsed `openstack network show' JSON, rendered by
`openstack-render-fields' with the field order of
`openstack-network-fields'.  This is the value of
`openstack-render-function' in `openstack-network-mode'."
  (openstack-render-fields "Network" id data openstack-network-fields))

;;;###autoload
(defun openstack-network-display (id)
  "Display the OpenStack network with ID in a dedicated buffer.
The buffer is named by `openstack-network-buffer-name' and put
into `openstack-network-mode', which fetches the network with
`openstack network show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
  (interactive (list (openstack-read-id "network"
                                    "OpenStack network ID: ")))
  (let ((openstack-buffer-name openstack-network-buffer-name))
    (openstack-display id #'openstack-network-mode)))

;;;###autoload
(define-derived-mode openstack-network-mode openstack-mode
  "OpenStack Network"
  "Major mode for displaying an OpenStack network resource.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  Fetching and rendering
are set buffer-locally to the network-specific fetcher and
renderer; they can be overridden globally like any other
`openstack-mode' buffer.  The dashboard URL points at the
project's network detail page."
  (setq-local openstack-fetch-function #'openstack-network--fetch)
  (setq-local openstack-render-function #'openstack-network--render)
  (setq-local openstack-id-prefix "project/networks")
  (setq-local openstack-url-suffix "/detail"))

(provide 'openstack-network)
;;; openstack-network.el ends here
