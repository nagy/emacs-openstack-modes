;;; openstack-console-tests.el --- Tests for openstack-console -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

(require 'ert)
(require 'openstack-console)

;;; Tests

(ert-deftest openstack-console-log-mode-is-derived ()
  "The console log view derives from the base mode.
It inherits the refresh pipeline, the ID handling and the bookmark
record, and it turns the URLs of the log into links."
  (with-temp-buffer
    (openstack-console-log-mode)
    (should (derived-mode-p 'openstack-mode))
    (should (eq openstack-fetch-function #'openstack-console--fetch))
    (should (eq openstack-render-function #'openstack-console--render))
    (should (equal openstack-id-prefix "compute"))
    (should (bound-and-true-p goto-address-mode))))

(ert-deftest openstack-console-fetch-runs-console-log ()
  "The fetcher runs `console log show' through the text path."
  (let ((args-seen nil)
        (text-seen nil)
        (success-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn text)
                              (ignore error-fn)
                              (setq args-seen args
                                    text-seen text
                                    success-seen success-fn)
                              :handle))))
      (should (eq (openstack-console--fetch "srv-1"
                                            (lambda (_text) nil)
                                            (lambda (_err) nil))
                  :handle))
      (should (equal args-seen '("console" "log" "show" "srv-1")))
      (should text-seen)
      (should (functionp success-seen)))))

(ert-deftest openstack-console-render-inserts-the-log ()
  "The renderer inserts the log text unchanged."
  (with-temp-buffer
    (openstack-console-log-mode)
    (let ((inhibit-read-only t))
      (openstack-console--render "srv-1"
                                 "Booting from Hard Disk...\nlogin: \n"))
    (should (equal (buffer-string)
                   "Booting from Hard Disk...\nlogin: \n"))))

(ert-deftest openstack-console-log-displays-its-own-buffer ()
  "The command displays the log in a buffer named after the mode."
  (let ((seen nil))
    (cl-letf (((symbol-function 'openstack-display)
               (lambda (id &optional mode)
                 (setq seen (list id mode openstack-buffer-name))
                 :buffer)))
      (should (eq (openstack-console-log "srv-1") :buffer))
      (should (equal seen
                     '("srv-1" openstack-console-log-mode
                       "*OpenStack Console Log*"))))))

(ert-deftest openstack-console-log-refreshes ()
  "Delivered text renders through the refresh pipeline."
  (let ((openstack-console-log-buffer-name "*OpenStack Console Log test*"))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function
                (lambda (_args &key success-fn error-fn text)
                  (ignore error-fn text)
                  (funcall success-fn "line one\n")
                  :handle))))
      (unwind-protect
          (progn
            (openstack-console-log "srv-1")
            (let ((buf (get-buffer "*OpenStack Console Log test* <srv-1>")))
              (should buf)
              (with-current-buffer buf
                (should (equal (buffer-string) "line one\n"))
                (should openstack--rendered)
                (should (null openstack--last-error)))))
        (let ((buf (get-buffer "*OpenStack Console Log test* <srv-1>")))
          (when buf (kill-buffer buf)))))))

(provide 'openstack-console-tests)
;;; openstack-console-tests.el ends here
