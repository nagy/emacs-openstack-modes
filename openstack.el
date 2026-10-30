;;; openstack.el --- Major modes for OpenStack resources -*- lexical-binding: t; -*-

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

;; Entry library of the package, so `(require 'openstack)' and
;; `(use-package openstack ...)' load everything the modes need:
;;
;; - `openstack-data' (openstack-data.el): the resource registry and
;;   the data entry points, for the modes and for other packages.
;; - `openstack-mode' (openstack-mode.el): the base show mode, the
;;   collection base mode and the renderers.
;; - `openstack-read' (openstack-read.el): the ID prompts and the
;;   `RESOURCE list' cache.
;; - `openstack-resources' (openstack-resources.el): the resource
;;   types and their generated show and list modes.
;;
;; The optional layers keep their own libraries and stay opt-in:
;; `openstack-xref' (jump to the resource of an ID), `openstack-url'
;; (the `openstack:' URL scheme), `ol-openstack' (Org links) and
;; `openstack-evil' (evil bindings).
;;
;;   (use-package openstack
;;     :config
;;     (setq openstack-refresh-interval 30))

;;; Code:

(require 'openstack-data)
(require 'openstack-mode)
(require 'openstack-read)
(require 'openstack-resources)

(provide 'openstack)
;;; openstack.el ends here
