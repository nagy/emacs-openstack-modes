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
;; not need to customize it.  The data entry points live in
;; openstack-data.el: this file adds the buffers that display their
;; answers.
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
;; Talking to OpenStack goes through the data layer of
;; openstack-data.el, which reads the registry and calls the client
;; library (see openstack-cli.el).  The synchronous and asynchronous
;; request functions of that library wrap `openstack-program'.
;;
;; The file also holds the two layers that every resource type uses:
;;
;;   `openstack-list-mode' is the parent of the collection buffers
;;   (servers, volumes, images, networks, projects, containers).  It
;;   derives from `tabulated-list-mode', so a table comes with a
;;   clickable column header, per-column sorting, column resizing and
;;   point keeping across refreshes.
;;
;; The buffer ladder has two directions.  `openstack-go-to-parent'
;; climbs one level: a resource buffer opens the collection of its
;; own type, and a scoped collection opens its parent resource.
;; `openstack-next-sibling' and `openstack-previous-sibling' walk
;; sideways inside one collection.  The open collection buffer holds
;; the order of its rows, so a walk reads that buffer and makes no
;; client call; a walk whose collection buffer is not open signals
;; `user-error' and names the missing view.
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
(require 'button)
(require 'cl-lib)
(require 'js)
(require 'json)
(require 'outline)
(require 'tabulated-list)
(require 'thingatpt)
(require 'openstack-data)

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

(defcustom openstack-status-fields '("status" "vm_state" "host_status"
                                     "health_status")
  "Fields rendered as a status in display buffers.
A value of such a field takes its face from
`openstack-status-faces'; the field name comparison ignores
case."
  :type '(repeat string)
  :group 'openstack)

(defcustom openstack-date-fields '("created_at" "updated_at"
                                   "launched_at" "terminated_at"
                                   "deleted_at" "timestamp")
  "Fields rendered as a date in display buffers.
A value of such a field takes the `openstack-date' face, which
inherits `org-date'; the field name comparison ignores case.
Set this to nil to render dates with the default face."
  :type '(repeat string)
  :group 'openstack)

(defcustom openstack-reference-fields
  '(("subnets" . "subnet")
    ("project_id" . "project")
    ("tenant_id" . "project"))
  "Fields whose values name other resources.
