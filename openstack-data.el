;;; openstack-data.el --- OpenStack resource data -*- lexical-binding: t; -*-

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

;; The data layer of the package.  It answers questions about
;; OpenStack resources for any caller: a display buffer, an ID
;; prompt, an Org link or another package.  Nothing here writes a
;; buffer or opens one, so a consumer loads this file alone and pays
;; nothing for the modes, the faces or the refresh pipeline.
;;
;; The registry binds every resource type to the facts about it.  A
;; resource form in openstack-resources.el fills it through
;; `openstack--register-resource', and the data entry points read it,
;; so the type string, the client command and the list arguments
;; cannot disagree.
;;
;; Entry points:
;;
;;   openstack-resource-show        - parsed `RESOURCE show' data
;;   openstack-resource-show-async  - the same, with callbacks
;;   openstack-resource-list        - parsed `RESOURCE list' data
;;   openstack-resource-list-async  - the same, with callbacks
;;   openstack-resource-cancel      - cancel an asynchronous call
;;   openstack-resource-list-cached - list data, cached with a TTL
;;   openstack-resource-show-cached - show data, cached with a TTL
;;   openstack-resource-cached-rows - the cached rows only, no call
;;   openstack-resource-invalidate  - drop one or every cached answer
;;   openstack-resource-arguments   - the list arguments of a type
;;   openstack-resource-fields      - the show field order of a type
;;   openstack-resource-list-fields - the list column order of a type
;;   openstack-resource-field       - one field, key case ignored
;;   openstack-resource-id          - the id field of a resource
;;   openstack-resource-name        - the name field of a resource
;;   openstack-resource-definition  - the definition plist of a type
;;   openstack-resource-types       - type, mode and display command
;;
;; The data keeps the wire shape that the client prints: a hash table
;; per resource, with lower case field names from `RESOURCE show' and
;; title case column names from `RESOURCE list'.  Read it through
;; `openstack-resource-field', which compares names without case, and
;; keep the raw hash table when a caller needs the exact keys.
;;
;; Errors: a failed transport call signals `openstack-cli-error', a
;; child of `openstack-error'.  A call with an unknown type signals
;; `openstack-resource-error', another child, so a caller catches
;; either one with `openstack-error'.

;;; Code:

