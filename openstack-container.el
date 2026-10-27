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

;; This package provides `openstack-container-mode' and
;; `openstack-container-list-mode', the modes for containers of the
;; Object Storage service (Swift).  `openstack-define-resource' writes
;; both modes from the form below, so the client's resource name
;; appears once: it names the fetchers, the ID prompt, the buffer
;; names, the dashboard URL and the `openstack-resource-types' entry.
;;
;; Entry points:
;;
;;   M-x openstack-container-display RET       - display a container
;;   M-x openstack-container-list-display RET  - list all containers
;;
;; A Swift container has no UUID: its name is its identifier.  The
;; show mode therefore hands the name to the base mode as the resource
;; ID, and `openstack-read-id' completes names from `container list'
;; rows, which carry a Name field and no ID field.
;;
;; The show mode fetches a container with `openstack container show'
;; through the asynchronous CLI layer (see openstack-cli.el) and
;; renders the fields of `openstack-container-fields' first, in that
;; order; all remaining fields follow, sorted by name.  The list mode
;; renders `openstack container list' as a `tabulated-list-mode'
;; table; `openstack-container-list-arguments' adds "--long", so the
;; table shows the byte and object counts as well.  Both buffers
;; refresh themselves (see `openstack-refresh-interval') and inherit
;; the ID handling and bookmark support of the base mode.
;;
;; Horizon shows a container at "project/containers/NAME", so the
;; modes set `openstack-id-prefix' and leave `openstack-url-suffix'
;; empty.
;;
;; The S3 API of Swift is a separate interface on the same service:
;; its access key and secret come from `ec2 credentials' of the
;; Identity service.  This package does not display them.

;;; Code:

(require 'openstack-resource)

(openstack-define-resource "container"
  :noun "containers"
  :id-prefix "project/containers"
  :fields '("container" "bytes_used" "object_count" "storage_policy"
            "read_acl" "write_acl" "account" "sync_to" "sync_key"
            "properties")
  :list-fields '("Name" "Bytes" "Count")
  :list-arguments '("--long"))

;; Load the modes from the generated autoloads, so an installed
;; package fills `openstack-resource-types' at load time.
;;;###autoload (require 'openstack-container)

(provide 'openstack-container)
;;; openstack-container.el ends here
