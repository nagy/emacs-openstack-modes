;;; openstack-image-tests.el --- Tests for openstack-image -*- lexical-binding: t -*-

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

(defconst openstack-image-test--show-json
  (concat
   "{\"id\": \"img-1\", \"name\": \"ubuntu-24.04\", \"status\": \"active\", "
   "\"visibility\": \"public\", \"disk_format\": \"qcow2\", "
   "\"container_format\": \"bare\", \"size\": 234881024, "
   "\"owner\": \"a1b2c3d4e5f60718293a4b5c6d7e8f90\", "
   "\"tags\": [\"latest\"], \"zzz_extra\": \"late\", "
   "\"created_at\": \"2026-01-01T00:00:00Z\"}")
  "Parsable `openstack image show' output for the tests.
Contains fields from `openstack-image-fields' out of order plus
an unordered extra to exercise the sorting of unlisted fields.")

;;; Tests

(ert-deftest openstack-image-mode-is-derived ()
  "The image mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-image-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-image-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function #'openstack-image--fetch))
          (should (eq openstack-render-function #'openstack-image--render))
          (should (equal openstack-id-prefix "images")))
      (kill-buffer buf))))

(ert-deftest openstack-image-fetch-calls-async-request ()
  "The fetcher runs `openstack image show ID' through the CLI layer."
  (let ((args-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key _success-fn _error-fn)
                              (setq args-seen args)
                              :process-handle))))
      (should (eq (openstack-image--fetch
                   "img-1" (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("image" "show" "img-1"))))))

(ert-deftest openstack-image-render-shows-ordered-fields ()
  "The renderer lists `openstack-image-fields' first, in order."
  (let ((data (with-temp-buffer
                (insert openstack-image-test--show-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-image--render "img-1" data))
      (let ((text (buffer-string)))
        (should (string-match-p "Image: ubuntu-24.04\n" text))
        (should (string-match-p "^status: active$" text))
        (should (string-match-p "^tags: \\[\"latest\"\\]$" text))
        (should (< (string-match "^name: ubuntu-24.04$" text)
                   (string-match "^zzz_extra: late$" text)))))))

(ert-deftest openstack-image-display-renders-from-real-client ()
  "A full round trip renders the fixture's image fields."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = show ]; then "
           "echo '" openstack-image-test--show-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "img-1"))
       (unwind-protect
           (progn
             (openstack-image-display id)
             (let ((buf (get-buffer "*OpenStack Image* <img-1>")))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (should (derived-mode-p 'openstack-image-mode))
                 (should (string-match-p "^Image: ubuntu-24.04$"
                                         (buffer-string)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer "*OpenStack Image* <img-1>")))
           (when buf (kill-buffer buf))))))))

(defconst openstack-image-list-test--list-json
  (concat
   "[{\"ID\": \"img-1\", \"Name\": \"ubuntu-24.04\", \"Status\": \"active\", "
   "\"Size\": \"234881024\", \"Zebra\": \"late\", \"Alpha\": \"early\"}, "
   "{\"ID\": \"img-2\", \"Name\": \"debian-12\", \"Status\": \"active\", "
   "\"Size\": \"117440512\", \"Zebra\": \"late\", \"Alpha\": \"early\"}]")
  "Parsable `openstack image list' output for the tests.
Contains fields from `openstack-image-list-fields' out of
order, plus unordered extras (Alpha, Zebra) to exercise the
sorting of unlisted columns.")

;;; Tests

(ert-deftest openstack-image-list-mode-is-derived ()
  "The list mode derives from `openstack-list-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-image-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-image-list-mode)
          (should (derived-mode-p 'openstack-list-mode))
          (should (derived-mode-p 'tabulated-list-mode))
          (should openstack-collection)
          (should openstack-render-manages-buffer)
          (should (equal openstack-list--noun "images"))
          (should (eq openstack-fetch-function
                      #'openstack-image-list--fetch))
          (should (eq openstack-render-function
                      #'openstack-image-list--render))
          ;; RET on a row opens the image's show buffer.
          (should (eq openstack-show-command
                      #'openstack-image-display))
          ;; A collection has no resource ID: the ID commands error.
          (should-error (openstack--resource-id t) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-image-list-fetch-runs-image-list ()
  "The fetcher runs `openstack image list' through the CLI layer."
  (let ((args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (openstack-image-list--fetch
                   nil (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("image" "list")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-image-list-columns-ordered-and-sorted ()
  "Columns follow `openstack-image-list-fields', extras sorted."
  (let* ((data (with-temp-buffer
                 (insert openstack-image-list-test--list-json)
                 (goto-char (point-min))
                 (json-parse-buffer :object-type 'hash-table
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
         (columns (openstack-image-list--columns data)))
    (should (equal columns
                   '("ID" "Name" "Status" "Size" "Alpha" "Zebra")))))

(ert-deftest openstack-image-list-render-table ()
  "The renderer fills the tabulated list with a header and all rows."
  (let ((data (with-temp-buffer
                (insert openstack-image-list-test--list-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (openstack-image-list-mode)
      (openstack-image-list--render nil data)
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column '("ID" "Name" "Status" "Size" "Alpha" "Zebra"))
          (should (string-match-p (regexp-quote column) header)))
        (should (string-match-p "^img-1 +ubuntu-24\.04 +active +234881024 +early +late" text))
        (should (string-match-p "^img-2 +debian-12 +active +117440512 +early +late" text))
        ;; The first row is the row at point, with its resource ID.
        (should (equal (tabulated-list-get-id) "img-1"))))))

(ert-deftest openstack-image-list-render-empty ()
  "An empty list renders a placeholder instead of an empty buffer."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (openstack-image-list--render nil nil))
    (should (string-match-p "(no images)" (buffer-string)))))

(ert-deftest openstack-image-list-display-renders-from-real-client ()
  "A full round trip renders the fixture's image list.
The display command must set `openstack-collection' so the
refresh pipeline runs without a resource ID."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = list ]; then "
           "echo '" openstack-image-list-test--list-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5))
       (unwind-protect
           (progn
             (openstack-image-list-display)
             (let ((buf (get-buffer openstack-image-list-buffer-name)))
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
                   (should (string-match-p "^img-1 +ubuntu-24\\.04" text)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer openstack-image-list-buffer-name)))
           (when buf (kill-buffer buf))))))))

(provide 'openstack-image-tests)
;;; openstack-image-tests.el ends here
