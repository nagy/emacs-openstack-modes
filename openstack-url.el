;;; openstack-url.el --- The openstack: URL scheme for resources -*- lexical-binding: t; -*-

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
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library teaches `browse-url' the `openstack:' scheme, so a
;; link opens the display buffer of a resource from any buffer: a
;; mail, a log line, a shell transcript or `goto-address-mode'.
;;
;; A URL names the resource type and the resource ID:
;;
;;   openstack:server/b40b9091-4b4a-4a89-a1d1-2f0d6d1b8f01
;;   openstack:network/6f1e2d3c-0000-4000-8000-0000000000cc
;;
;; A URL with the ID alone resolves the type through the cache:
;;
;;   openstack:b40b9091-4b4a-4a89-a1d1-2f0d6d1b8f01
;;
;; Enable the scheme in your init file:
;;
;;   (require 'openstack-url)
;;
;; The autoload file carries two forms: the handler registration and
;; the stub of `openstack-url-browse'.  The stub loads this library
;; on the first `openstack:' URL, and the registration makes
;; `browse-url' ask this scheme before the library loads.  Both are
;; needed.  A registration alone names a void function, and a stub
;; alone never registers the scheme.

;;; Code:

(require 'browse-url)
(require 'openstack-mode)
(require 'openstack-read)

;;;###autoload
(defconst openstack-url-regexp "\\`openstack:"
  "Regexp that matches an `openstack:' URL.")

(defun openstack-url-split (path)
  "Return the (TYPE . ID) pair of the URL PATH.
PATH is `TYPE/ID' or `ID'.  A PATH without a slash yields a nil
TYPE, so `openstack-open-id' resolves the type through the
cache."
  (declare (pure t) (side-effect-free t))
  (let ((slash (string-search "/" path)))
    (if slash
        (cons (substring path 0 slash)
              (substring path (1+ slash)))
      (cons nil path))))

;;;###autoload
(defun openstack-url-browse (url &rest _args)
  "Open the OpenStack resource named by URL.
URL takes the form `openstack:TYPE/ID' or `openstack:ID'.  ARGS
are ignored, as `browse-url-handlers' require.
This function carries an autoload cookie, because the `add-to-list'
form at the end of this file reaches the autoload file through its
own cookie.  That form names this function, so the stub here must
exist: a handler list without a definition signals `void-function'
on the first `openstack:' URL.  The stub loads this library then."
  (pcase-let* ((path (replace-regexp-in-string "\\`openstack:/*" "" url))
               (`(,type . ,id) (openstack-url-split path)))
    (openstack-open-id id type)))

;; The cookie copies this form into the autoload file, so `browse-url'
;; knows the scheme before this library loads.  The cookie on
;; `openstack-url-browse' above writes the stub that the copied form
;; calls, which loads this library on the first `openstack:' URL.
;; Keep both cookies: the form alone names a void function, and the
;; stub alone leaves the scheme unregistered.  The defconst needs its
;; own cookie, because the copied form reads the variable.
;;;###autoload
(add-to-list 'browse-url-default-handlers
             (cons openstack-url-regexp #'openstack-url-browse))

(provide 'openstack-url)
;;; openstack-url.el ends here
