;;; openstack-evil-test.el --- Tests for openstack-evil -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Code:

(require 'ert)
(require 'openstack-test-helper)
(require 'evil)
(require 'openstack-evil)

;;; Helpers

(defun openstack-evil-test--normal ()
  "Enable evil in the current buffer and enter normal state."
  (evil-local-mode 1)
  (evil-normal-state))

(defun openstack-evil-test--rows (&rest ids)
  "Return list rows that hold IDS in their ID field."
  (mapcar (lambda (id)
            (let ((row (make-hash-table :test #'equal)))
              (puthash "ID" id row)
              row))
          ids))

(defun openstack-evil-test--render (rows)
  "Render ROWS as an OpenStack list table in the current buffer."
  (with-no-warnings
    (openstack-list-render "(no rows)" rows '("ID"))))

;;; Bindings

(ert-deftest openstack-evil-show-keys ()
  "Normal state runs the show commands instead of the evil operators."
  (with-temp-buffer
    (openstack-mode)
    (openstack-evil-show-mode 1)
    (openstack-evil-test--normal)
    (dolist (binding openstack-evil-show-keys)
      (should (eq (key-binding (key-parse (car binding)))
                  (cdr binding))))
    (should (eq (key-binding [mouse-2])
                #'openstack-mouse-display-at-point))))

(ert-deftest openstack-evil-list-keys ()
  "Normal state sorts with S, copies the row ID and keeps the search."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-evil-list-mode 1)
    (openstack-evil-test--normal)
    (dolist (binding openstack-evil-list-keys)
      (should (eq (key-binding (key-parse (car binding)))
                  (cdr binding))))
    (should (eq (key-binding (kbd "n")) #'evil-search-next))
    (should (eq (key-binding (kbd "N")) #'evil-search-previous))
    (should (eq (key-binding [mouse-2])
                #'openstack-mouse-display-at-point))))

(ert-deftest openstack-evil-list-visual-yank ()
  "Visual state binds y to the ID copy of the selected rows."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-evil-list-mode 1)
    (evil-local-mode 1)
    (evil-visual-line)
    (dolist (binding openstack-evil-list-visual-keys)
      (should (eq (key-binding (key-parse (car binding)))
                  (cdr binding))))))

(ert-deftest openstack-evil-folds-through-the-section-commands ()
  "The evil fold commands reach the sections of a show buffer.
Every show mode is a major mode of its own, so the handler names
the show minor mode of this file instead of each generated mode."
  (with-temp-buffer
    (openstack-mode)
    (openstack-evil-show-mode 1)
    (openstack-evil-test--normal)
    (let ((inhibit-read-only t)
          (data (json-parse-string
                 (concat "{\"name\": \"ubuntu\", "
                         "\"properties\": {\"arch\": \"x86_64\"}}")
                 :object-type 'hash-table :array-type 'list)))
      (openstack-render-fields "Image" "img-1" data '("name")))
    (let ((properties (openstack--section-of-type 'openstack-group
                                                  "properties")))
      (should properties)
      (should (seq-some (lambda (handler)
                          (memq 'openstack-evil-show-mode (car handler)))
                        evil-fold-list))
      (goto-char (oref properties start))
      (call-interactively #'evil-close-fold)
      (should (oref properties hidden))
      (call-interactively #'evil-open-fold)
      (should-not (oref properties hidden))
      (call-interactively #'evil-toggle-fold)
      (should (oref properties hidden))
      (call-interactively #'evil-open-folds)
      (should-not (oref properties hidden)))))

(ert-deftest openstack-evil-keeps-motions ()
  "The evil motions survive the bindings of the local minor modes."
  (with-temp-buffer
    (openstack-mode)
    (openstack-evil-show-mode 1)
    (openstack-evil-test--normal)
    (dolist (key '("j" "k" "gg" "G" "C-d" "C-u" "/"))
      (should-not (eq (key-binding (key-parse key))
                      'openstack-display-at-point)))
    (should (eq (key-binding (kbd "j")) #'evil-next-line))
    (should (eq (key-binding (kbd "G")) #'evil-goto-line))))

;;; Sorting

(ert-deftest openstack-evil-list-sorts-with-S ()
  "S sorts the column at point and reprints the table."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-evil-test--render
     (openstack-evil-test--rows "id-3" "id-1" "id-2"))
    (openstack-evil-list-mode 1)
    (openstack-evil-test--normal)
    (goto-char (point-min))
    (call-interactively (key-binding (kbd "S")))
    (should (equal (buffer-string) "id-1\nid-2\nid-3\n"))))

;;; Selection

(ert-deftest openstack-evil-list-copy-ids-visual-selection ()
  "A visual line selection copies its IDs and leaves visual state."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil))
    (with-temp-buffer
      (openstack-list-mode)
      (openstack-evil-test--render
       (openstack-evil-test--rows "id-1" "id-2" "id-3"))
      (openstack-evil-list-mode 1)
      (evil-local-mode 1)
      (goto-char (point-min))
      (evil-visual-select (point-min) (line-beginning-position 3) 'line)
      (call-interactively #'openstack-evil-list-copy-ids)
      (should (equal (car kill-ring) "id-1\nid-2"))
      (should-not (evil-visual-state-p)))))

(ert-deftest openstack-evil-list-copy-ids-copies-selection ()
  "A region copies the IDs of the rows it touches, one per line."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil))
    (with-temp-buffer
      (openstack-list-mode)
      (openstack-evil-test--render
       (openstack-evil-test--rows "id-1" "id-2" "id-3"))
      (goto-char (point-min))
      (let ((start (line-beginning-position)))
        (forward-line 2)
        (openstack-evil-list-copy-ids start (point))
        (should (equal (car kill-ring) "id-1\nid-2"))))))

(ert-deftest openstack-evil-list-copy-ids-copies-one-row ()
  "A region on one row copies only its ID."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil))
    (with-temp-buffer
      (openstack-list-mode)
      (openstack-evil-test--render
       (openstack-evil-test--rows "id-1" "id-2"))
      (openstack-evil-list-copy-ids (point-min) (line-end-position))
      (should (equal (car kill-ring) "id-1")))))

(ert-deftest openstack-evil-list-copy-ids-signals-without-id ()
  "A region without an OpenStack row signals a `user-error'."
  (with-temp-buffer
    (openstack-list-mode)
    (let ((inhibit-read-only t))
      (insert "plain text\n"))
    (should-error (openstack-evil-list-copy-ids (point-min) (point-max))
                  :type 'user-error)))

;;; Global mode

(ert-deftest openstack-evil-mode-enables-openstack-buffers ()
  "The global mode turns on the matching local mode, and only there."
  (unwind-protect
      (progn
        (openstack-evil-mode 1)
        (with-temp-buffer
          (openstack-mode)
          (should openstack-evil-show-mode)
          (should-not openstack-evil-list-mode))
        (with-temp-buffer
          (openstack-list-mode)
          (should openstack-evil-list-mode)
          (should-not openstack-evil-show-mode))
        (with-temp-buffer
          (fundamental-mode)
          (should-not openstack-evil-show-mode)
          (should-not openstack-evil-list-mode)))
    (openstack-evil-mode -1)))

(ert-deftest openstack-evil-mode-disables-local-modes ()
  "Turning the global mode off removes the local modes from open buffers."
  (openstack-evil-mode 1)
  (unwind-protect
      (with-temp-buffer
        (openstack-mode)
        (should openstack-evil-show-mode)
        (openstack-evil-mode -1)
        (should-not openstack-evil-show-mode))
    (openstack-evil-mode -1)))

;;; Autoloads

(ert-deftest openstack-evil-autoloads ()
  "The global mode carries an autoload cookie.
A fresh install must reach `openstack-evil-mode' without a
`require'."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (openstack-test--source "openstack-evil.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n(define-minor-mode openstack-evil-mode\\b"
             source))))

(ert-deftest openstack-evil-sibling-keys ()
  "The sibling walk keeps the major mode keys in normal state.
Evil binds neither `C-c' nor a side button, so the show keymap
reaches the two commands without a state binding."
  (with-temp-buffer
    (openstack-mode)
    (openstack-evil-show-mode 1)
    (openstack-evil-test--normal)
    (should-not (lookup-key evil-normal-state-map (kbd "C-c")))
    (should-not (lookup-key evil-normal-state-map [mouse-9]))
    (should (eq (key-binding (kbd "C-c C-n")) #'openstack-next-sibling))
    (should (eq (key-binding (kbd "C-c C-p"))
                #'openstack-previous-sibling))
    (should (eq (key-binding [mouse-9]) #'openstack-next-sibling))
    (should (eq (key-binding [mouse-8]) #'openstack-previous-sibling))))

(provide 'openstack-evil-test)
;;; openstack-evil-test.el ends here
