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
;; bookmark support; they only need to fetch and render their data
;; by setting `openstack-fetch-function' and
;; `openstack-render-function'.
;;
;; Display buffers keep themselves up to date through
;; `auto-revert-mode': the refresh runs
;; `openstack-fetch-function' asynchronously, so Emacs never
;; blocks on the client.  Fetches are throttled to one per
;; `openstack-refresh-interval' seconds (see `openstack-auto-revert').
;;
;; The package talks to OpenStack through the =openstack= command
;; line client (the python-openstackclient from nixpkgs, package
;; =openstackclient-full=), configured with `openstack-program'
;; (defined in openstack-cli.el).  The Nix build substitutes the
;; default value with the store path of that package, so users do
;; not need to customize it.
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
;; The file registers the `openstack-id' thing with `thingatpt', so
;; `(thing-at-point \='openstack-id)' yields the ID at point in any
;; buffer: the `openstack-id' text property of a rendered field or
;; list row first, then a UUID under point.  Display buffers also
;; provide the `uuid' thing from that property, because a narrow
;; table truncates the ID text but keeps the full ID in the property.
;;
;; The display buffer name is built from `openstack-buffer-name'
;; and the resource ID, so each resource has its own buffer;
;; the dashboard URL comes from `openstack-web-base-url',
;; `openstack-id-prefix', the ID and `openstack-url-suffix'.
;;
;; Talking to OpenStack goes through the `openstack-cli' library
;; (see openstack-cli.el), which wraps `openstack-program' with
;; synchronous and asynchronous request functions.
;;
;; The file also holds the two layers that every resource type uses:
;;
;;   `openstack-list-mode' is the parent of the collection buffers
;;   (servers, volumes, images, networks, containers).  It derives
;;   from `tabulated-list-mode', so a table comes with a clickable
;;   column header, per-column sorting, column resizing and point
;;   keeping across refreshes.
;;
;;   `openstack-define-resource' writes a whole resource type from
;;   one form: the show mode, the list mode, their display commands,
;;   fetchers, renderers and defcustoms.  It also records the type in
;;   `openstack-resource-definitions' and appends its entry to
;;   `openstack-resource-types', which the ID prompts, the Org links
;;   and the xref backend read.  The resource types themselves live
;;   in openstack-resources.el, one macro call each, so a resource
;;   name appears once and the parts cannot drift.

;;; Code:

(require 'bookmark)
(require 'autorevert)
(require 'cl-lib)
(require 'tabulated-list)
(require 'thingatpt)
(require 'openstack-cli)

;; Forward reference: the desktop notification of a state change.
(declare-function notifications-notify "notifications" (&rest params))
;; Forward reference: the generated display commands complete their ID.
(declare-function openstack-read-id "openstack-read" (type &optional prompt))

(defun openstack--read-resource-id (type prompt)
  "Read the ID of resource TYPE, prompting with PROMPT.
Load the ID completion on demand, so the macro expansion calls one
function that this file declares, and the base mode keeps no hard
dependency on the prompt layer (see openstack-read.el)."
  (require 'openstack-read)
  (openstack-read-id type prompt))


;;; Customization

(defgroup openstack nil
  "Base major mode for displaying OpenStack resources."
  :prefix "openstack-"
  :group 'tools)

(defcustom openstack-buffer-name "*OpenStack Resource*"
  "Name prefix of the buffer used to display an OpenStack resource.
`openstack-display' appends the resource ID, so each resource gets
its own buffer; the same ID always reuses its buffer."
  :type 'string
  :group 'openstack)

