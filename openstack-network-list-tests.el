;;; openstack-network-list-tests.el --- Tests for openstack-network-list -*- lexical-binding: t; -*-

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
(require 'openstack-network-list)

;; Forward reference: the list buffer's RET command.
(declare-function openstack-network-display "openstack-network" (id))

(defconst openstack-network-list-test--list-json
  (concat
   "[{\"ID\": \"net-1\", \"Name\": \"provider\", \"Status\": \"ACTIVE\", "
   "\"Subnets\": \"subnet-1\", \"Shared\": true, "
   "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
   "{\"ID\": \"net-2\", \"Name\": \"\", \"Status\": \"DOWN\", "
   "\"Subnets\": \"\", \"Shared\": false, "
   "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
  "Parsable `openstack network list' output for the tests.
Contains fields from `openstack-network-list-fields' out of
order, plus unordered extras (Alpha, Zebra) to exercise the
sorting of unlisted columns.")

;;; Tests

(ert-deftest openstack-network-list-mode-is-derived ()
  "The list mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-network-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-network-list-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function
                      #'openstack-network-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-network-list--render))
          ;; RET on a row opens the network's show buffer.
          (should (eq openstack-show-command
                      #'openstack-network-display))
          ;; A collection has no resource ID: the ID commands error.
          (should-error (openstack--resource-id t) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-network-list-fetch-runs-network-list ()
  "The fetcher runs `openstack network list' through the CLI layer."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (openstack-network-list--fetch
                   nil (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("network" "list")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-network-list-columns-ordered-and-sorted ()
  "Columns follow `openstack-network-list-fields', extras sorted."
  (let* ((data (with-temp-buffer
                 (insert openstack-network-list-test--list-json)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (columns (openstack-network-list--columns data)))
    (should (equal columns
                   '("ID" "Name" "Status" "Subnets" "Shared"
                     "Alpha" "Zebra")))))

(ert-deftest openstack-network-list-render-table ()
  "The renderer draws a padded table with a header and all rows."
  (let ((data (with-temp-buffer
                (insert openstack-network-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-network-list--render nil data))
      (let ((text (buffer-string)))
        (should (string-match-p
                 "^ID +Name +Status +Subnets +Shared +Alpha +Zebra *$"
                 text))
        (should (string-match-p
                 "^net-1 +provider +ACTIVE +subnet-1 +true +early +late *$"
                 text))
        ;; An empty name renders as the dash of `openstack--format-value'.
        (should (string-match-p "^net-2 +- +DOWN +- +- +early +late *$"
                                text))
        ;; A separator line under the header, at least as long as it.
        (should (string-match "^\\(-+\\)\n" text))
        (should (>= (length (match-string 1 text)) 10))))))

(ert-deftest openstack-network-list-render-empty ()
  "An empty list renders a placeholder instead of an empty buffer."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (openstack-network-list--render nil nil))
    (should (string-match-p "(no networks)" (buffer-string)))))

(ert-deftest openstack-network-list-display-renders-from-real-client ()
  "A full round trip renders the fixture's network list.
The display command must set `openstack-collection' so the
refresh pipeline runs without a resource ID."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = list ]; then "
           "echo '" openstack-network-list-test--list-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-network-list-display)
             (let ((buf (get-buffer openstack-network-list-buffer-name)))
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
                   (should (string-match-p "^net-1 +provider" text)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-network-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-network-list-autoloads ()
  "The entry points carry autoload cookies."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-network-list.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n\\(?:(defun openstack-network-list-display\\|(define-derived-mode openstack-network-list-mode\\)"
             source))))

(provide 'openstack-network-list-tests)
;;; openstack-network-list-tests.el ends here
