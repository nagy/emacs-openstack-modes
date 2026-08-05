;;; openstack-mode.el --- Base major mode for OpenStack resources -*- lexical-binding: t; -*-

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

;; This package provides the base major mode for displaying OpenStack
;; resources in Emacs buffers.  Every OpenStack resource has a unique
;; ID, so this mode handles the ID: it keeps a buffer-local copy of
;; the resource ID, and offers commands to copy it to the kill ring,
;; open the resource in the web dashboard, and jump back to the
;; resource in a previous buffer.
;;
;; The mode derives from `special-mode' (read-only display buffers)
;; and is itself intended as a parent for resource-specific modes
;; (servers, volumes, images, networks, ...):
;;
;;   (define-derived-mode openstack-server-mode
;;     openstack-mode "OpenStack Server"
;;     "Render server-specific fields.")
;;
;; Derived modes inherit the ID handling, the keymap, and the
;; bookmark support; they only need to render their fields.
;;
;; The package talks to OpenStack through the =openstack= command
;; line client (the python-openstackclient from nixpkgs, package
;; =openstackclient-full=), configured with
;; `openstack-program'.  The Nix build substitutes the default value
;; with the store path of that package, so users do not need to
;; customize it.
;;
;; `openstack--id' and `openstack--origin-buffer'
;; are marked permanent-local so they survive the
;; `kill-all-local-variables' that `define-derived-mode' runs when
;; entering the mode.
;;
;; Derived modes (for servers, volumes, images, networks, …) inherit
;; the ID handling from `openstack-mode' for free; they only
;; need to render their resource-specific fields.
;;
;; Entry points:
;;
;;   M-x openstack-mode RET  - start the mode (interactively)
;;   openstack-display       - display a resource by ID
;;   openstack-copy-id       - copy the ID to the kill ring
;;   openstack-open-web      - open the dashboard URL
;;   openstack-pop           - pop back to the origin buffer
;;
;; The buffer name is `openstack-buffer-name' by default and
;; the dashboard URL template is `openstack-web-base-url'.

;;; Code:

(require 'bookmark)
(eval-when-compile (require 'cl-lib))


;;; Customization

(defgroup openstack nil
  "Base major mode for displaying OpenStack resources."
  :prefix "openstack-"
  :group 'tools)

(defcustom openstack-buffer-name "*OpenStack Resource*"
  "Name of the buffer used to display an OpenStack resource."
  :type 'string
  :group 'openstack)

(defcustom openstack-web-base-url "https://horizon.example.org"
  "Base URL of the OpenStack dashboard for `openstack-open-web'.
The resource ID is appended to this URL."
  :type 'string
  :group 'openstack)

