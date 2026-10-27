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
;; The display buffer name is built from `openstack-buffer-name'
;; and the resource ID, so each resource has its own buffer;
;; the dashboard URL comes from `openstack-web-base-url',
;; `openstack-id-prefix', the ID and `openstack-url-suffix'.
;;
;; Talking to OpenStack goes through the `openstack-cli' library
;; (see openstack-cli.el), which wraps `openstack-program' with
;; synchronous and asynchronous request functions and caches
;; authentication tokens across calls.

;;; Code:

(require 'bookmark)
(require 'autorevert)
(require 'cl-lib)
(require 'openstack-cli)


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

(defvar-local openstack--last-fetch-time nil
  "Time of the last fetch of the current buffer as a `float-time'.")

(defvar-local openstack--last-error nil
  "Error condition reported by the last fetch, or nil when none.")

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
    (insert (propertize text 'face 'error))))


;;; Helper functions

(defun openstack--format-url (id)
  "Return the dashboard URL for resource ID.
ID is a string; the URL is built from
`openstack-web-base-url', `openstack-id-prefix', ID and
`openstack-url-suffix'."
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
buffer and the error goes to the header line.  Rendering is
skipped when DATA has the same content as the previously rendered
data, keeping point, marks and window start intact.  A refresh
requested while this fetch ran is served now.  Do nothing when
BUF is already dead or when MARKER is stale, i.e. when the fetch
was superseded while it ran."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (eq marker openstack--fetch-marker)
        (setq openstack--pending nil
              openstack--fetch-marker nil
              openstack--last-fetch-time (float-time))
        (if err
            (setq openstack--last-error err
                  header-line-format
                  (propertize
                   (format "OpenStack error: %s"
                           (or (plist-get (cdr err) :stderr)
                               (let ((data (cdr err)))
                                 (and (consp data)
                                      (stringp (car data))
                                      (car data)))
                               (error-message-string err)))
                   'face 'error))
          (setq openstack--last-error nil
                header-line-format nil)
          (unless (and openstack--rendered
                       (openstack--data-equal-p data openstack--last-data))
            (setq openstack--last-data data
                  openstack--rendered t)
            (let* ((window (get-buffer-window buf 0))
                   (point (point))
                   (start (and (window-live-p window) (window-start window))))
              (let ((inhibit-read-only t))
                (erase-buffer)
                (funcall openstack-render-function id data))
              (goto-char (min point (point-max)))
              (when (window-live-p window)
                (set-window-start window (min start (point-max)))))))
        (when openstack--refresh-requested
          (setq openstack--refresh-requested nil)
          (openstack--refresh))))))

(defun openstack--buffer-stale-p (&optional _noconfirm)
  "Return non-nil when the resource display is due for a refresh.
Used as `buffer-stale-function' by `auto-revert-mode'.  A refresh
is due when none ran yet or when the last one is older than
`openstack-refresh-interval' seconds.  An in-flight fetch is never
interrupted, and with `openstack-refresh-visible-only' a buffer
that no window displays is never stale."
  (and (not openstack--pending)
       (or (not openstack-refresh-visible-only)
           (get-buffer-window (current-buffer) t))
       (or (null openstack--last-fetch-time)
           (>= (- (float-time) openstack--last-fetch-time)
               openstack-refresh-interval))))

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
  (browse-url (openstack--format-url
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
  (let ((id (get-char-property (point) 'openstack-id)))
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

(defun openstack--insert-field (field value &optional id)
  "Insert one FIELD of a resource with its VALUE into the buffer.
When ID is non-nil, the value is propertized with `openstack-id'
and `mouse-face', so `openstack-display-at-point' can open the
resource from the ID field line."
  (let ((text (openstack--format-value value)))
    (when id
      (setq text (propertize text 'openstack-id id
                             'mouse-face 'highlight)))
    (insert (propertize field 'face 'font-lock-variable-name-face)
            ": " text "\n")))

(defun openstack-render-fields (title id data fields)
  "Insert a field table titled TITLE into the current buffer.
ID identifies the resource in the header (nil in collection
buffers); DATA is the parsed `RESOURCE show' JSON and FIELDS
the list of fields shown first, in that order.  Fields missing
from the data are skipped; every remaining field follows,
sorted by name, and nested values render as JSON.  Derived
resource modes call this from their
`openstack-render-function' with their own field order."
  (insert (format "%s: %s\n" title
                  (or (and (hash-table-p data) (gethash "name" data))
                      id)))
  (when id
    (insert "ID: " (propertize id 'openstack-id id
                                'mouse-face 'highlight)
            "\n\n"))
  (when (hash-table-p data)
    (let ((unshown (make-hash-table :test #'equal)))
      (maphash (lambda (key _value) (puthash key t unshown)) data)
      (dolist (field fields)
        (remhash field unshown)
        (let ((value (gethash field data)))
          (when value
            (openstack--insert-field field value
                                     (and id (string= field "id") id)))))
      (let ((remaining nil))
        (maphash (lambda (key _value) (push key remaining)) unshown)
        (dolist (field (sort remaining #'string<))
          (openstack--insert-field
           field (gethash field data)
           (and id (string= field "id") id)))))))

;;; Generic collection fetch and render

(defun openstack-list-fetch (resource _id success-fn error-fn)
  "Fetch all resources of RESOURCE type for a collection buffer.
RESOURCE is the client's resource command name, e.g. `server' or
`volume'.  Run `RESOURCE list' through
`openstack-cli-async-request' and call SUCCESS-FN with the
parsed JSON (a list of resource hash tables), or ERROR-FN with
an `openstack-cli-error' condition.  Return the client process,
so the display machinery can cancel the fetch.  The ID argument
is ignored: a collection buffer has no single resource ID.
Collection modes wrap this with their own resource name as their
`openstack-fetch-function'."
  (openstack-cli-async-request
   (list resource "list")
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

(defun openstack-list--insert-row (cells widths &optional face id)
  "Insert CELLS as one padded table row of column widths WIDTHS.
When FACE is non-nil, the cells are drawn in that face.  When ID
is non-nil, the cells carry the `openstack-id' text property with
ID and `mouse-face' for click feedback, so
`openstack-display-at-point' can open the resource of the row."
  (cl-loop for cell in cells
           for width in widths
           when id
             do (setq cell (propertize cell 'openstack-id id
                                       'mouse-face 'highlight))
           do (insert (if face (propertize cell 'face face) cell))
              (insert (make-string (- width (string-width cell)) ?\s)
                      "  "))
  (insert "\n"))

(defun openstack-list-render (placeholder rows fields)
  "Insert PLACEHOLDER or the table of collection ROWS.
PLACEHOLDER is inserted when ROWS is empty, e.g. `(no
servers)'; ROWS is the parsed `RESOURCE list' JSON, a list of
hash tables.  The columns come from `openstack-list-columns'
with FIELDS first, padded to the widest cell in each column.
Collection modes call this from their
`openstack-render-function' with their own field order."
  (let ((rows (cl-remove-if-not #'hash-table-p
                                (if (listp rows) rows (list rows)))))
    (if (null rows)
        (insert placeholder "\n")
      (let* ((columns (openstack-list-columns rows fields))
             (cell-rows
              (mapcar (lambda (row)
                        (mapcar (lambda (column)
                                  (openstack--format-value
                                   (gethash column row)))
                                columns))
                      rows))
             (widths (let ((ws (mapcar #'string-width columns)))
                       (dolist (cells cell-rows ws)
                         (setq ws (cl-mapcar
                                   (lambda (width cell)
                                     (max width (string-width cell)))
                                   ws cells))))))
        (openstack-list--insert-row columns widths 'bold)
        (insert (make-string (+ (apply #'+ widths)
                                (* 2 (length widths)))
                             ?-)
                "\n")
        ;; The `ID' column carries the resource ID: propertize every
        ;; data row with it, so RET opens the row's resource.
        (let ((id-column (cl-position "ID" columns :test #'string=)))
          (dolist (cells cell-rows)
            (openstack-list--insert-row
             cells widths nil
             (and id-column (nth id-column cells)))))))))

;;; Major mode

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
  (openstack--kill-pending)
  (setq-local revert-buffer-function #'openstack--revert-buffer)
  (setq-local buffer-stale-function #'openstack--buffer-stale-p)
  (setq-local bookmark-make-record-function
              #'openstack--bookmark-make-record)
  (add-hook 'kill-buffer-hook #'openstack--kill-pending nil t)
  (when openstack-auto-revert
    ;; A refresh is asynchronous and invisible: the auto-revert
    ;; "Reverting buffer ..." message would only spam the echo area.
    (setq-local auto-revert-verbose nil)
    (auto-revert-mode 1)))

(defun openstack--revert-buffer (&rest _args)
  "Re-fetch and re-render the current OpenStack resource.
Ignoring ARGS, as required by `revert-buffer-function'.  The
refresh is asynchronous: this function returns immediately and
the buffer updates when `openstack-fetch-function' delivers data."
  (openstack--refresh))

(provide 'openstack-mode)
;;; openstack-mode.el ends here
