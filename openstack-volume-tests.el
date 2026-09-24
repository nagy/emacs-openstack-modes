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
(require 'openstack-volume)

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

(ert-deftest openstack-volume-autoloads ()
  "The entry points carry autoload cookies."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-volume.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n\\(?:(defun openstack-volume-display\\|(define-derived-mode openstack-volume-mode\\)"
             source))))

(provide 'openstack-volume-tests)
;;; openstack-volume-tests.el ends here
