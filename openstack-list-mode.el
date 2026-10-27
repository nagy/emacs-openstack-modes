;;; openstack-list-mode.el --- Collection base mode for OpenStack -*- lexical-binding: t; -*-

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

;; This package provides `openstack-list-mode', the parent mode for
;; the OpenStack collection buffers (servers, volumes, images,
;; networks, ...).  It derives from `tabulated-list-mode', so the
;; table comes with a clickable column header, per-column sorting,
;; column resizing, truncation of long cells and point keeping
;; across refreshes.
;;
;; A derived list mode stays thin: it sets `openstack-fetch-function'
;; and `openstack-render-function' to its resource's functions, and
;; `openstack-list--noun' to the plural resource name.  Its renderer
;; calls `openstack-list-render' with the placeholder text, the
;; parsed `RESOURCE list' JSON and its column order.
;;
;; The refresh pipeline of `openstack-mode' still drives the buffer:
;; `openstack--init-display-buffer' wires the asynchronous fetch into
;; `revert-buffer' and `auto-revert-mode', so a list refreshes
;; without blocking Emacs.  `openstack-render-manages-buffer' tells
;; that pipeline to leave the buffer work to
;; `tabulated-list-print', which erases the buffer and returns point
;; to the row with the same resource ID.
;;
;; The header line holds the column labels, so the row count, the
;; sort state and the last fetch error go to the mode line instead
;; (see `openstack-list--mode-line').

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'openstack-mode)

(defgroup openstack-list nil
  "Display OpenStack resource collections as tables."
  :prefix "openstack-list-"
  :group 'openstack)

(defcustom openstack-list-min-column-width 6
  "Narrowest width of a table column, in characters.
`openstack-list-render' shrinks the widest columns first when the
table does not fit the window, and stops at this width, so every
column keeps a readable part of its value."
  :type 'natnum
  :group 'openstack-list)

;;; Fetcher and columns

(defun openstack-list-fetch (resource _id success-fn error-fn &optional args)
  "Fetch all resources of RESOURCE type for a collection buffer.
RESOURCE is the client's resource command name, e.g. `server' or
`volume'.  Run `RESOURCE list' through
`openstack-cli-async-request' and call SUCCESS-FN with the
parsed JSON (a list of resource hash tables), or ERROR-FN with
an `openstack-cli-error' condition.  ARGS appends extra client
arguments to the command, for a resource whose list needs an
option.  Return the client process,
so the display machinery can cancel the fetch.  The ID argument
is ignored: a collection buffer has no single resource ID.
Collection modes wrap this with their own resource name as their
`openstack-fetch-function'."
  (openstack-cli-async-request
   (append (list resource "list") args)
   :success-fn success-fn
   :error-fn error-fn))

(defun openstack-list-columns (rows fields)
  "Return the table columns of ROWS in display order.
FIELDS names the columns shown first, in that order; every
remaining field of ROWS follows, sorted by name.  The field
names are the title-case names the client prints for lists,
for example `ID' or `Volume Type'."
  (let ((unseen (make-hash-table :test #'equal))
        (columns nil))
    (dolist (row rows)
      (maphash (lambda (key _value) (puthash key t unseen)) row))
    (dolist (field fields)
      (when (gethash field unseen)
        (remhash field unseen)
        (push field columns)))
    (let ((remaining nil))
      (maphash (lambda (key _value) (push key remaining)) unseen)
      (nconc (nreverse columns) (sort remaining #'string<)))))

;;; Buffer state

(defvar-local openstack-list--noun "rows"
  "Plural resource name of the current list, used in the mode line.
A derived mode sets it, for example to \"servers\".")

(defvar-local openstack-list--count 0
  "Number of rows in the table of the current buffer.")

(defvar-local openstack-list--rows nil
  "Hash table that maps the row identities of the current buffer.
The sorters read the typed cell values through it.")

;;; Rows and cells

(defun openstack-list--rows (rows)
  "Return ROWS as a list of hash tables.
The client returns an empty string or nil for an empty list, and
a single hash table when the list holds one resource; normalize
both cases."
  (cl-remove-if-not #'hash-table-p
                    (cond ((null rows) nil)
                          ((listp rows) rows)
                          (t (list rows)))))

(defun openstack-list--row-identity-field (row name)
  "Return the value of ROW field NAME when it is a non-empty string."
  (let ((value (openstack--hash-field row name)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun openstack-list--row-id (row number)
  "Return the identity of ROW, a string.
Use the resource ID of ROW, then its name, because a Swift
container has no UUID; use NUMBER for a row without either
field, so `tabulated-list-print' can find the row again."
  (or (openstack-list--row-identity-field row "ID")
      (openstack-list--row-identity-field row "Name")
      (format "row-%d" number)))

(defun openstack-list--row-index (rows)
  "Return a hash table that maps the row identities of ROWS to rows.
The sorters of `tabulated-list-format' receive entry identities
only, so they read the typed cell values through this index."
  (let ((index (make-hash-table :test #'equal))
        (number 0))
    (dolist (row rows index)
      (setq number (1+ number))
      (puthash (openstack-list--row-id row number) row index))))

(defun openstack-list--cell (row column)
  "Return the display text of ROW's COLUMN, with its face.
A status value takes its face from `openstack-status-faces', and
a value that differs from the previous refresh takes
`openstack-field-changed'."
  (let* ((value (gethash column row))
         (previous (and (listp openstack--previous-data)
                        (openstack--row-match openstack--previous-data row)))
         (changed (and previous
                       (not (openstack--data-equal-p
                             value (gethash column previous)))))
         (face (openstack--cell-face column value changed))
         (text (openstack--format-value value)))
    (if face (propertize text 'face face) text)))

(defun openstack-list--entries (rows columns)
  "Return `tabulated-list-entries' for ROWS and COLUMNS.
Each element pairs the row identity with a vector of cell
strings.  The identity keeps point on the same resource when a
refresh re-sorts the table.  Emacs 31 requires a list here: a
cons makes `tabulated-list-print-entry' signal a type error."
  (let ((number 0))
    (mapcar
     (lambda (row)
       (setq number (1+ number))
       (list (openstack-list--row-id row number)
             (vconcat (mapcar (lambda (column)
                                (openstack-list--cell row column))
                              columns))))
     rows)))

;;; Sorting

(defun openstack-list--numeric-string-p (string)
  "Return non-nil when STRING holds a decimal number."
  (and (string-match-p "\\`[+-]?[0-9]+\\(?:\\.[0-9]+\\)?\\'" string) t))

(defun openstack-list--value-lessp (a b)
  "Return non-nil when value A sorts before value B.
Numbers compare as numbers, numeric strings compare as numbers,
and every other pair compares as strings, ignoring case."
  (cond
   ((and (numberp a) (numberp b)) (< a b))
   ((and (stringp a) (stringp b))
    (if (and (openstack-list--numeric-string-p a)
             (openstack-list--numeric-string-p b))
        (< (string-to-number a) (string-to-number b))
      (string-collate-lessp a b nil t)))
   (t (string-collate-lessp (format "%s" a) (format "%s" b) nil t))))

(defun openstack-list--sort-value (column entry)
  "Return the value of COLUMN for ENTRY, or nil when the row has none."
  (when-let* ((row (gethash (car entry) openstack-list--rows)))
    (gethash column row)))

(defun openstack-list--sorter (column)
  "Return the sort predicate of COLUMN.
The predicate compares typed values, so a numeric column sorts as
numbers.  Rows without a value sort last."
  (lambda (entry-a entry-b)
    (let ((a (openstack-list--sort-value column entry-a))
          (b (openstack-list--sort-value column entry-b)))
      (cond ((and a b) (openstack-list--value-lessp a b))
            ((null a) nil)
            (t t)))))

(defun openstack-list--numeric-column-p (rows column)
  "Return non-nil when every value in ROWS of COLUMN is a number.
An empty column does not count as numeric."
  (let ((seen nil)
        (numeric t))
    (dolist (row rows)
      (let ((value (gethash column row)))
        (when value
          (setq seen t)
          (unless (or (numberp value)
                      (and (stringp value)
                           (openstack-list--numeric-string-p value)))
            (setq numeric nil)))))
    (and seen numeric)))

;;; Column widths

(defun openstack-list--natural-widths (rows columns)
  "Return the width that each column needs to show all ROWS.
There is one width for every name in COLUMNS."
  (mapcar
   (lambda (column)
     (let ((width (string-width column)))
       (dolist (row rows width)
         (setq width
               (max width
                    (string-width
                     (openstack--format-value (gethash column row))))))))
   columns))

(defun openstack-list--available-width (columns)
  "Return the cell width available for COLUMNS in the current window.
The result leaves room for `tabulated-list-padding' and for the
separator that `tabulated-list-print-col' inserts after every
column but the last."
  (let* ((window (or (get-buffer-window (current-buffer) 0)
                     (selected-window)))
         (separators (max 0 (1- (length columns)))))
    (max (* (length columns) openstack-list-min-column-width)
         (- (window-width window) tabulated-list-padding separators))))

(defun openstack-list--fit-widths (widths available)
  "Return WIDTHS shrunk to fit AVAILABLE characters.
Shrink the widest column first, and stop shrinking at
`openstack-list-min-column-width'; `tabulated-list-print-col'
then truncates the cells that still overflow."
  (let ((widths (copy-sequence widths))
        (total (apply #'+ widths)))
    (while (and (> (length widths) 0)
                (> total available)
                (> (apply #'max widths) openstack-list-min-column-width))
      (let* ((widest (apply #'max widths))
             (position (cl-position widest widths))
             (width (max openstack-list-min-column-width
                         (- widest (- total available)))))
        (setf (nth position widths) width)
        (setq total (apply #'+ widths))))
    widths))

(defun openstack-list--format (rows columns)
  "Return `tabulated-list-format' for ROWS and COLUMNS.
Every column sorts through `openstack-list--sorter', a numeric
column is right-aligned, and the widths fit the current window."
  (let ((widths (openstack-list--fit-widths
                 (openstack-list--natural-widths rows columns)
                 (openstack-list--available-width columns)))
        (format nil))
    (dolist (column columns)
      (push (list column
                  (pop widths)
                  (openstack-list--sorter column)
                  :right-align (openstack-list--numeric-column-p rows column))
            format))
    (vconcat (nreverse format))))

;;; Rendering

(defun openstack-list--print-entry (id columns)
  "Print the table row of ID with cell strings COLUMNS.
`tabulated-list-print-entry' draws the cells; this function then
adds `openstack-id' and `mouse-face' to the whole line, so RET and
`mouse-2' open the row's resource from any column."
  (let ((start (point)))
    (tabulated-list-print-entry id columns)
    (add-text-properties start (1- (point))
                         (list 'openstack-id id
                               'mouse-face 'highlight))))

(defun openstack-list-render (placeholder rows fields)
  "Render PLACEHOLDER or ROWS as a `tabulated-list-mode' table.
PLACEHOLDER is a string such as \"(no servers)\", inserted when
ROWS is empty.  ROWS is the parsed `RESOURCE list' JSON, a list
of hash tables.  FIELDS names the columns shown first, in that
order; the remaining fields follow, sorted by name.  Collection
modes call this from their `openstack-render-function' with their
own column order."
  (let* ((rows (openstack-list--rows rows))
         (columns (or (openstack-list-columns rows fields) fields)))
    (setq-local openstack-list--count (length rows))
    (setq-local openstack-list--rows (openstack-list--row-index rows))
    (setq-local tabulated-list-format (openstack-list--format rows columns))
    (setq-local tabulated-list-entries
                (and rows (openstack-list--entries rows columns)))
    ;; The renderer supplies its own printer, so it can fill a plain
    ;; buffer as well as a buffer in `openstack-list-mode'.
    (setq-local tabulated-list-printer #'openstack-list--print-entry)
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (when (null rows)
      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (insert placeholder "\n")))))

(defun openstack-list--redraw ()
  "Redraw the table from the cached rows, without a new fetch.
`window-size-change-functions' calls this after a resize, because
the column widths depend on the window width.  The rows stay the
same, so no cell takes the change face."
  (when (and openstack--rendered openstack--last-data)
    (let ((openstack--previous-data openstack--last-data))
      (funcall openstack-render-function nil openstack--last-data))))

(defun openstack-list--window-size-changed (frame)
  "Redraw the OpenStack list buffers shown in FRAME.
A resize changes the width that the columns can use."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'openstack-list-mode)
        (openstack-list--redraw)))))

(add-hook 'window-size-change-functions #'openstack-list--window-size-changed)

;;; Row commands

(defun openstack-list--id-at-point ()
  "Return the resource ID of the row at point, or nil."
  (get-text-property (line-beginning-position) 'openstack-id))

;;;###autoload
(defun openstack-list-copy-id ()
  "Copy the ID of the resource on the current row to the kill ring."
  (interactive)
  (let ((id (openstack-list--id-at-point)))
    (unless id
      (user-error "No OpenStack resource on this line"))
    (kill-new id)
    (message "Copied OpenStack resource ID: %s" id)))

;;;###autoload
(defun openstack-list-open-web ()
  "Open the dashboard page of the resource on the current row."
  (interactive)
  (let ((id (openstack-list--id-at-point)))
    (unless id
      (user-error "No OpenStack resource on this line"))
    (browse-url (openstack--format-url id))))

;;; Mode line

(defun openstack-list--mode-line ()
  "Return the status segment of the mode line for a collection buffer.
Show the number of rows, the current sort order and the last fetch
error.  The header line cannot carry them, because
`tabulated-list-mode' uses it for the column labels."
  (concat " [" (number-to-string openstack-list--count)
          " " openstack-list--noun "]"
          (when tabulated-list-sort-key
            (format " [sort: %s %s]"
                    (car tabulated-list-sort-key)
                    (if (cdr tabulated-list-sort-key) "desc" "asc")))
          (when openstack--last-error
            (propertize (concat " [" (openstack--error-string
                                      openstack--last-error) "]")
                        'face 'error))))

(defun openstack-list--display-error (_err)
  "Force a mode line redraw, which shows the last fetch error.
ERR is accepted for `openstack-error-display-function' and not
needed: `openstack-list--mode-line' reads `openstack--last-error'."
  (force-mode-line-update))

;;; Major mode

(defvar-keymap openstack-list-mode-map
  :doc "Local keymap for `openstack-list-mode' buffers."
  :parent tabulated-list-mode-map
  "RET" #'openstack-display-at-point
  "<mouse-2>" #'openstack-mouse-display-at-point
  "c" #'openstack-list-copy-id
  "w" #'openstack-list-open-web)

;;;###autoload
(define-derived-mode openstack-list-mode tabulated-list-mode "OpenStack List"
  "Display a collection of OpenStack resources as a table.
This is the base mode for the resource list modes, which derive
from it.  It derives from `tabulated-list-mode', so the table gets
a clickable column header, per-column sorting, column resizing and
point keeping across refreshes.

A derived mode sets `openstack-fetch-function' and
`openstack-render-function' to its resource's functions, and
`openstack-list--noun' to the plural resource name of the mode
line.  The refresh pipeline of `openstack-mode' drives the buffer,
so a list fetches asynchronously and keeps itself up to date with
`auto-revert-mode'.

RET and `mouse-2' open the resource of the row with the
buffer-local `openstack-show-command'.  Errors go to the mode
line, because the header line holds the column labels.

\\{openstack-list-mode-map}"
  :group 'openstack-list
  (openstack--init-display-buffer)
  (setq-local openstack-collection t)
  (setq-local openstack-render-manages-buffer t)
  (setq-local openstack-error-display-function
              #'openstack-list--display-error)
  (setq-local openstack-list--noun "rows")
  (setq-local openstack-list--count 0)
  (setq-local openstack-list--rows nil)
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key nil)
  (setq-local tabulated-list-printer #'openstack-list--print-entry)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (openstack-list--mode-line)))))
  (hl-line-mode 1))

(provide 'openstack-list-mode)
;;; openstack-list-mode.el ends here
