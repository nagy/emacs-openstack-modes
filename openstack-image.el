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

;; This package provides `openstack-image-mode' and
;; `openstack-image-list-mode', the modes for disk images of the Image
;; service.  `openstack-define-resource' writes both modes from the
;; form below, so the client's resource name appears once: it names
;; the fetchers, the ID prompt, the buffer names, the dashboard URL
;; and the `openstack-resource-types' entry.
;;
;; Entry points:
;;
;;   M-x openstack-image-display RET       - display an image by ID
;;   M-x openstack-image-list-display RET  - list all images
;;
;; The show mode fetches an image with `openstack image show' through
;; the asynchronous CLI layer (see openstack-cli.el) and renders the
;; fields of `openstack-image-fields' first, in that order; all
;; remaining fields follow, sorted by name.  The list mode renders
;; `openstack image list' as a `tabulated-list-mode' table whose
;; columns start with `openstack-image-list-fields'.  Both buffers
;; refresh themselves (see `openstack-refresh-interval') and inherit
;; the ID handling and bookmark support of the base mode.
;;
;; Horizon shows an image at "images/ID", so the modes set
;; `openstack-id-prefix' to "images" and leave
;; `openstack-url-suffix' empty.

;;; Code:

(require 'openstack-resource)

(openstack-define-resource "image"
  :noun "images"
  :id-prefix "images"
  :fields '("name" "status" "visibility" "disk_format" "container_format"
            "size" "owner" "tags" "created_at" "updated_at")
  :list-fields '("ID" "Name" "Status" "Disk Format" "Container Format"
                 "Size"))

;; Load the modes from the generated autoloads, so an installed
;; package fills `openstack-resource-types' at load time.
;;;###autoload (require 'openstack-image)

(provide 'openstack-image)
;;; openstack-image.el ends here
