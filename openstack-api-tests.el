;;; openstack-api-tests.el --- Tests for openstack-api -*- lexical-binding: t -*-

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

;;; Commentary:

;; The OpenStack API layer runs against a fake cloud on loopback: a
;; `make-network-process' server with canned routes.  No test reaches
;; an OpenStack installation, and no test needs credentials.
;;
;; The accept counter of the fake server checks the keep-alive
;; promise of the layer: two sequential requests must cost one
;; connection, not two.

;;; Code:

(require 'ert)
(require 'openstack-api)

;;; Fake cloud

(defvar openstack-api-test--port nil
  "Port of the fake cloud that the current test runs against.")

(defvar openstack-api-test--server nil
  "Server process of the fake cloud, or nil.")

(defvar openstack-api-test--accepts 0
  "Number of connections the fake cloud accepted since the last start.")

(defvar openstack-api-test--requests nil
  "Requests the fake cloud received, newest first.
Each entry is a plist with `:head' (the request head as sent) and
`:body' (the request body).")

(defvar openstack-api-test--routes nil
  "Canned routes of the fake cloud, an alist of path and plist.
A route plist holds `:status' (default 200), `:headers' (alist),
`:body' (string, default empty) and `:delay' (seconds before the
response leaves, default 0).")

(defun openstack-api-test--content-length (head)
  "Return the Content-Length of request HEAD, or 0."
  (if (string-match "[Cc]ontent-[Ll]ength:[ \t]*\\([0-9]+\\)" head)
      (string-to-number (match-string 1 head))
    0))

(defun openstack-api-test--request-path (head)
  "Return the request target of request HEAD."
  (nth 1 (split-string (car (split-string head "\r?\n")) " ")))

(defun openstack-api-test--respond (proc head)
  "Send the canned response for request HEAD on PROC."
  (let* ((route (cdr (assoc (openstack-api-test--request-path head)
                            openstack-api-test--routes)))
         (status (or (plist-get route :status) 200))
         (headers (plist-get route :headers))
         (payload (or (plist-get route :body) ""))
         (delay (or (plist-get route :delay) 0))
         (send (lambda ()
                 (when (process-live-p proc)
                   (process-send-string
                    proc
                    (concat (format "HTTP/1.1 %d Fake\r\n" status)
                            "Content-Type: application/json\r\n"
                            (format "Content-Length: %d\r\n"
                                    (length payload))
                            (mapconcat (lambda (header)
                                         (format "%s: %s\r\n"
                                                 (car header) (cdr header)))
                                       headers "")
                            "\r\n"
                            payload))))))
    (if (> delay 0)
        (run-at-time delay nil send)
      (funcall send))))