(require 'cl-lib)
(require 'openstack-error)
(require 'openstack-cli)

;;; Conditions

(define-error 'openstack-resource-error "OpenStack resource error"
              'openstack-error)

;;; Customization

(defgroup openstack-data nil
  "Access to OpenStack resource data."
  :prefix "openstack-"
  :group 'tools)

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
  :group 'openstack-data)

(defcustom openstack-resource-cache-ttl 300
  "Seconds a cached client answer stays valid.
The cached entry points, `openstack-resource-list-cached' and
`openstack-resource-show-cached', return an answer older than this
many seconds only by fetching it again.  Set this to nil to keep
entries forever, or run `openstack-resource-invalidate' to drop
them by hand.  The interactive modes ignore the cache: a refresh
always asks the client."
  :type '(choice (number :tag "Seconds") (const :tag "Never expire" nil))
  :group 'openstack-data)

;;; Registry

(defvar openstack-resource-definitions nil
  "Alist of resource type to the definition plist of that type.
`openstack-define-resource' fills it when a resource file loads.
Each plist holds :type, :cli, :noun, :id-prefix, :url-suffix,
:fields, :list-fields, :list-arguments,
:list-arguments-variable, :list-prefix-arguments, :mode, :display,
:list-mode and :list-display.  The registry is the single source of
truth for the resource names: `openstack-resource-types' is its view
for the ID prompts, the Org links and the xref backend.")

(defun openstack-resource-definition (type)
  "Return the definition plist of resource TYPE, or nil."
  (alist-get type openstack-resource-definitions nil nil #'equal))

(defun openstack-resource-cli-name (type)
  "Return the client resource command name of resource TYPE.
The type string is the command name, unless the definition sets a
different :cli value."
  (or (plist-get (openstack-resource-definition type) :cli) type))

(defun openstack-resource-type (type)
  "Return the `openstack-resource-types' entry of resource TYPE."
  (assoc type openstack-resource-types))

(defun openstack-resource-type-for-mode (mode)
  "Return the resource type that MODE displays, or nil."
  (car (cl-find mode openstack-resource-types
                :key (lambda (entry) (nth 1 entry)))))

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

(defun openstack--definition-or-error (type)
  "Return the definition plist of resource TYPE.
Signal `openstack-resource-error' when no definition exists."
  (or (openstack-resource-definition type)
      (signal 'openstack-resource-error
              (list (format "Unknown OpenStack resource type: %s" type)))))

;;; Resource data

(defun openstack-resource-show (type id)
  "Return the parsed `RESOURCE show' data of resource TYPE with ID.
TYPE names a key of `openstack-resource-definitions'; ID goes to
the client unchanged.  The result is the parsed JSON of the client,
a hash table with its field names.  Signal
`openstack-resource-error' for an unknown TYPE, and
`openstack-cli-error' when the client fails or a timeout expires."
  (openstack--definition-or-error type)
  (openstack-cli-request
   (list (openstack-resource-cli-name type) "show" id)))

(defun openstack-resource-show-async (type id success-fn error-fn)
  "Fetch the data of resource TYPE with ID asynchronously.
Call SUCCESS-FN with the parsed JSON, or ERROR-FN with an
`openstack-cli-error' condition.  Signal `openstack-resource-error'
for an unknown TYPE, and `user-error' when a callback is missing.
Return the client process; `delete-process' on it cancels the
fetch, which then calls neither callback."
  (openstack--definition-or-error type)
  (openstack-cli-async-request
   (list (openstack-resource-cli-name type) "show" id)
   :success-fn success-fn
   :error-fn error-fn))

(defun openstack-resource-arguments (type)
  "Return the extra `RESOURCE list' arguments of resource TYPE.
Read the generated `openstack-TYPE-list-arguments' defcustom while
the variable exists, so a user customization wins over the default
of the definition.  Signal `openstack-resource-error' for an
unknown TYPE."
  (let* ((definition (openstack--definition-or-error type))
         (variable (plist-get definition :list-arguments-variable)))
    (if (and variable (boundp variable))
        (symbol-value variable)
      (plist-get definition :list-arguments))))

(defun openstack-resource-fields (type)
  "Return the show field order of resource TYPE.
Read the generated `openstack-TYPE-fields' defcustom while the
variable exists, so a user customization wins over the default of
the definition.  Signal `openstack-resource-error' for an unknown
TYPE."
  (let* ((definition (openstack--definition-or-error type))
         (variable (plist-get definition :fields-variable)))
    (if (and variable (boundp variable))
        (symbol-value variable)
      (plist-get definition :fields))))

(defun openstack-resource-list-fields (type)
  "Return the list column order of resource TYPE.
Read the generated `openstack-TYPE-list-fields' defcustom while the
variable exists, so a user customization wins over the default of
the definition.  Signal `openstack-resource-error' for an unknown
TYPE."
  (let* ((definition (openstack--definition-or-error type))
         (variable (plist-get definition :list-fields-variable)))
    (if (and variable (boundp variable))
        (symbol-value variable)
      (plist-get definition :list-fields))))

(defun openstack-resource-list (type &optional extra)
  "Return the parsed `RESOURCE list' data of resource TYPE.
The command takes the list arguments of the definition, plus
EXTRA, a list of client arguments.  The result is the parsed JSON
of the client, a list of hash tables with the column names of the
client.  Signal `openstack-resource-error' for an unknown TYPE,
and `openstack-cli-error' when the client fails."
  (openstack--definition-or-error type)
  (openstack-cli-request
   (append (list (openstack-resource-cli-name type) "list")
           (openstack-resource-arguments type)
           extra)))

(defun openstack-resource-list-async (type success-fn error-fn &optional extra)
  "Fetch all resources of TYPE asynchronously.
Call SUCCESS-FN with the parsed JSON, a list of hash tables, or
ERROR-FN with an `openstack-cli-error' condition.  The command
takes the list arguments of the definition, plus EXTRA, a list of
client arguments.  Signal `openstack-resource-error' for an unknown
TYPE, and `user-error' when a callback is missing.  Return the
client process; `delete-process' on it cancels the fetch, which
then calls neither callback."
  (openstack--definition-or-error type)
  (openstack-cli-async-request
   (append (list (openstack-resource-cli-name type) "list")
           (openstack-resource-arguments type)
           extra)
   :success-fn success-fn
   :error-fn error-fn))

(defun openstack-resource-cancel (request)
  "Cancel REQUEST, the client process of an asynchronous call.
Kill the process before it exits, so neither callback runs.
Return nil when REQUEST is nil or already finished."
  (when (process-live-p request)
    (delete-process request)))

;;; Cache

;; The cache lives here, in the data layer, so every caller shares
;; one answer: a prompt, a list buffer and another package read the
;; same rows.  Two alists keep the list rows and the show data apart,
;; keyed by type and by (TYPE . ID).  The interactive modes bypass
;; the cache on purpose: a refresh must show the cloud as it is now.

(defvar openstack-resource-change-functions nil
  "Abnormal hook run when a cached client answer changes.
Each function receives one plist with these keys:

  :type   the resource type string
  :id     the resource ID, nil for a list answer
  :kind   `list' or `show'
  :event  `fetched' or `invalidated'
  :old    the previous value, or nil
  :new    the new value, or nil after an invalidation

A fetch that returns the same content as the cached value signals
nothing, so a consumer sees real changes only.  The interactive
modes bypass the cache, so this hook reports the cache only.")

(defvar openstack-resource--list-cache nil
  "Alist of resource type to a cons of type, fetch time and list rows.")

(defvar openstack-resource--show-cache nil
  "Alist of (TYPE . ID) to a cons of key, fetch time and show data.")

(defun openstack-resource--cache-put (cache key value)
  "Return CACHE, an alist, with KEY bound to VALUE and the current time."
  (cons (cons key (cons (float-time) value))
        (assoc-delete-all key cache)))

(defun openstack-resource--cache-fresh-p (cell)
  "Return non-nil when cache CELL is still within the TTL."
  (or (null openstack-resource-cache-ttl)
      (< (- (float-time) (cadr cell))
         openstack-resource-cache-ttl)))

(defun openstack--data-equal-p (a b)
  "Return non-nil when client answers A and B have the same content.
Answers are parsed JSON: hash tables, lists, strings and numbers.
`equal' compares hash tables by identity, so recurse into their
contents here; this is what lets the change hook and the refresh
pipeline treat unchanged data as no change."
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

(defun openstack-resource--notify (type id kind old new event)
  "Run `openstack-resource-change-functions' for one cache change.
TYPE, ID, KIND, OLD, NEW and EVENT describe the change.  A fetch
that returns content equal to OLD signals nothing."
  (unless (and (eq event 'fetched) (openstack--data-equal-p old new))
    (run-hook-with-args 'openstack-resource-change-functions
                        (list :type type :id id :kind kind
                              :event event :old old :new new))))

(defun openstack-resource-cached-rows (type)
  "Return the cached list rows of resource TYPE.
Never run the client and never check the TTL: a stale entry comes
back as it is, and a type without an entry returns nil.  The ID
prompts, the xref backend and `openstack-read-name' read the cache
this way."
  (cddr (assoc type openstack-resource--list-cache)))

(defun openstack-resource-list-cached (type &optional force)
  "Return the list rows of resource TYPE, from the cache when fresh.
Fetch with `openstack-resource-list' when the entry is missing or
older than `openstack-resource-cache-ttl', or when FORCE is
non-nil.  Signal `openstack-resource-error' for an unknown TYPE,
and `openstack-cli-error' when the fetch fails."
  (openstack--definition-or-error type)
  (let* ((entry (assoc type openstack-resource--list-cache))
         (old (and entry (cddr entry))))
    (if (and (not force) entry (openstack-resource--cache-fresh-p entry))
        old
      (let ((rows (openstack-resource-list type)))
        (setq rows (and (listp rows) rows))
        (setq openstack-resource--list-cache
              (openstack-resource--cache-put openstack-resource--list-cache
                                             type rows))
        (openstack-resource--notify type nil 'list old rows 'fetched)
        rows))))

(defun openstack-resource-show-cached (type id &optional force)
  "Return the show data of resource TYPE with ID, from the cache.
Fetch with `openstack-resource-show' when the entry is missing or
older than `openstack-resource-cache-ttl', or when FORCE is
non-nil.  Signal `openstack-resource-error' for an unknown TYPE,
and `openstack-cli-error' when the fetch fails."
  (openstack--definition-or-error type)
  (let* ((key (cons type id))
         (entry (assoc key openstack-resource--show-cache))
         (old (and entry (cddr entry))))
    (if (and (not force) entry (openstack-resource--cache-fresh-p entry))
        old
      (let ((data (openstack-resource-show type id)))
        (setq openstack-resource--show-cache
              (openstack-resource--cache-put openstack-resource--show-cache
                                             key data))
        (openstack-resource--notify type id 'show old data 'fetched)
        data))))

(defun openstack-resource-invalidate (&optional type id)
  "Drop cached client answers.
With TYPE and ID, drop the show data of that resource.  With TYPE
alone, drop the list rows of that type.  Without arguments, drop
every answer.  Run `openstack-resource-change-functions' for every
entry that goes.  Return nil."
  (cond
   ((and type id)
    (let* ((key (cons type id))
           (entry (assoc key openstack-resource--show-cache)))
      (setq openstack-resource--show-cache
            (assoc-delete-all key openstack-resource--show-cache))
      (when entry
        (openstack-resource--notify type id 'show (cddr entry) nil
                                    'invalidated))))
   (type
    (let ((entry (assoc type openstack-resource--list-cache)))
      (setq openstack-resource--list-cache
            (assoc-delete-all type openstack-resource--list-cache))
      (when entry
        (openstack-resource--notify type nil 'list (cddr entry) nil
                                    'invalidated))))
   (t
    (dolist (cell openstack-resource--list-cache)
      (openstack-resource--notify (car cell) nil 'list (cddr cell) nil
                                  'invalidated))
    (dolist (cell openstack-resource--show-cache)
      (openstack-resource--notify (car (car cell)) (cdr (car cell)) 'show
                                  (cddr cell) nil 'invalidated))
    (setq openstack-resource--list-cache nil
          openstack-resource--show-cache nil)))
  nil)

;;; Field access

;; The client prints field names in lower case for `RESOURCE show'
;; and in title case for `RESOURCE list', so every reader compares
;; the names without case.

(defun openstack--hash-field (table name)
  "Return the value of TABLE field NAME, ignoring key case.
Return nil when TABLE holds no key that matches NAME."
  (cl-loop for key being the hash-keys of table
           using (hash-value value)
           when (and (stringp key) (string-equal-ignore-case key name))
           return value))

(defun openstack-resource-field (data name)
  "Return resource DATA field NAME, ignoring case.
DATA is the hash table that `openstack-resource-show' or
`openstack-resource-list' returns, NAME a field name such as
\"name\" or \"ID\".  Return nil when DATA holds no such field."
  (if (hash-table-p data)
      (openstack--hash-field data name)
    nil))

(defun openstack-resource-id (data)
  "Return the id field of resource DATA, or nil.
DATA is the hash table that `openstack-resource-show' or
`openstack-resource-list' returns; a list row spells the field
\"ID\" and a show result spells it \"id\"."
  (openstack-resource-field data "id"))

(defun openstack-resource-name (data)
  "Return the name field of resource DATA, or nil.
A resource without a name field, such as a Swift container, reports
its identifier under another key; see `openstack-resource-field'."
  (openstack-resource-field data "name"))

(provide 'openstack-data)
;;; openstack-data.el ends here
