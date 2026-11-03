;;; ol-openstack.el --- Org links to OpenStack resources -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: outlines, hypermedia
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

;; This library registers the `openstack' Org link type.  A link
;; names the resource type and the resource ID:
;;
;;   [[openstack:server/b40b9091-4b4a-4a89-a1d1-2f0d6d1b8f01][web-1]]
;;   [[openstack:network/6f1e2d3c-0000-4000-8000-0000000000cc]]
;;
;; Following such a link opens the resource with the display
;; command of its type (see `openstack-resource-types'), so the link
;; behaves like RET on a list row.  Storing a link with
;; `org-store-link' from a resource buffer writes one back.
;;
;; Export builds the dashboard URL of the resource from the
;; buffer-local URL settings of the mode, so a exported document
;; links to Horizon, and the settings stay in one place.
;;
;; Enable the link type in your init file:
;;
;;   (with-eval-after-load 'org
;;     (require 'ol-openstack))

;;; Code:

(require 'ol)
(require 'openstack-mode)
(require 'openstack-resources)

(defun openstack-org--split (path)
  "Split the `openstack' link PATH into a (TYPE . ID) pair.
Signal a `user-error' when PATH does not follow the
TYPE/ID form."
  (declare (side-effect-free t))
  (save-match-data
    (unless (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" path)
      (user-error "Malformed OpenStack link, expected TYPE/ID: %s" path))
    (cons (match-string 1 path) (match-string 2 path))))

(defun openstack-org--entry (type)
  "Return the resource entry of link TYPE.
Signal a `user-error' when TYPE is not in
`openstack-resource-types'."
  (declare (side-effect-free t))
  (or (openstack-resource-type type)
      (user-error "Unknown OpenStack resource type: %s" type)))

(defun openstack-org--dashboard-url (type id)
  "Return the dashboard URL of the resource of TYPE with ID.
The URL comes from `openstack-dashboard-url' with the buffer-local
`openstack-id-prefix' and `openstack-url-suffix' of the mode of
TYPE, so the link export never repeats those settings."
  (let ((buf (generate-new-buffer " *openstack-org-url*")))
    (unwind-protect
        (with-current-buffer buf
          (funcall (nth 1 (openstack-org--entry type)))
          (openstack-dashboard-url id))
      (kill-buffer buf))))

(defun openstack-org-follow (path &optional _arg)
  "Open the OpenStack resource named by the link PATH.
PATH is TYPE/ID; the display command of TYPE opens the resource
in its own mode.  ARG is ignored."
  (pcase-let ((`(,type . ,id) (openstack-org--split path)))
    (funcall (nth 2 (openstack-org--entry type)) id)))

(defun openstack-org-complete (&optional _arg)
  "Complete an `openstack' link, prompting for type and ID.
ARG is ignored.  Return the link path TYPE/ID."
  (let ((type (completing-read "OpenStack resource type: "
                               (mapcar #'car openstack-resource-types)
                               nil t)))
    (format "openstack:%s/%s" type
            (read-string "OpenStack resource ID: "))))

(defun openstack-org--description (type id)
  "Return a link description for the resource of TYPE with ID.
Prefer the name the last fetch rendered, fall back to ID."
  (let ((name (and (hash-table-p openstack--last-data)
                   (gethash "name" openstack--last-data))))
    (format "OpenStack %s %s" type
            (if (and (stringp name) (not (string-empty-p name)))
                name
              id))))

(defun openstack-org-store ()
  "Store an `openstack' link to the resource in the current buffer.
Return nil outside a resource buffer and in collection buffers,
which have no resource ID."
  (when (derived-mode-p 'openstack-mode)
    (when-let* ((id (openstack--resource-id))
                (type (openstack-resource-type-for-mode major-mode)))
      (org-link-store-props
       :type "openstack"
       :link (format "openstack:%s/%s" type id)
       :description (openstack-org--description type id))
      t)))

(defun openstack-org-export (path description backend _info)
  "Export the `openstack' link PATH to the dashboard.
PATH is TYPE/ID, DESCRIPTION is the link text, BACKEND is the
export backend.  The URL comes from
`openstack-org--dashboard-url'.  An unknown type exports the
plain path, so a document still builds."
  (condition-case nil
      (pcase-let* ((`(,type . ,id) (openstack-org--split path))
                   (desc (or description path))
                   (url (openstack-org--dashboard-url type id)))
        (pcase backend
          ('html (format "<a href=\"%s\">%s</a>" url desc))
          ('latex (format "\\href{%s}{%s}" url desc))
          (_ desc)))
    (user-error (or description path))))

(org-link-set-parameters "openstack"
                         :follow #'openstack-org-follow
                         :complete #'openstack-org-complete
                         :store #'openstack-org-store
                         :export #'openstack-org-export)

(provide 'ol-openstack)
;;; ol-openstack.el ends here
