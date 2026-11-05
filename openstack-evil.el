;;; openstack-evil.el --- Evil bindings for OpenStack modes -*- lexical-binding: t; -*-

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
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional evil integration for the OpenStack modes.  The file is
;; separate and declares no evil dependency, so users without evil
;; install nothing.  It needs evil 1.14 or later.
;;
;;   (require 'openstack-evil)
;;   (openstack-evil-mode 1)
;;
;; The mode binds keys in the normal and visual states of OpenStack
;; buffers and leaves the evil motions alone: j, k, gg, G, C-d, C-u,
;; /, n and N keep their meaning.  Evil state maps take precedence
;; over the major mode map, so RET, q, g and every command key of
;; the modes needs a state binding to reach the buffer at all.
;;
;; Show buffers keep the command keys of the mode: RET opens the
;; resource at point, q quits the window, gr refreshes, p pops back
;; to the origin buffer, c copies the resource ID, w opens the
;; dashboard page and TAB folds the block around point.  Evil
;; operators on those keys do nothing in a read-only buffer, so the
;; commands win.  The `dired-jump' and `dired-up-directory' remaps
;; climb one resource level up.
;;
;; List buffers treat a row as the unit: RET opens the row, c or Y
;; copies its ID, w opens its dashboard page, q quits the window, gr
;; refreshes, S sorts the current column, % narrows the table to the
;; rows that match and W widens it again.  The evil motions stay
;; untouched, so n and N repeat a search and j and k move by row.  A
;; visual line selection followed by y copies the IDs of every
;; selected row, one per line.
;;
;; The local minor modes below do the work.  Enable
;; `openstack-evil-mode' instead of them.

;;; Code:

(require 'evil)
(require 'openstack-mode)

;;; Bindings

(defvar openstack-evil-show-keys
  '(("RET" . openstack-display-at-point)
    ("<mouse-2>" . openstack-mouse-display-at-point)
    ("q" . quit-window)
    ("gr" . revert-buffer)
    ;; TAB is C-i, the jump of the evil jump list, in the normal state.
    ;; A show buffer folds a block instead, and p returns to the buffer
    ;; that opened it.
    ("TAB" . openstack-toggle-section)
    ("p" . openstack-pop)
    ("c" . openstack-copy-id)
    ("w" . openstack-open-web)
    ("<remap> <dired-jump>" . openstack-go-to-parent)
    ("<remap> <dired-up-directory>" . openstack-go-to-parent))
  "Keys that `openstack-evil-mode' binds in show buffers.
Each entry is a key description and the command it runs.  The
bindings replace evil operators that do nothing in a read-only
buffer, such as paste on p and change on c.  The `dired-jump' and
`dired-up-directory' remaps climb one resource level up.")

(defvar openstack-evil-list-keys
  '(("RET" . openstack-display-at-point)
    ("<mouse-2>" . openstack-mouse-display-at-point)
    ("q" . quit-window)
    ("gr" . revert-buffer)
    ("S" . tabulated-list-sort)
    ("%" . openstack-list-narrow)
    ("W" . openstack-list-widen)
    ("c" . openstack-copy-id)
    ("Y" . openstack-copy-id)
    ("w" . openstack-open-web)
    ("<remap> <dired-jump>" . openstack-go-to-parent)
    ("<remap> <dired-up-directory>" . openstack-go-to-parent))
  "Keys that `openstack-evil-mode' binds in list buffers.
Each entry is a key description and the command it runs.  A row is
the unit: S sorts the column at point, c or Y copies the ID of
the row at point, and % narrows the table while W widens it again.
The table is read-only, so the evil operators behind % and W have
nothing to do there.  n, N, j and k stay evil motions.")

(defvar openstack-evil-list-visual-keys
  '(("y" . openstack-evil-list-copy-ids))
  "Keys that `openstack-evil-mode' binds in visual state of list buffers.
A visual line selection feeds `openstack-evil-list-copy-ids', so a
range of rows yields a range of IDs.")

;;; Local minor modes

(define-minor-mode openstack-evil-show-mode
  "Install the evil bindings of show buffers.
Do not enable this mode directly: enable `openstack-evil-mode'."
  :group 'openstack
  :lighter nil)

(define-minor-mode openstack-evil-list-mode
  "Install the evil bindings of list buffers.
Do not enable this mode directly: enable `openstack-evil-mode'."
  :group 'openstack
  :lighter nil)

(defun openstack-evil--bind (state mode keys)
  "Bind STATE's evil keys for MODE from the KEYS list.
KEYS is a list of key descriptions and commands."
  (apply #'evil-define-minor-mode-key state mode
         (mapcan (lambda (binding)
                   (list (key-parse (car binding)) (cdr binding)))
                 keys)))

(openstack-evil--bind 'normal 'openstack-evil-show-mode
                      openstack-evil-show-keys)
(openstack-evil--bind 'normal 'openstack-evil-list-mode
                      openstack-evil-list-keys)
(openstack-evil--bind 'visual 'openstack-evil-list-mode
                      openstack-evil-list-visual-keys)

;;; Selection

(defun openstack-evil--ids-between (start end)
  "Return the row IDs of the OpenStack list rows between START and END.
A row carries its ID in the `openstack-id' text property of the
whole line, so a selection that touches any column still names the
resource."
  (let ((ids nil))
    (save-excursion
      (goto-char start)
      (while (and (not (eobp))
                  (< (line-beginning-position) end))
        (let ((id (get-text-property (line-beginning-position)
                                     'openstack-id)))
          (when id
            (push id ids)))
        (forward-line 1)))
    (nreverse ids)))

(defun openstack-evil-list-copy-ids (start end)
  "Copy the IDs of the OpenStack list rows between START and END.
One ID goes per line, in row order.  A visual selection supplies
START and END from `evil-visual-range', so a line selection that
reaches beyond the last row still stops at its last ID."
  (interactive
   (if (evil-visual-state-p)
       (let ((range (evil-visual-range)))
         (list (nth 0 range) (nth 1 range)))
     (list (region-beginning) (region-end)))
   openstack-list-mode)
  (let ((ids (openstack-evil--ids-between start end)))
    (unless ids
      (user-error "No OpenStack resource in the selection"))
    (kill-new (mapconcat #'identity ids "\n"))
    (message "Copied %d OpenStack resource ID%s"
             (length ids)
             (if (= (length ids) 1) "" "s")))
  (when (evil-visual-state-p)
    (evil-exit-visual-state)))

;;; Global minor mode

(defun openstack-evil--enable-buffer ()
  "Enable the evil bindings in an OpenStack buffer.
Leave buffers of other modes alone."
  (cond ((derived-mode-p 'openstack-list-mode)
         (openstack-evil-list-mode 1))
        ((derived-mode-p 'openstack-mode)
         (openstack-evil-show-mode 1))))

(defun openstack-evil--disable-buffer ()
  "Disable the evil bindings in the current buffer."
  (when (bound-and-true-p openstack-evil-show-mode)
    (openstack-evil-show-mode -1))
  (when (bound-and-true-p openstack-evil-list-mode)
    (openstack-evil-list-mode -1)))

;;;###autoload
(define-minor-mode openstack-evil-mode
  "Global minor mode that gives OpenStack buffers evil bindings.
The bindings keep the evil motions and put every OpenStack command
on a direct key.  Show and list buffers bind their own key sets.
Turn the mode off to give the buffers back to their major mode
maps."
  :global t
  :group 'openstack
  :lighter nil
  (if openstack-evil-mode
      (progn
        (add-hook 'after-change-major-mode-hook
                  #'openstack-evil--enable-buffer)
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (openstack-evil--enable-buffer))))
    (remove-hook 'after-change-major-mode-hook
                 #'openstack-evil--enable-buffer)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (openstack-evil--disable-buffer)))))

(provide 'openstack-evil)
;;; openstack-evil.el ends here
