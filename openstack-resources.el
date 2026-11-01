;;; openstack-resources.el --- OpenStack resource types -*- lexical-binding: t; -*-

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

;; The resource types this package displays, one
;; `openstack-define-resource' form each.  The macro in
;; openstack-mode.el writes the show mode, the list mode, their
;; display commands, fetchers, renderers and defcustoms from the form,
;; and registers the type for the ID prompts, the Org links and the
;; xref backend.
;;
;; The order of the forms is the order of `openstack-resources-types':
;; `openstack-read-type-of-id' and the type prompt walk it, so a
;; frequently used resource belongs near the top.
;;
;; A resource form carries:
;;
;;   :noun           plural name for the buffer name and the mode line
;;   :id-prefix      leading dashboard URL segments (default: the type)
;;   :url-suffix     trailing dashboard URL segments (default: none)
;;   :fields         fields the show mode renders first
;;   :list-fields    columns the list mode shows first
;;   :list-arguments extra client arguments of `RESOURCE list'
;;   :parent         parent spec of the resource: the type that owns
;;                   it, the show fields that hold its ID and the
;;                   list arguments that filter by it
;;
;; The `:parent' spec drives `openstack-go-to-parent': the resource
;; buffer climbs to its own list, filtered by the parent, and the
;; next climb opens the parent itself.
;;
;; openstack-mode.el ends with an autoloaded `require' of this file, so
;; an installed package loads the resource types, and fills the
;; registries, at startup.

;;; Code:

(require 'openstack-mode)

;;; Servers

(openstack-define-resource "server"
  :noun "servers"
  :id-prefix "compute"
  :fields '("name" "status" "host_status" "vm_state"
            "OS-EXT-AZ:availability_zone" "project_id"
            "flavor" "addresses" "image"
            "created_at" "updated_at")
  :parent '(:type "project" :field "project_id"
            :arguments ("--project" :id))
  :list-fields '("ID" "Name" "Status" "Host" "Task State"
                 "Networks" "Image Name" "Flavor"))

;;; Volumes

(openstack-define-resource "volume"
  :noun "volumes"
  :id-prefix "volumes"
  :fields '("name" "status" "size" "volume_type" "bootable"
            "attachments" "availability_zone"
            "created_at" "updated_at")
  :parent '(:type "project"
            :field ("os-vol-tenant-attr:tenant_id" "project_id" "tenant_id")
            :arguments ("--project" :id))
  :list-fields '("ID" "Name" "Status" "Size" "Volume Type"
                 "Attached to"))

;;; Images

(openstack-define-resource "image"
  :noun "images"
  :id-prefix "images"
  :fields '("name" "status" "visibility" "disk_format" "container_format"
            "size" "owner" "tags" "created_at" "updated_at")
  :value-formatters '(("size" . openstack--format-size)
                      ("virtual_size" . openstack--format-size))
  :parent '(:type "project" :field "owner"
            :arguments ("--project" :id))
  :list-prefix-arguments '("--all")
  :list-fields '("ID" "Name" "Status" "Disk Format" "Container Format"
                 "Size"))

;;; Networks

(openstack-define-resource "network"
  :noun "networks"
  :id-prefix "project/networks"
  :url-suffix "/detail"
  :fields '("name" "status" "admin_state_up" "shared" "router:external"
            "subnets" "project_id"
            "provider:network_type" "provider:physical_network"
            "provider:segmentation_id" "mtu"
            "created_at" "updated_at")
  :parent '(:type "project" :field ("project_id" "tenant_id")
            :arguments ("--project" :id))
  :list-fields '("ID" "Name" "Status" "Subnets" "Shared"
                 "Router External"))

;;; Projects

;; The Identity service serves a project under its own dashboard
;; panel, so the URL differs from the other resource types: the
;; project detail view lives at `identity/projects/ID/detail/'.  The
;; `parent_id' of a nested project holds a project ID, but the field
;; of a top-level project holds the domain ID, so it stays plain text
;; instead of an `openstack-reference-fields' entry.

(openstack-define-resource "project"
  :noun "projects"
  :id-prefix "identity/projects"
  :url-suffix "/detail"
  :fields '("name" "enabled" "description" "domain_id" "parent_id"
            "is_domain" "tags" "options")
  :list-arguments '("--long")
  :list-fields '("ID" "Name" "Enabled" "Domain ID" "Description"))

;;; Containers

;; A Swift container has no UUID: its name acts as the resource ID, and
;; `openstack container list' reports that name in place of an ID.  The
;; extra "--long" makes the client report the byte and object counts.
;; The S3 API of Swift is a separate interface on the same service: its
;; access key and secret come from `ec2 credentials' of the Identity
;; service, which this package does not display.

(openstack-define-resource "container"
  :noun "containers"
  :id-prefix "project/containers"
  :fields '("container" "bytes_used" "object_count" "storage_policy"
            "read_acl" "write_acl" "account" "sync_to" "sync_key"
            "properties")
  :list-fields '("Name" "Bytes" "Count")
  :list-arguments '("--long"))

(provide 'openstack-resources)
;;; openstack-resources.el ends here