(defcustom openstack-render-function #'openstack-render-default
  "Function used to render an OpenStack resource into the current buffer.
It is called with two arguments, the resource ID and the fetched
data, in the display buffer with `inhibit-read-only' bound to t.
Derived resource modes should set this (buffer-locally or
globally) to their own renderer instead of advising a private
function."
  :type 'function
  :group 'openstack)

(defcustom openstack-fetch-function #'openstack-fetch-default
  "Function used to fetch the data of the current buffer's resource.
It is called with three arguments: the resource ID, a success
callback and an error callback.  It must eventually call exactly
one of them: the success callback with the fetched data, or the
error callback with an error condition.  The fetch may complete
asynchronously; when it does, return its process object so that
killing the buffer can cancel the fetch.  Derived resource modes
should set this to their own fetcher, typically wrapping
`openstack-cli-async-request'."
  :type 'function
  :group 'openstack)

(defcustom openstack-auto-revert t
  "Whether resource buffers refresh themselves with `auto-revert-mode'.
When non-nil, `openstack-mode' enables `auto-revert-mode', which
re-fetches the resource through `openstack-fetch-function' and
re-renders the buffer when the data changed.  The fetch is
asynchronous, so the refresh never blocks Emacs."
  :type 'boolean
  :group 'openstack)

(defcustom openstack-refresh-interval 30
  "Minimum seconds between automatic refreshes of a resource buffer.
Automatic refreshing (see `openstack-auto-revert') re-fetches a
buffer only when the last fetch is at least this old.  A manual
\\[revert-buffer] always fetches."
  :type 'number
  :group 'openstack)

(defcustom openstack-refresh-fast-interval 5
  "Minimum seconds between refreshes while a status still changes.
A buffer whose status belongs to `openstack-transitional-states'
polls with this interval; every other buffer polls every
`openstack-refresh-interval' seconds.  A value above
`openstack-refresh-interval' never slows a refresh down."
  :type 'number
  :group 'openstack)

(defcustom openstack-transitional-states
  '("BUILD" "REBOOT" "DELETING" "REBUILD" "MIGRATING" "RESIZE"
    "BACKUP" "creating" "queued" "saving")
  "Status values that mark a resource as still changing.
The comparison ignores case, because `RESOURCE show' and
`RESOURCE list' spell the same state differently.  A buffer
with such a status refreshes every
`openstack-refresh-fast-interval' seconds."
  :type '(repeat string)
  :group 'openstack)

(defcustom openstack-refresh-visible-only t
  "Whether automatic refreshes skip buffers no window displays.
When non-nil (the default), `auto-revert-mode' re-fetches a
resource buffer only while it is visible somewhere; buried
buffers cost no API calls and refresh when next displayed.  A
manual \\[revert-buffer] always fetches."
  :type 'boolean
  :group 'openstack)

(defcustom openstack-web-base-url "https://horizon.example.org"
  "Base URL of the OpenStack dashboard for `openstack-open-web'.
The resource ID is appended to this URL."
  :type 'string
  :group 'openstack)

(defcustom openstack-id-prefix "resource"
  "Path segments identifying the resource type in the dashboard URL.
The segments follow `openstack-web-base-url' and precede the
resource ID.  A mode may use several segments, for example
project/networks."
  :type 'string
  :group 'openstack)

(defcustom openstack-url-suffix ""
  "Path segments appended after the resource ID in the dashboard URL.
Horizon shows many detail pages below a trailing segment, for
example project/networks/ID/detail; a mode for such a resource
sets this to /detail.  The default adds nothing."
  :type 'string
  :group 'openstack)

(defcustom openstack-show-command #'openstack-display
  "Command used by `openstack-display-at-point' to display a resource.
It is called with one argument, the resource ID at point.
Collection modes bind this buffer-locally to their resource's
display command (e.g. `openstack-server-display'), so a row in a
list buffer opens the right kind of show buffer."
  :type 'function
  :group 'openstack)

(defcustom openstack-resource-types nil
  "Resource types with a derived mode.
Each entry is a list of the type name, the mode that displays the
resource and the command that opens its display buffer.  Prompts,
Org links and xref navigation read this table.

The resource modes fill the table when they load: each one calls
`openstack-define-resource', which appends its entry.  The default
is therefore empty.  Add an entry here only for a mode that does
not use the macro."
  :type '(repeat (list (string :tag "Type")
                       (symbol :tag "Mode")
                       (symbol :tag "Display command")))
  :group 'openstack)

(defcustom openstack-status-fields '("status" "vm_state" "host_status"
                                     "health_status")
  "Fields rendered as a status in display buffers.
A value of such a field takes its face from
`openstack-status-faces'; the field name comparison ignores
case."
  :type '(repeat string)
  :group 'openstack)

(defcustom openstack-status-faces
  '(;; Healthy states.
    ("active" . openstack-status-ok)
    ("available" . openstack-status-ok)
    ("in-use" . openstack-status-ok)
    ("healthy" . openstack-status-ok)
    ("up" . openstack-status-ok)
    ;; Inactive states.
    ("down" . openstack-status-off)
    ("shutoff" . openstack-status-off)
    ("stopped" . openstack-status-off)
    ("paused" . openstack-status-off)
    ("suspended" . openstack-status-off)
    ("shelved" . openstack-status-off)
    ("shelved_offloaded" . openstack-status-off)
    ;; States that still change.
    ("build" . openstack-status-pending)
    ("building" . openstack-status-pending)
    ("reboot" . openstack-status-pending)
    ("rebuild" . openstack-status-pending)
    ("resize" . openstack-status-pending)
    ("resizing" . openstack-status-pending)
    ("migrating" . openstack-status-pending)
    ("deleting" . openstack-status-pending)
    ("creating" . openstack-status-pending)
    ("queued" . openstack-status-pending)
    ("saving" . openstack-status-pending)
    ("uploading" . openstack-status-pending)
    ("attaching" . openstack-status-pending)
    ("detaching" . openstack-status-pending)
    ("extending" . openstack-status-pending)
    ("maintenance" . openstack-status-pending)
    ("unknown" . openstack-status-pending)
    ("pending_delete" . openstack-status-pending)
    ;; Failure states.
    ("error" . openstack-status-error)
    ("error_deleting" . openstack-status-error)
    ("unhealthy" . openstack-status-error)
    ("killed" . openstack-status-error))
  "Faces of the status values in display buffers.
Each entry maps a status value to a face.  The comparison
ignores case, because `RESOURCE show' and `RESOURCE list' spell
the same state differently.  A value missing here keeps the
default face."
  :type '(repeat (cons (string :tag "Status") (symbol :tag "Face")))
  :group 'openstack)

;;; Faces

(defface openstack-status-ok
  '((t :inherit success))
  "Face for a status that needs no attention."
  :group 'openstack)

(defface openstack-status-pending
  '((t :inherit warning))
  "Face for a status that still changes."
  :group 'openstack)

(defface openstack-status-error
  '((t :inherit error))
  "Face for a status that reports a failure."
  :group 'openstack)

(defface openstack-status-off
  '((t :inherit shadow))
  "Face for a status that marks an inactive resource."
  :group 'openstack)

(defface openstack-field-changed
  '((t :inherit highlight))
  "Face for a field whose value changed since the last refresh."
  :group 'openstack)

(defface openstack-field-name
  '((t :inherit font-lock-variable-name-face))
  "Face for the field names of a resource display.
It inherits the font-lock face of variable names, so a theme
that styles code names styles these names too.  Set this face
alone to style the OpenStack displays without touching code
buffers."
  :group 'openstack)

(defface openstack-error
  '((t :inherit error))
  "Face for a fetch error, in the buffer, header line or mode line."
  :group 'openstack)


;;; Mode variables

(defvar-local openstack--id nil
  "ID of the OpenStack resource displayed in the current buffer.")
(put 'openstack--id 'permanent-local t)

(defvar-local openstack--origin-buffer nil
  "Buffer to return to with `openstack-pop'.")
(put 'openstack--origin-buffer 'permanent-local t)

(defvar-local openstack--pending nil
  "In-flight fetch of the current buffer, or nil when idle.
Non-nil while a fetch runs: t when the fetcher returned no
process handle, the process object otherwise (see
`openstack-fetch-function').")
;; `openstack--pending' survives `kill-all-local-variables' (run by
;; `define-derived-mode' when a derived mode supersedes this one) so
;; the new mode can cancel the old mode's fetch.  The cached view
;; below deliberately does not survive: the new mode's renderer must
;; draw its own.
(put 'openstack--pending 'permanent-local t)

(defvar-local openstack--fetch-marker nil
  "Identity marker of the fetch currently in flight.
The callbacks of `openstack--refresh' capture it and drop out
when it no longer matches: a fetch superseded by a mode change
must not render through the new mode's renderer nor clear its
state.")

(defvar-local openstack--refresh-requested nil
  "Non-nil when a refresh was requested while one was already running.
The request is served as soon as the running fetch completes, so
a manual refresh is never silently swallowed.")

(defvar-local openstack--last-data nil
  "Data rendered into the current buffer by the last refresh.")

(defvar-local openstack--rendered nil
  "Non-nil once `openstack-render-function' ran in this buffer.")

(defvar openstack--previous-data nil
  "Data rendered into the buffer by the previous refresh.
Bound around rendering by `openstack--refresh-done', so the
renderers can mark the fields whose value changed.  Deliberately
not buffer-local.")

(defvar openstack-state-change-functions nil
  "Abnormal hook run when a refresh changes a status value.
Each function receives a plist with :buffer, :id, :field, :old
and :new.  Add `openstack-notify-state-change' for messages and
desktop notifications.")

(defvar-local openstack--last-fetch-time nil
  "Time of the last fetch of the current buffer as a `float-time'.")

(defvar-local openstack--last-error nil
  "Error condition reported by the last fetch, or nil when none.")

(defvar-local openstack-error-display-function
    #'openstack--display-error-in-header
  "Function that shows the last fetch error in the current buffer.
It receives the error condition, or nil to clear the display.
The default writes the header line; `openstack-list-mode' replaces
it, because the tabulated list modes use the header line for the
column labels and report the error in the mode line instead.")

(defvar-local openstack-render-manages-buffer nil
  "Non-nil when `openstack-render-function' prints the whole buffer.
A tabulated list renderer erases the buffer and restores point by
row identity itself, so `openstack--refresh-done' must not erase
before the call nor move point after it.")

(defvar-local openstack-collection nil
  "Non-nil when the buffer displays a collection of resources.
Collections (e.g. a server list) have no single resource ID:
`openstack--id' stays nil, `openstack-fetch-function' receives
nil as the ID, and the ID commands (`openstack-copy-id' and
friends) do not apply.  Deliberately not `permanent-local': a
mode switch back to a single-resource view must clear it.")

(defvar openstack-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'openstack-copy-id)
    (define-key map (kbd "w") #'openstack-open-web)
    (define-key map (kbd "p") #'openstack-pop)
    (define-key map (kbd "RET") #'openstack-display-at-point)
    (define-key map [mouse-2] #'openstack-mouse-display-at-point)
    map)
  "Keymap for `openstack-mode'.

This keymap is used as the parent of the keymap installed by
`openstack-mode', which itself is a parent for derived
resource modes.  `q' and `g' are inherited from `special-mode'.
RET and `mouse-2' open the resource at point (a row in a
collection buffer).")

(defvar openstack-bookmark-handler 'openstack-bookmark-jump
  "Symbol of the bookmark handler for resource buffers.")

(defconst openstack--saved-id-suffix " ::OpenStack"
  "Suffix appended to the ID in the bookmark record.")

(defun openstack--error-string (err)
  "Return a short message for CLI error condition ERR.
The message carries the client's standard error when it exists,
and falls back to the error message of the condition."
  (format "OpenStack error: %s"
          (or (plist-get (cdr err) :stderr)
              (let ((data (cdr err)))
                (and (consp data)
                     (stringp (car data))
                     (car data)))
              (error-message-string err))))

(defun openstack--display-error-in-header (err)
  "Show fetch error ERR in the header line, or clear it when ERR is nil."
  (setq header-line-format
        (and err (propertize (openstack--error-string err)
                             'face 'openstack-error))))

(defun openstack--render-error (err)
  "Insert an error message for CLI condition ERR into the buffer.
ERR is an `openstack-cli-error' condition.  The message is
inserted in the error face so the user can see why a resource
failed to load."
  (let* ((msg (condition-case nil
                  (let ((data (cdr err)))
                    (format "%s" (plist-get data :stderr)))
                (error nil)))
         (text (or msg "Unknown OpenStack CLI error")))
    (insert (propertize text 'face 'openstack-error))))


;;; Helper functions

(defun openstack-resource-type (type)
  "Return the `openstack-resource-types' entry of resource TYPE."
  (assoc type openstack-resource-types))

(defun openstack-resource-type-for-mode (mode)
  "Return the resource type that MODE displays, or nil."
  (car (cl-find mode openstack-resource-types
                :key (lambda (entry) (nth 1 entry)))))

(defun openstack-dashboard-url (id)
  "Return the dashboard URL for resource ID.
ID is a string; the URL is built from
`openstack-web-base-url', `openstack-id-prefix', ID and
`openstack-url-suffix'.  The Org link export and the
`openstack:' URL handler of `openstack-url.el' call this
function, so every consumer builds the same URL."
  (format "%s/%s/%s%s"
          (string-trim-right openstack-web-base-url "/")
          (string-trim openstack-id-prefix "/" "/")
          id
          openstack-url-suffix))

(defun openstack--buffer-name-for-id (id)
  "Return the display buffer name for resource ID.
The name is `openstack-buffer-name' with ID appended, so distinct
resources do not overwrite each other's buffers."
  (format "%s <%s>" openstack-buffer-name id))

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
      ;; The live buffer object must not be stored: bookmark.el
      ;; warns against it (it dies with the session) and the jump
      ;; handler rebuilds the buffer from `openstack-id' anyway.
      (openstack-id . ,id)
      (handler . ,openstack-bookmark-handler))))

;;;###autoload
(defun openstack-bookmark-jump (bookmark)
  "Jump to the OpenStack resource described by BOOKMARK.
BOOKMARK is a bookmark record as created by
`openstack--bookmark-make-record'."
  (let ((id (bookmark-prop-get bookmark 'openstack-id)))
    (openstack-display id)))


;;; Identifier

(defun openstack--id-property-at-point ()
  "Return the `openstack-id' text property at point, or nil."
  (get-char-property (point) 'openstack-id))

(defun openstack-id-thing ()
  "Return the OpenStack resource ID at point, or nil.
Read the `openstack-id' text property of a rendered field or list
row first, then a UUID under point.  This function gives the
value of the `openstack-id' THING, so other packages read an ID
with (thing-at-point \='openstack-id)."
  (or (openstack--id-property-at-point)
      (thing-at-point 'uuid t)))

(defun openstack-id-bounds ()
  "Return the bounds of the OpenStack resource ID at point, or nil.
The bounds span the text that carries the `openstack-id' text
property, which is a whole list row or an ID field line.  Without
the property the bounds are those of the UUID under point."
  (if-let* ((id (openstack--id-property-at-point)))
      (let ((start (if (and (> (point) (point-min))
                            (equal id (get-char-property
                                       (1- (point)) 'openstack-id)))
                       (or (previous-single-property-change
                            (point) 'openstack-id nil (point-min))
                           (point-min))
                     (point)))
            (end (if (and (< (point) (point-max))
                          (equal id (get-char-property
                                     (1+ (point)) 'openstack-id)))
                     (or (next-single-property-change
                          (point) 'openstack-id nil (point-max))
                         (point-max))
                   (1+ (point)))))
        (cons start end))
    (bounds-of-thing-at-point 'uuid)))

(put 'openstack-id 'thing-at-point #'openstack-id-thing)
(put 'openstack-id 'bounds-of-thing-at-point #'openstack-id-bounds)

;;; Commands

(defun openstack-render-default (id data)
  "Insert the default display of resource ID into the current buffer.
DATA is ignored: the default renderer shows only the ID.  This is
the default value of `openstack-render-function'; derived modes
provide their own renderer by setting that variable."
  (ignore data)
  (insert (format "OpenStack resource\n\nID: %s\n" id)))

(defun openstack-fetch-default (_id success-fn _error-fn)
  "Fetch nothing and complete immediately with nil data.
This is the default value of `openstack-fetch-function'; derived
resource modes provide their own fetcher to pull resource data
with `openstack-cli-async-request'.  SUCCESS-FN is called with
nil; ERROR-FN is unused."
  (funcall success-fn nil))

(defun openstack--data-equal-p (a b)
  "Return non-nil when fetch results A and B have the same content.
Fetch results are parsed JSON: hash tables, lists, strings and
numbers.  `equal' compares hash tables by identity, so recurse
into their contents here; this is what lets
`openstack--refresh-done' skip re-rendering unchanged data."
  (cond
   ((and (hash-table-p a) (hash-table-p b))
    (and (= (hash-table-count a) (hash-table-count b))
         (catch 'unequal
           (maphash
            (lambda (key value)
              (unless (openstack--data-equal-p
                       value (gethash key b 'openstack--missing))
                (throw 'unequal nil)))
            a)
           t)))
   ((and (consp a) (consp b))
    (and (openstack--data-equal-p (car a) (car b))
         (openstack--data-equal-p (cdr a) (cdr b))))
   (t (equal a b))))

;; The client prints field names in lower case for `RESOURCE show'
;; and in title case for `RESOURCE list', so the status helpers
;; compare names and values without case.

(defun openstack--hash-field (table name)
  "Return the value of TABLE field NAME, ignoring key case.
Return nil when TABLE holds no key that matches NAME."
  (cl-loop for key being the hash-keys of table
           using (hash-value value)
           when (and (stringp key) (string-equal-ignore-case key name))
           return value))

(defun openstack--status-field-p (field)
  "Return non-nil when FIELD holds a status value."
  (cl-some (lambda (name) (string-equal-ignore-case name field))
           openstack-status-fields))

(defun openstack--status-face (field value)
  "Return the status face of FIELD with VALUE, or nil.
Only a field named in `openstack-status-fields' takes a face, and
`openstack-status-faces' supplies it."
  (when (and (stringp value) (openstack--status-field-p field))
    (cdr (assoc-string value openstack-status-faces t))))

(defun openstack--field-changed-p (field value)
  "Return non-nil when FIELD holds a VALUE other than last render."
  (and openstack--previous-data
       (hash-table-p openstack--previous-data)
       (not (openstack--data-equal-p
             value (gethash field openstack--previous-data)))))

(defun openstack--cell-face (field value changed)
  "Return the face list for FIELD with VALUE.
CHANGED marks a value that differs from the previous refresh, so
a status face and the change face combine."
  (let ((status (openstack--status-face field value)))
    (cond ((and changed status)
           (list 'openstack-field-changed status))
          (changed 'openstack-field-changed)
          (status status))))

(defun openstack--row-match (rows row)
  "Return the row of ROWS that carries the same ID as ROW, or nil."
  (when-let* ((id (and (hash-table-p row)
                       (openstack--hash-field row "id"))))
    (cl-find-if (lambda (other)
                  (and (hash-table-p other)
                       (equal id (openstack--hash-field other "id"))))
                rows)))

(defun openstack--row-status-changes (old-row row)
  "Return the status changes of OLD-ROW that ROW now shows.
Each element is a list of ID, FIELD, old value and new value."
  (let ((id (or (and (hash-table-p row) (openstack--hash-field row "id"))
                openstack--id)))
    (cl-loop for field in openstack-status-fields
             for old = (and (hash-table-p old-row)
                            (openstack--hash-field old-row field))
             for new = (and (hash-table-p row)
                            (openstack--hash-field row field))
             when (and (stringp old) (stringp new)
                       (not (string-equal old new)))
             collect (list id field old new))))

(defun openstack--status-changes (previous data)
  "Return the status changes between PREVIOUS and DATA.
PREVIOUS and DATA are the results of two consecutive refreshes: a
hash table for a resource buffer, a list of rows for a collection
buffer.  Each element is a list of ID, FIELD, old value and new
value."
  (cond
   ((and (hash-table-p previous) (hash-table-p data))
    (openstack--row-status-changes previous data))
   ((and (listp previous) (listp data))
    (let (changes)
      (dolist (row (cl-remove-if-not #'hash-table-p data)
                   (nreverse changes))
        (when-let* ((old-row (openstack--row-match previous row)))
          (dolist (change (openstack--row-status-changes old-row row))
            (push change changes))))))))

(defun openstack--notify-state-changes (data previous)
  "Run `openstack-state-change-functions' for the changes in DATA.
PREVIOUS holds the data of the last render.  Every status value
that differs calls the hook once, with the buffer, the resource
ID, the field and the old and the new value."
  (dolist (change (openstack--status-changes previous data))
    (pcase-let ((`(,_ ,field ,old ,new) change))
      (run-hook-with-args 'openstack-state-change-functions
                          :buffer (current-buffer)
                          :id (car change)
                          :field field
                          :old old
                          :new new))))

(defun openstack-notify-state-change (&rest plist)
  "Report one OpenStack state change from PLIST.
PLIST carries :buffer, :id, :field, :old and :new, as the
`openstack-state-change-functions' hook passes them.  Print a
message and, on a graphical display, send a desktop
notification."
  (let ((id (plist-get plist :id))
        (field (plist-get plist :field))
        (old (plist-get plist :old))
        (new (plist-get plist :new)))
    (message "OpenStack %s: %s %s to %s" id field old new)
    (when (display-graphic-p)
      (ignore-errors
        (notifications-notify
         :title (format "OpenStack %s %s" field new)
         :body (format "%s changed from %s to %s" id old new))))))

(defun openstack--transitional-state-p (state)
  "Return non-nil when STATE still changes."
  (and (stringp state)
       (cl-some (lambda (name) (string-equal-ignore-case name state))
                openstack-transitional-states)))

(defun openstack--transitional-row-p (row)
  "Return non-nil when a status field of ROW still changes."
  (and (hash-table-p row)
       (cl-some (lambda (field)
                  (openstack--transitional-state-p
                   (openstack--hash-field row field)))
                openstack-status-fields)))

(defun openstack--transitional-p (data)
  "Return non-nil when DATA holds a status that still changes.
DATA is the hash table of a resource or the list of rows of a
collection."
  (cond
   ((hash-table-p data) (openstack--transitional-row-p data))
   ((listp data) (cl-some #'openstack--transitional-row-p data))
   (t nil)))

(defun openstack--refresh-delay ()
  "Return the seconds to wait before the next automatic refresh.
A buffer with a status from `openstack-transitional-states' polls
every `openstack-refresh-fast-interval' seconds, up to the upper
bound of `openstack-refresh-interval'."
  (if (openstack--transitional-p openstack--last-data)
      (min openstack-refresh-fast-interval openstack-refresh-interval)
    openstack-refresh-interval))

(defun openstack--refresh ()
  "Fetch fresh data for the current buffer and render it.
Runs `openstack-fetch-function' with the resource ID and the two
callbacks that finish the refresh; the fetch may complete later
and must then call exactly one of them.  Collection buffers (see
`openstack-collection') refresh without an ID: their fetcher
receives nil.  Nothing happens when neither an ID nor the
 collection flag is set.  A refresh requested while a fetch is
already in flight is remembered and served when that fetch
completes.  A fetcher that signals counts as a failed fetch;
when the fetcher returns a process object, it is remembered so
`openstack--kill-pending' can cancel it."
  (cond
   ((and (null openstack--id) (not openstack-collection)) nil)
   (openstack--pending
    ;; A manual refresh during a running fetch must not be lost.
    (setq openstack--refresh-requested t))
   (t
    (let* ((buf (current-buffer))
           (id openstack--id)
           (marker (list nil))
           (settled nil))
      (setq openstack--pending t
            openstack--fetch-marker marker)
      (let ((handle
             (condition-case thrown
                 (funcall openstack-fetch-function
                          id
                          (lambda (data)
                            ;; Settled before done: `openstack--refresh-done'
                            ;; clears `openstack--pending', and the setq below
                            ;; must not resurrect it.
                            (setq settled t)
                            (openstack--refresh-done buf marker id data nil))
                          (lambda (err)
                            (setq settled t)
                            (openstack--refresh-done buf marker id nil err)))
               (error
                ;; A fetcher that signals must not freeze the buffer.
                (setq settled t)
                (openstack--refresh-done buf marker id nil thrown)
                nil))))
        (setq openstack--pending (and (not settled) (or handle t))))))))

(defun openstack--refresh-done (buf marker id data err)
  "Complete the fetch of BUF marked MARKER for ID with DATA or ERR.
Called by the callbacks of `openstack--refresh'.  ERR is the error
condition of a failed fetch: the last good content stays in the
buffer and the error goes to the buffer's status display (see
`openstack-error-display-function').  Rendering is skipped when
DATA has the same content as the previously rendered data,
keeping point, marks and window start intact.  A refresh
requested while this fetch ran is served now.  Do nothing when
BUF is already dead or when MARKER is stale, i.e. when the fetch
was superseded while it ran."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (eq marker openstack--fetch-marker)
        (setq openstack--pending nil
              openstack--fetch-marker nil
              openstack--last-fetch-time (float-time)
              openstack--last-error err)
        (funcall openstack-error-display-function err)
        (unless (or err
                    (and openstack--rendered
                         (openstack--data-equal-p data openstack--last-data)))
          (let ((openstack--previous-data
                 (and openstack--rendered openstack--last-data)))
            (setq openstack--last-data data
                  openstack--rendered t)
            (if openstack-render-manages-buffer
                ;; The renderer prints the buffer itself and keeps the
                ;; position by row identity: no erase, no point move.
                (funcall openstack-render-function id data)
              (let* ((window (get-buffer-window buf 0))
                     (point (point))
                     (start (and (window-live-p window)
                                 (window-start window))))
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (funcall openstack-render-function id data))
                (goto-char (min point (point-max)))
                (when (window-live-p window)
                  (set-window-start window (min start (point-max))))))
            (openstack--notify-state-changes data openstack--previous-data)))
        (when openstack--refresh-requested
          (setq openstack--refresh-requested nil)
          (openstack--refresh))))))

(defun openstack--buffer-stale-p (&optional _noconfirm)
  "Return non-nil when the resource display is due for a refresh.
Used as `buffer-stale-function' by `auto-revert-mode'.  A refresh
is due when none ran yet or when the last one is older than the
delay of `openstack--refresh-delay': `openstack-refresh-interval'
seconds, or `openstack-refresh-fast-interval' while a status
still changes.  An in-flight fetch is never interrupted, and with
`openstack-refresh-visible-only' a buffer that no window
displays is never stale."
  (and (not openstack--pending)
       (or (not openstack-refresh-visible-only)
           (get-buffer-window (current-buffer) t))
       (or (null openstack--last-fetch-time)
           (>= (- (float-time) openstack--last-fetch-time)
               (openstack--refresh-delay)))))

(defun openstack--kill-pending ()
  "Cancel an in-flight fetch and forget its handle.
Called from `kill-buffer-hook' and when entering the mode: a dead
buffer, or a new fetcher superseding the old one, must not leave
the fetcher's process running."
  (when (processp openstack--pending)
    (delete-process openstack--pending))
  (setq openstack--pending nil
        openstack--fetch-marker nil))
(put 'openstack--kill-pending 'permanent-local-hook t)

;;;###autoload
(defun openstack-display (id &optional mode)
  "Display the OpenStack resource with ID in a dedicated buffer.
The buffer is named by `openstack--buffer-name-for-id' and put into
MODE, defaulting to `openstack-mode'.  Derived modes are entered
by passing their symbol, which activates their specialized
fetcher and renderer (see `openstack-server-display').  The
content is fetched with `openstack-fetch-function' and rendered
with `openstack-render-function'; the fetch may complete later,
in which case the buffer fills in asynchronously."
  (interactive "sOpenStack resource ID: ")
  (let* ((buf (get-buffer-create (openstack--buffer-name-for-id id)))
         (origin (current-buffer)))
    (with-current-buffer buf
      (funcall (or mode #'openstack-mode))
      (setq-local openstack--id id)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    (pop-to-buffer buf)))

;;;###autoload
(defun openstack-copy-id ()
  "Copy the ID of the current OpenStack resource to the kill ring."
  (interactive)
  (let ((id (openstack--resource-id t)))
    (kill-new id)
    (message "Copied OpenStack resource ID: %s" id)))

;;;###autoload
(defun openstack-open-web ()
  "Open the dashboard page for the current OpenStack resource."
  (interactive)
  (browse-url (openstack-dashboard-url
               (openstack--resource-id t))))

;;;###autoload
(defun openstack-pop ()
  "Pop back to the buffer the resource was displayed from."
  (interactive)
  (let ((origin openstack--origin-buffer))
    (cond ((buffer-live-p origin)
           (pop-to-buffer origin))
          (t
           (user-error "The origin buffer for this resource is gone")))))

;;;###autoload
(defun openstack-set-id (id)
  "Set the ID of the current buffer's OpenStack resource to ID."
  (interactive "sOpenStack resource ID: ")
  (setq-local openstack--id id)
  (message "Set OpenStack resource ID: %s" id))

;;;###autoload
(defun openstack-display-at-point ()
  "Display the OpenStack resource whose ID is at point.
The ID is read from the `openstack-id' text property, which the
generic renderers attach to the ID field line and to the rows of
collection buffers.  The resource is opened with the buffer-local
`openstack-show-command' (a collection mode binds it to its
resource's display command), defaulting to `openstack-display'."
  (interactive)
  (let ((id (openstack--id-property-at-point)))
    (unless id
      (user-error "No OpenStack resource ID at point"))
    (funcall openstack-show-command id)))

;;;###autoload
(defun openstack-mouse-display-at-point (event)
  "Display the OpenStack resource at the position of mouse EVENT.
Like `openstack-display-at-point', but takes the position from
the click, which need not be point."
  (interactive "e")
  (let* ((position (event-end event))
         (window (posn-window position))
         (pos (posn-point position)))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char pos)
        (openstack-display-at-point)))))


;;; Generic resource fetch and render

(defun openstack-show-fetch (resource id success-fn error-fn)
  "Fetch the details of resource RESOURCE with ID for a display buffer.
RESOURCE is the client's resource command name, e.g. `server' or
`volume'.  Run `RESOURCE show ID' through
`openstack-cli-async-request' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error'
condition.  Return the client process, so the display machinery
can cancel the fetch.  Derived resource modes wrap this with
their own resource name as their `openstack-fetch-function'."
  (openstack-cli-async-request
   (list resource "show" id)
   :success-fn success-fn
   :error-fn error-fn))

(defun openstack--format-value (value)
  "Return the display text of one resource field VALUE.
Strings and numbers are shown as they are (an empty string as
a dash); booleans, lists, hash tables and anything else fall
back to their JSON encoding."
  (cond
   ((null value) "-")
   ((stringp value) (if (string-empty-p value) "-" value))
   ((numberp value) (number-to-string value))
   ((eq value t) "true")
   (t (json-encode value))))

(defun openstack--insert-field (field value &optional id width)
  "Insert one FIELD of a resource with its VALUE into the buffer.
When ID is non-nil, the value is propertized with `openstack-id'
and `mouse-face', so `openstack-display-at-point' can open the
resource from the ID field line.  WIDTH, when a number, gives the
column at which values start, so the field name gets padded with
spaces after its colon.  A status value takes its face from
`openstack-status-faces', and a value that differs from the
previous refresh takes `openstack-field-changed'."
  (let* ((text (openstack--format-value value))
         (name-width (string-width field))
         (face (openstack--cell-face
                field value (openstack--field-changed-p field value))))
    (when face
      (setq text (propertize text 'face face)))
    (when id
      (setq text (propertize text 'openstack-id id
                             'mouse-face 'highlight)))
    (insert (propertize field 'face 'openstack-field-name
                        'openstack-field field)
            ":"
            (make-string (if width
                             (1+ (- width name-width))
                           1)
                         ?\s)
            text "\n")))

(defun openstack-render-fields (title id data fields)
  "Insert a field table titled TITLE into the current buffer.
ID identifies the resource in the header (nil in collection
buffers); DATA is the parsed `RESOURCE show' JSON and FIELDS
the list of fields shown first, in that order.  Fields missing
from the data are skipped; every remaining field follows,
sorted by name, and nested values render as JSON.  Every value
starts at one column, one space past the longest field name, so
the table lines up.  Derived resource modes call this from
their `openstack-render-function' with their own field order."
  (insert (format "%s: %s\n" title
                  (or (and (hash-table-p data) (gethash "name" data))
                      id)))
  (when id
    (insert (propertize "ID" 'face 'openstack-field-name)
            ": " (propertize id 'openstack-id id
                            'mouse-face 'highlight)
            "\n\n"))
  (when (hash-table-p data)
    (let ((unshown (make-hash-table :test #'equal))
          (rows nil))
      (maphash (lambda (key _value) (puthash key t unshown)) data)
      (dolist (field fields)
        (remhash field unshown)
        (let ((value (gethash field data)))
          (when value
            (push (list field value
                        (and id (string= field "id") id))
                  rows))))
      (let ((remaining nil))
        (maphash (lambda (key _value) (push key remaining)) unshown)
        (dolist (field (sort remaining #'string<))
          (push (list field (gethash field data)
                      (and id (string= field "id") id))
                rows)))
      (setq rows (nreverse rows))
      (let ((width (apply #'max 0
                          (mapcar (lambda (row)
                                    (string-width (nth 0 row)))
                                  rows))))
        (dolist (row rows)
          (openstack--insert-field
           (nth 0 row) (nth 1 row) (nth 2 row) width))))))

;;; Imenu

(defun openstack--imenu-index ()
  "Return an imenu index of the field lines of the current buffer.
Every `Field: value' line that the renderers write becomes an
entry, so `imenu' jumps to a field and `which-function-mode'
names the field at point."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((field (get-text-property (point) 'openstack-field)))
          (push (cons field (point)) index))
        (forward-line 1)))
    (nreverse index)))

;;; Collection helpers

;; The table renderer and the collection base mode live further down
;; in this file, after the base mode: `openstack-list-mode' derives
;; from `tabulated-list-mode' and calls
;; `openstack--init-display-buffer'.

;;; Major mode

(defun openstack--init-display-buffer ()
  "Prepare the current buffer for displaying OpenStack data.
Shared by `openstack-mode' and `openstack-list-mode': it cancels a
fetch left over from a previous mode, wires the asynchronous
refresh into `revert-buffer', bookmark and `auto-revert-mode'.
A caller runs it after its parent mode, so these settings win
over the parent's own `revert-buffer-function'."
  (openstack--kill-pending)
  (setq-local revert-buffer-function #'openstack--revert-buffer)
  (setq-local buffer-stale-function #'openstack--buffer-stale-p)
  ;; A narrow table truncates the ID text but keeps the full ID in
  ;; the `openstack-id' property, so the `uuid' thing reads the
  ;; property here.  The thing itself already serves `openstack-id'.
  (setq-local thing-at-point-provider-alist
              (cons '(uuid . openstack-id-thing)
                    thing-at-point-provider-alist))
  (add-hook 'kill-buffer-hook #'openstack--kill-pending nil t)
  (when openstack-auto-revert
    ;; A refresh is asynchronous and invisible: the auto-revert
    ;; "Reverting buffer ..." message would only spam the echo area.
    (setq-local auto-revert-verbose nil)
    (auto-revert-mode 1)))

;;;###autoload
(define-derived-mode openstack-mode special-mode
  "OpenStack Resource"
  "Display an OpenStack resource in the current buffer.
This is the base mode for OpenStack resource display.  It
provides ID handling: copy the ID, open the dashboard page, and
pop back to the origin buffer.

This mode is intended as a parent for resource-specific derived
modes; they inherit the ID handling and only override fetching
and rendering by setting `openstack-fetch-function' and
`openstack-render-function' to their own functions.

The renderers attach an `openstack-id' text property to the ID
field lines and to the rows of collection buffers: RET or
`mouse-2' there opens the resource with the buffer-local
`openstack-show-command' (`openstack-display-at-point')."
  :group 'openstack
  ;; Entering the mode again (a derived mode superseding this one,
  ;; or `openstack-display' on an existing buffer) replaces the
  ;; fetcher and renderer: cancel any in-flight fetch so the buffer
  ;; starts from a clean slate.
  (openstack--init-display-buffer)
  (setq-local imenu-create-index-function #'openstack--imenu-index)
  ;; A resource buffer bookmarks its ID; a collection buffer has none.
  (setq-local bookmark-make-record-function
              #'openstack--bookmark-make-record))

(defun openstack--revert-buffer (&rest _args)
  "Re-fetch and re-render the current OpenStack resource.
Ignoring ARGS, as required by `revert-buffer-function'.  The
refresh is asynchronous: this function returns immediately and
the buffer updates when `openstack-fetch-function' delivers data."
  (openstack--refresh))


;;; Collection buffers

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
    (browse-url (openstack-dashboard-url id))))

;;; Imenu

(defun openstack-list--imenu-index ()
  "Return an imenu index of the rows of the current table.
Name every row by its name field and its ID, so `imenu' and
`consult-imenu' jump straight to a resource."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((id (get-text-property (point) 'openstack-id)))
          (let* ((row (and (hash-table-p openstack-list--rows)
                           (gethash id openstack-list--rows)))
                 (name (and row (openstack--hash-field row "Name")))
                 (label (if (and (stringp name)
                                 (not (string-empty-p name))
                                 (not (equal name id)))
                            (format "%s (%s)" name id)
                          id)))
            (push (cons label (point)) index)))
        (forward-line 1)))
    (nreverse index)))

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
                        'face 'openstack-error))))

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
  (setq-local imenu-create-index-function #'openstack-list--imenu-index)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (openstack-list--mode-line)))))
  (hl-line-mode 1))


;;; Resource definitions

(defvar openstack-resource-definitions nil
  "Alist of resource type to the definition plist of that type.
`openstack-define-resource' fills it when a resource file loads.
Each plist holds :type, :cli, :noun, :id-prefix, :url-suffix,
:fields, :list-fields, :list-arguments, :mode, :display, :list-mode
and :list-display.  The registry is the single source of truth for
the resource names: `openstack-resource-types' is its view for the
ID prompts, the Org links and the xref backend.")

(defun openstack-resource-definition (type)
  "Return the definition plist of resource TYPE, or nil."
  (alist-get type openstack-resource-definitions nil nil #'equal))

(defun openstack-resource-cli-name (type)
  "Return the client resource command name of resource TYPE.
The type string is the command name, unless the definition sets a
different :cli value."
  (or (plist-get (openstack-resource-definition type) :cli) type))

(defun openstack--register-resource (type definition)
  "Record resource TYPE with the definition plist DEFINITION.
Store the plist in `openstack-resource-definitions', and append
TYPE to `openstack-resource-types' unless an entry exists there
already.  An existing entry stays, so a user customization does not
lose the display command it names."
  (let ((cell (assoc type openstack-resource-definitions)))
    (if cell
        (setcdr cell definition)
      (setq openstack-resource-definitions
            (append openstack-resource-definitions
                    (list (cons type definition))))))
  (unless (assoc type openstack-resource-types)
    (setq openstack-resource-types
          (append openstack-resource-types
                  (list (list type
                              (plist-get definition :mode)
                              (plist-get definition :display))))))
  definition)

(defun openstack-define-resource--value (properties key &optional default)
  "Return the value of a property of PROPERTIES, the macro argument plist.
Read the form stored under KEY, and return DEFAULT when
PROPERTIES holds no KEY.  Evaluate the form, so a quoted list in the
macro call arrives here as a list."
  (let ((form (plist-get properties key)))
    (if (null form) default (eval form t))))

(defun openstack-define-resource--fill (text)
  "Return TEXT with its lines wrapped to fit a docstring.
The type name goes into the text, so a long resource name would
push a line past the byte-compiler's limit without the fill."
  (with-temp-buffer
    (insert text)
    (let ((fill-column 74))
      (fill-region (point-min) (point-max)))
    (buffer-string)))

(defun openstack-define-resource--doc (format-string &rest args)
  "Return the docstring of FORMAT-STRING applied to ARGS, wrapped.
The macro passes FORMAT-STRING and its ARGS, so every generated
docstring reaches the byte-compiler in a form that respects the
line limit."
  (openstack-define-resource--fill (apply #'format format-string args)))

(defmacro openstack-define-resource (type &rest properties)
  "Define the show and list modes of the OpenStack resource TYPE.
TYPE is the client's resource command name as a string, for example
\"server\" or \"container\".  Every symbol the macro defines starts
with `openstack-TYPE': the show and list modes, their display
commands, fetchers, renderers and the defcustoms of their buffer
names, field orders and client arguments.

PROPERTIES is a plist with these keys:

  :noun          plural resource name, default TYPE plus \"s\"
  :cli           client resource command, default TYPE
  :id-prefix     leading dashboard URL segments, default :cli
  :url-suffix    trailing dashboard URL segments, default \"\"
  :fields        fields rendered first by the show mode
  :list-fields   columns shown first by the list mode
  :list-arguments  extra client arguments of `RESOURCE list'

The macro records the definition in `openstack-resource-definitions'
and adds its entry to `openstack-resource-types', so the ID prompts,
the Org links and the xref backend learn about the new type."
  (declare (indent 1) (debug (stringp &rest sexp)))
  (let* ((type (eval type t))
         (cli (openstack-define-resource--value properties :cli type))
         (noun (openstack-define-resource--value properties :noun
                                                 (concat type "s")))
         (id-prefix (openstack-define-resource--value properties :id-prefix
                                                      cli))
         (url-suffix (openstack-define-resource--value properties
                                                       :url-suffix ""))
         (fields (openstack-define-resource--value properties :fields))
         (list-fields (openstack-define-resource--value properties
                                                        :list-fields))
         (list-arguments (openstack-define-resource--value properties
                                                          :list-arguments))
         (title (capitalize type))
         (plural (capitalize noun))
         (base (format "openstack-%s" type))
         (buffer-name (intern (format "%s-buffer-name" base)))
         (fields-var (intern (format "%s-fields" base)))
         (fetch (intern (format "%s--fetch" base)))
         (render (intern (format "%s--render" base)))
         (display (intern (format "%s-display" base)))
         (mode (intern (format "%s-mode" base)))
         (list-buffer-name (intern (format "%s-list-buffer-name" base)))
         (list-fields-var (intern (format "%s-list-fields" base)))
         (list-arguments-var (intern (format "%s-list-arguments" base)))
         (list-fetch (intern (format "%s-list--fetch" base)))
         (list-columns (intern (format "%s-list--columns" base)))
         (list-render (intern (format "%s-list--render" base)))
         (list-display (intern (format "%s-list-display" base)))
         (list-mode (intern (format "%s-list-mode" base)))
         (list-group (intern (format "%s-list" base))))
    `(progn
       (defcustom ,buffer-name
         ,(openstack-define-resource--doc "*OpenStack %s*" title)
         ,(openstack-define-resource--doc "Name prefix of the buffer used to display an OpenStack %s.
`%s' appends the %s ID, so each %s gets its own buffer; the same
ID always reuses its buffer." type display type type)
         :type 'string
         :group 'openstack)

       (defcustom ,fields-var
         ',fields
         ,(openstack-define-resource--doc "Fields shown first, in this order, by `%s'.
Fields missing from the %s data are skipped; every other field of
`openstack %s show' is rendered after them, sorted by name."
                  mode type cli)
         :type '(repeat string)
         :group 'openstack)

       (defun ,fetch (id success-fn error-fn)
         ,(openstack-define-resource--doc "Fetch the data of %s ID with `openstack-show-fetch'.
Run `openstack %s show ID' and call SUCCESS-FN with the parsed
JSON, or ERROR-FN with an `openstack-cli-error' condition.  Return
the client process, so the display machinery can cancel the fetch.
This is the value of `openstack-fetch-function' in `%s'."
                  type cli mode)
         (openstack-show-fetch ,cli id success-fn error-fn))

       (defun ,render (id data)
         ,(openstack-define-resource--doc "Insert the display of %s ID with DATA into the buffer.
DATA is the parsed `openstack %s show' JSON, rendered by
`openstack-render-fields' with the field order of `%s'.  This is
the value of `openstack-render-function' in `%s'."
                  type cli fields-var mode)
         (openstack-render-fields ,title id data ,fields-var))

       (defun ,display (id)
         ,(openstack-define-resource--doc "Display the OpenStack %s with ID in a dedicated buffer.
The buffer is named by `%s' and put into `%s', which fetches the
%s with `openstack %s show' and renders its fields.  The fetch is
asynchronous: the buffer fills in when the client delivers data,
and keeps itself up to date afterwards."
                  type buffer-name mode type cli)
         (interactive (list (openstack--read-resource-id
                             ,type
                             ,(openstack-define-resource--doc "OpenStack %s ID: "
                                                              type))))
         (let ((openstack-buffer-name ,buffer-name))
           (openstack-display id #',mode)))

       (define-derived-mode ,mode openstack-mode
         ,title
         ,(openstack-define-resource--doc "Major mode for displaying an OpenStack %s resource.
Derives from `openstack-mode', inheriting the ID handling, the
refresh pipeline and bookmark support.  Fetching and rendering are
set buffer-locally to the %s-specific fetcher and renderer; they
can be overridden globally like any other `openstack-mode' buffer.
The dashboard URL uses the `%s' prefix." type type id-prefix)
         (setq-local openstack-fetch-function #',fetch)
         (setq-local openstack-render-function #',render)
         (setq-local openstack-id-prefix ,id-prefix)
         (setq-local openstack-url-suffix ,url-suffix))

       (defgroup ,list-group nil
         ,(openstack-define-resource--doc "Display OpenStack %s lists in Emacs." type)
         :prefix ,(openstack-define-resource--doc "%s-list-" base)
         :group 'openstack)

       (defcustom ,list-buffer-name
         ,(openstack-define-resource--doc "*OpenStack %s*" plural)
         ,(openstack-define-resource--doc "Name of the buffer listing OpenStack %s.
The list shows all %s, so unlike single-resource buffers the name
carries no ID suffix." noun noun)
         :type 'string
         :group ',list-group)

       (defcustom ,list-fields-var
         ',list-fields
         ,(openstack-define-resource--doc "Columns shown first, in this order, by `%s'.
Columns missing from the data are skipped; every remaining field is
appended, sorted by name." list-mode)
         :type '(repeat string)
         :group ',list-group)

       (defcustom ,list-arguments-var
         ',list-arguments
         ,(openstack-define-resource--doc "Extra client arguments of `openstack %s list'.
The list fetcher appends them to the command; the default asks for
nothing beyond the client's own default output." cli)
         :type '(repeat string)
         :group ',list-group)

       (defun ,list-fetch (id success-fn error-fn)
         ,(openstack-define-resource--doc "Fetch all %s with `openstack %s list' asynchronously.
The ID argument is ignored: a collection buffer has no single
resource ID.  The list runs with the extra arguments of `%s'.
Call SUCCESS-FN with the parsed JSON (a list of %s hash tables), or
ERROR-FN with an `openstack-cli-error' condition.  Return the
client process, so the display machinery can cancel the fetch.
This is the value of `openstack-fetch-function' in `%s'."
                  noun cli list-arguments-var type list-mode)
         (openstack-list-fetch ,cli id success-fn error-fn
                               ,list-arguments-var))

       (defun ,list-columns (rows)
         ,(openstack-define-resource--doc "Return the table columns of ROWS in display order.
The fields of `%s' present in the data come first, in that order;
every remaining field of ROWS follows, sorted by name."
                  list-fields-var)
         (openstack-list-columns rows ,list-fields-var))

       (defun ,list-render (_id data)
         ,(openstack-define-resource--doc "Insert the table of %s DATA into the current buffer.
DATA is the parsed `openstack %s list' JSON, a list of hash tables.
The columns come from `%s', padded to the widest cell in each
column.  This is the value of `openstack-render-function' in `%s'."
                  noun cli list-fields-var list-mode)
         (openstack-list-render ,(openstack-define-resource--doc "(no %s)" noun) data
                                ,list-fields-var))

       (defun ,list-display ()
         ,(openstack-define-resource--doc "Display all OpenStack %s in a dedicated table buffer.
The buffer is named by `%s' and put into `%s', which fetches the
%s with `openstack %s list' and renders them as a table.  The fetch
is asynchronous: the buffer fills in when the client delivers
data, and keeps itself up to date afterwards."
                  noun list-buffer-name list-mode noun cli)
         (interactive)
         (let ((buf (get-buffer-create ,list-buffer-name))
               (origin (current-buffer)))
           (with-current-buffer buf
             (,list-mode)
             (setq-local openstack--origin-buffer origin)
             (openstack--refresh))
           (pop-to-buffer buf)))

       (define-derived-mode ,list-mode openstack-list-mode
         ,(openstack-define-resource--doc "OpenStack %s" plural)
         ,(openstack-define-resource--doc "Major mode for listing OpenStack %s.
Derives from `openstack-list-mode', a `tabulated-list-mode' for
OpenStack collections, so the table has a clickable column header,
per-column sorting and column resizing.  The buffer has no resource
ID and the ID commands do not apply.  The %s are fetched with
`openstack %s list' through the asynchronous CLI layer; RET or
`mouse-2' on a row opens the %s's show buffer (`%s')."
                  noun noun cli type display)
         (setq-local openstack-fetch-function #',list-fetch)
         (setq-local openstack-render-function #',list-render)
         (setq-local openstack-id-prefix ,id-prefix)
         (setq-local openstack-url-suffix ,url-suffix)
         (setq-local openstack-list--noun ,noun)
         (setq-local openstack-show-command #',display))

       (openstack--register-resource
        ,type
        (list :type ,type
              :cli ,cli
              :noun ,noun
              :id-prefix ,id-prefix
              :url-suffix ,url-suffix
              :fields ',fields
              :list-fields ',list-fields
              :list-arguments ',list-arguments
              :mode ',mode
              :display ',display
              :list-mode ',list-mode
              :list-display ',list-display)))))

;; The definitions in openstack-resources.el fill the type
;; registries, so an installed package loads them at startup.
;;;###autoload (require 'openstack-resources)

(provide 'openstack-mode)
;;; openstack-mode.el ends here
