;;; openstack-network-tests.el --- Tests for openstack-network -*- lexical-binding: t; -*-

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
(require 'openstack-network)

(defconst openstack-network-test--show-json
  (concat
   "{\"id\": \"net-1\", \"name\": \"provider\", \"status\": \"ACTIVE\", "
   "\"admin_state_up\": true, \"shared\": true, "
   "\"router:external\": false, \"subnets\": [\"subnet-1\"], "
   "\"provider:network_type\": \"vxlan\", "
   "\"provider:segmentation_id\": 42, \"zzz_extra\": \"late\", "
   "\"created_at\": \"2026-01-01T00:00:00Z\"}")
  "Parsable `openstack network show' output for the tests.
Contains fields from `openstack-network-fields' out of order plus
an unordered extra to exercise the sorting of unlisted fields.")

;;; Tests

(ert-deftest openstack-network-mode-is-derived ()
  "The network mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-network-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-network-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function #'openstack-network--fetch))
          (should (eq openstack-render-function #'openstack-network--render))
          (should (equal openstack-id-prefix "project/networks"))
          (should (equal openstack-url-suffix "/detail")))
      (kill-buffer buf))))

(ert-deftest openstack-network-mode-dashboard-url ()
  "The dashboard URL points at the project's network detail page."
  (let ((buf (generate-new-buffer " *openstack-network-test*"))
        (openstack-web-base-url "https://horizon.example.org"))
    (unwind-protect
        (with-current-buffer buf
          (openstack-network-mode)
          (should (equal
                   (openstack--format-url "net-1")
                   "https://horizon.example.org/project/networks/net-1/detail")))
      (kill-buffer buf))))

(ert-deftest openstack-network-fetch-calls-async-request ()
  "The fetcher runs `openstack network show ID' through the CLI layer."
  (let ((args-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key _success-fn _error-fn)
                              (setq args-seen args)
                              :process-handle))))
      (should (eq (openstack-network--fetch
                   "net-1" (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("network" "show" "net-1"))))))

(ert-deftest openstack-network-render-shows-ordered-fields ()
  "The renderer lists `openstack-network-fields' first, in order."
  (let ((data (with-temp-buffer
                (insert openstack-network-test--show-json)
                (goto-char (point-min))
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object nil))))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (openstack-network--render "net-1" data))
      (let ((text (buffer-string)))
        (should (string-match-p "Network: provider\n" text))
        (should (string-match-p "^status: ACTIVE$" text))
        (should (string-match-p "^subnets: \\[\"subnet-1\"\\]$" text))
        (should (< (string-match "^name: provider$" text)
                   (string-match "^zzz_extra: late$" text)))))))

(ert-deftest openstack-network-display-renders-from-real-client ()
  "A full round trip renders the fixture's network fields."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = show ]; then "
           "echo '" openstack-network-test--show-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "net-1"))
       (unwind-protect
           (progn
             (openstack-network-display id)
             (let ((buf (get-buffer "*OpenStack Network* <net-1>")))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (should (derived-mode-p 'openstack-network-mode))
                 (should (string-match-p "^Network: provider$"
                                         (buffer-string)))
                 (should (null openstack--last-error)))))
         (let ((buf (get-buffer "*OpenStack Network* <net-1>")))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-network-autoloads ()
  "The file loads itself from the generated autoloads."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-network.el"))
                  (buffer-string))))
    ;; The macro writes the commands, so the file needs one autoloaded
    ;; require instead of a cookie per generated command.
    (should (string-match-p
             "^;;;###autoload (require 'openstack-network)$"
             source))))

(provide 'openstack-network-tests)
;;; openstack-network-tests.el ends here
