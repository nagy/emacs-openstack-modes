;;; openstack-server-tests.el --- Tests for openstack-server -*- lexical-binding: t -*-

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

(defconst openstack-server-test--show-json
  (concat
   "{\"id\": \"abc-123\", \"name\": \"web-1\", \"status\": \"ACTIVE\", "
   "\"flavor\": {\"id\": \"1\", \"name\": \"m1.small\"}, "
   "\"addresses\": {\"public\": [{\"addr\": \"10.0.0.5\"}]}, "
   "\"custom_field\": \"x\", \"aaa_first\": \"early\", "
   "\"zzz_last\": \"late\", \"created_at\": \"2026-01-01T00:00:00Z\"}")
  "Parsable `openstack server show' output for the tests.
Contains fields from `openstack-server-fields' out of order,
plus unordered extras (`aaa_first', `zzz_last') to exercise the
sorting of unlisted fields.")

(defun openstack-server-test--fixture-data ()
  "Parse `openstack-server-test--show-json' into a hash table."
  (with-temp-buffer
    (insert openstack-server-test--show-json)
    (goto-char (point-min))
    (json-parse-buffer
     :object-type 'hash-table
     :array-type 'list
     :null-object nil
     :false-object nil)))

(defun openstack-server-test--with-fixture-buffer (fn)
  "Run FN in a fresh temporary display buffer.
The buffer is entered into `openstack-server-mode' with the ID
\"abc-123\" and killed afterwards."
  (let ((buf (generate-new-buffer " *openstack-server-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-server-mode)
          (setq-local openstack--id "abc-123")
          (funcall fn buf))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Tests

(ert-deftest openstack-server-mode-is-derived ()
  "The server mode derives from `openstack-mode' with buffer-locals."
  (let ((buf (generate-new-buffer " *openstack-server-test*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-server-mode)
          (should (derived-mode-p 'openstack-mode))
          (should (eq openstack-fetch-function #'openstack-server--fetch))
          (should (eq openstack-render-function #'openstack-server--render))
          (should (equal openstack-id-prefix "compute"))
          ;; The base mode's ID handling survives.
          (setq-local openstack--id "abc-123")
          (should (equal (openstack--resource-id t) "abc-123")))
      (kill-buffer buf))))

(ert-deftest openstack-server-fetch-calls-async-request ()
  "The fetcher runs `openstack server show ID' through the CLI layer."
  (let ((args-seen nil) (success-seen nil) (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                   (setq args-seen args
                         success-seen success-fn
                         error-seen error-fn)
                   :process-handle))))
      (should (eq (openstack-server--fetch
                   "abc-123" (lambda (_d) nil) (lambda (_e) nil))
                  :process-handle))
      (should (equal args-seen '("server" "show" "abc-123")))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-server-render-shows-ordered-fields ()
  "The renderer lists `openstack-server-fields' first, in order."
  (openstack-server-test--with-fixture-buffer
   (lambda (_buf)
     (let ((inhibit-read-only t))
       (openstack-server--render "abc-123" (openstack-server-test--fixture-data)))
     (let ((text (buffer-string)))
       (should (string-match-p "Server: web-1\n" text))
       (should (string-match-p "ID: abc-123\n" text))
       (should (string-match-p "^status: ACTIVE$" text))
       ;; Nested values come out as JSON.
       (should (string-match-p "^flavor: {\"id\":\"1\",\"name\":\"m1.small\"}$"
                               text))
       ;; Listed fields precede unlisted ones.
       (should (< (string-match "^name: web-1$" text)
                  (string-match "^aaa_first: early$" text)))))))

(ert-deftest openstack-server-render-skips-missing-and-sorts-rest ()
  "Missing fields are skipped; unlisted fields render sorted by name."
  (openstack-server-test--with-fixture-buffer
   (lambda (_buf)
     (let ((inhibit-read-only t))
       (openstack-server--render "abc-123" (openstack-server-test--fixture-data)))
     (let ((text (buffer-string)))
       (should-not (string-match-p "^host_status:" text))
       (should-not (string-match-p "^image:" text))
       (should-not (string-match-p "^updated_at:" text))
       ;; Unlisted fields are sorted, not hash-table order.
       (should (< (string-match "^aaa_first: early$" text)
                  (string-match "^custom_field: x$" text)))
       (should (< (string-match "^custom_field: x$" text)
                  (string-match "^zzz_last: late$" text)))))))

(ert-deftest openstack-server-format-value-cases ()
  "Value formatting: nil, empty, booleans, scalars and nested data."
  (should (equal (openstack-server--format-value nil) "-"))
  (should (equal (openstack-server--format-value "") "-"))
  (should (equal (openstack-server--format-value "ACTIVE") "ACTIVE"))
  (should (equal (openstack-server--format-value 2) "2"))
  (should (equal (openstack-server--format-value t) "true"))
  (should (equal (openstack-server--format-value '(1 2)) "[1,2]")))

(ert-deftest openstack-server-render-non-hash-data ()
  "Non-hash data does not error; the ID identifies the server."
  (openstack-server-test--with-fixture-buffer
   (lambda (_buf)
     (let ((inhibit-read-only t))
       (openstack-server--render "abc-123" nil))
     (should (string-match-p "Server: abc-123\n" (buffer-string))))))

(ert-deftest openstack-server-display-enters-server-mode ()
  "The display command creates the server buffer in the server mode."
  (openstack-cli-test--with-fixture-program
   "printf '%s' 'not json'\n"
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "abc-123"))
       (unwind-protect
           (let ((displayed nil))
             (openstack-server-display id)
             (let ((buf (get-buffer (format "*OpenStack Server* <%s>" id))))
               (should buf)
               (with-current-buffer buf
                 (should (derived-mode-p 'openstack-server-mode))
                 (should (equal openstack--id id))
                 ;; The buffer-local fetcher hits the real CLI layer;
                 ;; the fixture answers "not json", so the fetch fails
                 ;; and the error lands in the header line.
                 (openstack-cli-test--wait-until
                  (lambda () (not openstack--pending)))
                 (setq displayed (and openstack--last-error t))
                 (should displayed))))
         (let ((buf (get-buffer (format "*OpenStack Server* <%s>" id))))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-server-display-renders-from-real-client ()
  "A full round trip renders the fixture's server fields.
The fixture client answers `server show' with fixed JSON; the
display command must render it through the async pipeline."
  (openstack-cli-test--with-fixture-program
   (concat "if [ \"$2\" = show ]; then "
           "echo '" openstack-server-test--show-json "'; fi\n")
   (lambda (program)
     (let ((openstack-program program)
           (openstack-cli-use-token nil)
           (openstack-cli-timeout 5)
           (id "abc-123"))
       (unwind-protect
           (progn
             (openstack-server-display id)
             (let ((buf (get-buffer (format "*OpenStack Server* <%s>" id))))
               (should buf)
               (openstack-cli-test--wait-until
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and openstack--rendered
                              (not openstack--pending))))))
               (with-current-buffer buf
                 (let ((text (buffer-string)))
                   (should (string-match-p "^Server: web-1$" text))
                   (should (string-match-p "^status: ACTIVE$" text))
                   (should (null openstack--last-error))))))
         (let ((buf (get-buffer (format "*OpenStack Server* <%s>" id))))
           (when buf (kill-buffer buf))))))))

(ert-deftest openstack-server-autoloads ()
  "The entry points carry autoload cookies."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "openstack-server.el"))
                  (buffer-string))))
    (should (string-match-p
             "^;;;###autoload\n\\(?:(defun openstack-server-display\\|(define-derived-mode openstack-server-mode\\)"
             source))))

(provide 'openstack-server-tests)
;;; openstack-server-tests.el ends here
