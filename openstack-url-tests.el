;;; openstack-url-tests.el --- Tests for openstack-url -*- lexical-binding: t; -*-

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
(require 'openstack-url)

;;; Tests

(ert-deftest openstack-url-registers-handler ()
  "Loading the library registers the scheme with `browse-url'."
  (should (assoc openstack-url-regexp browse-url-default-handlers)))

(ert-deftest openstack-url-split-type-and-id ()
  "A URL of the TYPE/ID form yields both parts."
  (should (equal (openstack-url-split "server/srv-1")
                 (cons "server" "srv-1")))
  ;; An ID may hold a slash-free name with a dash, and the type ends
  ;; at the first slash only.
  (should (equal (openstack-url-split "network/project/net-1")
                 (cons "network" "project/net-1"))))

(ert-deftest openstack-url-split-id-alone ()
  "A URL without a slash yields a nil type."
  (should (equal (openstack-url-split "srv-1") (cons nil "srv-1"))))

(ert-deftest openstack-url-browse-opens-resource ()
  "The handler passes the parsed type and ID to `openstack-open-id'."
  (let (seen)
    (cl-letf (((symbol-function 'openstack-open-id)
               (lambda (id &optional type)
                 (setq seen (list id type))
                 'opened)))
      (should (eq (openstack-url-browse "openstack:server/srv-1") 'opened))
      (should (equal seen '("srv-1" "server")))
      (openstack-url-browse "openstack://network/net-1")
      (should (equal seen '("net-1" "network")))
      (openstack-url-browse "openstack:srv-1")
      (should (equal seen '("srv-1" nil))))))

;;; openstack-url-tests.el ends here
