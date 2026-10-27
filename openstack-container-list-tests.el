;;; openstack-container-list-tests.el --- Tests for openstack-container-list -*- lexical-binding: t; -*-

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
(require 'openstack-container)

;; Forward reference: the list buffer's RET command.
(declare-function openstack-container-display "openstack-container" (id))

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

(ert-deftest openstack-container-list-autoloads ()
  "The file loads itself from the generated autoloads."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-container.el"))
                  (buffer-string))))
    ;; The macro writes the commands, so the file needs one autoloaded
    ;; require instead of a cookie per generated command.
    (should (string-match-p
             "^;;;###autoload (require 'openstack-container)$"
             source))))

(provide 'openstack-container-list-tests)
;;; openstack-container-list-tests.el ends here
