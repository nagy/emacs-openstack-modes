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
(require 'openstack-server)

;; Forward reference: the list buffer's RET command.
(declare-function openstack-server-display "openstack-server" (id))

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
  "The list mode derives from `openstack-list-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-server-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-server-list-mode)
          (should (derived-mode-p 'openstack-list-mode))
          (should (derived-mode-p 'tabulated-list-mode))
          (should openstack-collection)
          (should openstack-render-manages-buffer)
          (should (equal openstack-list--noun "servers"))
          (should (eq openstack-fetch-function
                      #'openstack-server-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-server-list--render))
          ;; RET on a row opens the server's show buffer.
          (should (eq openstack-show-command
                      #'openstack-server-display))
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
  "The renderer fills the tabulated list with a header and all rows."
  (let ((data (with-temp-buffer
                (insert openstack-server-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (openstack-server-list-mode)
      (openstack-server-list--render nil data)
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column '("ID" "Name" "Status" "Alpha" "Zebra"))
          (should (string-match-p (regexp-quote column) header)))
        (should (string-match-p "^id-1 +web-1 +ACTIVE +early +late" text))
        (should (string-match-p "^id-2 +web-2 +SHUTOFF +early +late" text))
        ;; The first row is the row at point, with its resource ID.
        (should (equal (tabulated-list-get-id) "id-1"))))))

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
                 (should (string-match-p
                          "Name" (prin1-to-string header-line-format)))
                 (let ((text (buffer-string)))
                   (should (string-match-p "^id-1 +web-1" text)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-server-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-server-list-RET-opens-server-show ()
  "RET on a row opens the server's show buffer for the row's ID."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = list ]; then "
           "echo '" openstack-server-list-test--list-json "'; "
           "elif [ \"$2\" = show ]; then "
           "echo '{\"id\": \"id-1\", \"name\": \"web-1\", "
           "\"status\": \"ACTIVE\"}'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-server-list-display)
             (let ((list-buf (get-buffer
                              openstack-server-list-buffer-name)))
               (should list-buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p list-buf)
                       (with-current-buffer list-buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer list-buf
                 (re-search-forward "id-1")
                 (goto-char (match-beginning 0))
                 (openstack-display-at-point))
               (let ((show-buf (get-buffer "*OpenStack Server* <id-1>")))
                 (should show-buf)
                 (openstack-cli-test--wait-until
                  (lambda ()
                    (and (buffer-live-p show-buf)
                         (with-current-buffer show-buf
                           (and openstack--rendered
                                (not openstack--pending))))))
                 (with-current-buffer show-buf
                   (should (string-match-p "web-1" (buffer-string)))
                   (should (null openstack--last-error))))))
         (dolist (name (list openstack-server-list-buffer-name
                             "*OpenStack Server* <id-1>"))
           (let ((buf (get-buffer name)))
             (when buf (kill-buffer buf)))))))))

(ert-deftest openstack-server-list-autoloads ()
  "The file loads itself from the generated autoloads."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-server.el"))
                  (buffer-string))))
    ;; The macro writes the commands, so the file needs one autoloaded
    ;; require instead of a cookie per generated command.
    (should (string-match-p
             "^;;;###autoload (require 'openstack-server)$"
             source))))

(provide 'openstack-server-list-tests)
;;; openstack-server-list-tests.el ends here
