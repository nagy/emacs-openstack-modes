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
(require 'openstack-image)

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

(ert-deftest openstack-image-autoloads ()
  "The file loads itself from the generated autoloads."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-image.el"))
                  (buffer-string))))
    ;; The macro writes the commands, so the file needs one autoloaded
    ;; require instead of a cookie per generated command.
    (should (string-match-p
             "^;;;###autoload (require 'openstack-image)$"
             source))))

(provide 'openstack-image-tests)
;;; openstack-image-tests.el ends here
