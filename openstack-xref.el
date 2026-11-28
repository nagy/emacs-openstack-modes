;;; openstack-xref.el --- Xref navigation for OpenStack resources -*- lexical-binding: t; -*-

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

;; An xref backend for OpenStack resource IDs.  `M-.' on an ID
;; opens the display buffer of that resource, from any buffer: a
;; log line, a mail, an Org document or a rendered field.  The
;; resource type comes from `openstack-read-type-of-id', so the
;; user never names it.
;;
;; The backend recognizes two kinds of identifier:
;;
;;   - the `openstack-id' text property of a rendered field or row
;;   - a UUID under point, which needs no fontification
;;
;; Both come through the `openstack-id' thing that `openstack-mode'
;; registers, so the backend keeps no identifier logic of its own.
;;
;; `M-?' lists the resources that a cached `RESOURCE list' row
;; mentions in one of its fields, so a server leads to its image
;; or its network.
;;
;; Enable it in your init file:
;;
;;   (require 'openstack-xref)
;;
;; `M-.' works without that line once the package installs its
;; autoloads.  The autoload file carries two forms: the hook entry
;; and the stub of `openstack-xref-backend'.  The stub loads this
;; library on the first xref request, and the hook entry puts the
;; backend on `xref-backend-functions' before the library loads.
;; Both are needed.  A hook entry alone names a void function, and a
;; stub alone never adds the hook.

;;; Code:

(require 'xref)
(require 'thingatpt)
(require 'openstack-mode)
(require 'openstack-read)

;;; Location

(cl-defstruct openstack-xref-location
  "Location of an OpenStack resource, for `xref'."
  type
  id)

(cl-defmethod xref-location-marker ((location openstack-xref-location))
  "Open the display buffer of LOCATION and return a marker there."
  (let ((buffer (openstack-open-id
                 (openstack-xref-location-id location)
                 (openstack-xref-location-type location))))
    (with-current-buffer buffer
      (copy-marker (point-min)))))

(cl-defmethod xref-location-group ((location openstack-xref-location))
  "Return the group title of LOCATION."
  (format "OpenStack %s" (openstack-xref-location-type location)))

(cl-defmethod xref-location-line ((_location openstack-xref-location))
  "Return the line number of an OpenStack resource, which is 1."
  1)

;;; Identifier

(defun openstack-xref-identifier-at-point ()
  "Return the OpenStack resource ID at point, or nil.
Ask the `openstack-id' thing, which prefers the `openstack-id'
text property of a rendered field or list row and falls back to a
UUID under point."
  (declare (side-effect-free t))
  (thing-at-point 'openstack-id t))

;;;###autoload
(defun openstack-xref-backend ()
  "Return the OpenStack xref backend when point holds a resource ID.
An `openstack-id' text property claims the identifier at once; a
bare UUID claims it only when `openstack-read-type-of-id' finds
its type, so another backend still handles a foreign UUID.  When
`xref-find-definitions' asks and the cache does not hold the ID,
the probe says how to teach it.
This function carries an autoload cookie, because the `add-hook'
form at the end of this file reaches the autoload file through its
own cookie.  That form names this function, so the stub here must
exist: a hook entry without a definition signals
`void-function', and `xref-find-backend' runs that hook in every
buffer.  The stub loads this library on the first xref request."
  (let ((id (openstack-xref-identifier-at-point)))
    (when id
      (cond ((get-char-property (point) 'openstack-id) 'openstack)
            ((openstack-read-type-of-id id) 'openstack)
            ;; A probe stays quiet for a foreign UUID, because every
            ;; buffer runs it.  The user who asks for a definition
            ;; over the UUID needs the hint.
            ((eq this-command 'xref-find-definitions)
             (message "OpenStack: %s is not in the list cache; %s"
                      id "run M-x openstack-read-refresh")
             nil)))))

;;; Backend

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql openstack)))
  "Return the identifier at point, or signal a `user-error'."
  (or (openstack-xref-identifier-at-point)
      (user-error "No OpenStack resource ID at point")))

(cl-defmethod xref-backend-identifier-completion-table
    ((_backend (eql openstack)))
  "Return the cached resource IDs as completion candidates."
  (openstack-read-ids))

(cl-defmethod xref-backend-definitions ((_backend (eql openstack)) identifier)
  "Return the definition of the resource with IDENTIFIER.
Signal a `user-error' when the list cache holds no row of
IDENTIFIER: the type lookup runs no client call, so a jump to a
resource that the cache does not know cannot resolve."
  (let ((type (openstack-read-type-of-id identifier)))
    (unless type
      (user-error "OpenStack: %s is not in the list cache; %s"
                  identifier "run M-x openstack-read-refresh"))
    (list (xref-make
           (format "OpenStack %s %s" type
                   (or (openstack-read-name identifier) identifier))
           (make-openstack-xref-location :type type :id identifier)))))

(cl-defmethod xref-backend-references ((_backend (eql openstack)) identifier)
  "Return the cached resources that mention IDENTIFIER in a field.
Read the cached `RESOURCE list' rows only, so the scan runs no
client call.  It finds the direct relations a list row reports,
such as the image of a server or the network of a port; fill the
cache with `openstack-read-refresh' to widen it."
  (mapcar
   (lambda (reference)
     (xref-make
      (format "OpenStack %s %s"
              (plist-get reference :type)
              (or (plist-get reference :name)
                  (plist-get reference :id)))
      (make-openstack-xref-location
       :type (plist-get reference :type)
       :id (plist-get reference :id))))
   (openstack-read-references identifier)))

;; The cookie copies this form into the autoload file, so the
;; backend claims a buffer before this library loads.  The cookie on
;; `openstack-xref-backend' above writes the stub that the copied
;; form calls, which loads this library on the first xref request.
;; Keep both cookies: the form alone names a void function, and the
;; stub alone leaves the hook empty.
;;;###autoload
(add-hook 'xref-backend-functions #'openstack-xref-backend)

(provide 'openstack-xref)
;;; openstack-xref.el ends here
