;;; openstack-list-mode-tests.el --- Tests for openstack-list-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

(require 'ert)
(require 'openstack-mode)
(require 'openstack-resources)

;;; Helpers

(defun openstack-list-test--rows (&rest specs)
  "Return row hash tables built from SPECS.
Each spec is an alist of field name and value."
  (mapcar (lambda (spec)
            (let ((row (make-hash-table :test #'equal)))
              (dolist (pair spec row)
                (puthash (car pair) (cdr pair) row))))
          specs))

(defun openstack-list-test--render (rows)
  "Render ROWS as a table in the current buffer.
The columns come from `openstack-list-test--fields'."
  (with-no-warnings
    (openstack-list-render "(no rows)" rows '("ID" "Name" "Size"))))

;;; Mode

(ert-deftest openstack-list-mode-is-tabulated ()
  "The collection base mode derives from `tabulated-list-mode'."
  (with-temp-buffer
    (openstack-list-mode)
    (should (derived-mode-p 'openstack-list-mode))
    (should (derived-mode-p 'tabulated-list-mode))
    ;; A collection has no resource ID, and the renderer owns the buffer.
    (should openstack-collection)
    (should openstack-render-manages-buffer)
    (should-not (eq bookmark-make-record-function
                    #'openstack--bookmark-make-record))
    (should (eq bookmark-make-record-function
                #'openstack-list--bookmark-make-record))
    ;; The refresh pipeline of `openstack-mode' still drives the buffer.
    (should (eq revert-buffer-function #'openstack--revert-buffer))
    (should (eq buffer-stale-function #'openstack--buffer-stale-p))
    (should (eq tabulated-list-printer #'openstack-list--print-entry))
    (should (null tabulated-list-sort-key))))

(ert-deftest openstack-list-mode-keymap ()
  "RET, `mouse-2', `c', `J' and `w' act on the row, and sorting keeps S."
  (dolist (binding (list (cons (kbd "RET") #'openstack-display-at-point)
                         (cons [mouse-2] #'openstack-mouse-display-at-point)
                         (cons (kbd "c") #'openstack-list-copy-id)
                         (cons (kbd "J") #'openstack-json-view)
                         (cons (kbd "w") #'openstack-list-open-web)))
    (should (eq (lookup-key openstack-list-mode-map (car binding))
                (cdr binding))))
  (should (eq (lookup-key openstack-list-mode-map (kbd "S"))
              #'tabulated-list-sort)))

;;; Bookmarks

(ert-deftest openstack-list-bookmark-record ()
  "A collection bookmark keeps the type, scope, arguments and sort."
  (with-temp-buffer
    (openstack-server-list-mode)
    (setq-local openstack-list--scope
                '(:type "project" :id "proj-1"
                  :arguments ("--project" "proj-1")))
    (setq-local openstack-list--prefix-arguments '("--all"))
    (setq-local tabulated-list-sort-key '("Name" . t))
    (let ((record (openstack-list--bookmark-make-record)))
      (should (equal (car record) "Servers ::OpenStack list"))
      (should (equal (bookmark-prop-get record 'openstack-list-type)
                     "server"))
      (should (equal (bookmark-prop-get record 'openstack-list-scope)
                     '(:type "project" :id "proj-1"
                       :arguments ("--project" "proj-1"))))
      (should (equal (bookmark-prop-get
                      record 'openstack-list-prefix-arguments)
                     '("--all")))
      (should (equal (bookmark-prop-get record 'openstack-list-sort-key)
                     '("Name" . t)))
      (should (eq (bookmark-prop-get record 'handler)
                  'openstack-list-bookmark-jump)))))

(ert-deftest openstack-list-bookmark-jump ()
  "A jump reopens the table with the recorded scope and sort."
  (let ((buffer (generate-new-buffer " *openstack-list-bookmark*"))
        (seen nil))
    (unwind-protect
        (cl-letf (((symbol-function 'openstack-server-list-display)
                   (lambda (arg scope)
                     (setq seen (list arg scope))
                     buffer)))
          (openstack-list-bookmark-jump
           `(("Servers ::OpenStack list")
             (openstack-list-type . "server")
             (openstack-list-scope . (:type "project" :id "proj-1"))
             (openstack-list-prefix-arguments . ("--all"))
             (openstack-list-sort-key . ("Name" . t))
             (handler . openstack-list-bookmark-jump))))
        (should (equal seen '(t (:type "project" :id "proj-1"))))
        (with-current-buffer buffer
          (should (equal tabulated-list-sort-key '("Name" . t)))))
      (kill-buffer buffer)))

(ert-deftest openstack-list-bookmark-jump-unknown-type ()
  "A bookmark of an unregistered type signals a `user-error'."
  (should-error (openstack-list-bookmark-jump
                 '(("X")
                   (openstack-list-type . "nope")
                   (handler . openstack-list-bookmark-jump)))
                :type 'user-error))

;;; Rendering

(ert-deftest openstack-list-render-fills-rows ()
  "The renderer fills the table with one line per row and a mode line count."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows
      '(("ID" . "id-1") ("Name" . "web-1") ("Size" . "9"))
      '(("ID" . "id-2") ("Name" . "web-2") ("Size" . "10"))))
    (should (equal (buffer-string)
                   (concat "id-1 web-1    9\n"
                           "id-2 web-2   10\n")))
    (should (equal openstack-list--count 2))
    (should (equal (tabulated-list-get-id) "id-1"))
    (should (string-match-p "\\[2 rows\\]"
                            (openstack-list--mode-line)))))

(ert-deftest openstack-list-render-empty-placeholder ()
  "An empty list shows the placeholder and counts no rows."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render nil)
    (should (equal (buffer-string) "(no rows)\n"))
    (should (equal openstack-list--count 0))
    (should (string-match-p "\\[0 rows\\]"
                            (openstack-list--mode-line)))))

(ert-deftest openstack-list-render-propertizes-rows ()
  "Every row carries its resource ID over the whole line."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows
      '(("ID" . "id-1") ("Name" . "web-1") ("Size" . "9"))))
    (should (equal (get-text-property (point-min) 'openstack-id) "id-1"))
    (goto-char (1- (line-end-position)))
    (should (equal (get-text-property (point) 'openstack-id) "id-1"))
    (should (eq (get-text-property (point) 'mouse-face) 'highlight))))

(ert-deftest openstack-list-render-rows-are-buttons ()
  "A row is one text button that names its resource in the tooltip.
The mouse face comes from the button type, so the properties of a
row stop before its newline and the runs of two rows never join."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows
      '(("ID" . "id-1") ("Name" . "web-1") ("Size" . "9"))
      '(("ID" . "id-2") ("Name" . "web-2") ("Size" . "10"))))
    (goto-char (point-min))
    (should (get-text-property (point) 'button))
    (should (eq (button-type (point)) 'openstack-object))
    (should (equal (get-text-property (point) 'help-echo)
                   "Open web-1 (id-1)"))
    (should (eq (get-text-property (point) 'mouse-face) 'highlight))
    ;; The newline of a row keeps no button, so the rows stay apart.
    (should (null (get-text-property (line-end-position) 'mouse-face)))
    (forward-line 1)
    (should (equal (get-text-property (point) 'help-echo)
                   "Open web-2 (id-2)"))))

(ert-deftest openstack-list-render-keeps-point-on-id ()
  "A re-render with the rows in another order keeps point on the same ID."
  (with-temp-buffer
    (openstack-list-mode)
    (let ((first (openstack-list-test--rows
                  '(("ID" . "id-1") ("Name" . "web-1") ("Size" . "9"))
                  '(("ID" . "id-2") ("Name" . "web-2") ("Size" . "10"))))
          (reversed (openstack-list-test--rows
                     '(("ID" . "id-2") ("Name" . "web-2") ("Size" . "10"))
                     '(("ID" . "id-1") ("Name" . "web-1") ("Size" . "9")))))
      (openstack-list-test--render first)
      (forward-line 1)
      (should (equal (tabulated-list-get-id) "id-2"))
      (openstack-list-test--render reversed)
      (should (equal (tabulated-list-get-id) "id-2")))))

;;; Sorting

(ert-deftest openstack-list-sort-reorders-and-flips ()
  "Sorting by a column reorders the rows, and a second sort flips them."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows
      '(("ID" . "id-1") ("Name" . "web-b") ("Size" . "9"))
      '(("ID" . "id-2") ("Name" . "web-a") ("Size" . "10"))))
    ;; Column N in `tabulated-list-sort' counts from zero.
    (tabulated-list-sort 1)
    (goto-char (point-min))
    (should (equal (tabulated-list-get-id) "id-2"))
    (should (null (cdr tabulated-list-sort-key)))
    (tabulated-list-sort 1)
    (goto-char (point-min))
    (should (equal (tabulated-list-get-id) "id-1"))
    (should (cdr tabulated-list-sort-key))))

(ert-deftest openstack-list-sort-is-typed ()
  "A numeric column sorts as numbers, not as printed strings."
  (let* ((rows (openstack-list-test--rows
                '(("ID" . "id-1") ("Size" . "9"))
                '(("ID" . "id-2") ("Size" . "10"))))
         (openstack-list--rows (openstack-list--row-index rows))
         (sorter (openstack-list--sorter "Size")))
    (should (funcall sorter '("id-1") '("id-2")))
    (should-not (funcall sorter '("id-2") '("id-1"))))
  ;; Rows without a value sort last, in both directions.
  (let* ((rows (openstack-list-test--rows
                '(("ID" . "id-1"))
                '(("ID" . "id-2") ("Size" . "10"))))
         (openstack-list--rows (openstack-list--row-index rows))
         (sorter (openstack-list--sorter "Size")))
    (should (funcall sorter '("id-2") '("id-1")))
    (should-not (funcall sorter '("id-1") '("id-2")))))

(ert-deftest openstack-list-numeric-column-right-aligns ()
  "A column whose values all hold numbers is right-aligned."
  (let* ((rows (openstack-list-test--rows
                '(("ID" . "id-1") ("Size" . "9"))
                '(("ID" . "id-2") ("Size" . "10"))))
         (format (openstack-list--format rows '("ID" "Size"))))
    (should (openstack-list--numeric-column-p rows "Size"))
    (should-not (openstack-list--numeric-column-p rows "ID"))
    (should (plist-get (nthcdr 3 (aref format 1)) :right-align))
    (should-not (plist-get (nthcdr 3 (aref format 0)) :right-align))))

;;; Column widths

(ert-deftest openstack-list-widths-fit-the-window ()
  "Fit widths keep every column readable and the total within the window."
  (let ((wide (openstack-list--fit-widths '(40 30 20) 40)))
    (should (<= (apply #'+ wide) 40))
    (should (cl-every (lambda (width)
                        (>= width openstack-list-min-column-width))
                      wide))
    ;; The widest column gives up the space first.
    (should (< (nth 0 wide) 40)))
  ;; Widths that fit stay untouched.
  (should (equal (openstack-list--fit-widths '(4 5 6) 100) '(4 5 6))))

(ert-deftest openstack-list-long-cells-stay-on-one-line ()
  "A long cell keeps the line short: widths fit the window, text does not wrap."
  (with-temp-buffer
    (openstack-list-mode)
    ;; The mode truncates long display lines instead of wrapping them.
    (should truncate-lines)
    (cl-letf (((symbol-function 'openstack-list--available-width)
               (lambda (_columns &optional _window) 40)))
      (openstack-list-test--render
       (openstack-list-test--rows
        (list (cons "ID" "id-1")
              (cons "Name" (make-string 200 ?a))
              (cons "Size" "9")))))
    (should (equal (count-lines (point-min) (point-max)) 1))
    ;; The long column took the window budget, not its full 200 characters.
    (should (<= (nth 1 (aref tabulated-list-format 1)) 40))))

(ert-deftest openstack-list-widths-keep-column-labels ()
  "A fitted column keeps the whole of its label."
  ;; The label of the first column sets its floor, so the column gives
  ;; up its space before it cuts its own name.
  (let ((fitted (openstack-list--fit-widths '(40 30 20) 40 '(20 6 6))))
    (should (<= (apply #'+ fitted) 40))
    (should (>= (nth 0 fitted) 20)))
  (let* ((rows (openstack-list-test--rows
                (list (cons "Availability Zone" "nova")
                      (cons "Name" "web-1"))))
         (format
          (cl-letf (((symbol-function 'openstack-list--available-width)
                     (lambda (_columns &optional _window) 14)))
            (openstack-list--format rows '("Availability Zone" "Name")))))
    (should (>= (nth 1 (aref format 0)) 17))))

(ert-deftest openstack-list-render-records-the-budget ()
  "A render keeps the column budget of its window."
  (with-temp-buffer
    (openstack-list-mode)
    (cl-letf (((symbol-function 'openstack-list--available-width)
               (lambda (_columns &optional _window) 40)))
      (openstack-list-test--render
       (openstack-list-test--rows
        (list (cons "ID" "id-1") (cons "Name" "web-1")))))
    (should (equal openstack-list--fit-width 40))))

(ert-deftest openstack-list-refit-follows-the-window-width ()
  "A resize repaints only when the column budget changed."
  (with-temp-buffer
    (openstack-list-mode)
    (let ((calls 0)
          (budget 100))
      (setq-local openstack-render-function
                  (lambda (&rest _arguments) (setq calls (1+ calls))))
      (setq-local openstack--rendered t)
      (setq-local openstack--last-data (list (make-hash-table :test #'equal)))
      (setq-local tabulated-list-format [("ID" 4 nil)])
      (cl-letf (((symbol-function 'openstack-list--available-width)
                 (lambda (_columns &optional _window) budget)))
        (setq-local openstack-list--fit-width budget)
        ;; A frame event that keeps the width asks for no reprint.
        (should-not (openstack-list--refit-needed-p (selected-window)))
        (openstack-list--schedule-refit)
        (openstack-list--run-refits)
        (should (= calls 0))
        ;; A narrower window repaints once.
        (setq budget 20)
        (should (openstack-list--refit-needed-p (selected-window)))
        (openstack-list--schedule-refit)
        (openstack-list--run-refits)
        (should (= calls 1))))))

;;; Status display

(ert-deftest openstack-list-error-goes-to-mode-line ()
  "A fetch error leaves the column header in place and shows in the mode line."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows '(("ID" . "id-1") ("Name" . "web-1"))))
    (let ((header header-line-format))
      ;; `openstack--refresh-done' sets the error and then calls the
      ;; display function.
      (setq openstack--last-error '(error "the client failed"))
      (funcall openstack-error-display-function openstack--last-error)
      (should (eq header header-line-format))
      (let ((line (openstack-list--mode-line)))
        (should (string-match "the client failed" line))
        ;; The error segment takes the package error face.
        (should (eq (get-text-property (match-beginning 0) 'face line)
                    'openstack-error))))))

;;; Row commands

(ert-deftest openstack-list-copy-id-of-a-row ()
  "`openstack-list-copy-id' copies the ID of the row at point."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows '(("ID" . "id-7") ("Name" . "web-7"))))
    (openstack-list-copy-id)
    (should (equal (car kill-ring) "id-7"))))

(ert-deftest openstack-list-copy-id-needs-a-row ()
  "The row commands signal a user-error off a resource row."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render nil)
    (goto-char (point-min))
    (should-error (openstack-list-copy-id) :type 'user-error)
    (should-error (openstack-list-open-web) :type 'user-error)))

(provide 'openstack-list-mode-tests)
;;; openstack-list-mode-tests.el ends here
