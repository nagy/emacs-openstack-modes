;;; openstack-mode-tests.el --- Tests for openstack-mode -*- lexical-binding: t -*-

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

(defun openstack-test--make-resource-buffer ()
  "Create a temporary buffer displaying resource \"res-123\".
The buffer is put into `openstack-mode' with ID
\"res-123\", and is returned."
  (let ((buf (generate-new-buffer " *openstack-test*")))
    (with-current-buffer buf
      (openstack-mode)
      (setq-local openstack--id "res-123")
      (setq-local openstack--origin-buffer (current-buffer))
      (openstack--refresh))
    buf))

(define-derived-mode openstack-test-child-mode openstack-mode
  "OpenStack Test Child"
  "Minimal derived mode, used to test mode switches.")

;;; Tests

(ert-deftest openstack-mode-autoloads ()
  "Every user-facing entry point carries an autoload cookie.
A fresh install must reach `openstack-display' and friends without
an explicit `require'."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-mode.el"))
                  (buffer-string))))
    (dolist (entry '("openstack-display" "openstack-copy-id"
                     "openstack-open-web" "openstack-pop"
                     "openstack-set-id" "openstack-mode"
                     "openstack-json-view"
                     "openstack-display-at-point"
                     "openstack-mouse-display-at-point"))
      (should (string-match-p
               (format "^;;;###autoload\n(\\(?:defun\\|define-derived-mode\\) %s\\b"
                       (regexp-quote entry))
               source)))))

(ert-deftest openstack-mode-resource-autoloads ()
  "The mode file loads the resource definitions from the autoloads.
The macro writes the commands, so no cookie can precede them in the
source; one autoloaded require loads the definitions instead."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-mode.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload (require 'openstack-resources)$"
             source))))

(ert-deftest openstack-mode-basic ()
  "Buffer gets the mode with a read-only, dedicated buffer."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (eq major-mode 'openstack-mode))
          (should (equal mode-name "OpenStack Resource"))
          (should buffer-read-only)
          (should (string-match-p "^OpenStack resource" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-display-per-resource-buffer ()
  "Each resource ID gets its own buffer; the same ID reuses it."
  (let ((openstack-buffer-name "*OpenStack test*")
        (buf-a nil) (buf-b nil))
    (unwind-protect
        (progn
          (openstack-display "id-a")
          (setq buf-a (current-buffer))
          (should (equal (buffer-name buf-a) "*OpenStack test* <id-a>"))
          (openstack-display "id-b")
          (setq buf-b (current-buffer))
          (should (equal (buffer-name buf-b) "*OpenStack test* <id-b>"))
          (should-not (eq buf-a buf-b))
          ;; Re-displaying id-a must return to the same buffer, not
          ;; create a second one.
          (openstack-display "id-a")
          (should (eq (current-buffer) buf-a))
          (should-not (get-buffer "*OpenStack test* <id-b>3")))
      (dolist (b (list buf-a buf-b))
        (when (buffer-live-p b) (kill-buffer b))))))
(ert-deftest openstack-mode-copy-id ()
  "`openstack-copy-id' puts the ID on the kill ring."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (openstack-copy-id)
          (should (equal (car kill-ring) "res-123")))
      (kill-buffer buf))))

(ert-deftest openstack-mode-copy-id-no-id ()
  "Copying without an ID signals a user-error."
  (with-temp-buffer
    (openstack-mode)
    (should-error (openstack-copy-id) :type 'user-error)))

(ert-deftest openstack-mode-pop ()
  "`openstack-pop' returns to the origin buffer."
  (let* ((origin (generate-new-buffer " *openstack-origin*"))
         (buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack--origin-buffer origin)
          (openstack-pop)
          (should (eq (current-buffer) origin)))
      (kill-buffer buf)
      (kill-buffer origin))))

(ert-deftest openstack-mode-pop-missing-origin ()
  "Popping without an origin buffer signals a user-error."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack--origin-buffer nil)
          (should-error (openstack-pop) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-mode-set-id ()
  "`openstack-set-id' updates the buffer-local ID."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (openstack-set-id "new-id")
          (should (equal openstack--id "new-id")))
      (kill-buffer buf))))

