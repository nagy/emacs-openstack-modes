;;; openstack-resource-tests.el --- Tests for openstack-resource -*- lexical-binding: t; -*-

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
(require 'openstack-resource)
(require 'openstack-server)
(require 'openstack-volume)
(require 'openstack-image)
(require 'openstack-network)
(require 'openstack-container)

;;; Tests

(ert-deftest openstack-resource-definitions-registered ()
  "Every definition matches the symbols and the table entry it names.
This test guards the refactor: a mode file states its resource name
once, so a definition and its generated commands cannot drift."
  (should openstack-resource-definitions)
  (dolist (entry openstack-resource-definitions)
    (let* ((type (car entry))
           (definition (cdr entry))
           (mode (intern (format "openstack-%s-mode" type)))
           (display (intern (format "openstack-%s-display" type)))
           (list-mode (intern (format "openstack-%s-list-mode" type)))
           (list-display (intern (format "openstack-%s-list-display" type))))
      (should (equal (plist-get definition :type) type))
      ;; The type string serves as the client command name.
      (should (equal (openstack-resource-cli-name type) type))
      (should (eq (plist-get definition :mode) mode))
      (should (eq (plist-get definition :display) display))
      (should (eq (plist-get definition :list-mode) list-mode))
      (should (eq (plist-get definition :list-display) list-display))
      (dolist (function (list mode display list-mode list-display))
        (should (fboundp function)))
      (should (equal (openstack-resource-type-for-mode mode) type))
      (should (equal (nth 1 (openstack-resource-type type)) mode))
      (should (eq (nth 2 (openstack-resource-type type)) display)))))

(ert-deftest openstack-resource-types-match-definitions ()
  "The table and the registry hold the same types in the same order.
The ID prompts, the Org links and the xref backend read the table,
so a definition missing there stays invisible to them."
  (should (equal (mapcar #'car openstack-resource-types)
                 (mapcar #'car openstack-resource-definitions))))

(ert-deftest openstack-resource-mode-settings-come-from-definition ()
  "The generated modes carry the settings of their definition."
  (dolist (entry openstack-resource-definitions)
    (let ((definition (cdr entry))
          (buf (generate-new-buffer " *openstack-resource-test*")))
      (unwind-protect
          (with-current-buffer buf
            (funcall (plist-get definition :list-mode))
            (should (equal openstack-id-prefix
                           (plist-get definition :id-prefix)))
            (should (equal openstack-url-suffix
                           (plist-get definition :url-suffix)))
            (should (equal openstack-list--noun
                           (plist-get definition :noun)))
            (should (eq openstack-show-command
                        (plist-get definition :display)))
            (should (equal (openstack-resource-type-for-mode
                            (plist-get definition :list-mode))
                           nil)))
        (kill-buffer buf)))))

(ert-deftest openstack-resource-cli-name-override ()
  "A definition may name a different client command."
  (let ((openstack-resource-definitions
         (cons '("custom" :type "custom" :cli "custom-cli")
               openstack-resource-definitions)))
    (should (equal (openstack-resource-cli-name "custom") "custom-cli"))
    (should (equal (openstack-resource-cli-name "server") "server"))
    (should (equal (openstack-resource-cli-name "unknown") "unknown"))))

(ert-deftest openstack-resource-definition-values ()
  "The registry keeps the properties of the macro call."
  (let ((definition (openstack-resource-definition "container")))
    (should (equal (plist-get definition :noun) "containers"))
    (should (equal (plist-get definition :id-prefix)
                   "project/containers"))
    (should (equal (plist-get definition :url-suffix) ""))
    (should (equal (plist-get definition :list-arguments) '("--long")))
    (should (equal (plist-get definition :list-fields)
                   '("Name" "Bytes" "Count"))))
  (should (null (openstack-resource-definition "unknown"))))

(provide 'openstack-resource-tests)
;;; openstack-resource-tests.el ends here