Each entry maps a show field name to the resource type of its
values.  The client reports such values as a list of IDs, as a
network lists the `subnets' it owns, or as one ID, as every
resource names its `project_id'.  The show renderer prints one ID
per line, each with the `openstack-id' face and the `openstack-id'
text property, so RET, a click or `push-button' opens the
referenced resource through the display command that
`openstack-resource-types' holds for its type.  A type without a
display command there signals a `user-error'.  The field name
comparison ignores case.  A list column still shows the IDs on
one line of text."
  :type '(alist :key-type (string :tag "Field")
                :value-type (string :tag "Type"))
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

(defface openstack-date
  '((t :inherit org-date))
  "Face for the value of a date field in display buffers.
It inherits `org-date', so a theme that styles Org dates styles
these dates too.  `openstack-date-fields' names the fields that
take this face."
  :group 'openstack)

(defface openstack-id
  '((t :inherit marginalia-number))
  "Face for a resource ID in display buffers.
It inherits `marginalia-number', so a theme that styles
Marginalia numbers styles these IDs too.  The renderers apply it
to the `ID' line of a show buffer, to the `id' field, to the
`ID' column of a resource list and to every ID of a field that
`openstack-reference-fields' names."
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
    (define-key map (kbd "J") #'openstack-json-view)
    (define-key map (kbd "TAB") #'openstack-toggle-section)
    (define-key map (kbd "p") #'openstack-pop)
    (define-key map (kbd "C-c C-n") #'openstack-next-sibling)
    (define-key map (kbd "C-c C-p") #'openstack-previous-sibling)
    (define-key map [mouse-9] #'openstack-next-sibling)
    (define-key map [mouse-8] #'openstack-previous-sibling)
    (define-key map [remap dired-jump] #'openstack-go-to-parent)
    (define-key map [remap dired-up-directory] #'openstack-go-to-parent)
    (define-key map (kbd "RET") #'openstack-display-at-point)
    (define-key map [mouse-2] #'openstack-mouse-display-at-point)
    map)
  "Keymap for `openstack-mode'.

This keymap is used as the parent of the keymap installed by
`openstack-mode', which itself is a parent for derived
resource modes.  `q' and `g' are inherited from `special-mode'.
RET and `mouse-2' open the resource at point (a row in a
collection buffer.  `dired-jump' and `dired-up-directory' climb
one level with `openstack-go-to-parent', so the keys that walk up
a directory tree walk up the resource hierarchy in these
buffers.  \\[openstack-next-sibling] and
\\[openstack-previous-sibling] walk to the next and the previous
resource of the same collection, and the back and forward mouse
buttons run the same two commands.")

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
      (openstack-mode . ,major-mode)
      (handler . ,openstack-bookmark-handler))))

;;;###autoload
(defun openstack-bookmark-jump (bookmark)
  "Jump to the OpenStack resource described by BOOKMARK.
BOOKMARK is a bookmark record as created by
`openstack--bookmark-make-record'.  The recorded mode renders the
buffer, so a server bookmark comes back as a server buffer; a
record of an older bookmark without a mode opens the base mode."
  (let ((id (bookmark-prop-get bookmark 'openstack-id))
        (mode (bookmark-prop-get bookmark 'openstack-mode)))
    (openstack-display id mode)))


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

;; The client prints field names in lower case for `RESOURCE show'
;; and in title case for `RESOURCE list', so the status helpers
;; compare names and values without case.

(defun openstack--status-field-p (field)
  "Return non-nil when FIELD holds a status value."
  (declare (side-effect-free t))
  (cl-some (lambda (name) (string-equal-ignore-case name field))
           openstack-status-fields))

(defun openstack--status-face (field value)
  "Return the status face of FIELD with VALUE, or nil.
Only a field named in `openstack-status-fields' takes a face, and
`openstack-status-faces' supplies it."
  (declare (side-effect-free t))
  (when (and (stringp value) (openstack--status-field-p field))
    (cdr (assoc-string value openstack-status-faces t))))

(defun openstack--field-changed-p (field value)
  "Return non-nil when FIELD holds a VALUE other than last render."
  (and openstack--previous-data
       (hash-table-p openstack--previous-data)
       (not (openstack--data-equal-p
             value (gethash field openstack--previous-data)))))

(defun openstack--date-field-p (field)
  "Return non-nil when FIELD holds a date value.
The client spells a list column with spaces where `RESOURCE show'
uses underscores, so both spellings match."
  (declare (side-effect-free t))
  (let ((name (string-replace " " "_" field)))
    (cl-some (lambda (other) (string-equal-ignore-case other name))
             openstack-date-fields)))

(defun openstack--id-field-p (field)
  "Return non-nil when FIELD names the ID of the resource.
`RESOURCE show' spells the field `id' and `RESOURCE list' spells
the column `ID', so the comparison ignores case."
  (declare (pure t) (side-effect-free t))
  (string-equal-ignore-case field "id"))

(defun openstack--reference-type (field)
  "Return the resource type that the values of FIELD name, or nil.
Read `openstack-reference-fields'; the field name comparison
ignores case."
  (declare (side-effect-free t))
  (cdr (assoc-string field openstack-reference-fields t)))

(defun openstack--cell-face (field value changed)
  "Return the face list for FIELD with VALUE.
CHANGED marks a value that differs from the previous refresh, so
a status, ID or date face and the change face combine."
  (declare (side-effect-free t))
  (let ((special (or (openstack--status-face field value)
                     (and (openstack--id-field-p field)
                          'openstack-id)
                     (and (stringp value)
                          (openstack--date-field-p field)
                          'openstack-date))))
    (cond ((and changed special)
           (list 'openstack-field-changed special))
          (changed 'openstack-field-changed)
          (special special))))

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
  (declare (side-effect-free t))
  (and (stringp state)
       (cl-some (lambda (name) (string-equal-ignore-case name state))
                openstack-transitional-states)))

(defun openstack--transitional-row-p (row)
  "Return non-nil when a status field of ROW still changes."
  (declare (side-effect-free t))
  (and (hash-table-p row)
       (cl-some (lambda (field)
                  (openstack--transitional-state-p
                   (openstack--hash-field row field)))
                openstack-status-fields)))

(defun openstack--transitional-p (data)
  "Return non-nil when DATA holds a status that still changes.
DATA is the hash table of a resource or the list of rows of a
collection."
  (declare (side-effect-free t))
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

;;; JSON view

(defvar-local openstack--json-buffer nil
  "JSON view buffer linked to this display buffer.
`openstack-json-view' sets it, and `openstack--refresh-done'
redraws the linked buffer after a fetch.")

(defvar-local openstack-json--source nil
  "OpenStack display buffer whose last fetch this JSON buffer shows.")

(defvar openstack-json-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `openstack-json-mode'.")

(defun openstack-json--buffer-name (source)
  "Return the JSON view buffer name for SOURCE."
  (format "%s JSON" (buffer-name source)))

(defun openstack-json--render (data &optional collection)
  "Replace the current buffer with DATA as pretty printed JSON.
COLLECTION marks DATA that a collection fetch returned, whose
empty nil result prints as an empty JSON array."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (and collection (null data))
        (insert "[]")
      (when data
        (insert (json-encode data))
        (json-pretty-print-buffer)))
    (goto-char (point-min))
    ;; A read-only view has nothing to save: keep the buffer out of
    ;; the modification state, so exiting asks no question.
    (set-buffer-modified-p nil)))

(defun openstack-json--redraw (source)
  "Redraw the JSON view linked to SOURCE from its last fetch."
  (when-let* ((json (buffer-local-value 'openstack--json-buffer source)))
    (when (buffer-live-p json)
      (with-current-buffer json
        (when (eq openstack-json--source source)
          (openstack-json--render
           (buffer-local-value 'openstack--last-data source)
           (buffer-local-value 'openstack-collection source)))))))

(defun openstack-json--revert (&rest _args)
  "Redraw the current JSON buffer from its OpenStack display buffer."
  (when (buffer-live-p openstack-json--source)
    (openstack-json--render
     (buffer-local-value 'openstack--last-data openstack-json--source)
     (buffer-local-value 'openstack-collection openstack-json--source))))

(define-derived-mode openstack-json-mode js-json-mode "OpenStack JSON"
  "Major mode for the JSON view of an OpenStack buffer.
The buffer shows the last fetch result of the OpenStack display
buffer in `openstack-json--source' as pretty printed JSON.  It
is read-only; `openstack-json-view' creates it, and a refresh of
the display buffer redraws it.

\\{openstack-json-mode-map}"
  :group 'openstack
  (openstack--detach-directory)
  (setq-local revert-buffer-function #'openstack-json--revert)
  (setq buffer-read-only t))

;;;###autoload
(defun openstack-json-view ()
  "Show the JSON data behind the current OpenStack buffer.
The new buffer holds the pretty printed JSON of the last fetch of
this buffer, whether it displays a resource or a collection.
The command reuses the buffer it created before: a second call
switches to that buffer instead of making another one, and a
refresh of this buffer redraws it."
  (interactive nil openstack-mode openstack-list-mode)
  (unless (derived-mode-p 'openstack-mode 'openstack-list-mode)
    (user-error "Not an OpenStack buffer"))
  (unless openstack--rendered
    (user-error "No OpenStack data to show yet"))
  (let* ((source (current-buffer))
         (name (openstack-json--buffer-name source))
         (buffer (get-buffer name)))
    (if (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (eq major-mode 'openstack-json-mode)))
        (with-current-buffer buffer
          (unless (eq openstack-json--source source)
            (setq-local openstack-json--source source)
            (openstack-json--render
             (buffer-local-value 'openstack--last-data source)
             (buffer-local-value 'openstack-collection source))))
      (setq buffer (get-buffer-create (generate-new-buffer-name name)))
      (with-current-buffer buffer
        (openstack-json-mode)
        (setq-local openstack-json--source source)
        (openstack-json--render
         (buffer-local-value 'openstack--last-data source)
         (buffer-local-value 'openstack-collection source))))
    (setq-local openstack--json-buffer buffer)
    (pop-to-buffer buffer)))

;;; Point keeping

;; A render erases the buffer, so `openstack--refresh-done' records the
;; line of point before the render and restores it after the render.
;; The record names the line and not a buffer position: the field name,
;; the resource ID of a field value or, for a line without an identity,
;; the text of the line and its ordinal among the equal lines above it.
;; So a refresh keeps the reader on the same field even when a field
;; appears above it, and a second window that shows the buffer keeps its
;; own place.

(defun openstack--line-property (property)
  "Return the first PROPERTY value of the current line, or nil."
  (declare (side-effect-free t))
  (let ((end (line-end-position))
        (position (line-beginning-position))
        (value nil))
    (while (and (not value) (< position end))
      (setq value (get-text-property position property))
      (unless value
        (setq position (next-single-property-change
                        position property nil end))))
    value))

(defun openstack--line-identity ()
  "Return the identity of the line of point, or nil.
The identity is a cons of a kind and a value: `field' and the
field name, `id' and the resource ID of a field value, or `text'
and the text of the line.  A line of whitespace alone has no
identity, because its text would match every blank line."
  (declare (side-effect-free t))
  (or (when-let* ((field (get-text-property (line-beginning-position)
                                            'openstack-field)))
        (cons 'field field))
      (when-let* ((id (openstack--line-property 'openstack-id)))
        (cons 'id id))
      (let ((text (string-trim-right
                   (buffer-substring-no-properties (line-beginning-position)
                                                   (line-end-position)))))
        (unless (string-empty-p text)
          (cons 'text text)))))

(defun openstack--identity-ordinal (identity)
  "Return the number of lines above point that carry IDENTITY.
The count is the ordinal of the line of point among the equal
identities of the buffer, so two records that share a key name
keep their own line."
  (declare (side-effect-free t))
  (let ((origin (line-beginning-position))
        (count 0))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) origin)
        (when (equal (openstack--line-identity) identity)
          (setq count (1+ count)))
        (forward-line 1)))
    count))

(defun openstack--point-record (&optional position)
  "Return a record of the line at POSITION, or nil.
POSITION defaults to point.  The record holds the identity of the
line, its ordinal among the equal identities above, the number of
lines from that line to the line of POSITION and the column of
POSITION.  A line without an identity leans on the nearest line
above that has one, so the record keeps the distance from that
line.  Return nil when no line of the buffer has an identity,
because then there is no place to keep."
  (let ((offset 0)
        column
        identity)
    (save-excursion
      (goto-char (or position (point)))
      (setq column (- (point) (line-beginning-position)))
      (beginning-of-line)
      (let ((done nil))
        (while (not done)
          (setq identity (openstack--line-identity))
          (cond (identity (setq done t))
                ((bobp) (setq done t))
                (t
                 (setq offset (1+ offset))
                 (forward-line -1))))))
    (when identity
      (list :identity identity
            :ordinal (openstack--identity-ordinal identity)
            :offset offset
            :column column))))

(defun openstack--identity-position (identity ordinal)
  "Return the start of the line that IDENTITY names at ORDINAL.
ORDINAL counts from zero among the lines that carry IDENTITY, so
two records that share a key name keep their own line.  Return
nil when the buffer holds no such line.  When it holds fewer
lines than ORDINAL, the last one answers, because a line can go
away between two refreshes and the reader stays in the same part
of the buffer."
  (declare (side-effect-free t))
  (let ((index 0)
        (found nil)
        (last nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (equal (openstack--line-identity) identity)
          (setq last (line-beginning-position))
          (unless (or found (< index ordinal))
            (setq found last))
          (setq index (1+ index)))
        (forward-line 1)))
    (or found last)))

(defun openstack--record-position (record)
  "Return the buffer position that RECORD names, or nil.
The position is the start of the line that the identity of RECORD
names, moved down by the recorded number of lines and set to the
recorded column.  A shorter line clips the column to its end."
  (when record
    (save-excursion
      (goto-char (point-min))
      (when-let* ((start (openstack--identity-position
                          (plist-get record :identity)
                          (plist-get record :ordinal))))
        (goto-char start)
        (forward-line (plist-get record :offset))
        (let ((column (plist-get record :column)))
          (unless (zerop column)
            (goto-char (min (+ (line-beginning-position) column)
                            (line-end-position)))))
        (point)))))

(defun openstack--restore-point (record)
  "Move point to the position that RECORD describes.
A nil RECORD moves point to the start of the buffer, because no
line carried an identity before the render."
  (goto-char (or (openstack--record-position record) (point-min))))

(defun openstack--window-records ()
  "Return the point record of every other window that shows the buffer.
Every window but the selected one contributes one cons of the
window and its record.  The selected window needs no entry,
because its point is the point of the buffer.  A window whose line
has no identity contributes a nil record."
  (let ((buffer (current-buffer))
        (selected (selected-window))
        records)
    (dolist (window (get-buffer-window-list buffer nil t))
      (unless (eq window selected)
        (push (cons window (openstack--point-record (window-point window)))
              records)))
    records))

(defun openstack--restore-window-points (records)
  "Move the point of every window of RECORDS to its recorded line.
A window whose line is gone shows the start of the buffer, and a
dead window stays alone."
  (dolist (record records)
    (let ((window (car record)))
      (when (window-live-p window)
        (set-window-point window
                          (or (openstack--record-position (cdr record))
                              (point-min)))))))

(defun openstack--refresh-done (buf marker id data err)
  "Complete the fetch of BUF marked MARKER for ID with DATA or ERR.
Called by the callbacks of `openstack--refresh'.  ERR is the error
condition of a failed fetch: the last good content stays in the
buffer and the error goes to the buffer's status display (see
`openstack-error-display-function').  Rendering is skipped when
DATA has the same content as the previously rendered data,
keeping point, marks and window start intact.  A render records the
line of point before it erases the buffer and restores that line
afterwards, so a field that appeared above point does not carry
the reader away; every other window that shows BUF keeps the line
of its own point.  A refresh requested while this fetch ran is
served now.  Do nothing when BUF is already dead or when MARKER
is stale, i.e. when the fetch was superseded while it ran."
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
              (let* ((record (openstack--point-record))
                     (windows (openstack--window-records))
                     (sections (openstack--collapsed-sections))
                     (window (get-buffer-window buf 0))
                     (start (and (window-live-p window)
                                 (window-start window))))
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (funcall openstack-render-function id data))
                (openstack--restore-sections sections)
                (openstack--restore-point record)
                (openstack--restore-window-points windows)
                (when (window-live-p window)
                  (set-window-start window (min start (point-max))))))
            (openstack--notify-state-changes data openstack--previous-data)
            ;; Rendering changed the text, not the user's file: a
            ;; read-only display buffer stays unmodified.
            (set-buffer-modified-p nil)
            (openstack-json--redraw buf)))
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
(defun openstack-buffer (id &optional mode)
  "Return the display buffer of the OpenStack resource with ID.
The buffer is named by `openstack--buffer-name-for-id' and put into
MODE, defaulting to `openstack-mode'.  Derived modes are entered by
passing their symbol, which activates their specialized fetcher and
renderer (see `openstack-server-display').  The content is fetched
with `openstack-fetch-function' and rendered with
`openstack-render-function'; the fetch may complete later, in which
case the buffer fills in asynchronously.  This function selects no
window, so a caller can read the buffer or show it itself; the
command `openstack-display' pops it."
  (let ((buf (get-buffer-create (openstack--buffer-name-for-id id)))
        (origin (current-buffer)))
    (with-current-buffer buf
      (funcall (or mode #'openstack-mode))
      (setq-local openstack--id id)
      (setq-local openstack--origin-buffer origin)
      (openstack--refresh))
    buf))

;;;###autoload
(defun openstack-display (id &optional mode)
  "Display the OpenStack resource with ID in a dedicated buffer.
The buffer comes from `openstack-buffer', which fetches the content
and keeps it up to date in MODE; this command pops it into a window."
  (interactive "sOpenStack resource ID: ")
  (pop-to-buffer (openstack-buffer id mode)))

;;;###autoload
(defun openstack-copy-id ()
  "Copy the ID of the current OpenStack resource to the kill ring."
  (interactive nil openstack-mode)
  (let ((id (openstack--resource-id t)))
    (kill-new id)
    (message "Copied OpenStack resource ID: %s" id)))

;;;###autoload
(defun openstack-open-web ()
  "Open the dashboard page for the current OpenStack resource."
  (interactive nil openstack-mode)
  (browse-url (openstack-dashboard-url
               (openstack--resource-id t))))

;;;###autoload
(defun openstack-pop ()
  "Pop back to the buffer the resource was displayed from."
  (interactive nil openstack-mode)
  (let ((origin openstack--origin-buffer))
    (cond ((buffer-live-p origin)
           (pop-to-buffer origin))
          (t
           (user-error "The origin buffer for this resource is gone")))))

;;;###autoload
(defun openstack-set-id (id)
  "Set the ID of the current buffer's OpenStack resource to ID."
  (interactive "sOpenStack resource ID: " openstack-mode)
  (setq-local openstack--id id)
  (message "Set OpenStack resource ID: %s" id))

;;;###autoload
(defun openstack-display-at-point ()
  "Display the OpenStack resource whose ID is at point.
The ID is read from the `openstack-id' text property, which the
generic renderers attach to the ID field line, to the IDs of a
`openstack-reference-fields' field and to the rows of collection
buffers.  A reference carries its resource type in the
`openstack-ref-type' property: when `openstack-resource-types'
holds a display command for that type, this command runs it, so
a subnet opens in a subnet buffer once its mode exists.  Every
other ID opens with the buffer-local `openstack-show-command',
which a collection mode binds to its resource's display command,
defaulting to `openstack-display'."
  (interactive nil openstack-mode openstack-list-mode)
  (let* ((id (openstack--id-property-at-point))
         (type (and id (get-char-property (point) 'openstack-ref-type)))
         (entry (and type (openstack-resource-type type))))
    (unless id
      (user-error "No OpenStack resource ID at point"))
    (cond ((null type) (funcall openstack-show-command id))
          (entry (funcall (nth 2 entry) id))
          (t (user-error "No display command for resource type %s"
                         type)))))

;;;###autoload
(defun openstack-mouse-display-at-point (event)
  "Display the OpenStack resource at the position of mouse EVENT.
Like `openstack-display-at-point', but takes the position from
the click, which need not be point."
  (interactive "e" openstack-mode openstack-list-mode)
  (let* ((position (event-end event))
         (window (posn-window position))
         (pos (posn-point position)))
    (with-current-buffer (window-buffer window)
      (save-excursion
        (goto-char pos)
        (openstack-display-at-point)))))


;;; Generic resource fetch and render

(defun openstack-show-fetch (type id success-fn error-fn)
  "Fetch the details of resource TYPE with ID for a display buffer.
TYPE names a key of `openstack-resource-definitions', e.g.
`server' or `volume'.  Run `RESOURCE show ID' through
`openstack-resource-show-async' and call SUCCESS-FN with the
parsed JSON, or ERROR-FN with an `openstack-cli-error' condition.
Return the client process, so the display machinery can cancel the
fetch.  Derived resource modes wrap this with their own type as
their `openstack-fetch-function'."
  (openstack-resource-show-async type id success-fn error-fn))

(defvar-local openstack-value-formatters nil
  "Alist of field name to formatter function for the show renderer.
A formatter converts a field value to display text and wins over
`openstack--format-value'.  Field names compare without case, so
`size' covers both the show field and a list column of that name.
A resource definition sets it through `:value-formatters'.")

(defun openstack--format-size (value)
  "Return byte count VALUE in human readable form.
A non-numeric VALUE falls back to `openstack--format-value'."
  (declare (side-effect-free t))
  (if (numberp value)
      (file-size-human-readable value)
    (openstack--format-value value)))

(defun openstack--plain-list-p (value)
  "Return non-nil when VALUE is a non-empty list of plain values.
A plain value is a string, a number, a boolean or nil.  A list
that holds a hash table or another list stays JSON."
  (declare (pure t) (side-effect-free t))
  (and (consp value)
       (seq-every-p (lambda (item)
                      (or (stringp item) (numberp item)
                          (eq item t) (null item)))
                    value)))

(defun openstack--format-value (value &optional field)
  "Return the display text of one resource field VALUE.
FIELD, when non-nil, looks up a formatter in
`openstack-value-formatters' first.  Strings and numbers are
shown as they are (an empty string as a dash); booleans and a
list of plain values such as the `tags' of an image print as
text; a field that `openstack-reference-fields' names prints
through `openstack--insert-references' instead; nested lists,
hash tables and anything else fall back to their JSON encoding."
  (declare (side-effect-free t))
  (let ((formatter (and field
                        (cdr (assoc (downcase field)
                                    openstack-value-formatters)))))
    (cond
     (formatter (funcall formatter value))
     ((null value) "-")
     ((stringp value) (if (string-empty-p value) "-" value))
     ((numberp value) (number-to-string value))
     ((eq value t) "true")
     ((openstack--plain-list-p value)
      (mapconcat #'openstack--format-value value ", "))
     (t (json-encode value)))))

;;; Text buttons

;; An ID in a display buffer is a text button of the type
;; `openstack-object'.  The type carries the mouse face, the follow link
;; rule and the action, so a renderer names no mouse face of its own and
;; the button works with `push-button', `C-h .' and `next-button'.  The
;; mode keymap keeps RET and `mouse-2'.  Button properties are plain
;; symbols here, because `define-button-type' reserves the keyword
;; `:type' and `:supertype' alone.  The type keeps no keymap, because an
;; inherited `button-map' would bind RET and TAB and shadow the mode
;; keymap of a list row.

(defun openstack--button-push (button)
  "Open the OpenStack resource of BUTTON.
A collection buffer opens the row of the table, and every other
buffer opens the resource at point, as `openstack-display-at-point'
documents."
  (when (or (integerp button) (markerp button))
    (goto-char button))
  (openstack-display-at-point))

(defun openstack--button-follow-mouse-1-p (_position)
  "Return non-nil when one click follows the button at POSITION.
A collection buffer keeps the left click for the selection of a
row, so a reader opens a row with RET or the middle button."
  (not (derived-mode-p 'openstack-list-mode)))

(define-button-type 'openstack-object
  'action #'openstack--button-push
  'face nil
  'mouse-face 'highlight
  'follow-link #'openstack--button-follow-mouse-1-p
  'keymap nil)

(defun openstack--buttonize (start end &optional help)
  "Make the text between START and END an OpenStack object button.
HELP is the text of the tooltip.  The text keeps its own faces,
because the type names no face."
  (make-text-button start end :type 'openstack-object 'help-echo help))

(defun openstack--button-string (text &optional help)
  "Return TEXT as an OpenStack object button.
HELP is the text of the tooltip."
  (declare (pure t) (side-effect-free t))
  (make-text-button text nil :type 'openstack-object 'help-echo help))

(defun openstack--insert-field (field value &optional id width)
  "Insert one FIELD of a resource with its VALUE into the buffer.
When ID is non-nil, the value becomes an `openstack-object' button
that carries `openstack-id', so `openstack-display-at-point' and
`push-button' open the resource from the ID field line.  WIDTH,
when a number, gives the column at which values start, so the
field name gets padded with spaces after its colon.  A status
value takes its face from `openstack-status-faces', a date field
named in `openstack-date-fields' takes `openstack-date', the `id'
field takes `openstack-id', and a value that differs from the
previous refresh takes `openstack-field-changed'."
  (let* ((text (openstack--format-value value field))
         (name-width (string-width field))
         (face (openstack--cell-face
                field value (openstack--field-changed-p field value))))
    (when face
      (setq text (propertize text 'face face)))
    (when id
      (setq text (openstack--button-string
                  (propertize text 'openstack-id id)
                  (format "Open %s" id))))
    (insert (propertize field 'face 'openstack-field-name
                        'openstack-field field)
            ":"
            (make-string (if width
                             (1+ (- width name-width))
                           1)
                         ?\s)
            text "\n")))

(defun openstack--insert-references (field values &optional width)
  "Insert FIELD, a resource ID or a list of them in VALUES.
VALUES is one ID string or a list of ID strings.  Every ID becomes
an `openstack-object' button that carries the `openstack-id' face,
the `openstack-id' text property and `openstack-ref-type' with the
resource type that `openstack-reference-fields' names for FIELD,
so RET, `mouse-2', a click and `push-button' open the referenced
resource.  WIDTH, when a number, gives the column at which values
start, so the field name gets padded with spaces after its colon
and the later IDs line up under the first one.  A list that
differs from the previous refresh takes `openstack-field-changed'
on every ID as well."
  (let* ((values (if (stringp values) (list values) values))
         (type (openstack--reference-type field))
         (face (if (openstack--field-changed-p field values)
                   '(openstack-field-changed openstack-id)
                 'openstack-id))
         (pad (make-string (if width
                               (1+ (- width (string-width field)))
                             1)
                           ?\s))
         (continuation (make-string (+ (string-width field) 1
                                       (string-width pad))
                                    ?\s))
         (first t))
    (dolist (value values)
      (insert (if first
                  (concat (propertize field 'face 'openstack-field-name
                                      'openstack-field field)
                          ":" pad)
                continuation))
      (insert (openstack--button-string
               (propertize (openstack--format-value value)
                           'face face
                           'openstack-id value
                           'openstack-ref-type type)
               (if type
                   (format "Open %s %s" type value)
                 (format "Open %s" value)))
              "\n")
      (setq first nil))))

(defun openstack--insert-properties (properties)
  "Insert PROPERTIES, a hash table of resource metadata, as a block.
The block starts with a `properties' line and closes the field
table.  Every key follows on its own indented line, sorted by
name, with its value aligned one column past the longest key.
The client flattens the Glance `locations' attribute into this
hash table, so a list of record values prints as a nested block.
The block is a foldable section."
  (insert (propertize "properties:"
                      'face 'openstack-field-name
                      'openstack-field "properties"
                      'openstack-section "properties")
          "\n")
  (let ((keys nil))
    (maphash (lambda (key _value) (push key keys)) properties)
    (setq keys (sort keys #'string<))
    (let ((width (apply #'max 0 (mapcar #'string-width keys))))
      (dolist (key keys)
        (let ((value (gethash key properties)))
          (if (openstack--record-list-p value)
              (openstack--insert-records key value 2)
            (insert "  ")
            (openstack--insert-field key value nil width)))))))

(defun openstack--record-list-p (value)
  "Return non-nil when VALUE is a non-empty list of hash tables."
  (and (listp value) value (seq-every-p #'hash-table-p value)))

(defun openstack--address-list-p (field value)
  "Return non-nil when FIELD names addresses and VALUE holds them.
VALUE is a hash table that maps a network name to a list of
address records, as `openstack server show' reports `addresses'."
  (declare (side-effect-free t))
  (and (hash-table-p value)
       (string-equal field "addresses")))

(defun openstack--address-strings (records)
  "Return the `addr' values of the address RECORDS, sorted.
Return nil when RECORDS is no list of address records or holds no
address."
  (declare (side-effect-free t))
  (when (openstack--record-list-p records)
    (let ((addresses (delq nil
                           (mapcar (lambda (record)
                                     (openstack-resource-field record "addr"))
                                   records))))
      (when addresses
        (sort addresses #'string<)))))

(defun openstack--insert-addresses (field networks)
  "Insert FIELD with NETWORKS, one network per indented line.
NETWORKS is a hash of network name to address records.  The
addresses of a network follow its name, sorted and separated by a
comma, aligned one column past the longest network name.  The
block is a foldable section."
  (insert (propertize (concat field ":")
                      'face 'openstack-field-name
                      'openstack-field field
                      'openstack-section field)
          "\n")
  (let ((names nil))
    (maphash (lambda (name _records) (push name names)) networks)
    (setq names (sort names #'string<))
    (let ((width (apply #'max 0 (mapcar #'string-width names))))
      (dolist (name names)
        (insert "  " (format (format "%%-%ds" width) name) ": "
                (or (mapconcat #'identity
                               (openstack--address-strings
                                (gethash name networks))
                               ", ")
                    "-")
                "\n")))))
(defun openstack--insert-records (field records &optional indent)
  "Insert FIELD, a list of RECORDS, as an indented block.
INDENT, the number of leading spaces, defaults to 0.  Every key of
every record follows on its own line, sorted by name, with a `- '
marker before the first key of each record and the values aligned
past the longest key.  A block at the start of a line is a
foldable section; a nested block stays inside the section of its
field."
  (setq indent (or indent 0))
  (let ((heading (concat field ":"))
        (properties (list 'face 'openstack-field-name
                          'openstack-field field)))
    (when (zerop indent)
      (setq properties (append properties
                               (list 'openstack-section field))))
    (insert (make-string indent ?\s)
            (apply #'propertize heading properties)
            "\n"))
  (let ((keys nil))
    (dolist (record records)
      (maphash (lambda (key _value) (cl-pushnew key keys :test #'equal))
               record))
    (setq keys (sort keys #'string<))
    (let ((width (apply #'max 0 (mapcar #'string-width keys))))
      (dolist (record records)
        (let ((first t))
          (dolist (key keys)
            (let ((value (gethash key record)))
              (when value
                (insert (make-string (if first (+ indent 2) (+ indent 4))
                                     ?\s))
                (when first (insert "- "))
                (openstack--insert-field key value nil width)
                (setq first nil)))))))))

(defun openstack--row-kind (field value)
  "Return the kind of the display row of FIELD with VALUE.
`properties' marks the metadata hash table that closes the
field table, `addresses' the hash of network name to address
records of a server, `records' a list of hash tables,
`references' a resource ID or a list of them, as
`openstack-reference-fields' names it, and nil a plain field
line."
  (declare (side-effect-free t))
  (cond
   ((and (hash-table-p value) (string-equal field "properties"))
    'properties)
   ((openstack--address-list-p field value)
    'addresses)
   ((openstack--record-list-p value)
    'records)
   ((and (openstack--reference-type field)
         (or (openstack--plain-list-p value)
             (and (stringp value) (not (string-empty-p value)))))
    'references)))

(defun openstack-render-fields-to-string (title id data fields)
  "Return a field table titled TITLE as a string.
ID identifies the resource in the header (nil in collection
buffers); DATA is the parsed `RESOURCE show' JSON and FIELDS
the list of fields shown first, in that order.  Fields missing
from the data are skipped; every remaining field follows,
sorted by name, and nested values render as JSON.  Every value
starts at one column, one space past the longest field name, so
the table lines up.  A hash-table `properties' value is the
last entry and prints as an indented `key: value' block; a
`locations' list of hash tables prints as an indented block of
records; a field named in `openstack-reference-fields' prints
one referenced ID per line.  The text carries the same faces and
`openstack-id' properties as the buffer view, because
`openstack-render-fields' inserts this string."
  (with-temp-buffer
    (let ((heading (format "%s: %s" title
                           (or (and (hash-table-p data) (gethash "name" data))
                               id))))
      (insert (propertize heading 'openstack-section heading) "\n"))
    (when id
      (insert (propertize "ID" 'face 'openstack-field-name)
              ": " (openstack--button-string
                     (propertize id 'face 'openstack-id
                                 'openstack-id id)
                     (format "Open %s" id))
              "\n\n"))
    (when (hash-table-p data)
      (let ((unshown (make-hash-table :test #'equal))
            (properties nil)
            (rows nil))
        (cl-labels
            ((add-row (field value)
               "Record FIELD with VALUE as a display row, or as PROPERTIES."
               (let ((kind (and value (openstack--row-kind field value))))
                 (if (eq kind 'properties)
                     (setq properties value)
                   (push (list field value
                               (and id (string= field "id") id)
                               kind)
                         rows)))))
          (maphash (lambda (key _value) (puthash key t unshown)) data)
          (dolist (field fields)
            (remhash field unshown)
            (let ((value (gethash field data)))
              (when value
                (add-row field value))))
          (let ((remaining nil))
            (maphash (lambda (key _value) (push key remaining)) unshown)
            (dolist (field (sort remaining #'string<))
              (add-row field (gethash field data)))))
        (setq rows (nreverse rows))
        (let ((width (apply #'max 0
                            (mapcar (lambda (row)
                                      (string-width (nth 0 row)))
                                    rows))))
          (dolist (row rows)
            (pcase (nth 3 row)
              ('records
               (openstack--insert-records (nth 0 row) (nth 1 row)))
              ('addresses
               (openstack--insert-addresses (nth 0 row) (nth 1 row)))
              ('references
               (openstack--insert-references (nth 0 row) (nth 1 row) width))
              (_
               (openstack--insert-field
                (nth 0 row) (nth 1 row) (nth 2 row) width)))))
        (when properties
          (openstack--insert-properties properties))))
    (buffer-string)))

(defun openstack-render-fields (title id data fields)
  "Insert a field table titled TITLE into the current buffer.
ID identifies the resource in the header (nil in collection
buffers); DATA is the parsed `RESOURCE show' JSON and FIELDS
the list of fields shown first, in that order.  Derived resource
modes call this from their `openstack-render-function' with their
own field order.  The text, its faces and its `openstack-id'
properties come from `openstack-render-fields-to-string', so a
caller without a buffer asks for the same text as a string."
  (insert (openstack-render-fields-to-string title id data fields)))

(defun openstack-resource-render (type data &optional id)
  "Return the display text of resource TYPE with DATA as a string.
DATA is the parsed JSON of `openstack-resource-show', or nil.  ID
names the resource in the header; it defaults to the id field of
DATA, then to its name field.  The field order and the value
formatters come from the definition, so this function and the show
mode of TYPE write the same text.  Signal
`openstack-resource-error' for an unknown TYPE."
  (let* ((definition (openstack--definition-or-error type))
         (formatters (plist-get definition :value-formatters))
         (id (or id
                 (openstack-resource-id data)
                 (openstack-resource-name data))))
    (let ((openstack-value-formatters formatters))
      (openstack-render-fields-to-string
       (capitalize type) id data (openstack-resource-fields type)))))

;;; Sections

;; A display buffer folds its blocks through `outline-minor-mode'.  A
;; heading is a line that carries the text property `openstack-section'
;; with the name of the block, and `outline-search-function' finds it,
;; so no heading needs a special character in its text.  Every block is
;; a top level block, so `outline-level' answers one for each of them.

(defun openstack--outline-search (&optional bound move backward looking-at)
  "Search for the next text property `openstack-section'.
BOUND, MOVE, BACKWARD and LOOKING-AT have the meaning that
`outline-search-function' documents."
  (outline-search-text-property 'openstack-section nil bound move backward
                                looking-at))

(defun openstack--section-headings ()
  "Return the start of every section heading of the current buffer.
The positions come in buffer order."
  (let (headings
        (position (point-min)))
    (save-excursion
      (while (< position (point-max))
        (when (get-text-property position 'openstack-section)
          (push position headings))
        (setq position (or (next-single-property-change
                            position 'openstack-section nil (point-max))
                           (point-max)))))
    (nreverse headings)))

(defun openstack--collapsed-sections ()
  "Return the names of the folded sections of the current buffer.
`openstack--refresh-done' reads this before it erases the buffer, so
a refresh keeps the fold of a reader."
  (when (bound-and-true-p outline-minor-mode)
    (let (names)
      (dolist (heading (openstack--section-headings))
        (save-excursion
          (goto-char heading)
          (when (outline-invisible-p (line-end-position))
            (push (get-text-property heading 'openstack-section) names))))
      names)))

(defun openstack--keep-final-newline-visible ()
  "Stop every fold of the current buffer from hiding the last newline.
`outline-hide-subtree' folds up to `point-max' for a section that
ends the buffer, and Emacs drops the line break of an invisible
newline, so the next block would draw on the row of the folded
heading."
  (when (eq (char-before (point-max)) ?\n)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (and (eq (overlay-get overlay 'invisible) 'outline)
                 (= (overlay-end overlay) (point-max)))
        (move-overlay overlay (overlay-start overlay)
                      (1- (point-max)))))))

(defun openstack--hide-section (name)
  "Fold the section NAME of the current buffer when it is present."
  (when-let* ((heading (seq-find
                        (lambda (position)
                          (equal (get-text-property
                                  position 'openstack-section)
                                 name))
                        (openstack--section-headings)))
              (inhibit-read-only t))
    (save-excursion
      (goto-char heading)
      (outline-hide-subtree)
      (openstack--keep-final-newline-visible))))

(defun openstack--restore-sections (names)
  "Fold the sections of NAMES in the current buffer."
  (dolist (name names)
    (openstack--hide-section name)))

(defun openstack--enclosing-section ()
  "Return the start of the heading of the section around point.
Return nil when point sits above the first section."
  (save-excursion
    (beginning-of-line)
    (if (get-text-property (point) 'openstack-section)
        (point)
      (when (outline-previous-heading)
        (point)))))

(defun openstack-toggle-section ()
  "Fold or unfold the OpenStack block around point.
A block is the title and the field table, the `properties' block or
a `locations' block.  The command works on every line of a block,
so a reader folds a long block from the middle of it."
  (interactive nil openstack-mode)
  (let ((heading (openstack--enclosing-section)))
    (unless heading
      (user-error "No OpenStack section at point"))
    (save-excursion
      (goto-char heading)
      (outline-toggle-children)
      (openstack--keep-final-newline-visible))))

;;; Imenu

(defun openstack--imenu-index ()
  "Return an imenu index of the sections and field lines of the buffer.
Every heading and every `Field: value' line that the renderers
write becomes an entry, so `imenu' jumps to a field or a block and
`which-function-mode' names it at point."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((get-text-property (point) 'openstack-section)
          (push (cons (get-text-property (point) 'openstack-section) (point))
                index))
         ((get-text-property (point) 'openstack-field)
          (push (cons (get-text-property (point) 'openstack-field) (point))
                index)))
        (forward-line 1)))
    (nreverse index)))

;;; Collection helpers

;; The table renderer and the collection base mode live further down
;; in this file, after the base mode: `openstack-list-mode' derives
;; from `tabulated-list-mode' and calls
;; `openstack--init-display-buffer'.

;;; Major mode

(defun openstack--detach-directory ()
  "Move the current buffer to the temporary directory.
A display buffer shows data from a cloud, not a file: it belongs
to no project, so `project.el', version control and language
servers stay out of it.  The local `default-directory' points at
the variable `temporary-file-directory'.  Every mode that creates
a buffer outside `openstack--init-display-buffer' calls this
function itself."
  (setq-local default-directory
              (file-name-as-directory temporary-file-directory)))

(defun openstack--init-display-buffer ()
  "Prepare the current buffer for displaying OpenStack data.
Shared by `openstack-mode' and `openstack-list-mode': it cancels a
fetch left over from a previous mode, wires the asynchronous
refresh into `revert-buffer', bookmark and `auto-revert-mode'.
A caller runs it after its parent mode, so these settings win
over the parent's own `revert-buffer-function'."
  (openstack--kill-pending)
  (openstack--detach-directory)
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
field lines, to the IDs of an `openstack-reference-fields' field
and to the rows of collection buffers: RET or `mouse-2' there
opens the resource with the buffer-local `openstack-show-command';
`openstack-display-at-point' carries it out."
  :group 'openstack
  ;; Entering the mode again (a derived mode superseding this one,
  ;; or `openstack-display' on an existing buffer) replaces the
  ;; fetcher and renderer: cancel any in-flight fetch so the buffer
  ;; starts from a clean slate.
  (openstack--init-display-buffer)
  (setq-local imenu-create-index-function #'openstack--imenu-index)
  ;; A heading carries `openstack-section', so the outline search finds
  ;; it and no heading needs a special character in its text.  Every
  ;; block is a top level block, so the level answers one.  The
  ;; renderers keep their own faces, so the outline highlight stays
  ;; off.
  (setq-local outline-search-function #'openstack--outline-search)
  (setq-local outline-level (lambda () 1))
  (setq-local outline-minor-mode-highlight nil)
  (outline-minor-mode 1)
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
table does not fit the window, and stops at this width or at the
width of the column label, whichever is wider, so every column
keeps a readable part of its value and its whole name."
  :type 'natnum
  :group 'openstack-list)

;;; Fetcher and columns

(defvar-local openstack-list--prefix-arguments nil
  "Extra client arguments that the last display command requested.
`openstack-list-fetch' appends them after the resource's
`:list-arguments'.  A display command sets them from its prefix
argument; `gr' and the automatic refresh keep them.")

(defvar-local openstack-list--scope nil
  "Parent that the rows of the current table belong to, or nil.
nil means that the table lists every resource of its type.  A
plist with these keys:

  :type       the resource type of the parent
  :id         the ID of the parent resource
  :arguments  extra client arguments that filter the rows by the
              parent

`openstack-go-to-parent' opens the parent resource from this
plist, and `openstack-list-fetch' appends the arguments, so `gr'
and the automatic refresh keep the scope.")

(defun openstack-list-fetch (resource _id success-fn error-fn &optional args)
  "Fetch all resources of RESOURCE type for a collection buffer.
RESOURCE names a key of `openstack-resource-definitions', e.g.
`server' or `volume'.  Run `RESOURCE list' through
`openstack-resource-list-async' and call SUCCESS-FN with the
parsed JSON (a list of resource hash tables), or ERROR-FN with
an `openstack-cli-error' condition.  ARGS appends extra client
arguments to the command, for a resource whose list needs an
option.  The buffer-local `openstack-list--prefix-arguments'
follow ARGS, so a display command can add the arguments of its
prefix argument.  The buffer-local `openstack-list--scope' also
follows, so a table filtered by a parent keeps that filter.
Return the client process,
so the display machinery can cancel the fetch.  The ID argument
is ignored: a collection buffer has no single resource ID.
Collection modes wrap this with their own resource type as their
`openstack-fetch-function'."
  (openstack-resource-list-async resource success-fn error-fn
                                 (append args
                                         (plist-get openstack-list--scope
                                                    :arguments)
                                         openstack-list--prefix-arguments)))

(defun openstack-list-columns (rows fields)
  "Return the table columns of ROWS in display order.
FIELDS names the columns shown first, in that order; every
remaining field of ROWS follows, sorted by name.  The field
names are the title-case names the client prints for lists,
for example `ID' or `Volume Type'."
  (declare (side-effect-free t))
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

;;; Collection bookmarks

(defconst openstack-list--saved-suffix " ::OpenStack list"
  "Suffix appended to the name of a collection bookmark.")

(defun openstack-list--bookmark-make-record ()
  "Return a bookmark record for the current collection buffer.
The record holds the resource type, the scope, the prefix
arguments and the sort key, so a jump reopens the table that the
user saved.  A collection has no resource ID, so the record of a
resource bookmark does not apply."
  (let* ((type (openstack-resource-type-for-mode major-mode))
         (definition (and type (openstack-resource-definition type))))
    (unless definition
      (user-error "This OpenStack buffer lists no resources"))
    `(,(format "%s%s" (capitalize (plist-get definition :noun))
               openstack-list--saved-suffix)
      (openstack-list-type . ,type)
      (openstack-list-scope . ,openstack-list--scope)
      (openstack-list-prefix-arguments . ,openstack-list--prefix-arguments)
      (openstack-list-sort-key . ,tabulated-list-sort-key)
      (handler . openstack-list-bookmark-jump))))

;;;###autoload
(defun openstack-list-bookmark-jump (bookmark)
  "Jump to the OpenStack collection described by BOOKMARK.
BOOKMARK is a bookmark record as created by
`openstack-list--bookmark-make-record'.  The display command of
the resource type opens the table, scoped and sorted as the record
says."
  (let* ((type (bookmark-prop-get bookmark 'openstack-list-type))
         (definition (and type (openstack-resource-definition type)))
         (display (plist-get definition :list-display))
         (prefix (bookmark-prop-get bookmark
                                    'openstack-list-prefix-arguments))
         (scope (bookmark-prop-get bookmark 'openstack-list-scope))
         (sort (bookmark-prop-get bookmark 'openstack-list-sort-key)))
    (unless display
      (user-error "Unknown OpenStack resource type: %s" type))
    (let ((buffer (funcall display (and prefix t) scope)))
      (with-current-buffer buffer
        (setq-local tabulated-list-sort-key sort)
        (when (bound-and-true-p openstack--rendered)
          (openstack-list--redraw)))
      buffer)))

;;; Going up one level

(defun openstack--display-command (type)
  "Return the display command that `openstack-resource-types' holds for TYPE."
  (declare (side-effect-free t))
  (nth 2 (openstack-resource-type type)))

(defun openstack-list--scope-buffer-name (base scope)
  "Return the buffer name of the collection named BASE with SCOPE.
A scoped table needs its own buffer, so two parents do not
overwrite each other's table."
  (declare (pure t) (side-effect-free t))
  (format "%s <%s>" base (plist-get scope :id)))

(defun openstack--parent-scope (type data)
  "Return the scope plist of resource TYPE with show DATA, or nil.
DATA is the parsed `RESOURCE show' JSON of the resource, which
holds the ID of the parent.  Return nil when the definition names
no parent.  Signal `user-error' when the definition names one but
DATA lacks its ID, so a climb never lands in an unscoped table by
accident."
  (when (openstack-resource-parent type)
    (let ((id (openstack-resource-parent-id type data)))
      (unless id
        (user-error "The parent of this OpenStack %s is not known yet" type))
      (list :type (openstack-resource-parent-type type)
            :id id
            :arguments (openstack-resource-parent-arguments type id)))))

(defun openstack--go-to-own-list ()
  "Display the collection buffer of the current resource buffer.
When the definition names a parent, the collection keeps that
parent as its scope, so the next climb opens the parent."
  (let* ((type (openstack-resource-type-for-mode major-mode))
         (list-display (and type
                            (plist-get (openstack-resource-definition type)
                                       :list-display))))
    (unless list-display
      (user-error "This OpenStack buffer lists no resources"))
    (funcall list-display nil
             (openstack--parent-scope type openstack--last-data))))

(defun openstack--go-to-scope ()
  "Display the parent resource of the current collection buffer."
  (let ((scope openstack-list--scope))
    (unless scope
      (user-error "This OpenStack list sits at the top level"))
    (let ((display (openstack--display-command (plist-get scope :type))))
      (unless display
        (user-error "No display command for resource type %s"
                    (plist-get scope :type)))
      (funcall display (plist-get scope :id)))))

;;;###autoload
(defun openstack-go-to-parent ()
  "Open the view one level above the current OpenStack buffer.
In a resource buffer, display the collection of the resource's own
type, filtered by the parent of the resource when the definition
names one; a second call then opens that parent.  The ladder of a
server runs server, server list of its project, project.  A
collection buffer without a scope sits at the top level and
signals `user-error'."
  (interactive nil openstack-mode openstack-list-mode)
  (cond
   ((derived-mode-p 'openstack-list-mode) (openstack--go-to-scope))
   ((derived-mode-p 'openstack-mode) (openstack--go-to-own-list))
   (t (user-error "This buffer displays no OpenStack resource"))))

;;; Sibling navigation

(defun openstack--collection-label (type scope)
  "Return the human name of the collection of TYPE with SCOPE.
SCOPE is the scope plist of the table, or nil for the top-level
table of TYPE.  The commands that need an open table name it in
their `user-error'."
  (declare (pure t) (side-effect-free t))
  (if scope
      (format "%s list of %s %s"
              type (plist-get scope :type) (plist-get scope :id))
    (format "%s list" type)))

(defun openstack--same-scope-p (one other)
  "Return non-nil when the scope plists ONE and OTHER name one parent.
The client arguments of the scope stay out of the comparison, so a
table keeps its identity across a fetch."
  (declare (pure t) (side-effect-free t))
  (equal (and one (list (plist-get one :type) (plist-get one :id)))
         (and other (list (plist-get other :type) (plist-get other :id)))))

(defun openstack--collection-buffer (type scope)
  "Return the open table buffer of TYPE with SCOPE, or nil.
The lookup reads the major mode and the scope of every buffer, so a
customized buffer name or a moved buffer still answers.  A table
without a scope is the top-level collection of TYPE."
  (let ((mode (plist-get (openstack-resource-definition type) :list-mode)))
    (and mode
         (seq-find (lambda (buffer)
                     (with-current-buffer buffer
                       (and (eq major-mode mode)
                            (openstack--same-scope-p openstack-list--scope
                                                     scope))))
                   (buffer-list)))))

(defun openstack-list--children ()
  "Return the IDs of the rows of the current table in display order.
The function reads the rows that the buffer shows, so the sort
column decides the order and a narrowed table reports what its
reader sees."
  (save-excursion
    (goto-char (point-min))
    (let (ids)
      (while (not (eobp))
        (when-let* ((id (openstack-list--id-at-point)))
          (push id ids))
        (forward-line 1))
      (nreverse ids))))

(defun openstack--sibling-collection ()
  "Return the collection that holds the siblings of the current resource.
The value is a plist with :type, the resource type of the buffer,
:label, the human name of the table, and :ids, the row IDs in
display order.  The table of the resource's own type holds the
siblings, scoped to the parent that `openstack-go-to-parent' names,
so the climb and the walk share one ladder.

Signal `user-error' when the buffer displays no resource, when the
definition names a parent but the data lacks its ID, and when the
table is not open."
  (let ((type (openstack-resource-type-for-mode major-mode)))
    (unless type
      (user-error "This OpenStack buffer holds no collection"))
    (let* ((scope (openstack--parent-scope type openstack--last-data))
           (label (openstack--collection-label type scope))
           (buffer (openstack--collection-buffer type scope)))
      (unless buffer
        (user-error "Open the %s first" label))
      (list :type type
            :label label
            :ids (with-current-buffer buffer
                   (openstack-list--children))))))

(defun openstack--display-sibling (type id)
  "Display the resource TYPE with ID and keep the origin of the walk.
`openstack-pop' returns to the buffer that started the walk, not to
the neighbour that the walk came from."
  (let ((display (plist-get (openstack-resource-definition type) :display))
        (origin openstack--origin-buffer))
    (unless display
      (user-error "No display command for resource type %s" type))
    (funcall display id)
    (when (and (buffer-live-p origin)
               (derived-mode-p 'openstack-mode)
               (not (eq openstack--origin-buffer origin)))
      (setq-local openstack--origin-buffer origin))))

(defun openstack--move-sibling (n)
  "Open the sibling N entries from the resource of the current buffer.
A negative N walks back.  Signal `user-error' when the sibling
collection is not open, when the resource is not a row of that
table, and when the walk leaves the collection."
  (let* ((collection (openstack--sibling-collection))
         (ids (plist-get collection :ids))
         (label (plist-get collection :label))
         (id (openstack--resource-id t))
         (position (seq-position ids id #'equal)))
    (unless ids
      (user-error "The %s holds no resources" label))
    (unless position
      (user-error "%s is not in the %s" id label))
    (let ((target (+ position n)))
      (unless (and (<= 0 target) (< target (length ids)))
        (user-error "No %s sibling for %s"
                    (if (> n 0) "next" "previous") id))
      (openstack--display-sibling (plist-get collection :type)
                                  (nth target ids)))))

;;;###autoload
(defun openstack-next-sibling (&optional n)
  "Open the N-th next resource of the collection of this buffer.
The collection is the table of the resource's own type, scoped to
its parent when the definition names one, so a walk stays inside
the project of a server.  The open table holds the order, so the
walk fetches nothing and the sort column of that table decides the
order.  N defaults to 1, and a negative N walks back.

Signal `user-error' when the buffer displays no resource, when the
table is not open, when the resource is not a row of that table,
and when the walk leaves the collection."
  (interactive "p" openstack-mode)
  (openstack--move-sibling (or n 1)))

;;;###autoload
(defun openstack-previous-sibling (&optional n)
  "Open the N-th previous resource of the collection of this buffer.
This is `openstack-next-sibling' with the opposite direction, so it
reads the same table.  N defaults to 1, and a negative N walks
forward."
  (interactive "p" openstack-mode)
  (openstack--move-sibling (- (or n 1))))

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
  (declare (pure t) (side-effect-free t))
  (cl-remove-if-not #'hash-table-p
                    (cond ((null rows) nil)
                          ((listp rows) rows)
                          (t (list rows)))))

(defun openstack-list--row-identity-field (row name)
  "Return the value of ROW field NAME when it is a non-empty string."
  (declare (side-effect-free t))
  (let ((value (openstack--hash-field row name)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun openstack-list--row-id (row number)
  "Return the identity of ROW, a string.
Use the resource ID of ROW, then its name, because a Swift
container has no UUID; use NUMBER for a row without either
field, so `tabulated-list-print' can find the row again."
  (declare (side-effect-free t))
  (or (openstack-list--row-identity-field row "ID")
      (openstack-list--row-identity-field row "Name")
      (format "row-%d" number)))

(defun openstack-list--row-index (rows)
  "Return a hash table that maps the row identities of ROWS to rows.
The sorters of `tabulated-list-format' receive entry identities
only, so they read the typed cell values through this index."
  (declare (side-effect-free t))
  (let ((index (make-hash-table :test #'equal))
        (number 0))
    (dolist (row rows index)
      (setq number (1+ number))
      (puthash (openstack-list--row-id row number) row index))))

(defun openstack-list--cell (row column)
  "Return the display text of ROW's COLUMN, with its face.
A status value takes its face from `openstack-status-faces', a
date column named in `openstack-date-fields' takes
`openstack-date', the `ID' column takes `openstack-id', and a
value that differs from the previous refresh takes
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
  (declare (pure t) (side-effect-free t))
  (and (string-match-p "\\`[+-]?[0-9]+\\(?:\\.[0-9]+\\)?\\'" string) t))

(defun openstack-list--value-lessp (a b)
  "Return non-nil when value A sorts before value B.
Numbers compare as numbers, numeric strings compare as numbers,
and every other pair compares as strings, ignoring case."
  (declare (side-effect-free t))
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
  (declare (side-effect-free t))
  (when-let* ((row (gethash (car entry) openstack-list--rows)))
    (gethash column row)))

(defun openstack-list--sorter (column)
  "Return the sort predicate of COLUMN.
The predicate compares typed values, so a numeric column sorts as
numbers.  Rows without a value sort last."
  (declare (side-effect-free t))
  (lambda (entry-a entry-b)
    (let ((a (openstack-list--sort-value column entry-a))
          (b (openstack-list--sort-value column entry-b)))
      (cond ((and a b) (openstack-list--value-lessp a b))
            ((null a) nil)
            (t t)))))

(defun openstack-list--numeric-column-p (rows column)
  "Return non-nil when every value in ROWS of COLUMN is a number.
An empty column does not count as numeric."
  (declare (side-effect-free t))
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

(defvar-local openstack-list--width-window nil
  "Window that decides the column widths, or nil before a render.
The buffer holds one `tabulated-list-format' for every window that
shows it, so one window decides the widths.  A render pins the
window that draws the table here, and a later resize reads the pin,
because a timer or a frame event never restyles the columns from a
window of another size.")

(defvar-local openstack-list--fit-width nil
  "Column budget of the last render, or nil before the first one.
A resize compares `openstack-list--available-width' with this value
before it redraws, so an event that changes no width reprints
nothing.")

(defun openstack-list--width-window (&optional hint)
  "Return the window whose width decides the column widths.
Prefer the pin in `openstack-list--width-window' while it still
shows the table, then HINT, then the selected window while it shows
the table, then the first window that shows it."
  (let ((shown (get-buffer-window-list (current-buffer) nil t)))
    (cond
     ((memq openstack-list--width-window shown)
      openstack-list--width-window)
     ((memq hint shown) hint)
     ((memq (selected-window) shown) (selected-window))
     ((car shown))
     (t (selected-window)))))

(defun openstack-list--pin-width-window (&optional hint)
  "Pin the window that decides the column widths, and return it.
HINT is the window that the caller offers, or nil.  A window that
does not show the table stays unpinned."
  (let ((window (openstack-list--width-window hint)))
    (when (memq window (get-buffer-window-list (current-buffer) nil t))
      (setq openstack-list--width-window window))
    window))

(defun openstack-list--natural-widths (rows columns)
  "Return the width that each column needs to show all ROWS.
There is one width for every name in COLUMNS."
  (declare (side-effect-free t))
  (mapcar
   (lambda (column)
     (let ((width (string-width column)))
       (dolist (row rows width)
         (setq width
               (max width
                    (string-width
                     (openstack--format-value (gethash column row))))))))
   columns))

(defun openstack-list--available-width (columns &optional window)
  "Return the cell width available for COLUMNS in WINDOW.
The result leaves room for `tabulated-list-padding' and for the
separator that `tabulated-list-print-col' inserts after every
column but the last."
  (declare (side-effect-free t))
  (let ((window (openstack-list--width-window window))
        (separators (max 0 (1- (length columns)))))
    (max (* (length columns) openstack-list-min-column-width)
         (- (window-width window) tabulated-list-padding separators))))

(defun openstack-list--column-floors (columns)
  "Return the narrowest width of every name in COLUMNS.
A column keeps `openstack-list-min-column-width' and the whole of
its own name, so a fitted table never cuts a column label."
  (declare (side-effect-free t))
  (mapcar (lambda (column)
            (max openstack-list-min-column-width (string-width column)))
          columns))

(defun openstack-list--widest-above-floor (widths floors)
  "Return the position of the widest column that can shrink.
WIDTHS holds the column widths and FLOORS their narrowest values.
The answer is nil when every column already sits at its floor."
  (declare (pure t) (side-effect-free t))
  (let ((position 0)
        (number 0)
        (widest nil))
    (dolist (width widths)
      (when (and (> width (nth number floors))
                 (or (null widest) (> width widest)))
        (setq widest width
              position number))
      (setq number (1+ number)))
    (and widest position)))

(defun openstack-list--fit-widths (widths available &optional minimums)
  "Return WIDTHS shrunk to fit AVAILABLE characters.
Shrink the widest column first.  MINIMUMS holds the narrowest width
of each column and defaults to `openstack-list-min-column-width'
for every one of them.  A column never goes below its minimum, and
`tabulated-list-print-col' then truncates the cells that still
overflow."
  (declare (side-effect-free t))
  (let ((widths (copy-sequence widths))
        (floors (or minimums
                    (make-list (length widths)
                               openstack-list-min-column-width)))
        (total (apply #'+ widths)))
    (let ((position (and (> total available)
                         (openstack-list--widest-above-floor widths floors))))
      (while position
        (setf (nth position widths)
              (max (nth position floors)
                   (- (nth position widths) (- total available))))
        (setq total (apply #'+ widths))
        (setq position (and (> total available)
                            (openstack-list--widest-above-floor
                             widths floors)))))
    widths))

(defun openstack-list--format (rows columns &optional window)
  "Return `tabulated-list-format' for ROWS and COLUMNS.
Every column sorts through `openstack-list--sorter', a numeric
column is right-aligned, and the widths fit WINDOW, which defaults
to the window that decides the widths of the table."
  (declare (side-effect-free t))
  (let* ((minimums (openstack-list--column-floors columns))
         (widths (openstack-list--fit-widths
                  (openstack-list--natural-widths rows columns)
                  (openstack-list--available-width columns window)
                  minimums))
         (format nil))
    (dolist (column columns)
      (push (list column
                  (pop widths)
                  (openstack-list--sorter column)
                  :right-align (openstack-list--numeric-column-p rows column))
            format))
    (vconcat (nreverse format))))

;;; Rendering

(defun openstack-list--row-help (id)
  "Return the tooltip of the table row with identity ID.
Name the row by its name field and its ID, as the completion
prompt names a candidate."
  (declare (side-effect-free t))
  (let ((row (and (hash-table-p openstack-list--rows)
                  (gethash id openstack-list--rows))))
    (if-let* ((name (and row (openstack-resource-name row))))
        (format "Open %s (%s)" name id)
      (format "Open %s" id))))

(defun openstack-list--print-entry (id columns)
  "Print the table row of ID with cell strings COLUMNS.
`tabulated-list-print-entry' draws the cells; this function then
makes the whole line an `openstack-object' button that carries
`openstack-id', so RET, `mouse-2', a click and `push-button' open
the row's resource from any column and a tooltip names it."
  (let ((start (point)))
    (tabulated-list-print-entry id columns)
    (add-text-properties start (1- (point)) (list 'openstack-id id))
    (openstack--buttonize start (1- (point))
                          (openstack-list--row-help id))))

(defun openstack-list--table-line (cells widths aligns)
  "Return CELLS as one table line, padded to WIDTHS with ALIGNS.
ALIGNS holds `right' for a right-aligned cell and any other symbol
for a left-aligned one.  Trailing blanks go away, so a line ends at
its last visible character."
  (declare (pure t) (side-effect-free t))
  (string-trim-right
   (mapconcat #'identity
              (cl-mapcar (lambda (cell width align)
                           (if (eq align 'right)
                               (format (format "%%%ds" width) cell)
                             (format (format "%%-%ds" width) cell)))
                         cells widths aligns)
              "  ")
   " "))

(defun openstack-list-render-to-string (rows fields &optional placeholder)
  "Return ROWS as an aligned text table.
ROWS is the parsed `RESOURCE list' JSON, a list of hash tables.
FIELDS names the columns shown first, in that order, exactly as for
`openstack-list-render'; the remaining columns follow, sorted by
name.  A numeric column turns right-aligned.  The text carries no
faces and needs no buffer, so a caller without a window reads the
same columns as the list mode.  PLACEHOLDER replaces the table when
ROWS is empty."
  (let* ((rows (openstack-list--rows rows))
         (columns (or (openstack-list-columns rows fields) fields)))
    (if (null rows)
        (concat (or placeholder "") "\n")
      (let* ((widths (openstack-list--natural-widths rows columns))
             (aligns (mapcar
                      (lambda (column)
                        (if (openstack-list--numeric-column-p rows column)
                            'right
                          'left))
                      columns))
             (header (openstack-list--table-line
                      columns widths
                      (make-list (length columns) 'left)))
             (lines (mapcar
                     (lambda (row)
                       (openstack-list--table-line
                        (mapcar (lambda (column)
                                  (openstack--format-value
                                   (gethash column row)))
                                columns)
                        widths aligns))
                     rows)))
        (concat header "\n" (mapconcat #'identity lines "\n") "\n")))))

(defun openstack-resource-render-list (type rows)
  "Return the display text of resource TYPE for ROWS as a string.
ROWS is the parsed JSON of `openstack-resource-list'.  The column
order and the empty placeholder come from the definition, so this
function and the list mode of TYPE show the same columns.  Signal
`openstack-resource-error' for an unknown TYPE."
  (let ((definition (openstack--definition-or-error type)))
    (openstack-list-render-to-string
     rows
     (openstack-resource-list-fields type)
     (format "(no %s)" (plist-get definition :noun)))))

(defun openstack-list-render (placeholder rows fields)
  "Render PLACEHOLDER or ROWS as a `tabulated-list-mode' table.
PLACEHOLDER is a string such as \"(no servers)\", inserted when
ROWS is empty.  ROWS is the parsed `RESOURCE list' JSON, a list
of hash tables.  FIELDS names the columns shown first, in that
order; the remaining fields follow, sorted by name.  Collection
modes call this from their `openstack-render-function' with their
own column order."
  (let* ((rows (openstack-list--rows rows))
         (columns (or (openstack-list-columns rows fields) fields))
         (window (openstack-list--pin-width-window)))
    (setq-local openstack-list--count (length rows))
    (setq-local openstack-list--rows (openstack-list--row-index rows))
    (setq-local openstack-list--fit-width
                (openstack-list--available-width columns window))
    (setq-local tabulated-list-format
                (openstack-list--format rows columns window))
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
        (insert placeholder "\n")))
    (set-buffer-modified-p nil)))

(defun openstack-list--redraw ()
  "Redraw the table from the cached rows, without a new fetch.
`openstack-list--run-refits' calls this after a resize, because the
column widths depend on the window width.  The rows stay the same,
so no cell takes the change face."
  (when (and openstack--rendered openstack--last-data)
    (let ((openstack--previous-data openstack--last-data))
      (funcall openstack-render-function nil openstack--last-data))))

(defun openstack-list--refit-needed-p (window)
  "Return non-nil when WINDOW offers another column budget.
The table holds the budget of its last render in
`openstack-list--fit-width', so a frame event that changed no width
asks for no reprint.  A buffer that never rendered needs none."
  (let ((columns (mapcar #'car (append tabulated-list-format nil))))
    (and openstack-list--fit-width
         columns
         (not (equal (openstack-list--available-width columns window)
                     openstack-list--fit-width)))))

(defvar openstack-list--refit-buffers nil
  "List buffers that wait for a column refit.")

(defvar openstack-list--refit-timer nil
  "Timer that runs the pending column refits, or nil.")

(defun openstack-list--schedule-refit ()
  "Queue a column refit of the current list buffer.
`window-size-change-functions' runs during redisplay, and a reprint
must wait for the redisplay to end, so the refit goes through a
zero delay timer."
  (cl-pushnew (current-buffer) openstack-list--refit-buffers)
  (unless (timerp openstack-list--refit-timer)
    (setq openstack-list--refit-timer
          (run-at-time 0 nil #'openstack-list--run-refits))))

(defun openstack-list--run-refits ()
  "Redraw the list buffers that wait for a column refit."
  (setq openstack-list--refit-timer nil)
  (dolist (buffer (prog1 openstack-list--refit-buffers
                    (setq openstack-list--refit-buffers nil)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'openstack-list-mode)
                   (openstack-list--refit-needed-p
                    (openstack-list--width-window)))
          (openstack-list--redraw))))))

(defun openstack-list--window-size-changed (frame)
  "Queue a column refit for the list buffers shown in FRAME.
A resize changes the width that the columns can use.  Only a buffer
whose column budget changed repaints, so an event that grows the
echo area costs nothing."
  (dolist (window (window-list frame 'nomini))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'openstack-list-mode)
                 (openstack-list--refit-needed-p window))
        (openstack-list--schedule-refit)))))

(add-hook 'window-size-change-functions #'openstack-list--window-size-changed)

;;; Row commands

(defun openstack-list--id-at-point ()
  "Return the resource ID of the row at point, or nil."
  (get-text-property (line-beginning-position) 'openstack-id))

;;;###autoload
(defun openstack-list-copy-id ()
  "Copy the ID of the resource on the current row to the kill ring."
  (interactive nil openstack-list-mode)
  (let ((id (openstack-list--id-at-point)))
    (unless id
      (user-error "No OpenStack resource on this line"))
    (kill-new id)
    (message "Copied OpenStack resource ID: %s" id)))

;;;###autoload
(defun openstack-list-open-web ()
  "Open the dashboard page of the resource on the current row."
  (interactive nil openstack-list-mode)
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
          (when openstack-list--scope
            (format " [%s %s]"
                    (plist-get openstack-list--scope :type)
                    (plist-get openstack-list--scope :id)))
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
  "J" #'openstack-json-view
  "w" #'openstack-list-open-web)

(keymap-set openstack-list-mode-map "<remap> <dired-jump>"
            #'openstack-go-to-parent)
(keymap-set openstack-list-mode-map "<remap> <dired-up-directory>"
            #'openstack-go-to-parent)

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
  ;; A collection bookmarks its type, scope, arguments and sort key.
  (setq-local bookmark-make-record-function
              #'openstack-list--bookmark-make-record)
  (setq-local mode-line-format
              (append (default-value 'mode-line-format)
                      '((:eval (openstack-list--mode-line)))))
  (hl-line-mode 1))


;;; Resource definitions

;; The registry lives in openstack-data.el, which this file requires:
;; the macro below fills it, and the data entry points read it.

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
  :list-prefix-arguments  extra client arguments of `RESOURCE list'
                  when the display command gets a prefix argument
  :value-formatters  alist of show field name to formatter function
  :parent        parent spec plist: :type names the resource type
                 that owns TYPE, :field the show field or fields
                 that hold the parent ID, :arguments extra
                 `RESOURCE list' arguments that filter the rows of
                 TYPE by the parent, with `:id' standing for the
                 parent ID

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
         (list-prefix-arguments (openstack-define-resource--value
                                 properties :list-prefix-arguments))
         (value-formatters (openstack-define-resource--value
                            properties :value-formatters))
         (parent (openstack-define-resource--value properties :parent))
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
         (openstack-show-fetch ,type id success-fn error-fn))

       (defun ,render (id data)
         ,(openstack-define-resource--doc "Insert the display of %s ID with DATA into the buffer.
DATA is the parsed `openstack %s show' JSON, rendered by
`openstack-render-fields' with the field order of `%s'.  This is
the value of `openstack-render-function' in `%s'."
                  type cli fields-var mode)
         (let ((openstack-value-formatters ',value-formatters))
           (openstack-render-fields ,title id data ,fields-var)))

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
         (openstack-list-fetch ,type id success-fn error-fn))

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

       (defun ,list-display (&optional arg scope)
         ,(openstack-define-resource--doc "Display all OpenStack %s in a dedicated table buffer.
The buffer is named by `%s' and put into `%s', which fetches the
%s with `openstack %s list' and renders them as a table.  The fetch
is asynchronous: the buffer fills in when the client delivers
data, and keeps itself up to date afterwards.

SCOPE, when non-nil, is the parent scope plist that
`openstack-go-to-parent' builds: it names the parent in the
buffer name, filters the rows by the parent and lets the next
climb open the parent resource.

With a prefix argument, append the `:list-prefix-arguments' of
the definition to the client arguments.  A resource without them
ignores the prefix argument."
                  noun list-buffer-name list-mode noun cli)
         (interactive "P")
         (let* ((buffer-name (if scope
                                 (openstack-list--scope-buffer-name
                                  ,list-buffer-name scope)
                               ,list-buffer-name))
                (buf (get-buffer-create buffer-name))
                (origin (current-buffer)))
           (with-current-buffer buf
             (,list-mode)
             (setq-local openstack-list--prefix-arguments
                         (and arg ',list-prefix-arguments))
             (setq-local openstack-list--scope scope)
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
              :fields-variable ',fields-var
              :list-fields ',list-fields
              :list-fields-variable ',list-fields-var
              :list-arguments ',list-arguments
              :list-arguments-variable ',list-arguments-var
              :list-prefix-arguments ',list-prefix-arguments
              :parent ',parent
              :mode ',mode
              :display ',display
              :list-mode ',list-mode
              :list-display ',list-display)))))

;; The definitions in openstack-resources.el fill the type
;; registries, so an installed package loads them at startup.
;;;###autoload (require 'openstack-resources)

(provide 'openstack-mode)
;;; openstack-mode.el ends here
