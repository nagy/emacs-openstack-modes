;;; openstack-list-mode-test.el --- Tests for openstack-list-mode -*- lexical-binding: t; -*-

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

;;; Code:

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

(ert-deftest openstack-list-column-labels-from-snake-case ()
  "A snake case column name gets a title case header label."
  (should (equal (openstack-list--column-label "vip_address")
                 "Vip Address"))
  (should (equal (openstack-list--column-label "id") "ID"))
  (should (equal (openstack-list--column-label "admin_state_up")
                 "Admin State Up"))
  ;; A client that prints title case needs no change.
  (should (equal (openstack-list--column-label "Volume Type")
                 "Volume Type"))
  (should (equal (openstack-list--column-label "ID") "ID")))

(ert-deftest openstack-list-render-labels-snake-case-columns ()
  "The table header shows the label of a snake case column."
  (let ((rows (openstack-list-test--rows
               (list (cons "vip_address" "10.0.0.10")))))
    (with-temp-buffer
      (openstack-list-mode)
      (openstack-list-render "(no rows)" rows '("vip_address"))
      ;; The format holds the label, and the sorters keep the key.
      (should (equal (mapcar #'car (append tabulated-list-format nil))
                     '("Vip Address")))
      (should (string-match-p "Vip Address"
                              (prin1-to-string header-line-format)))
      (should (string-match-p "10\\.0\\.0\\.10" (buffer-string))))
    ;; The string renderer names the same columns.
    (should (equal (car (split-string
                         (openstack-list-render-to-string
                          rows '("vip_address"))
                         "\n"))
                   "Vip Address"))))

(ert-deftest openstack-list-sort-key-stays-the-column-name ()
  "A sort by a labelled column reads the rows through its key."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-render
     "(no rows)"
     (openstack-list-test--rows
      (list (cons "id" "lb-b") (cons "vip_address" "10.0.0.20"))
      (list (cons "id" "lb-a") (cons "vip_address" "10.0.0.10")))
     '("id" "vip_address"))
    (tabulated-list-sort 1)
    (goto-char (point-min))
    (should (equal (tabulated-list-get-id) "lb-a"))
    (should (equal (car tabulated-list-sort-key) "Vip Address"))))

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
  "RET, `mouse-2', `o', `c', `J', `w', `%' and `W' act on the table."
  (dolist (binding (list (cons (kbd "RET") #'openstack-display-at-point)
                         (cons (kbd "o") #'openstack-open-other-window)
                         (cons [mouse-2] #'openstack-mouse-display-at-point)
                         (cons (kbd "c") #'openstack-copy-id)
                         (cons (kbd "J") #'openstack-json-view)
                         (cons (kbd "w") #'openstack-open-web)
                         (cons (kbd "%") #'openstack-list-narrow)
                         (cons (kbd "W") #'openstack-list-widen)))
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

;;; Narrowing

(ert-deftest openstack-list-narrow-keeps-the-matching-rows ()
  "A narrow keeps the rows whose text matches, and widen restores all.
The filter reads every field of a row, not just the shown columns."
  (with-temp-buffer
    (openstack-list-mode)
    (let ((data (openstack-list-test--rows
                 '(("ID" . "id-1") ("Name" . "web-1")
                   ("Status" . "ACTIVE"))
                 '(("ID" . "id-2") ("Name" . "db-1")
                   ("Status" . "SHUTOFF")))))
      (setq-local openstack-render-function
                  (lambda (_id rows)
                    (openstack-list-render "(no rows)" rows '("ID" "Name"))))
      (setq-local openstack--rendered t
                  openstack--last-data data)
      (openstack-list-render "(no rows)" data '("ID" "Name"))
      (should (string-match-p "^id-1" (buffer-string)))
      (should (string-match-p "^id-2" (buffer-string)))
      (openstack-list-narrow "active")
      (should (string-match-p "^id-1" (buffer-string)))
      (should-not (string-match-p "id-2" (buffer-string)))
      (should (equal openstack-list--count 1))
      (should (string-match-p "\\[match: active\\]"
                              (openstack-list--mode-line)))
      (openstack-list-widen)
      (should (string-match-p "^id-2" (buffer-string)))
      (should-not openstack-list--filter))))

(ert-deftest openstack-list-narrow-reports-no-match ()
  "A filter that matches nothing says so instead of \"no rows\"."
  (with-temp-buffer
    (openstack-list-mode)
    (let ((data (openstack-list-test--rows
                 '(("ID" . "id-1") ("Name" . "web-1")))))
      (setq-local openstack-render-function
                  (lambda (_id rows)
                    (openstack-list-render "(no servers)" rows '("ID" "Name"))))
      (setq-local openstack--rendered t
                  openstack--last-data data)
      (openstack-list-render "(no servers)" data '("ID" "Name"))
      (openstack-list-narrow "zzz")
      (should (equal (buffer-string) "(no rows match zzz)\n"))
      (should (equal openstack-list--count 0)))))

(ert-deftest openstack-list-filter-survives-a-refresh ()
  "A refresh keeps the filter and the rows that match it."
  (with-temp-buffer
    (openstack-server-list-mode)
    (let ((success-fn nil)
          (rows (openstack-list-test--rows
                 '(("ID" . "id-1") ("Name" . "web-1"))
                 '(("ID" . "id-2") ("Name" . "db-1")))))
      (setq-local openstack-fetch-function
                  (lambda (_id success _error) (setq success-fn success)))
      (openstack--refresh)
      (funcall success-fn rows)
      (openstack-list-narrow "web")
      (should (string-match-p "^id-1" (buffer-string)))
      (should-not (string-match-p "id-2" (buffer-string)))
      (openstack--refresh)
      (funcall success-fn rows)
      (should (string-match-p "^id-1" (buffer-string)))
      (should-not (string-match-p "id-2" (buffer-string)))
      (should (equal openstack-list--filter "web")))))

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

(defun openstack-list-test--many-rows (count status)
  "Return COUNT rows with a distinct ID and the given STATUS."
  (cl-loop for number below count
           collect (let ((row (make-hash-table :test #'equal)))
                     (puthash "ID" (format "id-%d" number) row)
                     (puthash "Name" (format "web-%d" number) row)
                     (puthash "Size" (number-to-string number) row)
                     (puthash "Status" status row)
                     row)))

(ert-deftest openstack-list-render-marks-changes-across-many-rows ()
  "A re-render of a 1000-row table marks every changed cell.
The render pipeline binds the ID index of the previous rows, so the
render finds the row it compares in one lookup; a scan of the
previous rows per cell would take seconds here."
  (with-temp-buffer
    (openstack-list-mode)
    (let* ((old (openstack-list-test--many-rows 1000 "BUILD"))
           (new (openstack-list-test--many-rows 1000 "ACTIVE"))
           (openstack--previous-data old)
           (openstack--previous-index (openstack--row-index old)))
      (with-no-warnings
        (openstack-list-render "(no rows)" new '("ID" "Name" "Status")))
      (should (equal openstack-list--count 1000))
      (goto-char (point-min))
      (search-forward "ACTIVE")
      (should (equal (get-text-property (match-beginning 0) 'face)
                     '(openstack-field-changed openstack-status-ok)))
      ;; The last row of the table takes the change face too.
      (goto-char (point-max))
      (search-backward "ACTIVE")
      (should (equal (get-text-property (match-beginning 0) 'face)
                     '(openstack-field-changed openstack-status-ok))))))

(ert-deftest openstack-list-status-changes-across-many-rows ()
  "The status scan of a 1000-row table reports every changed row."
  (let* ((old (openstack-list-test--many-rows 1000 "BUILD"))
         (new (openstack-list-test--many-rows 1000 "ACTIVE"))
         (openstack--previous-data old)
         (openstack--previous-index (openstack--row-index old)))
    (should (= (length (openstack--status-changes old new)) 1000))
    (should (null (openstack--status-changes new new)))))

(ert-deftest openstack-list-refresh-indexes-previous-rows ()
  "The refresh pipeline hands the render an ID index of the old rows.
Without the index a cell of a 1000-row table scans 1000 previous
rows, so count the field reads of a real refresh: the indexed path
stays in the thousands, the scan reaches millions."
  (let* ((old (openstack-list-test--many-rows 1000 "BUILD"))
         (new (openstack-list-test--many-rows 1000 "ACTIVE"))
         (reads 0)
         (buf (generate-new-buffer " *openstack-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-list-mode)
          (setq-local openstack--rendered t
                      openstack--last-data old
                      openstack--fetch-marker (list nil)
                      openstack-render-function
                      (lambda (_id data)
                        (openstack-list-render "(no rows)" data
                                               '("ID" "Name" "Status"))))
          (let ((original (symbol-function 'openstack--hash-field))
                (inhibit-read-only t))
            (cl-letf (((symbol-function 'openstack--hash-field)
                       (lambda (table name)
                         (setq reads (1+ reads))
                         (funcall original table name))))
              (openstack--refresh-done buf openstack--fetch-marker
                                       nil new nil)))
          (should (equal openstack-list--count 1000))
          (should (< reads 100000)))
      (kill-buffer buf))))

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
      (setq openstack--last-error '(error "The client failed"))
      (funcall openstack-error-display-function openstack--last-error)
      (should (eq header header-line-format))
      (let ((line (openstack-list--mode-line)))
        (should (string-match "The client failed" line))
        ;; The error segment takes the package error face.
        (should (eq (get-text-property (match-beginning 0) 'face line)
                    'openstack-error))))))

;;; Row commands

(ert-deftest openstack-list-copy-id-of-a-row ()
  "`openstack-copy-id' copies the ID of the row at point."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render
     (openstack-list-test--rows '(("ID" . "id-7") ("Name" . "web-7"))))
    (openstack-copy-id)
    (should (equal (car kill-ring) "id-7"))))

(ert-deftest openstack-list-copy-id-with-a-prefix-copies-a-link ()
  "A prefix argument copies the `openstack:TYPE/ID' form of the row."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil))
    (with-temp-buffer
      (openstack-server-list-mode)
      (openstack-list-test--render
       (openstack-list-test--rows '(("ID" . "id-7") ("Name" . "web-7"))))
      (openstack-copy-id '(4))
      (should (equal (car kill-ring) "openstack:server/id-7")))))

(ert-deftest openstack-list-copy-id-needs-a-row ()
  "The row commands signal a user-error off a resource row."
  (with-temp-buffer
    (openstack-list-mode)
    (openstack-list-test--render nil)
    (goto-char (point-min))
    (should-error (openstack-copy-id) :type 'user-error)
    (should-error (openstack-open-web) :type 'user-error)))

(defmacro openstack-list-test--with-region (rows &rest body)
  "Render ROWS and select all of them, then run BODY.
Bind `kill-ring' to a fresh list, so a copy test reads its own
answer."
  (declare (indent 1))
  `(let ((kill-ring nil)
         (kill-ring-yank-pointer nil))
     (with-temp-buffer
       (openstack-server-list-mode)
       (openstack-list-test--render ,rows)
       (goto-char (point-max))
       (set-mark (point-min))
       (activate-mark)
       ,@body)))

(ert-deftest openstack-list-copy-ids-of-a-region ()
  "An active region copies every selected row ID, one per line."
  (openstack-list-test--with-region
      (openstack-list-test--rows '(("ID" . "id-1") ("Name" . "web-1"))
                                 '(("ID" . "id-2") ("Name" . "web-2")))
    (openstack-copy-id)
    (should (equal (car kill-ring) "id-1\nid-2"))))

(ert-deftest openstack-list-copy-links-of-a-region ()
  "A prefix argument copies the `openstack:TYPE/ID' form of every row."
  (openstack-list-test--with-region
      (openstack-list-test--rows '(("ID" . "id-1"))
                                 '(("ID" . "id-2")))
    (openstack-copy-id '(4))
    (should (equal (car kill-ring)
                   "openstack:server/id-1\nopenstack:server/id-2"))))

(ert-deftest openstack-list-region-stops-at-its-last-row ()
  "A region that ends at the start of a line keeps that line out."
  (openstack-list-test--with-region
      (openstack-list-test--rows '(("ID" . "id-1"))
                                 '(("ID" . "id-2")))
    (goto-char (point-min))
    (forward-line 1)
    (set-mark (point))
    (goto-char (point-min))
    (activate-mark)
    (openstack-copy-id)
    (should (equal (car kill-ring) "id-1"))))

(ert-deftest openstack-list-open-web-of-a-region ()
  "An active region opens the dashboard page of every selected row."
  (let ((opened nil))
    (openstack-list-test--with-region
        (openstack-list-test--rows '(("ID" . "id-1"))
                                   '(("ID" . "id-2")))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url) (push url opened))))
        (openstack-open-web))
      (should (equal (nreverse opened)
                     '("https://horizon.example.org/compute/id-1"
                       "https://horizon.example.org/compute/id-2"))))))

;;; Row expansion

(defun openstack-list-test--networks ()
  "Return network list rows for the expansion tests."
  (openstack-list-test--rows
   '(("ID" . "net-1") ("Name" . "provider") ("Status" . "ACTIVE")
     ("Subnets" . "snet-1") ("Shared" . "False")
     ("Router External" . "False"))
   '(("ID" . "net-2") ("Name" . "private") ("Status" . "ACTIVE")
     ("Subnets" . "snet-2") ("Shared" . "False")
     ("Router External" . "False"))))

(defun openstack-list-test--subnets ()
  "Return subnet list rows for the expansion tests."
  (openstack-list-test--rows
   '(("ID" . "snet-1") ("Name" . "web-subnet") ("Network" . "provider")
     ("Subnet" . "10.0.0.0/24"))))

(defun openstack-list-test--ports ()
  "Return port list rows for the expansion tests."
  (openstack-list-test--rows
   '(("ID" . "port-1") ("Name" . "web-port") ("Status" . "ACTIVE"))))

(defmacro openstack-list-test--with-network-table (&rest body)
  "Render a network table and run BODY with the child fetches stubbed.
Bind `calls' to the pending client calls, newest first, as a list
of (TYPE ARGS SUCCESS-FN).  The stub answers nothing by itself, so
a test decides when an answer arrives."
  (declare (indent 0))
  `(let ((calls nil))
     (with-temp-buffer
       (openstack-network-list-mode)
       (setq-local openstack--rendered t)
       (setq-local openstack--last-data (openstack-list-test--networks))
       (cl-letf (((symbol-function 'openstack-resource-list-async)
                  (lambda (type success _error &optional extra)
                    (push (list type extra success) calls))))
         (openstack-list-render "(no networks)"
                                (openstack-list-test--networks)
                                '("ID" "Name" "Status"))
         ,@body))))

(defmacro openstack-list-test--deliver-children ()
  "Answer every pending child fetch that `calls' holds.
The answer runs through the callback of the real transport, so the
table reprints the way it does after a real client answer."
  (declare (indent 0))
  `(while calls
     (let ((call (pop calls)))
       (funcall (nth 2 call)
                (pcase (nth 0 call)
                  ("subnet" (openstack-list-test--subnets))
                  ("port" (openstack-list-test--ports)))))))

(defun openstack-list-test--line-of (text)
  "Return the line of the current buffer that holds TEXT, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward text nil t)
      (buffer-substring-no-properties (line-beginning-position)
                                      (line-end-position)))))

(ert-deftest openstack-list-toggle-expansion-shows-the-children ()
  "TAB fetches the child rows of a row and indents them below it.
The child rows take the columns of their own type, so a subnet row
shows its CIDR beside the columns of the network table."
  (openstack-list-test--with-network-table
    (openstack-list-toggle-expansion)
    (should (equal (mapcar (lambda (call) (list (nth 0 call) (nth 1 call)))
                           (reverse calls))
                   '(("subnet" ("--network" "net-1"))
                     ("port" ("--network" "net-1")))))
    (openstack-list-test--deliver-children)
    (let ((line (openstack-list-test--line-of "^  snet-1")))
      (should (string-prefix-p "  snet-1" line))
      (should (string-match-p "web-subnet" line))
      (should (string-match-p "10\\.0\\.0\\.0/24" line)))
    (should (openstack-list-test--line-of "^  port-1"))
    ;; The other row stays closed, and the count speaks of the parents.
    (should (equal (count-matches "^net-" (point-min) (point-max)) 2))
    (should (equal openstack-list--count 2))))

(ert-deftest openstack-list-toggle-expansion-collapses ()
  "A second TAB hides the child rows without another client call."
  (openstack-list-test--with-network-table
    (openstack-list-toggle-expansion)
    (openstack-list-test--deliver-children)
    (should (openstack-list-test--line-of "^  snet-1"))
    (openstack-list-toggle-expansion)
    (should-not (openstack-list-test--line-of "^  snet-1"))
    (should-not calls)
    ;; The answer stays cached, so the row opens again at once.
    (openstack-list-toggle-expansion)
    (should (openstack-list-test--line-of "^  snet-1"))
    (should-not calls)))

(ert-deftest openstack-list-expanded-row-is-a-link-of-its-type ()
  "A child row carries its own type, so RET opens the subnet buffer."
  (openstack-list-test--with-network-table
    (openstack-list-toggle-expansion)
    (openstack-list-test--deliver-children)
    (goto-char (point-min))
    (should (re-search-forward "^  snet-1" nil t))
    (should (equal (get-text-property (point) 'openstack-id) "snet-1"))
    (should (equal (get-text-property (point) 'openstack-ref-type) "subnet"))
    (let ((shown nil))
      (cl-letf (((symbol-function 'openstack-subnet-display)
                 (lambda (id) (setq shown id))))
        (openstack-display-at-point))
      (should (equal shown "snet-1")))))

(ert-deftest openstack-list-expanded-row-collapses-from-a-child ()
  "TAB on a child row collapses the row that shows it."
  (openstack-list-test--with-network-table
    (openstack-list-toggle-expansion)
    (openstack-list-test--deliver-children)
    (goto-char (point-min))
    (should (re-search-forward "^  snet-1" nil t))
    (openstack-list-toggle-expansion)
    (should-not (openstack-list-test--line-of "^  snet-1"))))

(ert-deftest openstack-list-expanded-row-keeps-its-children-on-a-sort ()
  "A sort keeps the child rows behind the row that shows them."
  (openstack-list-test--with-network-table
    (openstack-list-toggle-expansion)
    (openstack-list-test--deliver-children)
    ;; Sort by name, so the private network comes first.
    (tabulated-list-sort 1)
    (let ((lines (split-string (buffer-string) "\n" t))
          (parent nil))
      (dolist (line lines)
        (cond ((string-prefix-p "net-1" line) (setq parent "net-1"))
              ((string-prefix-p "net-2" line) (setq parent "net-2"))
              ((string-prefix-p "  " line)
               (should (equal parent "net-1"))))))
    (should (string-prefix-p "net-2"
                             (car (split-string (buffer-string) "\n" t))))
    (should (equal (gethash "snet-1" openstack-list--row-parents) "net-1"))
    (should (equal (gethash "port-1" openstack-list--row-parents) "net-1"))))

(ert-deftest openstack-list-expansion-needs-a-child-type ()
  "A table of a type that owns no resource signals a user-error."
  (with-temp-buffer
    (openstack-container-list-mode)
    (setq-local openstack--rendered t)
    (setq-local openstack--last-data
                (openstack-list-test--rows '(("Name" . "logs"))))
    (openstack-list-render "(no containers)"
                           (openstack-list-test--rows '(("Name" . "logs")))
                           '("Name"))
    (goto-char (point-min))
    (should-error (openstack-list-toggle-expansion) :type 'user-error)))

(ert-deftest openstack-list-refresh-drops-the-child-answers ()
  "A refresh forgets the child rows, so an expanded row reads again."
  (with-temp-buffer
    (openstack-network-list-mode)
    (setq-local openstack-list--child-answers
                (let ((table (make-hash-table :test #'equal)))
                  (puthash '("subnet" . "net-1") (list :state 'done)
                           table)
                  table))
    (setq-local openstack-fetch-function (lambda (&rest _) nil))
    (openstack--refresh)
    (should-not openstack-list--child-answers)))

(provide 'openstack-list-mode-test)
;;; openstack-list-mode-test.el ends here
