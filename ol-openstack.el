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
(require 'openstack-read)
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
The URL comes from `openstack--dashboard-url-of', which reads
`:id-prefix' and `:url-suffix' from the definition of TYPE, so the
link export never repeats those settings."
  (declare (side-effect-free t))
  (openstack--dashboard-url-of type id))

(defun openstack-org-follow (path &optional _arg)
  "Open the OpenStack resource named by the link PATH.
PATH is TYPE/ID; the display command of TYPE opens the resource
in its own mode.  ARG is ignored."
  (pcase-let ((`(,type . ,id) (openstack-org--split path)))
    (funcall (nth 2 (openstack-org--entry type)) id)))

(defun openstack-org-complete (&optional _arg)
  "Complete an `openstack' link, prompting for type and ID.
ARG is ignored.  Return the link path TYPE/ID.  The type prompt
keeps its answers in `openstack-read-type-history'."
  (let ((type (completing-read "OpenStack resource type: "
                               (mapcar #'car openstack-resource-types)
                               nil t nil 'openstack-read-type-history)))
    (format "openstack:%s/%s" type
            (read-string "OpenStack resource ID: "))))

(defun openstack-org--description (type id)
  "Return a link description for the resource of TYPE with ID.
Prefer the name the last fetch rendered, fall back to ID."
  (declare (side-effect-free t))
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

(defconst openstack-org--html-escapes
  '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;") ("\"" . "&quot;"))
  "Characters that need an entity in exported HTML.
The list stays here instead of calling `org-html-encode-plain-text',
because that function lives in `ox-html' and this library must
load without the HTML exporter.")

(defun openstack-org--html-escape (text)
  "Return TEXT with every HTML metacharacter replaced by an entity.
The result is safe in element content and in a quoted attribute,
so a hostile resource name cannot inject markup into the export."
  (declare (side-effect-free t))
  (replace-regexp-in-string
   (regexp-opt (mapcar #'car openstack-org--html-escapes))
   (lambda (match) (cdr (assoc match openstack-org--html-escapes)))
   text t t))

(defconst openstack-org--latex-escapes
  '(("\\" . "\\textbackslash{}") ("{" . "\\{") ("}" . "\\}")
    ("$" . "\\$") ("%" . "\\%") ("&" . "\\&")
    ("_" . "\\_") ("#" . "\\#") ("~" . "\\textasciitilde{}")
    ("^" . "\\textasciicircum{}"))
  "Characters that need an escape in a LaTeX argument.
The list stays here instead of calling `org-latex--protect-text',
because that function lives in `ox-latex' and this library must
load without the LaTeX exporter.")

(defun openstack-org--latex-escape (text)
  "Return TEXT with every LaTeX metacharacter escaped.
A resource name with a brace, a percent sign or a backslash would
otherwise end the argument or comment out the rest of the line."
  (declare (side-effect-free t))
  (replace-regexp-in-string
   (regexp-opt (mapcar #'car openstack-org--latex-escapes))
   (lambda (match) (cdr (assoc match openstack-org--latex-escapes)))
   text t t))

(defun openstack-org--md-escape-text (text)
  "Return TEXT with the characters that end a markdown link escaped."
  (declare (side-effect-free t))
  (replace-regexp-in-string
   (regexp-opt '("\\" "[" "]"))
   (lambda (match) (concat "\\" match))
   text t t))

(defun openstack-org--md-escape-url (url)
  "Return URL with the parentheses and backslashes escaped.
An unescaped parenthesis ends the destination of a markdown link."
  (declare (side-effect-free t))
  (replace-regexp-in-string
   (regexp-opt '("\\" "(" ")"))
   (lambda (match) (concat "\\" match))
   url t t))

(defun openstack-org-export (path description backend _info)
  "Export the `openstack' link PATH to the dashboard.
PATH is TYPE/ID, DESCRIPTION is the link text, BACKEND is the
export backend.  The URL comes from
`openstack-org--dashboard-url'.  HTML and markdown keep the link;
a backend without a link syntax keeps the description.  Every
backend that takes the URL escapes it and the description, because
a container or server name comes from the cloud.  An unknown type
exports the plain path, so a document still builds."
  (declare (side-effect-free t))
  (condition-case nil
      (pcase-let* ((`(,type . ,id) (openstack-org--split path))
                   (desc (or description path))
                   (url (openstack-org--dashboard-url type id)))
        (pcase backend
          ('html (format "<a href=\"%s\">%s</a>"
                         (openstack-org--html-escape url)
                         (openstack-org--html-escape desc)))
          ('latex (format "\\href{%s}{%s}"
                          (openstack-org--latex-escape url)
                          (openstack-org--latex-escape desc)))
          ('md (format "[%s](%s)"
                       (openstack-org--md-escape-text desc)
                       (openstack-org--md-escape-url url)))
          (_ desc)))
    (user-error (or description path))))

(org-link-set-parameters "openstack"
                         :follow #'openstack-org-follow
                         :complete #'openstack-org-complete
                         :store #'openstack-org-store
                         :export #'openstack-org-export)

(provide 'ol-openstack)
;;; ol-openstack.el ends here
