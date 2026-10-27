;;; openstack-volume-tests.el --- Tests for openstack-volume -*- lexical-binding: t -*-

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

(defconst openstack-volume-test--show-json
  (concat
   "{\"id\": \"vol-1\", \"name\": \"data-1\", \"status\": \"in-use\", "
   "\"size\": 20, \"volume_type\": \"__DEFAULT__\", \"bootable\": \"false\", "
   "\"attachments\": [{\"server_id\": \"srv-1\", \"device\": \"/dev/vdb\"}], "
   "\"availability_zone\": \"nova\", \"zzz_extra\": \"late\", "
   "\"created_at\": \"2026-01-01T00:00:00Z\"}")
  "Parsable `openstack volume show' output for the tests.
Contains fields from `openstack-volume-fields' out of order plus
an unordered extra to exercise the sorting of unlisted fields.")

;;; Tests

(ert-deftest openstack-volume-mode-is-derived ()
  "The volume mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-volume-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-volume-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function #'openstack-volume--fetch))
          (should (eq openstack-render-function #'openstack-volume--render))
          (should (equal openstack-id-prefix "volumes")))
      (kill-buffer buf))))

(ert-deftest openstack-volume-fetch-calls-async-request ()
  "The fetcher runs `openstack volume show ID' through the CLI layer."
  (let ((args-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key _success-fn _error-fn)
                              (setq args-seen args)
                              :process-handle))))
      (should (eq (openstack-volume--fetch
                   "vol-1" (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("volume" "show" "vol-1"))))))

(ert-deftest openstack-volume-render-shows-ordered-fields ()
  "The renderer lists `openstack-volume-fields' first, in order."
  (let ((data (with-temp-buffer
                (insert openstack-volume-test--show-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-volume--render "vol-1" data))
      (let ((text (buffer-string)))
        (should (string-match-p "Volume: data-1\n" text))
        (should (string-match-p "^status: in-use$" text))
        (should (string-match-p "^attachments: \\[{\"server_id\"" text))
        (should (< (string-match "^name: data-1$" text)
                   (string-match "^zzz_extra: late$" text)))))))

(ert-deftest openstack-volume-display-renders-from-real-client ()
  "A full round trip renders the fixture's volume fields."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = show ]; then "
           "echo '" openstack-volume-test--show-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "vol-1"))
       (unwind-protect
           (progn
             (openstack-volume-display id)
             (let ((buf (get-buffer "*OpenStack Volume* <vol-1>")))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (should (derived-mode-p 'openstack-volume-mode))
                 (should (string-match-p "^Volume: data-1$"
                                         (buffer-string)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer "*OpenStack Volume* <vol-1>")))
           (when buf (kill-buffer buf))))))))

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

(provide 'openstack-volume-tests)
;;; openstack-volume-tests.el ends here