(ert-deftest openstack-mode-format-url ()
  "URL is built from base URL, prefix and ID."
  (let ((openstack-web-base-url "https://horizon.example.org")
        (openstack-id-prefix "servers"))
    (should (equal (openstack-dashboard-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-format-url-trailing-slash ()
  "A trailing slash in the base URL is trimmed."
  (let ((openstack-web-base-url "https://horizon.example.org/")
        (openstack-id-prefix "servers"))
    (should (equal (openstack-dashboard-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-format-url-suffix ()
  "A URL suffix follows the ID, for Horizon detail pages."
  (let ((openstack-web-base-url "https://horizon.example.org")
        (openstack-id-prefix "/project/networks/")
        (openstack-url-suffix "/detail"))
    (should (equal (openstack-dashboard-url "abc-123")
                   "https://horizon.example.org/project/networks/abc-123/detail"))))

(ert-deftest openstack-mode-format-url-no-suffix ()
  "The default URL suffix adds nothing after the ID."
  (let ((openstack-web-base-url "https://horizon.example.org")
        (openstack-id-prefix "servers")
        (openstack-url-suffix ""))
    (should (equal (openstack-dashboard-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-bookmark-record ()
  "`openstack--bookmark-make-record' stores the ID."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((record (openstack--bookmark-make-record)))
            (should (equal (bookmark-prop-get record 'openstack-id)
                           "res-123"))
            (should (equal (car record) "res-123 ::OpenStack"))
            ;; A live buffer object in the record dies with the session.
            (should-not (assq 'buffer (cdr record)))
            (should (equal (bookmark-prop-get record 'handler)
                           'openstack-bookmark-jump))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-bookmark-jump ()
  "Jumping to a bookmark displays the recorded resource ID."
  (let ((buf (openstack-test--make-resource-buffer))
        displayed)
    (unwind-protect
        (let ((record (with-current-buffer buf
                        (openstack--bookmark-make-record))))
          (cl-letf (((symbol-function 'openstack-display)
                     (lambda (id) (setq displayed id))))
            (openstack-bookmark-jump record))
          (should (equal displayed "res-123")))
      (kill-buffer buf))))

(ert-deftest openstack-mode-revert ()
  "`revert-buffer' keeps the buffer content intact."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (revert-buffer)
          (should (string-match-p "ID: res-123" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-async-render ()
  "Delivered data renders asynchronously through the fetch pipeline.
The fetch callback renders into the buffer after the fetch
returned; until then the old content stays."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let (success-fn)
            (setq-local openstack-fetch-function
                        (lambda (_id success _error)
                          (setq success-fn success)))
            (setq-local openstack-render-function
                        (lambda (id data) (insert (format "%s|%s" id data))))
            (openstack--refresh)
            (should success-fn)
            (should (string-match-p "ID: res-123" (buffer-string)))
            (funcall success-fn "data-1")
            (should (equal (buffer-string) "res-123|data-1"))
            (should-not openstack--pending)))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-skips-in-flight-fetch ()
  "A second refresh while one runs starts no new fetch."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((calls 0))
            (setq-local openstack-fetch-function
                        (lambda (_id _success _error)
                          (setq calls (1+ calls))))
            (openstack--refresh)
            (openstack--refresh)
            (should (= calls 1))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-unchanged-data-keeps-point ()
  "Unchanged data leaves the buffer, point and marks alone."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((success-fn nil)
                (renders 0))
            (setq-local openstack-fetch-function
                        (lambda (_id success _error)
                          (setq success-fn success)))
            (setq-local openstack-render-function
                        (lambda (_id data)
                          (setq renders (1+ renders))
                          (insert data)))
            (openstack--refresh)
            (funcall success-fn "same")
            (should (= renders 1))
            (goto-char (point-min))
            (forward-char 2)
            (let ((point (point)))
              (openstack--refresh)
              (funcall success-fn "same")
              (should (= renders 1))
              (should (= (point) point)))
            ;; Fresh data re-renders.
            (openstack--refresh)
            (funcall success-fn "other")
            (should (= renders 2))
            (should (equal (buffer-string) "other"))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-error-keeps-content ()
  "A failed fetch keeps the old content and reports in the header line."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((success-fn nil)
                (error-fn nil)
                (content (buffer-string)))
            (setq-local openstack-fetch-function
                        (lambda (_id success error)
                          (setq success-fn success error-fn error)))
            (openstack--refresh)
            (funcall error-fn '(openstack-cli-error :stderr "auth failed"))
            (should (equal (buffer-string) content))
            (should (string-match-p "auth failed" header-line-format))
            (should openstack--last-error)
            ;; The next successful fetch clears the error.
            (openstack--refresh)
            (funcall success-fn "fine")
            (should-not header-line-format)
            (should-not openstack--last-error)))
      (kill-buffer buf))))

(ert-deftest openstack-mode-kill-buffer-cancels-fetch ()
  "Killing the buffer deletes an in-flight fetch process."
  (let ((buf (openstack-test--make-resource-buffer))
        (proc nil))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack-fetch-function
                      (lambda (_id _success _error)
                        (setq proc (start-process
                                    "openstack-test-fetch" nil
                                    "sleep" "60"))))
          (openstack--refresh)
          (should (processp openstack--pending))
          (kill-buffer buf)
          (should-not (process-live-p proc)))
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest openstack-mode-stale-p-throttles-refreshes ()
  "`openstack--buffer-stale-p' throttles to `openstack-refresh-interval'."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((openstack-refresh-interval 30)
                (openstack-refresh-visible-only nil))
            (setq-local openstack--last-fetch-time (float-time))
            (should-not (openstack--buffer-stale-p))
            (setq-local openstack--last-fetch-time (- (float-time) 31))
            (should (openstack--buffer-stale-p))
            ;; An in-flight fetch is never interrupted.
            (setq-local openstack--pending t)
            (should-not (openstack--buffer-stale-p))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-stale-p-skips-hidden-buffers ()
  "Hidden buffers are never stale with `openstack-refresh-visible-only'.
Buried resource buffers must not cost API calls for the rest of
the session."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack--last-fetch-time (- (float-time) 300))
          (let ((openstack-refresh-visible-only t))
            (should-not (openstack--buffer-stale-p)))
          (let ((openstack-refresh-visible-only nil))
            (should (openstack--buffer-stale-p))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-unchanged-hash-data-keeps-point ()
  "Unchanged parsed JSON (hash tables) counts as unchanged data.
`equal' compares hash tables by identity, so the pipeline uses
`openstack--data-equal-p' for the comparison."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((success-fn nil)
                (renders 0))
            (setq-local openstack-fetch-function
                        (lambda (_id success _error)
                          (setq success-fn success)))
            (setq-local openstack-render-function
                        (lambda (_id data)
                          (setq renders (1+ renders))
                          (insert (gethash "name" data))))
            (openstack--refresh)
            (funcall success-fn
                     (json-parse-string
                      "{\"name\": \"web-1\", \"status\": \"ACTIVE\"}"))
            (should (= renders 1))
            ;; Same content in a fresh hash table: no re-render.
            (openstack--refresh)
            (funcall success-fn
                     (json-parse-string
                      "{\"name\": \"web-1\", \"status\": \"ACTIVE\"}"))
            (should (= renders 1))
            ;; Changed content re-renders.
            (openstack--refresh)
            (funcall success-fn
                     (json-parse-string
                      "{\"name\": \"web-1\", \"status\": \"SHUTOFF\"}"))
            (should (= renders 2))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-fetcher-error-does-not-freeze ()
  "A fetcher that signals reports the error and stays refreshable."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack-fetch-function
                      (lambda (_id _success _error)
                        (user-error "bad fetch args")))
          (openstack--refresh)
          (should-not openstack--pending)
          (should openstack--last-error)
          (should (string-match-p "bad fetch args" header-line-format))
          ;; The buffer keeps accepting refreshes.
          (setq-local openstack-fetch-function
                      (lambda (_id success _error)
                        (funcall success "fine")))
          (openstack--refresh)
          (should-not openstack--last-error)
          (should-not openstack--pending))
      (kill-buffer buf))))

(ert-deftest openstack-mode-refresh-requested-while-busy ()
  "A manual refresh during a running fetch is not swallowed.
It runs as soon as the running fetch completes."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((calls 0)
                (success-fn nil))
            (setq-local openstack-fetch-function
                        (lambda (_id success _error)
                          (setq calls (1+ calls))
                          (setq success-fn success)))
            (openstack--refresh)
            ;; Like a user pressing g while the fetch runs.
            (openstack--refresh)
            (should (= calls 1))
            (should openstack--refresh-requested)
            (funcall success-fn "data")
            ;; The pending request triggered a follow-up fetch.
            (should (= calls 2))
            (should openstack--pending)
            (should-not openstack--refresh-requested)
            (funcall success-fn "data")
            (should-not openstack--pending)))
      (kill-buffer buf))))

(ert-deftest openstack-mode-auto-revert-wiring ()
  "`openstack-mode' hands refreshing to `auto-revert-mode'."
  (dolist (setting '(t nil))
    (let ((buf (generate-new-buffer " *openstack-test*")))
      (unwind-protect
          (with-current-buffer buf
            (let ((openstack-auto-revert setting))
              (openstack-mode)
              (should (eq buffer-stale-function
                          #'openstack--buffer-stale-p))
              (if setting
                  (should auto-revert-mode)
                (should-not auto-revert-mode))))
        (kill-buffer buf)))))

(ert-deftest openstack-mode-switch-cancels-in-flight-fetch ()
  "A derived mode superseding this one starts from a clean slate.
`openstack--pending' is permanent-local, so the new mode body
sees the old mode's fetch and can kill its process; the cached view resets, so the new renderer draws its own."
  (let ((buf (openstack-test--make-resource-buffer))
        (proc nil))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack-fetch-function
                      (lambda (_id _success _error)
                        (setq proc (start-process
                                    "openstack-test-fetch" nil
                                    "sleep" "60"))))
          (openstack--refresh)
          (should (processp openstack--pending))
          (openstack-test-child-mode)
          (should-not (process-live-p proc))
          (should-not openstack--pending)
          ;; The resource identity survives the switch, while the
          ;; cached view resets: the new renderer draws its own.
          (should (equal openstack--id "res-123"))
          (should-not openstack--rendered)
          (openstack--refresh)
          (should openstack--rendered)
          (should (string-match-p "ID: res-123" (buffer-string))))
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (when (process-live-p proc)
        (delete-process proc)))))

;;; Generic resource helpers

(ert-deftest openstack-format-value-cases ()
  "Value formatting: nil, empty, booleans, scalars and nested data."
  (should (equal (openstack--format-value nil) "-"))
  (should (equal (openstack--format-value "") "-"))
  (should (equal (openstack--format-value "ACTIVE") "ACTIVE"))
  (should (equal (openstack--format-value 2) "2"))
  (should (equal (openstack--format-value t) "true"))
  ;; A list of plain values prints as text, a nested one as JSON.
  (should (equal (openstack--format-value '(1 2)) "1, 2"))
  (should (equal (openstack--format-value '("subnet-1" "subnet-2"))
                 "subnet-1, subnet-2"))
  (should (equal (openstack--format-value '("latest")) "latest"))
  (should (equal (openstack--format-value '((1 2) 3)) "[[1,2],3]"))
  (let ((table (make-hash-table :test #'equal)))
    (puthash "a" 1 table)
    (should (equal (openstack--format-value (list table))
                   "[{\"a\":1}]")))
  ;; A formatter from `openstack-value-formatters' wins for its field,
  ;; and field names compare without case.
  (let ((openstack-value-formatters '(("size" . openstack--format-size))))
    (should (equal (openstack--format-value 234881024 "size") "224M"))
    (should (equal (openstack--format-value 0 "Size") "0"))
    (should (equal (openstack--format-value 5 "other") "5"))
    (should (equal (openstack--format-value nil "size") "-"))))

(ert-deftest openstack-render-fields-orders-and-sorts ()
  "`openstack-render-fields' lists FIELDS first, the rest sorted.
Missing fields are skipped and nested values render as JSON."
  (let ((data (with-temp-buffer
                (insert "{\"name\": \"data-1\", \"status\": \"in-use\", "
                        "\"zzz\": \"late\", \"aaa\": {\"k\": 1}, "
                        "\"size\": 20, \"host\": null}")
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil)))
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Volume" "vol-1" data
                               '("name" "size" "missing"))
      (let ((text (buffer-string)))
        (should (string-match-p "Volume: data-1\n" text))
        (should (string-match-p "ID: vol-1\n" text))
        (should (< (string-match "^name: +data-1$" text)
                   (string-match "^size: +20$" text)
                   (string-match "^aaa: +{\"k\":1}$" text)
                   (string-match "^zzz: +late$" text)))
        (should-not (string-match-p "^missing:" text))
        (should (string-match-p "^host: +-$" text))))))

(ert-deftest openstack-render-fields-aligns-values ()
  "Every value starts past the longest field name, one column for all.
A volume detail buffer lines up like a table, however much the
field names differ in length."
  (let ((data (json-parse-string
               (concat "{\"name\": \"data-1\", \"status\": \"active\", "
                       "\"size\": 1, \"container_format\": \"bare\"}")
               :object-type 'hash-table :array-type 'list)))
    (with-temp-buffer
      (openstack-render-fields "Volume" nil data
                               '("name" "status" "size"
                                 "container_format"))
      (let ((columns nil)
            (longest "container_format")
            (case-fold-search nil))
        (goto-char (point-min))
        (while (not (eobp))
          (when (looking-at "\\([a-z_]+\\): +\\(\\S-\\)")
            (goto-char (match-beginning 2))
            (push (current-column) columns)
            (beginning-of-line))
          (forward-line 1))
        (should (= (length columns) 4))
        ;; One column: every entry matches the first.
        (should (equal columns (make-list (length columns) (car columns))))
        (should (= (car columns) (+ 2 (length longest))))))))

(ert-deftest openstack-render-fields-expands-properties ()
  "A hash-table `properties' value becomes the final, indented block.
Keys sort by name and their values line up past the longest key,
instead of one JSON dump."
  (let ((data (json-parse-string
               (concat "{\"name\": \"ubuntu-24.04\", "
                       "\"status\": \"active\", \"zzz_last\": \"late\", "
                       "\"properties\": {\"os_hash_value\": \"8cb9b\", "
                       "\"os_hidden\": \"false\", "
                       "\"os_hash_algo\": \"sha512\"}}")
               :object-type 'hash-table :array-type 'list)))
    (with-temp-buffer
      (openstack-render-fields "Image" nil data '("name" "status"))
      (let ((text (buffer-string))
            (plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (string-match-p "^properties:$" text))
        (should (string-match-p "^  os_hash_algo:  sha512$" text))
        (should (string-match-p "^  os_hash_value: 8cb9b$" text))
        (should (string-match-p "^  os_hidden:     false$" text))
        ;; The block closes the table, after the sorted leftovers.
        (should (< (string-match "^zzz_last:" text)
                   (string-match "^properties:$" text)))
        ;; Keys keep name order, and no JSON braces survive.
        (should (< (string-match "^  os_hash_algo:" text)
                   (string-match "^  os_hash_value:" text)
                   (string-match "^  os_hidden:" text)))
        (should-not (string-match-p "\"os_hash_algo\"" plain))))))

(ert-deftest openstack-render-fields-expands-locations ()
  "A `locations' list of hash tables expands to an indented block.
Every record marks its first line with a dash; keys sort by name
and the values align past the longest key."
  (let ((data (json-parse-string
               (concat "{\"name\": \"ubuntu-24.04\", "
                       "\"status\": \"active\", "
                       "\"locations\": ["
                       "{\"url\": \"rbd://80ec/image\", "
                       "\"metadata\": {\"store\": \"rbd\"}}, "
                       "{\"url\": \"swift://images/ubuntu\"}]}")
               :object-type 'hash-table :array-type 'list)))
    (with-temp-buffer
      (openstack-render-fields "Image" nil data '("name" "status"))
      (let ((text (buffer-string))
            (plain (buffer-substring-no-properties
                    (point-min) (point-max))))
        (should (string-match-p "^locations:$" text))
        (should (string-match-p "^  - metadata: {\"store\":\"rbd\"}$" text))
        (should (string-match-p "^    url:      rbd://80ec/image$" text))
        (should (string-match-p "^  - url:      swift://images/ubuntu$" text))
        (should-not (string-match-p "\"url\"" plain))))))

(ert-deftest openstack-render-fields-expands-nested-locations ()
  "The Glance `locations' attribute inside `properties' expands too.
The client flattens that attribute into the properties hash, so
the renderer must not leave it as one JSON line."
  (let ((data (json-parse-string
               (concat "{\"name\": \"ubuntu-24.04\", "
                       "\"properties\": {\"os_hash_algo\": \"sha512\", "
                       "\"locations\": [{\"url\": \"rbd://80ec/image\", "
                       "\"metadata\": {\"store\": \"rbd\"}}]}}")
               :object-type 'hash-table :array-type 'list)))
    (with-temp-buffer
      (openstack-render-fields "Image" nil data '("name"))
      (let ((text (buffer-string)))
        (should (string-match-p "^properties:$" text))
        (should (string-match-p "^  locations:$" text))
        (should (string-match-p
                 "^    - metadata: {\"store\":\"rbd\"}$" text))
        (should (string-match-p
                 "^      url:      rbd://80ec/image$" text))
        (should (string-match-p "^  os_hash_algo: sha512$" text))
        (should-not (string-match-p "\\[{\"url\"" text))))))

(ert-deftest openstack-show-fetch-runs-resource-show ()
  "`openstack-show-fetch' runs `RESOURCE show ID' via the CLI layer."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :handle))))
      (should (eq (openstack-show-fetch
                   "volume" "vol-1"
                   (lambda (_d) nil) (lambda (_e) nil))
                  :handle))
      (should (equal args-seen '("volume" "show" "vol-1")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-refresh-collection-without-id ()
  "A collection buffer refreshes without a resource ID.
The fetcher receives nil as the ID; without the
`openstack-collection' flag the same buffer would not refresh."
  (let ((buf (generate-new-buffer " *openstack-test*"))
        (ids-seen nil))
    (unwind-protect
        (with-current-buffer buf
          (openstack-mode)
          (let ((openstack-fetch-function
                 (lambda (id success-fn _error-fn)
                   (push id ids-seen)
                   (funcall success-fn nil))))
            (should (null openstack--id))
            (openstack--refresh)
            (should (null openstack--pending))
            (should (null ids-seen))
            (setq-local openstack-collection t)
            (openstack--refresh)
            (should (equal ids-seen '(nil)))
            (should openstack--rendered)))
      (kill-buffer buf))))

;;; Navigation

(ert-deftest openstack-list-render-propertizes-rows-with-id ()
  "Data rows carry `openstack-id' and `mouse-face' over the whole line."
  (let ((data (with-temp-buffer
                (insert "[{\"ID\": \"id-1\", \"Name\": \"web-1\"}, "
                        "{\"ID\": \"id-2\", \"Name\": \"web-2\"}]")
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (openstack-list-render "(none)" data '("ID" "Name"))
      ;; The header line holds the column labels, so the buffer starts
      ;; with the first row; the property covers its padding too.
      (should (equal (get-text-property (point-min) 'openstack-id)
                     "id-1"))
      (should (eq (get-text-property (point-min) 'mouse-face)
                  'highlight))
      (goto-char (point-min))
      (search-forward "web-1")
      (should (equal (get-text-property (match-beginning 0) 'openstack-id)
                     "id-1"))
      ;; The padding between two cells carries the property as well.
      (goto-char (point-min))
      (search-forward "id-1")
      (should (equal (get-text-property (1+ (match-end 0)) 'openstack-id)
                     "id-1"))
      (search-forward "id-2")
      (should (equal (get-text-property (match-beginning 0) 'openstack-id)
                     "id-2")))))

(ert-deftest openstack-render-fields-propertizes-id ()
  "The header ID and the `id' field line carry `openstack-id'."
  (let ((data (with-temp-buffer
                (insert "{\"id\": \"vol-1\", \"name\": \"data-1\", "
                        "\"size\": 20}")
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil)))
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Volume" "vol-1" data '("name"))
      (goto-char (point-min))
      (search-forward "vol-1")
      (should (equal (get-text-property (match-beginning 0) 'openstack-id)
                     "vol-1"))
      ;; The `id' field line, too.
      (re-search-forward "^id: +\\(vol-1\\)$")
      (should (equal (get-text-property (match-beginning 1) 'openstack-id)
                     "vol-1"))
      ;; Other fields do not carry it.
      (search-backward "data-1")
      (should (null (get-text-property (point) 'openstack-id))))))

(ert-deftest openstack-display-at-point-needs-id ()
  "Point without an `openstack-id' property signals a user-error."
  (with-temp-buffer
    (openstack-mode)
    (let ((inhibit-read-only t))
      (insert "no id here"))
    (goto-char (point-min))
    (should-error (openstack-display-at-point) :type 'user-error)))

(ert-deftest openstack-display-at-point-opens-resource ()
  "The resource at point is opened via `openstack-show-command'."
  (let ((shown nil))
    (with-temp-buffer
      (openstack-mode)
      (let ((inhibit-read-only t))
        (insert "ID: " (propertize "res-9" 'openstack-id "res-9") "\n"))
      (goto-char (point-min))
      (search-forward "res-9")
      (goto-char (match-beginning 0))
      (let ((openstack-show-command
             (lambda (id) (setq shown id))))
        (openstack-display-at-point)))
    (should (equal shown "res-9"))))

(ert-deftest openstack-mode-keymap-navigation ()
  "RET and `mouse-2' open the resource at point."
  (should (eq (lookup-key openstack-mode-map (kbd "RET"))
              #'openstack-display-at-point))
  (should (eq (lookup-key openstack-mode-map [mouse-2])
              #'openstack-mouse-display-at-point))
  (should (eq (lookup-key openstack-mode-map (kbd "J"))
              #'openstack-json-view)))

;;; JSON view

(defmacro openstack-test--with-json-source (data &rest body)
  "Run BODY with an OpenStack buffer holding DATA and a JSON view.
Binds `source' to the display buffer and `json' to the buffer
that `openstack-json-view' opened.  Kill both buffers afterwards."
  (declare (indent 1) (debug (form body)))
  `(let ((source (generate-new-buffer " *openstack-json-source*"))
         (json nil))
     (unwind-protect
         (progn
           (with-current-buffer source
             (openstack-mode)
             (setq-local openstack--id "srv-1")
             (setq-local openstack--rendered t)
             (setq-local openstack--last-data ,data)
             (openstack-json-view))
           (setq json (buffer-local-value 'openstack--json-buffer source))
           (with-current-buffer json
             ,@body))
       (when (buffer-live-p source) (kill-buffer source))
       (when (buffer-live-p json) (kill-buffer json)))))

(ert-deftest openstack-json-view-renders-last-data ()
  "The JSON buffer holds the pretty printed last fetch result."
  (openstack-test--with-json-source
      (openstack-test--parse "{\"id\": \"srv-1\", \"name\": \"web-1\"}")
    (should (derived-mode-p 'openstack-json-mode))
    (should (equal (buffer-name json) " *openstack-json-source* JSON"))
    (should buffer-read-only)
    (should (string-match-p "\"name\": \"web-1\"" (buffer-string)))
    (should (string-match-p "^{\n" (buffer-string)))))

(ert-deftest openstack-json-view-reuses-its-buffer ()
  "A second call switches to the same JSON buffer."
  (openstack-test--with-json-source
      (openstack-test--parse "{\"id\": \"srv-1\"}")
    (let ((first json))
      (with-current-buffer source
        (openstack-json-view))
      (should (eq (buffer-local-value 'openstack--json-buffer source) first))
      (should (eq (get-buffer (buffer-name first)) first)))))

(ert-deftest openstack-json-view-follows-a-refresh ()
  "A refresh of the display buffer redraws the JSON buffer."
  (openstack-test--with-json-source
      (openstack-test--parse "{\"id\": \"srv-1\", \"status\": \"BUILD\"}")
    (should (string-match-p "BUILD" (with-current-buffer json
                                      (buffer-string))))
    (with-current-buffer source
      (setq-local openstack--fetch-marker (list nil))
      (setq-local openstack-render-function
                  (lambda (id data)
                    (openstack-render-fields "Server" id data '("status"))))
      (let ((inhibit-read-only t))
        (openstack--refresh-done
         source openstack--fetch-marker "srv-1"
         (openstack-test--parse
          "{\"id\": \"srv-1\", \"status\": \"ACTIVE\"}")
         nil)))
    (with-current-buffer json
      (should (string-match-p "ACTIVE" (buffer-string)))
      (should-not (string-match-p "BUILD" (buffer-string))))))

(ert-deftest openstack-json-view-rejects-other-buffers ()
  "The command needs an OpenStack display buffer."
  (with-temp-buffer
    (should-error (openstack-json-view) :type 'user-error)))


;;; Things at point

(defconst openstack-test--uuid "6f1e2d3c-0000-4000-8000-0000000000cc"
  "A UUID that no fixture carries, for the thing tests.")

(ert-deftest openstack-id-thing-prefers-property ()
  "The `openstack-id' thing returns the property over the UUID text."
  (with-temp-buffer
    (insert "web-1 " openstack-test--uuid)
    (put-text-property (point-min) (point-max) 'openstack-id "srv-1")
    (goto-char (point-min))
    (should (equal (thing-at-point 'openstack-id t) "srv-1"))
    (should (equal (bounds-of-thing-at-point 'openstack-id)
                   (cons (point-min) (point-max))))
    (search-forward "6f1e2d3c")
    (should (equal (thing-at-point 'uuid t) openstack-test--uuid))))

(ert-deftest openstack-id-thing-without-property-returns-uuid ()
  "Without the property the thing falls back to the UUID under point."
  (with-temp-buffer
    (insert "log line " openstack-test--uuid " end")
    (goto-char (point-min))
    (search-forward "6f1e2d3c")
    (should (equal (thing-at-point 'openstack-id t) openstack-test--uuid))
    (should (equal (bounds-of-thing-at-point 'openstack-id)
                   (bounds-of-thing-at-point 'uuid)))))

(ert-deftest openstack-id-thing-bounds-cover-the-property-run ()
  "The bounds stop where the `openstack-id' property stops."
  (with-temp-buffer
    (insert "name")
    (put-text-property (point-min) (point-max) 'openstack-id "srv-1")
    (insert " tail")
    (goto-char (+ (point-min) 2))
    (should (equal (bounds-of-thing-at-point 'openstack-id)
                   (cons (point-min) (+ (point-min) 4))))
    ;; No property, no ID.
    (goto-char (point-max))
    (should (null (thing-at-point 'openstack-id t)))))

(ert-deftest openstack-mode-uuid-thing-reads-truncated-cell ()
  "A display buffer answers the `uuid' thing from the property.
A narrow table truncates the ID text, so the provider must return
the full ID from the property."
  (let ((buffer (generate-new-buffer " *openstack-thing-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (openstack-mode)
          (let ((inhibit-read-only t))
            (insert "6f1b4\u2026  web-1\n")
            (add-text-properties (point-min) (point-max)
                                 (list 'openstack-id
                                       openstack-test--uuid)))
          (goto-char (+ (point-min) 2))
          (should (equal (thing-at-point 'uuid t) openstack-test--uuid))
          (should (equal (bounds-of-thing-at-point 'openstack-id)
                         (cons (point-min) (point-max)))))
      (kill-buffer buffer))))


;;; Imenu

(ert-deftest openstack-imenu-index-lists-fields ()
  "Field lines become imenu entries at their own positions."
  (with-temp-buffer
    (openstack-mode)
    (let ((inhibit-read-only t)
          (data (json-parse-string
                 "{\"id\": \"srv-1\", \"name\": \"web-1\", \"status\": \"ACTIVE\"}"
                 :object-type 'hash-table :array-type 'list)))
      (openstack-render-fields "Server" "srv-1" data '("name"))
      (let ((index (openstack--imenu-index)))
        (should (equal (mapcar #'car index) '("name" "id" "status")))
        (dolist (entry index)
          (goto-char (cdr entry))
          (should (equal (get-text-property (point) 'openstack-field)
                         (car entry)))
          (should (string-prefix-p (concat (car entry) ": ")
                                   (buffer-substring-no-properties
                                    (point) (line-end-position)))))))))

(ert-deftest openstack-list-imenu-index-lists-rows ()
  "Rows become imenu entries, named by name and ID."
  (let ((data (json-parse-string
               "[{\"ID\": \"id-1\", \"Name\": \"web-1\"}, \
                    {\"ID\": \"id-2\", \"Name\": \"\"}]"
               :object-type 'hash-table :array-type 'list)))
    (with-temp-buffer
      (openstack-list-mode)
      (let ((inhibit-read-only t))
        (openstack-list-render "(none)" data '("ID" "Name")))
      (let ((index (openstack-list--imenu-index)))
        (should (equal (mapcar #'car index)
                       '("web-1 (id-1)" "id-2")))
        (dolist (entry index)
          (goto-char (cdr entry))
          (should (get-text-property (point) 'openstack-id)))))))

;;; Status faces, changes and notifications

(defun openstack-test--parse (json)
  "Parse the JSON string into the shapes the CLI layer returns."
  (with-temp-buffer
    (insert json)
    (goto-char (point-min))
    (json-parse-buffer :object-type 'hash-table
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun openstack-test--face-at (text)
  "Return the face property of the first occurrence of TEXT."
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (match-beginning 0) 'face))

(ert-deftest openstack-status-face-map ()
  "Status values map to faces, other fields keep none."
  (should (eq (openstack--status-face "status" "ACTIVE")
              'openstack-status-ok))
  ;; Show output and list output spell the state differently.
  (should (eq (openstack--status-face "Status" "active")
              'openstack-status-ok))
  (should (eq (openstack--status-face "status" "ERROR")
              'openstack-status-error))
  (should (eq (openstack--status-face "status" "BUILD")
              'openstack-status-pending))
  ;; The three status fields of the default map take a face.
  (should (eq (openstack--status-face "host_status" "UP")
              'openstack-status-ok))
  (should (eq (openstack--status-face "health_status" "unhealthy")
              'openstack-status-error))
  (should (eq (openstack--status-face "vm_state" "paused")
              'openstack-status-off))
  (should (eq (openstack--status-face "status" "attaching")
              'openstack-status-pending))
  (should (null (openstack--status-face "name" "ACTIVE")))
  (should (null (openstack--status-face "status" "made-up"))))

(ert-deftest openstack-status-faces-are-faces ()
  "Every face of `openstack-status-faces' exists."
  (dolist (entry openstack-status-faces)
    (should (facep (cdr entry)))))

(ert-deftest openstack-render-fields-date-face ()
  "A date field renders with `openstack-date'."
  (let ((data (openstack-test--parse
               "{\"id\": \"srv-1\", \"created_at\": \"2026-01-01T10:00:00Z\", \
\"name\": \"web-1\"}"))
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Server" "srv-1" data
                               '("name" "created_at"))
      (should (eq (openstack-test--face-at "2026-01-01T10:00:00Z")
                  'openstack-date))
      (should (null (openstack-test--face-at "web-1"))))))

(ert-deftest openstack-render-fields-date-face-in-list ()
  "A date column of a collection takes `openstack-date'."
  (let ((rows (openstack-test--parse
               "[{\"ID\": \"srv-1\", \"Name\": \"web-1\", \
\"Updated At\": \"2026-01-01T10:00:00Z\"}]")))
    (with-temp-buffer
      (openstack-list-render "(no servers)" rows
                             '("ID" "Name" "Updated At"))
      (goto-char (point-min))
      (search-forward "2026-01-01T10:00:00Z")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'openstack-date)))))

(ert-deftest openstack-date-face-combines-with-change-face ()
  "A changed date takes both the change face and the date face."
  (let* ((old (openstack-test--parse
               "{\"id\": \"srv-1\", \"updated_at\": \"2026-01-01\"}"))
         (new (openstack-test--parse
               "{\"id\": \"srv-1\", \"updated_at\": \"2026-01-02\"}"))
         (inhibit-read-only t))
    (with-temp-buffer
      (let ((openstack--previous-data old))
        (openstack-render-fields "Server" "srv-1" new '("updated_at")))
      (should (equal (openstack-test--face-at "2026-01-02")
                     '(openstack-field-changed openstack-date))))))

(ert-deftest openstack-date-fields-can-be-disabled ()
  "A nil `openstack-date-fields' leaves dates without a face."
  (let ((data (openstack-test--parse
               "{\"id\": \"srv-1\", \"created_at\": \"2026-01-01\"}"))
        (openstack-date-fields nil)
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Server" "srv-1" data '("created_at"))
      (should (null (openstack-test--face-at "2026-01-01"))))))

(ert-deftest openstack-render-fields-status-face ()
  "A status value renders with its status face."
  (let ((data (openstack-test--parse
               "{\"id\": \"srv-1\", \"name\": \"web-1\", \"status\": \"ACTIVE\"}"))
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Server" "srv-1" data '("name" "status"))
      (should (eq (openstack-test--face-at "ACTIVE")
                  'openstack-status-ok))
      (should (null (openstack-test--face-at "web-1"))))))

(ert-deftest openstack-render-fields-field-name-face ()
  "Field names take `openstack-field-name', not a font-lock face."
  (let ((data (openstack-test--parse
               "{\"id\": \"srv-1\", \"status\": \"ACTIVE\"}"))
        (inhibit-read-only t))
    (with-temp-buffer
      (openstack-render-fields "Server" "srv-1" data nil)
      (should (eq (openstack-test--face-at "ID") 'openstack-field-name))
      (should (eq (openstack-test--face-at "status")
                  'openstack-field-name)))))

(ert-deftest openstack-render-error-uses-error-face ()
  "The buffer and header line show a fetch error in `openstack-error'."
  (let ((err '(openstack-cli-error "failed" :stderr "auth failed")))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack--render-error err))
      (should (eq (get-text-property (point-min) 'face) 'openstack-error)))
    (let ((header-line-format nil))
      (openstack--display-error-in-header err)
      (should (eq (get-text-property 0 'face header-line-format)
                  'openstack-error))
      (openstack--display-error-in-header nil)
      (should-not header-line-format))))

(ert-deftest openstack-render-fields-marks-changed ()
  "A value that differs from the previous render takes the change face."
  (let* ((old (openstack-test--parse
               "{\"id\": \"srv-1\", \"name\": \"web-1\", \"status\": \"BUILD\"}"))
         (new (openstack-test--parse
               "{\"id\": \"srv-1\", \"name\": \"web-1\", \"status\": \"ACTIVE\"}"))
         (inhibit-read-only t))
    (with-temp-buffer
      (let ((openstack--previous-data old))
        (openstack-render-fields "Server" "srv-1" new '("name" "status")))
      (should (equal (openstack-test--face-at "ACTIVE")
                     '(openstack-field-changed openstack-status-ok)))
      ;; The unchanged name keeps no face.
      (should (null (openstack-test--face-at "web-1"))))))

(ert-deftest openstack-list-render-status-and-changes ()
  "List cells take the status face and the change face."
  (let* ((old (openstack-test--parse
               "[{\"ID\": \"srv-1\", \"Name\": \"web-1\", \"Status\": \"BUILD\"}, \
{\"ID\": \"srv-2\", \"Name\": \"web-2\", \"Status\": \"ACTIVE\"}]"))
         (new (openstack-test--parse
               "[{\"ID\": \"srv-1\", \"Name\": \"web-1\", \"Status\": \"ACTIVE\"}, \
{\"ID\": \"srv-2\", \"Name\": \"web-2\", \"Status\": \"ACTIVE\"}]")))
    (with-temp-buffer
      (let ((openstack--previous-data old))
        (openstack-list-render "(no servers)" new '("ID" "Name" "Status")))
      (goto-char (point-min))
      (let ((faces (text-properties-at (point))))
        (should (plist-get faces 'openstack-id)))
      ;; The changed row shows both faces, the unchanged row only the status.
      (goto-char (point-min))
      (search-forward "ACTIVE")
      (should (equal (get-text-property (match-beginning 0) 'face)
                     '(openstack-field-changed openstack-status-ok)))
      (search-forward "ACTIVE")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'openstack-status-ok)))))

(ert-deftest openstack-status-changes-resource ()
  "A resource buffer reports the status fields that changed."
  (let ((old (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"BUILD\"}"))
        (new (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"ACTIVE\"}")))
    (should (equal (openstack--status-changes old new)
                   '(("srv-1" "status" "BUILD" "ACTIVE"))))
    ;; The same status twice changes nothing.
    (should (null (openstack--status-changes new new)))))

(ert-deftest openstack-status-changes-collection ()
  "A collection buffer reports changes per row, keyed by row ID."
  (let ((old (openstack-test--parse
              "[{\"ID\": \"srv-1\", \"Status\": \"BUILD\"}, \
{\"ID\": \"srv-2\", \"Status\": \"ACTIVE\"}]"))
        (new (openstack-test--parse
              "[{\"ID\": \"srv-1\", \"Status\": \"ACTIVE\"}, \
{\"ID\": \"srv-2\", \"Status\": \"ACTIVE\"}, \
{\"ID\": \"srv-3\", \"Status\": \"ACTIVE\"}]")))
    (should (equal (openstack--status-changes old new)
                   '(("srv-1" "status" "BUILD" "ACTIVE"))))))

(ert-deftest openstack-state-change-hook ()
  "A state change calls the hook once with buffer, ID and values."
  (let ((old (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"BUILD\"}"))
        (new (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"ERROR\"}"))
        (calls nil))
    (with-temp-buffer
      (let ((openstack-state-change-functions
             (list (lambda (&rest plist) (push plist calls)))))
        (openstack--notify-state-changes new old))
      (should (equal (length calls) 1))
      (should (equal (plist-get (car calls) :id) "srv-1"))
      (should (equal (plist-get (car calls) :field) "status"))
      (should (equal (plist-get (car calls) :old) "BUILD"))
      (should (equal (plist-get (car calls) :new) "ERROR"))
      (should (eq (plist-get (car calls) :buffer) (current-buffer))))
    ;; No change, no call.
    (let (quiet)
      (let ((openstack-state-change-functions
             (list (lambda (&rest _plist) (setq quiet t)))))
        (with-temp-buffer
          (openstack--notify-state-changes new new)))
      (should-not quiet))))

(ert-deftest openstack-refresh-done-runs-hook ()
  "A refresh that changes the status calls the state hook.
The renderer sees the previous data and draws the change face."
  (let ((buf (generate-new-buffer " *openstack-test*"))
        (old (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"BUILD\"}"))
        (new (openstack-test--parse
              "{\"id\": \"srv-1\", \"status\": \"ACTIVE\"}"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (openstack-mode)
          (setq-local openstack--id "srv-1")
          (setq-local openstack--rendered t)
          (setq-local openstack--last-data old)
          (setq-local openstack--fetch-marker (list nil))
          (setq-local openstack-render-function
                      (lambda (id data)
                        (openstack-render-fields "Server" id data
                                                 '("status"))))
          (let ((openstack-state-change-functions
                 (list (lambda (&rest plist) (push plist calls))))
                (inhibit-read-only t))
            (openstack--refresh-done buf openstack--fetch-marker
                                     "srv-1" new nil))
          (should (equal (plist-get (car calls) :old) "BUILD"))
          (should (equal (plist-get (car calls) :new) "ACTIVE"))
          (should (string-match-p "^status: ACTIVE$" (buffer-string)))
          (should (equal (openstack-test--face-at "ACTIVE")
                         '(openstack-field-changed openstack-status-ok)))
          ;; The same data again is not re-rendered nor re-reported.
          (setq openstack--fetch-marker (list nil))
          (let ((inhibit-read-only t))
            (openstack--refresh-done buf openstack--fetch-marker
                                     "srv-1" new nil))
          (should (equal (length calls) 1)))
      (kill-buffer buf))))

(ert-deftest openstack-notify-state-change-messages ()
  "The default listener reports the transition in the echo area."
  (let ((seen nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq seen (apply #'format format-string args)))))
      (openstack-notify-state-change
       :buffer (current-buffer) :id "srv-1" :field "status"
       :old "BUILD" :new "ACTIVE"))
    (should (equal seen "OpenStack srv-1: status BUILD to ACTIVE"))))

(ert-deftest openstack-refresh-delay-adaptive ()
  "A transitional status polls faster, up to the normal interval."
  (let ((openstack-refresh-interval 30)
        (openstack-refresh-fast-interval 5))
    (with-temp-buffer
      (setq-local openstack--last-data
                  (openstack-test--parse "{\"status\": \"ACTIVE\"}"))
      (should (equal (openstack--refresh-delay) 30))
      (setq-local openstack--last-data
                  (openstack-test--parse "{\"status\": \"BUILD\"}"))
      (should (equal (openstack--refresh-delay) 5))
      ;; A collection polls fast while one row still changes.
      (setq-local openstack--last-data
                  (openstack-test--parse
                   "[{\"Status\": \"ACTIVE\"}, {\"Status\": \"BUILD\"}]"))
      (should (equal (openstack--refresh-delay) 5))
      (setq-local openstack--last-data
                  (openstack-test--parse "[{\"Status\": \"ACTIVE\"}]"))
      (should (equal (openstack--refresh-delay) 30))
      ;; The normal interval stays the upper bound.
      (let ((openstack-refresh-fast-interval 60))
        (setq-local openstack--last-data
                    (openstack-test--parse "{\"status\": \"BUILD\"}"))
        (should (equal (openstack--refresh-delay) 30))))))

(ert-deftest openstack-buffer-stale-p-uses-fast-interval ()
  "The stale check of `auto-revert-mode' honors the transitional delay."
  (let ((buf (generate-new-buffer " *openstack-test*"))
        (openstack-refresh-interval 30)
        (openstack-refresh-fast-interval 5)
        (openstack-refresh-visible-only nil))
    (unwind-protect
        (with-current-buffer buf
          (openstack-mode)
          (setq-local openstack--id "srv-1")
          (setq-local openstack--last-fetch-time (- (float-time) 10))
          (setq-local openstack--last-data
                      (openstack-test--parse "{\"status\": \"BUILD\"}"))
          (should (openstack--buffer-stale-p))
          (setq-local openstack--last-data
                      (openstack-test--parse "{\"status\": \"ACTIVE\"}"))
          (should-not (openstack--buffer-stale-p)))
      (kill-buffer buf))))

;;; Tests

(ert-deftest openstack-resource-definitions-registered ()
  "Every definition matches the symbols and the table entry it names.
This test guards the refactor: a mode file states its resource name
once, so a definition and its generated commands cannot drift."
  (should openstack-resource-definitions)
  (dolist (entry openstack-resource-definitions)
    (let* ((type (car entry))
           (definition (cdr entry))
           (mode (intern (format "openstack-%s-mode" type)))
           (display (intern (format "openstack-%s-display" type)))
           (list-mode (intern (format "openstack-%s-list-mode" type)))
           (list-display (intern (format "openstack-%s-list-display" type))))
      (should (equal (plist-get definition :type) type))
      ;; The type string serves as the client command name.
      (should (equal (openstack-resource-cli-name type) type))
      (should (eq (plist-get definition :mode) mode))
      (should (eq (plist-get definition :display) display))
      (should (eq (plist-get definition :list-mode) list-mode))
      (should (eq (plist-get definition :list-display) list-display))
      (dolist (function (list mode display list-mode list-display))
        (should (fboundp function)))
      (should (equal (openstack-resource-type-for-mode mode) type))
      (should (equal (nth 1 (openstack-resource-type type)) mode))
      (should (eq (nth 2 (openstack-resource-type type)) display)))))

(ert-deftest openstack-resource-types-match-definitions ()
  "The table and the registry hold the same types in the same order.
The ID prompts, the Org links and the xref backend read the table,
so a definition missing there stays invisible to them."
  (should (equal (mapcar #'car openstack-resource-types)
                 (mapcar #'car openstack-resource-definitions))))

(ert-deftest openstack-resource-mode-settings-come-from-definition ()
  "The generated modes carry the settings of their definition."
  (dolist (entry openstack-resource-definitions)
    (let ((definition (cdr entry))
          (buf (generate-new-buffer " *openstack-resource-test*")))
      (unwind-protect
          (with-current-buffer buf
            (funcall (plist-get definition :list-mode))
            (should (equal openstack-id-prefix
                           (plist-get definition :id-prefix)))
            (should (equal openstack-url-suffix
                           (plist-get definition :url-suffix)))
            (should (equal openstack-list--noun
                           (plist-get definition :noun)))
            (should (eq openstack-show-command
                        (plist-get definition :display)))
            (should (equal (openstack-resource-type-for-mode
                            (plist-get definition :list-mode))
                           nil)))
        (kill-buffer buf)))))

(ert-deftest openstack-resource-cli-name-override ()
  "A definition may name a different client command."
  (let ((openstack-resource-definitions
         (cons '("custom" :type "custom" :cli "custom-cli")
               openstack-resource-definitions)))
    (should (equal (openstack-resource-cli-name "custom") "custom-cli"))
    (should (equal (openstack-resource-cli-name "server") "server"))
    (should (equal (openstack-resource-cli-name "unknown") "unknown"))))

(ert-deftest openstack-resource-definition-values ()
  "The registry keeps the properties of the macro call."
  (let ((definition (openstack-resource-definition "container")))
    (should (equal (plist-get definition :noun) "containers"))
    (should (equal (plist-get definition :id-prefix)
                   "project/containers"))
    (should (equal (plist-get definition :url-suffix) ""))
    (should (equal (plist-get definition :list-arguments) '("--long")))
    (should (equal (plist-get definition :list-fields)
                   '("Name" "Bytes" "Count"))))
  (should (null (openstack-resource-definition "unknown"))))

(provide 'openstack-mode-tests)
;;; openstack-mode-tests.el ends here
