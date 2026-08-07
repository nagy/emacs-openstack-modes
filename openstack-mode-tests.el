;;; openstack-mode-tests.el --- Tests for openstack-mode -*- lexical-binding: t -*-

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
(require 'openstack-mode)

;;; Helpers

(defun openstack-test--make-resource-buffer ()
  "Create a temporary buffer displaying resource \"res-123\".
The buffer is put into `openstack-mode' with ID
\"res-123\", and is returned."
  (let ((buf (generate-new-buffer " *openstack-test*")))
    (with-current-buffer buf
      (openstack-mode)
      (setq-local openstack--id "res-123")
      (setq-local openstack--origin-buffer (current-buffer))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall openstack-render-function "res-123")))
    buf))

;;; Tests

(ert-deftest openstack-mode-basic ()
  "Buffer gets the mode with a read-only, dedicated buffer."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (eq major-mode 'openstack-mode))
          (should (equal mode-name "OpenStack Resource"))
          (should buffer-read-only)
          (should (string-match-p "^OpenStack resource" (buffer-string))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-copy-id ()
  "`openstack-copy-id' puts the ID on the kill ring."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (openstack-copy-id)
          (should (equal (car kill-ring) "res-123")))
      (kill-buffer buf))))

(ert-deftest openstack-mode-copy-id-no-id ()
  "Copying without an ID signals a user-error."
  (with-temp-buffer
    (openstack-mode)
    (should-error (openstack-copy-id) :type 'user-error)))

(ert-deftest openstack-mode-pop ()
  "`openstack-pop' returns to the origin buffer."
  (let* ((origin (generate-new-buffer " *openstack-origin*"))
         (buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack--origin-buffer origin)
          (openstack-pop)
          (should (eq (current-buffer) origin)))
      (kill-buffer buf)
      (kill-buffer origin))))

(ert-deftest openstack-mode-pop-missing-origin ()
  "Popping without an origin buffer signals a user-error."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (setq-local openstack--origin-buffer nil)
          (should-error (openstack-pop) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest openstack-mode-set-id ()
  "`openstack-set-id' updates the buffer-local ID."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (openstack-set-id "new-id")
          (should (equal openstack--id "new-id")))
      (kill-buffer buf))))

(ert-deftest openstack-mode-format-url ()
  "URL is built from base URL, prefix and ID."
  (let ((openstack-web-base-url "https://horizon.example.org")
        (openstack-id-prefix "servers"))
    (should (equal (openstack--format-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-format-url-trailing-slash ()
  "A trailing slash in the base URL is trimmed."
  (let ((openstack-web-base-url "https://horizon.example.org/")
        (openstack-id-prefix "servers"))
    (should (equal (openstack--format-url "abc-123")
                   "https://horizon.example.org/servers/abc-123"))))

(ert-deftest openstack-mode-bookmark-record ()
  "`openstack--bookmark-make-record' stores the ID."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (let ((record (openstack--bookmark-make-record)))
            (should (equal (bookmark-prop-get record 'openstack-id)
                           "res-123"))
            (should (equal (car record) "res-123 ::OpenStack"))))
      (kill-buffer buf))))

(ert-deftest openstack-mode-revert ()
  "`revert-buffer' keeps the buffer content intact."
  (let ((buf (openstack-test--make-resource-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (revert-buffer)
          (should (string-match-p "ID: res-123" (buffer-string))))
      (kill-buffer buf))))

(provide 'openstack-mode-tests)
;;; openstack-mode-tests.el ends here
