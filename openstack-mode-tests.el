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
                     "openstack-set-id" "openstack-mode"))
      (should (string-match-p
               (format "^;;;###autoload\n(\\(?:defun\\|define-derived-mode\\) %s\\b"
                       (regexp-quote entry))
               source)))))

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
    (should (equal (openstack--format-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-format-url-trailing-slash ()
  "A trailing slash in the base URL is trimmed."
  (let ((openstack-web-base-url "https://horizon.example.org/")
        (openstack-id-prefix "servers"))
    (should (equal (openstack--format-url "abc-123")
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
          (let ((openstack-refresh-interval 30))
            (setq-local openstack--last-fetch-time (float-time))
            (should-not (openstack--buffer-stale-p))
            (setq-local openstack--last-fetch-time (- (float-time) 31))
            (should (openstack--buffer-stale-p))
            ;; An in-flight fetch is never interrupted.
            (setq-local openstack--pending t)
            (should-not (openstack--buffer-stale-p))))
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
          ;; The resource identity survives the switch, and the new
          ;; mode renders its own view immediately (auto-revert sees
          ;; an empty fetch history and reverts at once).
          (should (equal openstack--id "res-123"))
          (should openstack--rendered)
          (should (string-match-p "ID: res-123" (buffer-string))))
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (when (process-live-p proc)
        (delete-process proc)))))

(provide 'openstack-mode-tests)
;;; openstack-mode-tests.el ends here
