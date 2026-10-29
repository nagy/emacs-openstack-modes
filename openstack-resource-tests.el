;;; openstack-resource-tests.el --- Tests for openstack-resources -*- lexical-binding: t; -*-

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

;;; Commentary:

;; The resource show and list modes all come from one macro, so their
;; tests come from one table.  `openstack-resource-test--fixtures'
;; holds, per resource type, a client answer for `RESOURCE show' and
;; one for `RESOURCE list', plus the names the test asserts.  The
;; macro `openstack-resource-test--def-type-tests' turns each body into
;; one ERT test per fixture, so a failure still names its resource.

;;; Code:

(require 'ert)
(require 'openstack-cli-tests)
(require 'openstack-resources)

(eval-and-compile
  (defconst openstack-resource-test--fixtures
    `(("server"
       :show-id "abc-123"
       :show-json
       ,(concat "{\"id\": \"abc-123\", \"name\": \"web-1\", "
                "\"status\": \"ACTIVE\", "
                "\"flavor\": {\"id\": \"1\", \"name\": \"m1.small\"}, "
                "\"addresses\": {\"public\": [{\"addr\": \"10.0.0.5\"}]}, "
                "\"custom_field\": \"x\", \"aaa_first\": \"early\", "
                "\"zzz_last\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("host_status" "image" "updated_at")
       :show-nested (("flavor" . "{\"id\":\"1\",\"name\":\"m1.small\"}"))
       :show-unlisted ("aaa_first" "custom_field" "zzz_last")
       :list-json
       ,(concat "[{\"ID\": \"id-1\", \"Name\": \"web-1\", "
                "\"Status\": \"ACTIVE\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}, "
                "{\"ID\": \"id-2\", \"Name\": \"web-2\", "
                "\"Status\": \"SHUTOFF\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Alpha" "Zebra")
       :list-rows ("^id-1 +web-1 +ACTIVE +early +late"
                   "^id-2 +web-2 +SHUTOFF +early +late")
       :list-first-id "id-1")

      ("volume"
       :show-id "vol-1"
       :show-json
       ,(concat "{\"id\": \"vol-1\", \"name\": \"data-1\", "
                "\"status\": \"in-use\", \"size\": 20, "
                "\"volume_type\": \"__DEFAULT__\", "
                "\"bootable\": \"false\", "
                "\"attachments\": [{\"server_id\": \"srv-1\", "
                "\"device\": \"/dev/vdb\"}], "
                "\"availability_zone\": \"nova\", "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("attachments" . "[{\"server_id\""))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"vol-1\", \"Name\": \"data-1\", "
                "\"Status\": \"in-use\", \"Size\": 20, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"vol-2\", \"Name\": \"\", "
                "\"Status\": \"available\", \"Size\": 10, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Size" "Alpha" "Zebra")
       :list-rows ("^vol-1 +data-1 +in-use +20 +early +late"
                   "^vol-2 +- +available +10 +early +late")
       :list-first-id "vol-1")

      ("image"
       :show-id "img-1"
       :show-json
       ,(concat "{\"id\": \"img-1\", \"name\": \"ubuntu-24.04\", "
                "\"status\": \"active\", "
                "\"visibility\": \"public\", "
                "\"disk_format\": \"qcow2\", "
                "\"container_format\": \"bare\", "
                "\"size\": 234881024, "
                "\"owner\": \"a1b2c3d4e5f60718293a4b5c6d7e8f90\", "
                "\"tags\": [\"latest\"], \"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("tags" . "[\"latest\"]"))
       :show-unlisted ("zzz_extra")
       :show-values (("size" . "224M"))
       :list-json
       ,(concat "[{\"ID\": \"img-1\", \"Name\": \"ubuntu-24.04\", "
                "\"Status\": \"active\", "
                "\"Size\": \"234881024\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}, "
                "{\"ID\": \"img-2\", \"Name\": \"debian-12\", "
                "\"Status\": \"active\", "
                "\"Size\": \"117440512\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Size" "Alpha" "Zebra")
       :list-rows ("^img-1 +ubuntu-24\\.04 +active +234881024 +early +late"
                   "^img-2 +debian-12 +active +117440512 +early +late")
       :list-first-id "img-1")

      ("network"
       :show-id "net-1"
       :show-json
       ,(concat "{\"id\": \"net-1\", \"name\": \"provider\", "
                "\"status\": \"ACTIVE\", "
                "\"admin_state_up\": true, \"shared\": true, "
                "\"router:external\": false, "
                "\"subnets\": [\"subnet-1\"], "
                "\"provider:network_type\": \"vxlan\", "
                "\"provider:segmentation_id\": 42, "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("subnets" . "[\"subnet-1\"]"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"net-1\", \"Name\": \"provider\", "
                "\"Status\": \"ACTIVE\", "
                "\"Subnets\": \"subnet-1\", \"Shared\": true, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"net-2\", \"Name\": \"\", "
                "\"Status\": \"DOWN\", \"Subnets\": \"\", "
                "\"Shared\": false, \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Subnets" "Shared"
                      "Alpha" "Zebra")
       :list-rows ("^net-1 +provider +ACTIVE +subnet-1 +true +early +late"
                   "^net-2 +- +DOWN +- +- +early +late")
       :list-first-id "net-1")

      ("container"
       :show-id "logs"
       :show-json
       ,(concat "{\"container\": \"logs\", \"bytes_used\": 4096, "
                "\"object_count\": 2, "
                "\"account\": \"v1/AUTH_demo\", "
                "\"read_acl\": \".r:*\", \"write_acl\": \"\", "
                "\"storage_policy\": \"default\", "
                "\"zzz_extra\": \"late\", "
                "\"properties\": {\"owner\": \"ops\"}}")
       :show-missing ("sync_to" "sync_key")
       :show-unlisted ("zzz_extra")
       :show-properties (("owner" . "ops"))
       :list-json
       ,(concat "[{\"Name\": \"logs\", \"Bytes\": 4096, "
                "\"Count\": 2}, "
                "{\"Name\": \"backups\", \"Bytes\": 1048576, "
                "\"Count\": 12}]")
       :list-columns ("Name" "Bytes" "Count")
       :list-rows ("^logs +4096 +2"
                   "^backups +1048576 +12")
       :list-first-id "logs"))
    "Client answers and expected texts, one entry per resource type.
Each entry is a list of the type string and a plist.  The plist
holds the ID, JSON and expectations of the show mode (:show-*) and
of the list mode (:list-*).  The first row of the list JSON names
:list-first-id, the row identity the table must report."))

(defmacro openstack-resource-test--def-type-tests (suffix &rest body)
  "Define SUFFIX tests, one per fixture in the fixture table.
Each test is named `openstack-TYPE-SUFFIX' and runs BODY with
`type' bound to the type string and `fixture' to its plist."
  (declare (indent 1) (debug (symbolp body)))
  `(progn
     ,@(mapcar
        (lambda (entry)
          (let ((type (car entry)))
            `(ert-deftest ,(intern (format "openstack-%s-%s" type suffix)) ()
               ,(format "Check `%s' against its fixture." type)
               (let ((type ,type)
                     (fixture ',(cdr entry)))
                 (ignore fixture)
                 ,@body))))
        openstack-resource-test--fixtures)))

;;; Helpers

(defun openstack-resource-test--parse (json)
  "Parse JSON into hash tables, lists and nil for false."
  (with-temp-buffer
    (insert json)
    (goto-char (point-min))
    (json-parse-buffer :object-type 'hash-table
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun openstack-resource-test--definition (type)
  "Return the resource definition plist of TYPE."
  (openstack-resource-definition type))

(defun openstack-resource-test--name (type format)
  "Return the symbol of TYPE with FORMAT applied to it.
FORMAT holds one `%s' for the type string."
  (intern (format format type)))

(defun openstack-resource-test--title (type)
  "Return the show table title of TYPE."
  (capitalize type))

(defun openstack-resource-test--show-buffer (type fixture)
  "Return the display buffer name of TYPE for FIXTURE."
  (format "%s <%s>"
          (symbol-value (openstack-resource-test--name
                         type "openstack-%s-buffer-name"))
          (plist-get fixture :show-id)))

(defun openstack-resource-test--fixture-script (fixture)
  "Return a client script answering FIXTURE's `show' and `list'."
  (format "if [ \"$2\" = show ]; then echo '%s'\nelif [ \"$2\" = list ]; then echo '%s'\nfi\n"
          (plist-get fixture :show-json)
          (plist-get fixture :list-json)))

(defun openstack-resource-test--wait-rendered (buffer)
  "Wait until BUFFER finishes its fetch and renders data."
  (openstack-cli-test--wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and openstack--rendered (not openstack--pending)))))))

