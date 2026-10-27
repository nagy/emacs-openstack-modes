;;; openstack-volume-list-tests.el --- Tests for openstack-volume-list -*- lexical-binding: t -*-

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
(require 'openstack-volume)

;; Forward reference: the list buffer's RET command.
(declare-function openstack-volume-display "openstack-volume" (id))

(defconst openstack-volume-list-test--list-json
  (concat
   "[{\"ID\": \"vol-1\", \"Name\": \"data-1\", \"Status\": \"in-use\", "
   "\"Size\": 20, \"Zebra\": \"late\", \"Alpha\": \"early\"}, "
   "{\"ID\": \"vol-2\", \"Name\": \"\", \"Status\": \"available\", "
   "\"Size\": 10, \"Zebra\": \"late\", \"Alpha\": \"early\"}]")
  "Parsable `openstack volume list' output for the tests.
Contains fields from `openstack-volume-list-fields' out of
order, plus unordered extras (Alpha, Zebra) to exercise the
sorting of unlisted columns.")

;;; Tests

(ert-deftest openstack-volume-list-mode-is-derived ()
  "The list mode derives from `openstack-list-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-volume-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-volume-list-mode)
          (should (derived-mode-p 'openstack-list-mode))
          (should (derived-mode-p 'tabulated-list-mode))
          (should openstack-collection)
          (should openstack-render-manages-buffer)
          (should (equal openstack-list--noun "volumes"))
          (should (eq openstack-fetch-function
                      #'openstack-volume-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-volume-list--render))
          ;; RET on a row opens the volume's show buffer.
          (should (eq openstack-show-command
                      #'openstack-volume-display))
          ;; A collection has no resource ID: the ID commands error.
          (should-error (openstack--resource-id t) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-volume-list-fetch-runs-volume-list ()
  "The fetcher runs `openstack volume list' through the CLI layer."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (openstack-volume-list--fetch
                   nil (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("volume" "list")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-volume-list-columns-ordered-and-sorted ()
  "Columns follow `openstack-volume-list-fields', extras sorted."
  (let* ((data (with-temp-buffer
                 (insert openstack-volume-list-test--list-json)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (columns (openstack-volume-list--columns data)))
    (should (equal columns
                   '("ID" "Name" "Status" "Size" "Alpha" "Zebra")))))

(ert-deftest openstack-volume-list-render-table ()
  "The renderer fills the tabulated list with a header and all rows."
  (let ((data (with-temp-buffer
                (insert openstack-volume-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (openstack-volume-list-mode)
      (openstack-volume-list--render nil data)
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column '("ID" "Name" "Status" "Size" "Alpha" "Zebra"))
          (should (string-match-p (regexp-quote column) header)))
        (should (string-match-p "^vol-1 +data-1 +in-use +20 +early +late" text))
        (should (string-match-p "^vol-2 +- +available +10 +early +late" text))
        ;; The first row is the row at point, with its resource ID.
        (should (equal (tabulated-list-get-id) "vol-1"))))))

(ert-deftest openstack-volume-list-render-empty ()
  "An empty list renders a placeholder instead of an empty buffer."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (openstack-volume-list--render nil nil))
    (should (string-match-p "(no volumes)" (buffer-string)))))

(ert-deftest openstack-volume-list-display-renders-from-real-client ()
  "A full round trip renders the fixture's volume list.
The display command must set `openstack-collection' so the
refresh pipeline runs without a resource ID."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = list ]; then "
           "echo '" openstack-volume-list-test--list-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-volume-list-display)
             (let ((buf (get-buffer openstack-volume-list-buffer-name)))
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
                   (should (string-match-p "^vol-1 +data-1" text)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-volume-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-volume-list-autoloads ()
  "The file loads itself from the generated autoloads."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-volume.el"))
                  (buffer-string))))
    ;; The macro writes the commands, so the file needs one autoloaded
    ;; require instead of a cookie per generated command.
    (should (string-match-p
             "^;;;###autoload (require 'openstack-volume)$"
             source))))

(provide 'openstack-volume-list-tests)
;;; openstack-volume-list-tests.el ends here
