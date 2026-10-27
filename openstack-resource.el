;;; openstack-resource.el --- Define OpenStack resource modes -*- lexical-binding: t; -*-

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

;; A resource mode repeats the client's resource name in many
;; places: the show fetcher, the list fetcher, the ID prompt, the
;; buffer names, the dashboard URL and the `openstack-resource-types'
;; entry.  `openstack-define-resource' writes all of them from one
;; form, so the type name appears once and the parts cannot drift.
;;
;; A resource file is short:
;;
;;   (require 'openstack-resource)
;;
;;   (openstack-define-resource "server"
;;     :id-prefix "compute"
;;     :fields '("name" "status")
;;     :list-fields '("ID" "Name" "Status"))
;;
;; The macro derives every symbol from the type: TYPE server gives
;; `openstack-server-mode', `openstack-server-display',
;; `openstack-server-list-mode', `openstack-server-list-display' and
;; the defcustoms of the same names.  It also records the definition
;; in `openstack-resource-definitions' and adds the type to
;; `openstack-resource-types', which the ID prompts, the Org links
;; and the xref backend read.
;;
;; The resource file ends with an autoloaded `require', so an
;; installed package fills the registry at load time:
;;
;;   ;;;###autoload (require 'openstack-server)
;;
;; The macro generates no autoload cookies of its own, because the
;; autoload generator scans the source, not the expansion; the
;; require loads the whole file on demand instead.

;;; Code:

(require 'cl-lib)
(require 'openstack-mode)
(require 'openstack-read)
(require 'openstack-list-mode)

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
         (interactive (list (openstack-read-id ,type
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

(provide 'openstack-resource)
;;; openstack-resource.el ends here
