;;; openstack-container-tests.el --- Tests for openstack-container -*- lexical-binding: t; -*-

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
(require 'openstack-cli-tests)
(require 'openstack-resources)

(defconst openstack-container-test--show-json
  (concat
   "{\"container\": \"logs\", \"bytes_used\": 4096, "
   "\"object_count\": 2, \"account\": \"v1/AUTH_demo\", "
   "\"read_acl\": \".r:*\", \"write_acl\": \"\", "
   "\"storage_policy\": \"default\", \"zzz_extra\": \"late\", "
   "\"properties\": {\"owner\": \"ops\"}}")
  "Parsable `openstack container show' output for the tests.
Contains fields from `openstack-container-fields' out of order plus
an unordered extra to exercise the sorting of unlisted fields.")

;;; Tests

(ert-deftest openstack-container-mode-is-derived ()
  "The container mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-container-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-container-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function #'openstack-container--fetch))
          (should (eq openstack-render-function
                      #'openstack-container--render))
          (should (equal openstack-id-prefix "project/containers"))
          (should (equal openstack-url-suffix "")))
      (kill-buffer buf))))

(ert-deftest openstack-container-mode-dashboard-url ()
  "The dashboard URL points at the project's container page."
  (let ((buf (generate-new-buffer " *openstack-container-test*"))
        (openstack-web-base-url "https://horizon.example.org"))
    (unwind-protect
        (with-current-buffer buf
          (openstack-container-mode)
          (should (equal
                   (openstack-dashboard-url "logs")
                   "https://horizon.example.org/project/containers/logs")))
      (kill-buffer buf))))

(ert-deftest openstack-container-fetch-calls-async-request ()
  "The fetcher runs `openstack container show NAME' through the CLI layer."
  (let ((args-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key _success-fn _error-fn)
                              (setq args-seen args)
                              :process-handle))))
      (should (eq (openstack-container--fetch
                   "logs" (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("container" "show" "logs"))))))

(ert-deftest openstack-container-render-shows-ordered-fields ()
  "The renderer lists `openstack-container-fields' first, in order."
  (let ((data (with-temp-buffer
                (insert openstack-container-test--show-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-container--render "logs" data))
      (let ((text (buffer-string)))
        (should (string-match-p "Container: logs\n" text))
        (should (string-match-p "^container: logs$" text))
        (should (string-match-p "^bytes_used: 4096$" text))
        (should (string-match-p "^object_count: 2$" text))
        (should (< (string-match "^storage_policy: default$" text)
                   (string-match "^zzz_extra: late$" text)))))))

(ert-deftest openstack-container-display-renders-from-real-client ()
  "A full round trip renders the fixture's container fields."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = show ]; then "
           "echo '" openstack-container-test--show-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "logs"))
       (unwind-protect
           (progn
             (openstack-container-display id)
             (let ((buf (get-buffer "*OpenStack Container* <logs>")))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (should (derived-mode-p 'openstack-container-mode))
                 (should (equal (openstack--resource-id) "logs"))
                 (should (string-match-p "^Container: logs$"
                                         (buffer-string)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer "*OpenStack Container* <logs>")))
           (when buf (kill-buffer buf))))))))

(defconst openstack-container-list-test--list-json
  (concat
   "[{\"Name\": \"logs\", \"Bytes\": 4096, \"Count\": 2}, "
   "{\"Name\": \"backups\", \"Bytes\": 1048576, \"Count\": 12}]")
  "Parsable `openstack container list --long' output for the tests.
A container has no ID field: the name identifies the row.")

;;; Tests

(ert-deftest openstack-container-list-mode-is-derived ()
  "The list mode derives from `openstack-list-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-container-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-container-list-mode)
          (should (derived-mode-p 'openstack-list-mode))
          (should (derived-mode-p 'tabulated-list-mode))
          (should openstack-collection)
          (should openstack-render-manages-buffer)
          (should (equal openstack-list--noun "containers"))
          (should (eq openstack-fetch-function
                      #'openstack-container-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-container-list--render))
          (should (equal openstack-id-prefix "project/containers"))
          (should (equal openstack-url-suffix ""))
          ;; RET on a row opens the container's show buffer.
          (should (eq openstack-show-command
                      #'openstack-container-display))
          ;; A collection has no resource ID: the ID commands error.
          (should-error (openstack--resource-id t) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-container-list-fetch-runs-container-list ()
  "The fetcher runs `openstack container list --long'."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (openstack-container-list--fetch
                   nil (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("container" "list" "--long")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-container-list-columns-ordered ()
  "Columns follow `openstack-container-list-fields'."
  (let* ((data (with-temp-buffer
                 (insert openstack-container-list-test--list-json)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (columns (openstack-container-list--columns data)))
    (should (equal columns '("Name" "Bytes" "Count")))))

(ert-deftest openstack-container-list-render-table ()
  "The renderer fills the table, and a row takes the name as its ID."
  (let ((data (with-temp-buffer
                (insert openstack-container-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (openstack-container-list-mode)
      (openstack-container-list--render nil data)
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column '("Name" "Bytes" "Count"))
          (should (string-match-p (regexp-quote column) header)))
        (should (string-match-p "^logs +4096 +2$" text))
        (should (string-match-p "^backups +1048576 +12$" text))
        ;; A container has no UUID: the row identity is the name.
        (should (equal (tabulated-list-get-id) "logs"))))))

(ert-deftest openstack-container-list-render-empty ()
  "An empty list renders a placeholder instead of an empty buffer."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (openstack-container-list--render nil nil))
    (should (string-match-p "(no containers)" (buffer-string)))))

(ert-deftest openstack-container-list-display-renders-from-real-client ()
  "A full round trip renders the fixture's container list."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$1\" = container ]; then "
           "echo '" openstack-container-list-test--list-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-container-list-display)
             (let ((buf (get-buffer openstack-container-list-buffer-name)))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (should openstack-collection)
                 (should (null openstack--id))
                 (should (string-match-p
                          "Name" (prin1-to-string header-line-format)))
                 (should (string-match-p "^logs +4096" (buffer-string)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-container-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(provide 'openstack-container-tests)
;;; openstack-container-tests.el ends here
