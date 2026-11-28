;;; openstack-xref-test.el --- Tests for openstack-xref -*- lexical-binding: t; -*-

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

;;; Code:

(require 'ert)
(require 'openstack-test-helper)
(require 'openstack-xref)
(require 'openstack-resources)

(defconst openstack-xref-test--uuid "6f1e2d3c-0000-4000-8000-0000000000cc"
  "A UUID that no test row carries.")

(defun openstack-xref-test--row (id name)
  "Return a list row hash table with ID and NAME."
  (let ((row (make-hash-table :test 'equal)))
    (puthash "ID" id row)
    (puthash "Name" name row)
    row))

(defmacro openstack-xref-test--with-cache (&rest body)
  "Run BODY with a warm cache and a stubbed CLI client."
  (declare (indent 0))
  `(let ((openstack-resource--list-cache nil))
     (cl-letf (((symbol-function 'openstack-cli-request)
                (lambda (args)
                  (pcase (car args)
                    ("server"
                     (list (openstack-xref-test--row "srv-1" "web-1")))
                    ("network"
                     (list (openstack-xref-test--row
                            openstack-xref-test--uuid "provider")))
                    (_ nil)))))
       (openstack-read-rows "server")
       (openstack-read-rows "network")
       ,@body)))

;;; Tests

(ert-deftest openstack-xref-registers-backend ()
  "Loading the library adds the backend probe to xref."
  (should (memq #'openstack-xref-backend xref-backend-functions)))

(ert-deftest openstack-xref-identifier-at-point ()
  "The identifier comes from the text property or a UUID."
  (openstack-xref-test--with-cache
    (let* ((buffer (generate-new-buffer " *openstack-xref-test*"))
           (id "srv-1"))
      (unwind-protect
          (with-current-buffer buffer
            (insert "no id here")
            (should (null (openstack-xref-identifier-at-point)))
            (should (null (openstack-xref-backend)))
            (erase-buffer)
            (insert (propertize id 'openstack-id id))
            (goto-char (point-min))
            (should (equal (openstack-xref-identifier-at-point) id))
            (should (eq (openstack-xref-backend) 'openstack))
            (erase-buffer)
            (insert "log line " openstack-xref-test--uuid " end")
            (goto-char (point-min))
            (search-forward "6f1e2d3c")
            (should (equal (openstack-xref-identifier-at-point)
                           openstack-xref-test--uuid))
            ;; The UUID belongs to a cached network, so the backend claims it.
            (should (eq (openstack-xref-backend) 'openstack))
            (erase-buffer)
            (insert "foreign 00000000-0000-4000-8000-00000000dead id")
            (goto-char (point-min))
            (search-forward "00000000")
            ;; No type carries this UUID, so other backends may run.
            (should (null (openstack-xref-backend))))
        (kill-buffer buffer)))))

(ert-deftest openstack-xref-definitions ()
  "A known ID yields one xref item with a location."
  (openstack-xref-test--with-cache
    (let* ((items (xref-backend-definitions 'openstack
                                            openstack-xref-test--uuid))
           (item (car items))
           (location (xref-item-location item)))
      (should (equal (length items) 1))
      (should (equal (xref-item-summary item)
                     "OpenStack network provider"))
      (should (eq (type-of location) 'openstack-xref-location))
      (should (equal (openstack-xref-location-type location) "network"))
      (should (equal (openstack-xref-location-id location)
                     openstack-xref-test--uuid))
      (should (equal (xref-location-group location) "OpenStack network"))
      (should (equal (xref-location-line location) 1)))))

(ert-deftest openstack-xref-definitions-unknown ()
  "An ID that no cached row carries signals a `user-error'."
  (openstack-xref-test--with-cache
    (should-error (xref-backend-definitions 'openstack "00000000-0000")
                  :type 'user-error)))

(ert-deftest openstack-xref-hints-at-a-cold-cache ()
  "An xref jump to an uncached UUID says how to cache it."
  ;; Any other command over the same UUID stays quiet, because every
  ;; buffer runs the probe.
  (let ((openstack-resource--list-cache nil)
        (this-command 'xref-find-definitions)
        (seen nil))
    (with-temp-buffer
      (insert "id " openstack-xref-test--uuid " here")
      (goto-char (point-min))
      (search-forward "6f1e2d3c")
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq seen (apply #'format format-string args)))))
        (should (null (openstack-xref-backend)))
        (should (string-match-p "openstack-read-refresh" seen)))))
  (let ((openstack-resource--list-cache nil)
        (this-command 'xref-find-references)
        (seen nil))
    (with-temp-buffer
      (insert "id " openstack-xref-test--uuid " here")
      (goto-char (point-min))
      (search-forward "6f1e2d3c")
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _args) (setq seen t))))
        (should (null (openstack-xref-backend)))
        (should-not seen)))))

(ert-deftest openstack-xref-completion-table ()
  "The completion table offers the cached IDs."
  (openstack-xref-test--with-cache
    (should (equal (xref-backend-identifier-completion-table 'openstack)
                   (list "srv-1" openstack-xref-test--uuid)))))

(ert-deftest openstack-xref-location-marker ()
  "The marker opens the display buffer of the location."
  (let* ((buffer (generate-new-buffer " *openstack-xref-target*"))
         (seen nil))
    (unwind-protect
        (with-current-buffer buffer
          (openstack-server-mode)
          (cl-letf (((symbol-function 'openstack-server-display)
                     (lambda (id) (setq seen id) buffer)))
            (let ((marker (xref-location-marker
                           (make-openstack-xref-location
                            :type "server" :id "srv-1"))))
              (should (equal seen "srv-1"))
              (should (eq (marker-buffer marker) buffer))
              (should (equal (marker-position marker) 1)))))
      (kill-buffer buffer))))

(ert-deftest openstack-xref-identifier-errors ()
  "Asking for an identifier away from an ID signals."
  (with-temp-buffer
    (insert "nothing")
    (goto-char (point-min))
    (should-error (xref-backend-identifier-at-point 'openstack)
                  :type 'user-error)))

(ert-deftest openstack-xref-references ()
  "A cached list row that mentions the ID yields a reference."
  (let ((openstack-resource--list-cache nil))
    (cl-letf (((symbol-function 'openstack-cli-request)
               (lambda (args)
                 (pcase (car args)
                   ("server"
                    (list (let ((row (openstack-xref-test--row
                                      "srv-1" "web-1")))
                            (puthash "Image ID"
                                     openstack-xref-test--uuid row)
                            row)))
                   ("network"
                    (list (openstack-xref-test--row
                           openstack-xref-test--uuid "provider")))
                   (_ nil)))))
      (openstack-read-rows "server")
      (openstack-read-rows "network")
      (let* ((items (xref-backend-references 'openstack
                                             openstack-xref-test--uuid))
             (item (car items)))
        (should (equal (length items) 1))
        (should (equal (xref-item-summary item)
                       "OpenStack server web-1"))
        (should (eq (type-of (xref-item-location item))
                    'openstack-xref-location))))))

(ert-deftest openstack-xref-references-unknown ()
  "An ID that no cached row mentions yields no reference."
  (openstack-xref-test--with-cache
    (should (null (xref-backend-references
                   'openstack "00000000-0000-4000-8000-00000000dead")))))

(ert-deftest openstack-xref-backend-autoloaded ()
  "The hook entry reaches the autoload file with a stub.
The `add-hook' form names `openstack-xref-backend', and
`xref-find-backend' runs that hook in every buffer.  The autoload
file needs both the hook entry and the stub: the entry alone names
a void function, and the stub alone leaves the hook empty."
  (let ((autoloads (openstack-test--autoloads "openstack-xref.el")))
    (should (string-match-p "^(autoload 'openstack-xref-backend \"openstack-xref\""
                            autoloads))
    (should (string-match-p
             "^(add-hook 'xref-backend-functions #'openstack-xref-backend)"
             autoloads))))

(provide 'openstack-xref-test)
;;; openstack-xref-test.el ends here
