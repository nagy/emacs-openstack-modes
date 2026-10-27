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

;; This package provides `openstack-network-mode' and
;; `openstack-network-list-mode', the modes for networks of the
;; Networking service.  `openstack-define-resource' writes both modes
;; from the form below, so the client's resource name appears once: it
;; names the fetchers, the ID prompt, the buffer names, the dashboard
;; URL and the `openstack-resource-types' entry.
;;
;; Entry points:
;;
;;   M-x openstack-network-display RET       - display a network by ID
;;   M-x openstack-network-list-display RET  - list all networks
;;
;; The show mode fetches a network with `openstack network show'
;; through the asynchronous CLI layer (see openstack-cli.el) and
;; renders the fields of `openstack-network-fields' first, in that
;; order; all remaining fields follow, sorted by name.  The list mode
;; renders `openstack network list' as a `tabulated-list-mode' table
;; whose columns start with `openstack-network-list-fields'.  Both
;; buffers refresh themselves (see `openstack-refresh-interval') and
;; inherit the ID handling and bookmark support of the base mode.
;;
;; Horizon shows a network at "project/networks/ID/detail", so the
;; modes set `openstack-id-prefix' to "project/networks" and
;; `openstack-url-suffix' to "/detail" instead of the single path
;; segment the compute modes use.

;;; Code:

(require 'openstack-resource)

(openstack-define-resource "network"
  :noun "networks"
  :id-prefix "project/networks"
  :url-suffix "/detail"
  :fields '("name" "status" "admin_state_up" "shared" "router:external"
            "subnets" "project_id"
            "provider:network_type" "provider:physical_network"
            "provider:segmentation_id" "mtu"
            "created_at" "updated_at")
  :list-fields '("ID" "Name" "Status" "Subnets" "Shared"
                 "Router External"))

;; Load the modes from the generated autoloads, so an installed
;; package fills `openstack-resource-types' at load time.
;;;###autoload (require 'openstack-network)

(provide 'openstack-network)
;;; openstack-network.el ends here