(defun openstack-api-test--filter (proc chunk)
  "Answer every complete request that arrives on PROC.
CHUNK is the new process output."
  (process-put proc 'buf (concat (or (process-get proc 'buf) "") chunk))
  (let ((buffer (process-get proc 'buf))
        (progress t))
    (while progress
      (setq progress nil)
      (when (string-match "\r\n\r\n" buffer)
        (let* ((head (substring buffer 0 (match-beginning 0)))
               (rest (substring buffer (match-end 0)))
               (length (openstack-api-test--content-length head)))
          (when (>= (length rest) length)
            (push (list :head head :body (substring rest 0 length))
                  openstack-api-test--requests)
            (openstack-api-test--respond proc head)
            (setq buffer (substring rest length))
            (setq progress t)))))
    (process-put proc 'buf buffer)))

(defun openstack-api-test--log (_server proc message)
  "Count the connections that MESSAGE reports for PROC."
  (when (string-match-p "accept" message)
    (setq openstack-api-test--accepts (1+ openstack-api-test--accepts))
    (ignore proc)))

(defun openstack-api-test--start (routes)
  "Start the fake cloud with ROUTES, return its port."
  (setq openstack-api-test--accepts 0
        openstack-api-test--requests nil
        openstack-api-test--routes routes)
  (setq openstack-api-test--server
        (make-network-process :name "openstack-api-test"
                              :server t
                              :host "127.0.0.1"
                              :service 0
                              :family 'ipv4
                              :noquery t
                              :log #'openstack-api-test--log
                              :filter #'openstack-api-test--filter))
  (process-contact openstack-api-test--server :service))

(defun openstack-api-test--stop ()
  "Stop the fake cloud."
  (when (process-live-p openstack-api-test--server)
    (delete-process openstack-api-test--server))
  (setq openstack-api-test--server nil))

(defmacro openstack-api-test--with-server (routes &rest body)
  "Run BODY against a fake cloud serving ROUTES.
Bind `openstack-api-test--port' to the port of the fake cloud."
  (declare (indent 1))
  `(let ((openstack-api-test--port (openstack-api-test--start ,routes)))
     (unwind-protect
         (progn ,@body)
       (openstack-api-test--stop))))

;;; Helpers

(defun openstack-api-test--wait (predicate)
  "Wait until PREDICATE returns non-nil, at most 5 seconds.
Accept process output while waiting, so requests finish."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(defun openstack-api-test--pause (seconds)
  "Accept process output for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.05))))

(defun openstack-api-test--url (path)
  "Return the fake cloud URL of PATH."
  (format "http://127.0.0.1:%d%s" openstack-api-test--port path))

(defun openstack-api-test--request (path &rest args)
  "Fire one request at PATH with ARGS, return (RESPONSE . ERROR).
Wait for the request to settle, then return the two results."
  (let (response failure)
    (apply #'openstack-api-request (openstack-api-test--url path)
           (lambda (result) (setq response result))
           (lambda (err) (setq failure err))
           args)
    (openstack-api-test--wait (lambda () (or response failure)))
    (cons response failure)))

;;; Parsing

(ert-deftest openstack-api-split-response-crlf ()
  "A wire response splits into header block and body."
  (should (equal (openstack-api--split-response
                  "HTTP/1.1 200 OK\r\nA: b\r\n\r\nbody")
                 (cons "HTTP/1.1 200 OK\r\nA: b" "body"))))

(ert-deftest openstack-api-split-response-lf ()
  "The LF endings of the url response buffer split too."
  (should (equal (openstack-api--split-response "HTTP/1.1 200 OK\nA: b\n\nbody")
                 (cons "HTTP/1.1 200 OK\nA: b" "body"))))

(ert-deftest openstack-api-parse-status ()
  "The status line yields the numeric status code."
  (should (= (openstack-api--parse-status "HTTP/1.1 404 Not Found") 404))
  (should (= (openstack-api--parse-status "HTTP/2 204 No Content") 204)))

(ert-deftest openstack-api-parse-status-malformed ()
  "A header block without a status line yields nil."
  (should (null (openstack-api--parse-status "garbage"))))

(ert-deftest openstack-api-parse-headers ()
  "Header names come back lower-case and trimmed."
  (should (equal (openstack-api--parse-headers
                  "HTTP/1.1 200 OK\nX-Subject-Token: tok-9\nRetry-After: 3\n")
                 '(("x-subject-token" . "tok-9") ("retry-after" . "3")))))

(ert-deftest openstack-api-response-header-ignores-case ()
  "The header lookup finds a name written in another case."
  (let ((response (openstack-api--make-response
                   :headers '(("x-subject-token" . "tok-9")))))
    (should (equal (openstack-api-response-header response "X-Subject-Token")
                   "tok-9"))
    (should (null (openstack-api-response-header response "X-Other")))))

;;; Requests against the fake cloud

(ert-deftest openstack-api-request-json-object ()
  "A 200 answer parses the body and keeps status and headers."
  (openstack-api-test--with-server
      '(("/server" :headers (("X-Subject-Token" . "tok-9"))
                   :body "{\"id\": \"abc\", \"name\": \"web-1\"}"))
    (let ((result (openstack-api-test--request "/server")))
      (should (null (cdr result)))
      (let ((response (car result)))
        (should (= (openstack-api-response-status response) 200))
        (should (equal (openstack-api-response-header response
                                                       "X-Subject-Token")
                       "tok-9"))
        (should (equal (gethash "id" (openstack-api-response-data response))
                       "abc"))))))

(ert-deftest openstack-api-request-empty-body ()
  "A 204 answer parses to nil data and no error."
  (openstack-api-test--with-server '(("/deleted" :status 204))
    (let ((result (openstack-api-test--request "/deleted")))
      (should (null (cdr result)))
      (should (= (openstack-api-response-status (car result)) 204))
      (should (null (openstack-api-response-data (car result)))))))

(ert-deftest openstack-api-request-http-error ()
  "A 404 answer reaches the error callback with status and body."
  (openstack-api-test--with-server
      '(("/missing" :status 404 :body "{\"error\": \"not found\"}"))
    (let* ((result (openstack-api-test--request "/missing"))
           (failure (cdr result))
           (data (cdr failure)))
      (should (null (car result)))
      (should (eq (car failure) 'openstack-api-error))
      (should (= (plist-get data :status) 404))
      (should (equal (plist-get data :body) "{\"error\": \"not found\"}"))
      (should (equal (plist-get data :method) "GET")))))

(ert-deftest openstack-api-request-invalid-json ()
  "A 2xx answer with a broken body reaches the error callback."
  (openstack-api-test--with-server '(("/broken" :body "not json"))
    (let ((failure (cdr (openstack-api-test--request "/broken"))))
      (should (eq (car failure) 'openstack-api-error))
      (should (plist-get (cdr failure) :reason)))))

(ert-deftest openstack-api-request-sends-method-headers-and-body ()
  "The request carries the method, the headers and the body."
  (openstack-api-test--with-server '(("/auth/tokens" :body "{}"))
    (openstack-api-test--request
     "/auth/tokens"
     :method "POST"
     :headers '(("X-Auth-Token" . "tok-1")
                ("OpenStack-API-Version" . "compute 2.1"))
     :data "{\"auth\": {}}")
    (let* ((request (car openstack-api-test--requests))
           (head (plist-get request :head)))
      (should (string-match-p "\\`POST /auth/tokens HTTP/1.1" head))
      (should (string-match-p "X-Auth-Token: tok-1" head))
      (should (string-match-p "OpenStack-API-Version: compute 2.1" head))
      (should (equal (plist-get request :body) "{\"auth\": {}}")))))

(ert-deftest openstack-api-request-timeout ()
  "A late answer fails with `openstack-api-timeout' and no success."
  (openstack-api-test--with-server '(("/slow" :delay 1 :body "{}"))
    (let* ((start (float-time))
           (result (openstack-api-test--request "/slow" :timeout 0.1))
           (failure (cdr result)))
      (should (null (car result)))
      (should (eq (car failure) 'openstack-api-timeout))
      (should (< (- (float-time) start) 0.9))
      (should (= (plist-get (cdr failure) :timeout) 0.1)))))

(ert-deftest openstack-api-cancel-runs-no-callback ()
  "A cancelled request runs neither callback."
  (openstack-api-test--with-server '(("/slow" :delay 1 :body "{}"))
    (let (response failure)
      (let ((request (openstack-api-request
                      (openstack-api-test--url "/slow")
                      (lambda (result) (setq response result))
                      (lambda (err) (setq failure err)))))
        (openstack-api-test--pause 0.1)
        (openstack-api-cancel request)
        (should (openstack-api-request-done request))
        (openstack-api-test--pause 0.4)
        (should (null response))
        (should (null failure))))))

(ert-deftest openstack-api-cancel-frees-the-connection ()
  "A request after a cancel opens a fresh connection and succeeds."
  (openstack-api-test--with-server '(("/slow" :delay 1 :body "{}")
                                     ("/fast" :body "{\"ok\": true}"))
    (let ((request (openstack-api-request
                    (openstack-api-test--url "/slow")
                    #'ignore #'ignore)))
      (openstack-api-test--pause 0.1)
      (openstack-api-cancel request))
    (let ((result (openstack-api-test--request "/fast")))
      (should (null (cdr result)))
      (should (eq t (gethash "ok" (openstack-api-response-data (car result))))))))

(ert-deftest openstack-api-request-keeps-the-connection ()
  "Two sequential requests cost one connection, one handshake."
  (openstack-api-test--with-server '(("/a" :body "{\"a\": 1}")
                                     ("/b" :body "{\"b\": 2}"))
    (let ((first (openstack-api-test--request "/a"))
          (second (openstack-api-test--request "/b")))
      (should (null (cdr first)))
      (should (null (cdr second)))
      (should (= openstack-api-test--accepts 1))
      (should (= (length openstack-api-test--requests) 2)))))

;;; Synchronous wrapper

(ert-deftest openstack-api-fetch-returns-response ()
  "The synchronous wrapper returns the parsed response."
  (openstack-api-test--with-server '(("/server" :body "{\"id\": \"abc\"}"))
    (let ((response (openstack-api-fetch (openstack-api-test--url "/server"))))
      (should (= (openstack-api-response-status response) 200))
      (should (equal (gethash "id" (openstack-api-response-data response))
                     "abc")))))

(ert-deftest openstack-api-fetch-signals-http-error ()
  "The synchronous wrapper signals the API error condition."
  (openstack-api-test--with-server '(("/missing" :status 404 :body "{}"))
    (should-error (openstack-api-fetch (openstack-api-test--url "/missing"))
                  :type 'openstack-api-error)))

(provide 'openstack-api-tests)
;;; openstack-api-tests.el ends here
