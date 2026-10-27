;;; openstack-server.el --- Display OpenStack servers -*- lexical-binding: t; -*-

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

;; This package provides `openstack-server-mode' and
;; `openstack-server-list-mode', the modes for servers of the Compute
;; service.  `openstack-define-resource' writes both modes from the
;; form below, so the client's resource name appears once: it names
;; the fetchers, the ID prompt, the buffer names, the dashboard URL
;; and the `openstack-resource-types' entry.
;;
;; Entry points:
;;
;;   M-x openstack-server-display RET       - display a server by ID
;;   M-x openstack-server-list-display RET  - list all servers
;;
;; The show mode fetches a server with `openstack server show'
;; through the asynchronous CLI layer (see openstack-cli.el) and
;; renders the fields of `openstack-server-fields' first, in that
;; order; all remaining fields follow, sorted by name.  The list
;; mode renders `openstack server list' as a `tabulated-list-mode'
;; table whose columns start with `openstack-server-list-fields'.
;; Both buffers refresh themselves (see `openstack-refresh-interval')
;; and inherit the ID handling and bookmark support of the base mode.
;;
;; Horizon shows a server at "compute/ID", so the modes set
;; `openstack-id-prefix' to "compute" and leave
;; `openstack-url-suffix' empty.

;;; Code:

(require 'openstack-resource)

(openstack-define-resource "server"
  :noun "servers"
  :id-prefix "compute"
  :fields '("name" "status" "host_status" "vm_state"
            "OS-EXT-AZ:availability_zone" "project_id"
            "flavor" "addresses" "image"
            "created_at" "updated_at")
  :list-fields '("ID" "Name" "Status" "Host" "Task State"
                 "Networks" "Image Name" "Flavor"))

;; Load the modes from the generated autoloads, so an installed
;; package fills `openstack-resource-types' at load time.
;;;###autoload (require 'openstack-server)

(provide 'openstack-server)
;;; openstack-server.el ends here