(defcustom openstack-id-prefix "resource"
  "Path segment identifying the resource type in the dashboard URL."
  :type 'string
  :group 'openstack)

(defcustom openstack-program "openstack"
  "Path to the OpenStack command line client executable.

This is the python-openstackclient program, normally installed
via Nix as the =openstackclient-full= package.  The Nix build
substitutes this default with the store path of that package."
  :type 'file
  :group 'openstack)


;;; Mode variables

(defvar-local openstack--id nil
  "ID of the OpenStack resource displayed in the current buffer.")
(put 'openstack--id 'permanent-local t)

(defvar-local openstack--origin-buffer nil
  "Buffer to return to with `openstack-pop'.")
(put 'openstack--origin-buffer 'permanent-local t)

(defvar openstack-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'openstack-copy-id)
    (define-key map (kbd "w") #'openstack-open-web)
    (define-key map (kbd "p") #'openstack-pop)
    map)
  "Keymap for `openstack-mode'.

This keymap is used as the parent of the keymap installed by
`openstack-mode', which itself is a parent for derived
resource modes.  `q' and `g' are inherited from `special-mode'.")

(defvar openstack-bookmark-handler 'openstack-bookmark-jump
  "Symbol of the bookmark handler for resource buffers.")

(defconst openstack--saved-id-suffix " ::OpenStack"
  "Suffix appended to the ID in the bookmark record.")


;;; Helper functions

(defun openstack--format-url (id)
  "Return the dashboard URL for resource ID.
ID is a string; the URL is built from
`openstack-web-base-url', `openstack-id-prefix'
and ID."
  (format "%s/%s/%s"
          (string-trim-right openstack-web-base-url "/")
          openstack-id-prefix
          id))

(defun openstack--resource-id (&optional errorp)
  "Return the ID of the resource in the current buffer.
Signal an error if ERRORP is non-nil and no ID is set."
  (or openstack--id
      (when errorp
        (user-error "No OpenStack resource ID is set in this buffer"))))

(defun openstack--bookmark-make-record ()
  "Return a bookmark record for the current resource buffer."
  (let ((id (openstack--resource-id t)))
    `(,(concat id openstack--saved-id-suffix)
      (buffer . ,(current-buffer))
      (openstack-id . ,id)
      (handler . ,openstack-bookmark-handler))))

(defun openstack-bookmark-jump (bookmark)
  "Jump to the OpenStack resource described by BOOKMARK.
BOOKMARK is a bookmark record as created by
`openstack--bookmark-make-record'."
  (let ((id (bookmark-prop-get bookmark 'openstack-id)))
    (openstack-display id)))


;;; Commands

(defun openstack--render (id)
  "Insert the display of resource ID into the current buffer.
This is the default rendering; derived modes should override it
with their own resource-specific layout."
  (insert (format "OpenStack resource\n\nID: %s\n" id)))

(defun openstack-display (id)
  "Display the OpenStack resource with ID in a dedicated buffer.
The buffer is named `openstack-buffer-name' and put into
`openstack-mode'.  The rendering is done by
`openstack--render'."
  (interactive "sOpenStack resource ID: ")
  (let* ((buf (get-buffer-create openstack-buffer-name))
         (origin (current-buffer)))
    (with-current-buffer buf
      (openstack-mode)
      (setq-local openstack--id id)
      (setq-local openstack--origin-buffer origin)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (openstack--render id)))
    (pop-to-buffer buf)))

(defun openstack-copy-id ()
  "Copy the ID of the current OpenStack resource to the kill ring."
  (interactive)
  (let ((id (openstack--resource-id t)))
    (kill-new id)
    (message "Copied OpenStack resource ID: %s" id)))

(defun openstack-open-web ()
  "Open the dashboard page for the current OpenStack resource."
  (interactive)
  (browse-url (openstack--format-url
               (openstack--resource-id t))))

(defun openstack-pop ()
  "Pop back to the buffer the resource was displayed from."
  (interactive)
  (let ((origin openstack--origin-buffer))
    (cond ((buffer-live-p origin)
           (pop-to-buffer origin))
          (t
           (user-error "The origin buffer for this resource is gone")))))

(defun openstack-set-id (id)
  "Set the ID of the current buffer's OpenStack resource to ID."
  (interactive "sOpenStack resource ID: ")
  (setq-local openstack--id id)
  (message "Set OpenStack resource ID: %s" id))


;;; Major mode

(define-derived-mode openstack-mode special-mode
  "OpenStack Resource"
  "Display an OpenStack resource in the current buffer.
This is the base mode for OpenStack resource display.  It
provides ID handling: copy the ID, open the dashboard page, and
pop back to the origin buffer.

This mode is intended as a parent for resource-specific derived
modes; they inherit the ID handling and only override the
rendering, for example by advising `openstack--render'."
  :group 'openstack
  (setq-local revert-buffer-function #'openstack--revert-buffer)
  (setq-local bookmark-make-record-function
              #'openstack--bookmark-make-record))

(defun openstack--revert-buffer (&rest _args)
  "Re-display the current OpenStack resource.
Ignoring ARGS, as required by `revert-buffer-function'."
  (let ((id openstack--id))
    (when id
      (let ((inhibit-read-only t))
        (erase-buffer)
        (openstack--render id)))))

(provide 'openstack-mode)
;;; openstack-mode.el ends here
