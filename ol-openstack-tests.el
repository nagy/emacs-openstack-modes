;;; ol-openstack-tests.el --- Tests for ol-openstack -*- lexical-binding: t; -*-

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
(require 'ol-openstack)
(require 'openstack-network-list)

;;; Tests

(ert-deftest ol-openstack-registers-link-type ()
  "The `openstack' link type carries all four handlers."
  (should (eq (org-link-get-parameter "openstack" :follow)
              #'openstack-org-follow))
  (should (eq (org-link-get-parameter "openstack" :complete)
              #'openstack-org-complete))
  (should (eq (org-link-get-parameter "openstack" :store)
              #'openstack-org-store))
  (should (eq (org-link-get-parameter "openstack" :export)
              #'openstack-org-export)))

(ert-deftest ol-openstack-types-are-reachable ()
  "Every link type names a mode and a display command."
  (dolist (entry openstack-org-types)
    (should (fboundp (nth 1 entry)))
    (should (fboundp (nth 2 entry)))))

(ert-deftest ol-openstack-split ()
  "A well-formed path splits into type and ID, a bad one signals."
  (should (equal (openstack-org--split "server/srv-1")
                 '("server" . "srv-1")))
  ;; IDs never contain a slash, so the first slash separates the parts.
  (should (equal (openstack-org--split "network/net/1")
                 '("network" . "net/1")))
  (should-error (openstack-org--split "server") :type 'user-error)
  (should-error (openstack-org--split "server/") :type 'user-error))

(ert-deftest ol-openstack-follow-dispatches-by-type ()
  "Following a link calls the display command of its type."
  (dolist (case '(("server" . openstack-server-display)
                  ("volume" . openstack-volume-display)
                  ("image" . openstack-image-display)
                  ("network" . openstack-network-display)))
    (let ((seen nil))
      (cl-letf (((symbol-function (cdr case))
                 (lambda (id) (setq seen id))))
        (openstack-org-follow (format "%s/res-1" (car case)))
        (should (equal seen "res-1"))))))

(ert-deftest ol-openstack-follow-rejects-unknown-type ()
  "An unknown type and a malformed path signal a `user-error'."
  (should-error (openstack-org-follow "router/res-1") :type 'user-error)
  (should-error (openstack-org-follow "res-1") :type 'user-error))

(ert-deftest ol-openstack-store ()
  "Storing from a resource buffer writes TYPE/ID and the name."
  (let ((buf (generate-new-buffer " *ol-openstack-store*"))
        (props nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (openstack-server-mode)
            (setq-local openstack--id "srv-1")
            (setq-local openstack--last-data
                        (let ((data (make-hash-table :test 'equal)))
                          (puthash "name" "web-1" data)
                          data)))
          (cl-letf (((symbol-function 'org-link-store-props)
                     (lambda (&rest plist) (setq props plist))))
            (with-current-buffer buf
              (should (eq (openstack-org-store) t))))
          (should (equal (plist-get props :type) "openstack"))
          (should (equal (plist-get props :link) "openstack:server/srv-1"))
          (should (equal (plist-get props :description)
                         "OpenStack server web-1")))
      (kill-buffer buf))))

(ert-deftest ol-openstack-store-falls-back-to-id ()
  "Without rendered data the description uses the ID."
  (let ((buf (generate-new-buffer " *ol-openstack-store*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-network-mode)
          (setq-local openstack--id "net-1")
          (should (string-match-p
                   "OpenStack network net-1"
                   (openstack-org--description "network" "net-1"))))
      (kill-buffer buf))))

(ert-deftest ol-openstack-store-ignores-other-buffers ()
  "A plain buffer, an unknown mode and a collection store nothing."
  (with-temp-buffer
    (should (null (openstack-org-store))))
  (let ((buf (generate-new-buffer " *ol-openstack-store*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-mode)
          (setq-local openstack--id "res-1")
          ;; The base mode is not in `openstack-org-types'.
          (should (null (openstack-org-store))))
      (kill-buffer buf)))
  (let ((buf (generate-new-buffer " *ol-openstack-store*")))
    (unwind-protect
        (with-current-buffer buf
          (openstack-network-list-mode)
          (setq-local openstack-collection t)
          ;; A collection buffer has no resource ID.
          (should (null (openstack-org-store))))
      (kill-buffer buf))))

(ert-deftest ol-openstack-dashboard-url-follows-modes ()
  "The exported URL uses the mode's own path settings."
  (let ((openstack-web-base-url "https://horizon.example.org"))
    (dolist (entry openstack-org-types)
      (let ((type (nth 0 entry)))
        (with-temp-buffer
          (funcall (nth 1 entry))
          (should (equal (openstack-org--dashboard-url type "res-1")
                         (openstack--format-url "res-1"))))))
    (should (equal (openstack-org--dashboard-url "network" "net-1")
                   "https://horizon.example.org/project/networks/net-1/detail"))
    (should (equal (openstack-org--dashboard-url "server" "srv-1")
                   "https://horizon.example.org/compute/srv-1"))))

(ert-deftest ol-openstack-export ()
  "Export builds dashboard URLs for HTML and LaTeX."
  (let ((openstack-web-base-url "https://horizon.example.org"))
    (should (equal
             (openstack-org-export "server/srv-1" "web-1" 'html nil)
             "<a href=\"https://horizon.example.org/compute/srv-1\">web-1</a>"))
    (should (equal
             (openstack-org-export "network/net-1" nil 'latex nil)
             "\\href{https://horizon.example.org/project/networks/net-1/detail}{network/net-1}"))
    (should (equal (openstack-org-export "image/img-1" "ubuntu" 'ascii nil)
                   "ubuntu"))))

(ert-deftest ol-openstack-export-keeps-unknown-types-plain ()
  "An unknown type exports the link text, so a document still builds."
  (should (equal (openstack-org-export "router/r-1" "my router" 'html nil)
                 "my router"))
  (should (equal (openstack-org-export "broken" nil 'html nil) "broken")))

(ert-deftest ol-openstack-complete ()
  "Completion prompts for a type and an ID."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection &rest _)
               (should (member "network" collection))
               "network"))
            ((symbol-function 'read-string) (lambda (_prompt) "net-1")))
    (should (equal (openstack-org-complete) "openstack:network/net-1"))))

(provide 'ol-openstack-tests)
;;; ol-openstack-tests.el ends here
