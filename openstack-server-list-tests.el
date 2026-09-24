;;; openstack-server-list-tests.el --- Tests for openstack-server-list -*- lexical-binding: t -*-

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
(require 'openstack-server-list)

(defconst openstack-server-list-test--list-json
  (concat
   "[{\"ID\": \"id-1\", \"Name\": \"web-1\", \"Status\": \"ACTIVE\", "
   "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
   "{\"ID\": \"id-2\", \"Name\": \"web-2\", \"Status\": \"SHUTOFF\", "
   "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
  "Parsable `openstack server list' output for the tests.
Contains fields from `openstack-server-list-fields' out of
order, plus unordered extras (Alpha, Zebra) to exercise the
sorting of unlisted columns.")

;;; Tests

(ert-deftest openstack-server-list-mode-is-derived ()
  "The list mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-server-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-server-list-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function
                      #'openstack-server-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-server-list--render))
          ;; A collection has no resource ID: the ID commands error.
          (should-error (openstack--resource-id t) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-server-list-fetch-runs-server-list ()
  "The fetcher runs `openstack server list' through the CLI layer."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (openstack-server-list--fetch
                   nil (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("server" "list")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-server-list-columns-ordered-and-sorted ()
  "Columns follow `openstack-server-list-fields', extras sorted."
  (let* ((data (with-temp-buffer
                 (insert openstack-server-list-test--list-json)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (columns (openstack-server-list--columns data)))
    (should (equal columns
                   '("ID" "Name" "Status" "Alpha" "Zebra")))))

(ert-deftest openstack-server-list-render-table ()
  "The renderer draws a padded table with a header and all rows."
  (let ((data (with-temp-buffer
                (insert openstack-server-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-server-list--render nil data))
      (let ((text (buffer-string)))
        (should (string-match-p "^ID +Name +Status +Alpha +Zebra *$" text))
        (should (string-match-p "^id-1 +web-1 +ACTIVE +early +late *$" text))
        (should (string-match-p "^id-2 +web-2 +SHUTOFF +early +late *$" text))
        ;; A separator line under the header, at least as long as it.
        (should (string-match "^\\(-+\\)\n" text))
        (should (>= (length (match-string 1 text)) 10))))))

(ert-deftest openstack-server-list-render-empty ()
  "An empty list renders a placeholder instead of an empty buffer."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (openstack-server-list--render nil nil))
    (should (string-match-p "(no servers)" (buffer-string)))))

(ert-deftest openstack-server-list-display-renders-from-real-client ()
  "A full round trip renders the fixture's server list.
The display command must set `openstack-collection' so the
refresh pipeline runs without a resource ID."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = list ]; then "
           "echo '" openstack-server-list-test--list-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-server-list-display)
             (let ((buf (get-buffer openstack-server-list-buffer-name)))
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
                 (let ((text (buffer-string)))
                   (should (string-match-p "^ID +Name +Status" text))
                   (should (string-match-p "^id-1 +web-1" text)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-server-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-server-list-autoloads ()
  "The entry points carry autoload cookies."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-server-list.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n\\(?:(defun openstack-server-list-display\\|(define-derived-mode openstack-server-list-mode\\)"
             source))))

(provide 'openstack-server-list-tests)
;;; openstack-server-list-tests.el ends here