(defun openstack-resource-test--wait-idle (buffer)
  "Wait until BUFFER has no fetch in flight."
  (openstack-cli-test--wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer (not openstack--pending))))))

(defun openstack-resource-test--positions (fields text)
  "Return (FIELD . POSITION) for the field lines of FIELDS in TEXT."
  (delq nil
        (mapcar (lambda (field)
                  (let ((pos (string-match
                              (concat "^" (regexp-quote field) ": ") text)))
                    (and pos (cons field pos))))
                fields)))

;;; Tests

(openstack-resource-test--def-type-tests mode-is-derived
  (let ((mode (openstack-resource-test--name type "openstack-%s-mode"))
        (definition (openstack-resource-test--definition type)))
    (with-temp-buffer
      (funcall mode)
      (should (derived-mode-p 'openstack-mode))
      (should (eq openstack-fetch-function
                  (openstack-resource-test--name type "openstack-%s--fetch")))
      (should (eq openstack-render-function
                  (openstack-resource-test--name type "openstack-%s--render")))
      (should (equal openstack-id-prefix (plist-get definition :id-prefix)))
      (should (equal openstack-url-suffix
                     (or (plist-get definition :url-suffix) "")))
      ;; The base mode's ID handling survives.
      (setq-local openstack--id (plist-get fixture :show-id))
      (should (equal (openstack--resource-id t) (plist-get fixture :show-id))))))

(openstack-resource-test--def-type-tests mode-dashboard-url
  (let ((mode (openstack-resource-test--name type "openstack-%s-mode"))
        (definition (openstack-resource-test--definition type))
        (openstack-web-base-url "https://horizon.example.org")
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (funcall mode)
      (should (equal (openstack-dashboard-url id)
                     (format "https://horizon.example.org/%s/%s%s"
                             (plist-get definition :id-prefix)
                             id
                             (or (plist-get definition :url-suffix) "")))))))

(openstack-resource-test--def-type-tests fetch-calls-async-request
  (let ((fetch (openstack-resource-test--name type "openstack-%s--fetch"))
        (cli (plist-get (openstack-resource-test--definition type) :cli))
        (id (plist-get fixture :show-id))
        (args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (funcall fetch id (lambda (_data) nil) (lambda (_err) nil))
                  :process-handle))
      (should (equal args-seen (list cli "show" id)))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(openstack-resource-test--def-type-tests render-shows-ordered-fields
  (let ((render (openstack-resource-test--name type "openstack-%s--render"))
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render id
                 (openstack-resource-test--parse
                  (plist-get fixture :show-json))))
      (let* ((text (buffer-string))
             (fields (plist-get (openstack-resource-test--definition type)
                                :fields))
             (positions (openstack-resource-test--positions fields text)))
        (should (string-match-p
                 (concat "^" (openstack-resource-test--title type) ": ")
                 text))
        (should (string-match-p (concat "^ID: " (regexp-quote id) "$")
                                text))
        ;; Listed fields keep their order.
        (should (> (length positions) 1))
        (should (equal (mapcar #'cdr positions)
                       (sort (mapcar #'cdr positions) #'<)))
        ;; Unlisted fields follow the listed ones, sorted by name.
        (let ((last-listed (apply #'max (mapcar #'cdr positions)))
              (unlisted nil))
          (dolist (field (plist-get fixture :show-unlisted))
            (let ((pos (string-match
                        (concat "^" (regexp-quote field) ": ") text)))
              (should pos)
              (should (> pos last-listed))
              (push pos unlisted)))
          (should (equal unlisted (sort unlisted #'<)))
          ;; A hash-table `properties' value closes the table as an
          ;; indented, sorted block instead of a JSON dump.
          (when-let* ((properties (plist-get fixture :show-properties)))
            (let ((first-property nil)
                  (previous nil)
                  (last-body (apply #'max
                                    (append (mapcar #'cdr positions)
                                            unlisted))))
              (should (string-match-p "^properties:$" text))
              (dolist (entry properties)
                (let ((pos (string-match
                            (concat "^  " (regexp-quote (car entry)) ": +"
                                    (regexp-quote (cdr entry)) "$")
                            text)))
                  (should pos)
                  (if previous
                      (should (> pos previous))
                    (setq first-property pos))
                  (setq previous pos)))
              (should (> first-property last-body))
              (should-not (string-match-p "^properties: {" text)))))
        ;; A field formatter rewrites the show value only.
        (dolist (entry (plist-get fixture :show-values))
          (should (string-match-p
                   (concat "^" (regexp-quote (car entry)) ": +"
                           (regexp-quote (cdr entry)) "$")
                   text)))
        ;; Missing fields are skipped.
        (dolist (field (plist-get fixture :show-missing))
          (should-not (string-match-p
                       (concat "^" (regexp-quote field) ": ") text)))
        ;; Nested values come out as JSON.
        (dolist (entry (plist-get fixture :show-nested))
          (should (string-match-p
                   (concat "^" (regexp-quote (car entry)) ": +"
                           (regexp-quote (cdr entry)))
                   text)))))))

(openstack-resource-test--def-type-tests render-non-hash-data
  (let ((render (openstack-resource-test--name type "openstack-%s--render"))
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render id nil))
      (should (string-match-p
               (concat "^" (openstack-resource-test--title type) ": "
                       (regexp-quote id) "$")
               (buffer-string))))))

(openstack-resource-test--def-type-tests display-renders-from-real-client
  (let ((display (openstack-resource-test--name type "openstack-%s-display"))
        (mode (openstack-resource-test--name type "openstack-%s-mode"))
        (id (plist-get fixture :show-id)))
    (openstack-cli-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall display id)
               (let ((buf (get-buffer
                           (openstack-resource-test--show-buffer type fixture))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (should (derived-mode-p mode))
                   (should (string-match-p
                            (concat "^" (openstack-resource-test--title type)
                                    ": ")
                            (buffer-string)))
                   (should (null openstack--last-error)))))
           (let ((buf (get-buffer
                       (openstack-resource-test--show-buffer type fixture))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests display-reports-client-error
  (let ((display (openstack-resource-test--name type "openstack-%s-display"))
        (id (plist-get fixture :show-id)))
    (openstack-cli-test--with-fixture-program
     "printf '%s' 'not json'\n"
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall display id)
               (let ((buf (get-buffer
                           (openstack-resource-test--show-buffer type fixture))))
                 (should buf)
                 (openstack-resource-test--wait-idle buf)
                 (with-current-buffer buf
                   (should openstack--last-error))))
           (let ((buf (get-buffer
                       (openstack-resource-test--show-buffer type fixture))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests list-mode-is-derived
  (let ((list-mode
         (openstack-resource-test--name type "openstack-%s-list-mode"))
        (definition (openstack-resource-test--definition type)))
    (with-temp-buffer
      (funcall list-mode)
      (should (derived-mode-p 'openstack-list-mode))
      (should (derived-mode-p 'tabulated-list-mode))
      (should openstack-collection)
      (should openstack-render-manages-buffer)
      (should (equal openstack-list--noun (plist-get definition :noun)))
      (should (eq openstack-fetch-function
                  (openstack-resource-test--name
                   type "openstack-%s-list--fetch")))
      (should (eq openstack-render-function
                  (openstack-resource-test--name
                   type "openstack-%s-list--render")))
      ;; RET on a row opens the resource's show buffer.
      (should (eq openstack-show-command
                  (openstack-resource-test--name type "openstack-%s-display")))
      ;; A collection has no resource ID: the ID commands error.
      (should-error (openstack--resource-id t) :type 'user-error))))

(openstack-resource-test--def-type-tests list-fetch-runs-list
  (let ((fetch (openstack-resource-test--name type "openstack-%s-list--fetch"))
        (definition (openstack-resource-test--definition type))
        (args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (funcall fetch nil (lambda (_data) nil)
                           (lambda (_err) nil))
                  :process-handle))
      (should (equal args-seen
                     (append (list (plist-get definition :cli) "list")
                             (plist-get definition :list-arguments))))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(openstack-resource-test--def-type-tests list-columns-ordered
  (let ((columns (openstack-resource-test--name
                  type "openstack-%s-list--columns")))
    (should (equal (funcall columns
                            (openstack-resource-test--parse
                             (plist-get fixture :list-json)))
                   (plist-get fixture :list-columns)))))

(openstack-resource-test--def-type-tests list-render-table
  (let ((list-mode
         (openstack-resource-test--name type "openstack-%s-list-mode"))
        (render (openstack-resource-test--name type "openstack-%s-list--render")))
    (with-temp-buffer
      (funcall list-mode)
      (funcall render nil
               (openstack-resource-test--parse
                (plist-get fixture :list-json)))
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column (plist-get fixture :list-columns))
          (should (string-match-p (regexp-quote column) header)))
        (dolist (row (plist-get fixture :list-rows))
          (should (string-match-p row text)))
        ;; The first row is the row at point, with its resource ID.
        (should (equal (tabulated-list-get-id)
                       (plist-get fixture :list-first-id)))))))

(openstack-resource-test--def-type-tests list-render-empty
  (let ((render (openstack-resource-test--name type "openstack-%s-list--render"))
        (noun (plist-get (openstack-resource-test--definition type) :noun)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render nil nil))
      (should (string-match-p (concat "(no " (regexp-quote noun) ")")
                              (buffer-string))))))

(openstack-resource-test--def-type-tests list-display-renders-from-real-client
  (let ((list-display
         (openstack-resource-test--name type "openstack-%s-list-display"))
        (list-buffer (openstack-resource-test--name
                      type "openstack-%s-list-buffer-name")))
    (openstack-cli-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall list-display)
               (let ((buf (get-buffer (symbol-value list-buffer))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (should openstack-collection)
                   (should (null openstack--id))
                   (should (string-match-p
                            "Name" (prin1-to-string header-line-format)))
                   (dolist (row (plist-get fixture :list-rows))
                     (should (string-match-p row (buffer-string))))
                   (should (null openstack--last-error)))))
           (let ((buf (get-buffer (symbol-value list-buffer))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests list-RET-opens-show
  (let ((list-display
         (openstack-resource-test--name type "openstack-%s-list-display"))
        (list-buffer (openstack-resource-test--name
                      type "openstack-%s-list-buffer-name"))
        (first-id (plist-get fixture :list-first-id))
        (show-buffer
         (openstack-resource-test--name type "openstack-%s-buffer-name")))
    (openstack-cli-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5)
             (expected (format "%s <%s>" (symbol-value show-buffer)
                               first-id)))
         (unwind-protect
             (progn
               (funcall list-display)
               (let ((buf (get-buffer (symbol-value list-buffer))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (re-search-forward (regexp-quote first-id))
                   (goto-char (match-beginning 0))
                   (openstack-display-at-point))
                 (let ((show (get-buffer expected)))
                   (should show)
                   (openstack-resource-test--wait-rendered show)
                   (with-current-buffer show
                     (should (null openstack--last-error))))))
           (dolist (name (list (symbol-value list-buffer) expected))
             (let ((buf (get-buffer name)))
               (when buf (kill-buffer buf))))))))))

(ert-deftest openstack-resource-tests-cover-registry ()
  "Every registered resource type has a fixture, in registry order."
  (should (equal (mapcar #'car openstack-resource-test--fixtures)
                 (mapcar #'car openstack-resource-definitions))))

(provide 'openstack-resource-tests)
;;; openstack-resource-tests.el ends here
