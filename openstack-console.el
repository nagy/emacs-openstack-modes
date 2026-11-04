;;; openstack-console.el --- Console log view for an OpenStack server -*- lexical-binding: t; -*-

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

;; `openstack console log show ID' prints the console output of a
;; server as plain text, not as JSON, so this view takes the text path
;; of `openstack-cli.el' instead of the JSON path that the resource
;; types use.
;;
;; The mode derives from `openstack-mode', so it inherits the ID
;; handling, the refresh pipeline (the log refreshes like any other
;; display buffer), the bookmark record and the `openstack-pop' origin.
;; `goto-address-mode' turns a URL of the log into a link; the text
;; keeps no face, so a copy of the log stays plain.

;;; Code:

(require 'goto-addr)
(require 'openstack-cli)
(require 'openstack-mode)

(defgroup openstack-console nil
  "Display the console log of an OpenStack server."
  :prefix "openstack-console-"
  :group 'openstack)

(defcustom openstack-console-log-buffer-name "*OpenStack Console Log*"
  "Name prefix of the console log buffer of a server.
`openstack-console-log' appends the server ID, so each server has
its own log buffer."
  :type 'string
  :group 'openstack-console)

(defun openstack-console--fetch (id success-fn error-fn)
  "Fetch the console log of the server with ID.
Run `console log show ID' through the text path of
`openstack-cli.el' and call SUCCESS-FN with the log text, or
ERROR-FN with an `openstack-cli-error' condition.  Return the
client process, so the display machinery can cancel the fetch."
  (openstack-cli-async-request
   (list "console" "log" "show" id)
   :success-fn success-fn
   :error-fn error-fn
   :text t))

(defun openstack-console--render (_id data)
  "Insert the console log DATA into the current buffer."
  (insert (or data "")))

;;;###autoload
(define-derived-mode openstack-console-log-mode openstack-mode
  "OpenStack Console Log"
  "Display the console log of an OpenStack server.
Derives from `openstack-mode', so the refresh pipeline, the ID
handling, `openstack-pop' and the bookmark record work as in a show
buffer.  The client prints the log as plain text, and
`goto-address-mode' turns its URLs into links.

\\{openstack-mode-map}"
  :group 'openstack-console
  (setq-local openstack-fetch-function #'openstack-console--fetch)
  (setq-local openstack-render-function #'openstack-console--render)
  (setq-local openstack-id-prefix "compute")
  (setq-local openstack-url-suffix "")
  (goto-address-mode 1))

;;;###autoload
(defun openstack-console-log (id)
  "Display the console log of the OpenStack server with ID."
  (interactive (list (openstack--read-resource-id "server" "Server ID: ")))
  (let ((openstack-buffer-name openstack-console-log-buffer-name))
    (openstack-display id #'openstack-console-log-mode)))

(provide 'openstack-console)
;;; openstack-console.el ends here
