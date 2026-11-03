;;; openstack-api.el --- Native client for the OpenStack REST API -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/nagy/emacs-openstack-modes

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
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

;; Thin client for the OpenStack REST API, built on the Emacs `url'
;; library.  It does not parse HTTP itself: `url-http' frames the
;; responses, decodes chunked bodies, follows redirects, negotiates
;; TLS with gnutls and keeps one socket per host open between polls.
;; This layer adds the parts that `url' does not offer: a request
;; object that a caller can cancel, a per-request timeout, JSON
;; parsing and an error condition shaped after
;; `openstack-cli-error'.
;;
;; Asynchronous usage:
;;
;;   (openstack-api-request
;;    "https://compute.example.org/servers/abc"
;;    (lambda (response)
;;      (message "%s" (openstack-api-response-data response)))
;;    (lambda (err)
;;      (message "%s" (error-message-string err)))
;;    :headers '(("X-Auth-Token" . "tok-1")))
;;
;; The success callback receives an `openstack-api-response' struct
;; with the HTTP status, the response headers, the raw body and the
;; parsed JSON.  The error callback receives an `openstack-api-error'
;; condition.  A request that a caller cancels or that times out runs
;; neither callback after the fact.
;;
;; Cancelling closes the underlying socket: a half-read response
;; cannot be discarded while the connection stays usable.  The next
;; request opens a fresh connection.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'openstack-error)

;;; Customization

(defgroup openstack-api nil
  "Native client for the OpenStack REST API."
  :prefix "openstack-api-"
  :group 'openstack)

(defcustom openstack-api-timeout 30
  "Seconds to wait for one OpenStack API response.
When a request stays unanswered for this long, its socket closes
and the error callback receives an `openstack-api-timeout'
condition.  Nil disables the timeout."
  :type '(choice (number :tag "Seconds") (const :tag "No timeout" nil))
  :group 'openstack-api)

;;; Conditions

(define-error 'openstack-api-error "OpenStack API error"
              'openstack-error)

(define-error 'openstack-api-timeout "OpenStack API request timed out"
              'openstack-api-error)

;;; Data types

(cl-defstruct (openstack-api-response
               (:constructor openstack-api--make-response))
  "One response of the OpenStack API.
The slots hold the status, the response headers as a lower-case
alist, the raw body and the parsed JSON data."
  status headers body data)

(cl-defstruct (openstack-api-request
               (:constructor openstack-api--make-request))
  "Handle of one in-flight OpenStack API request.
The slots hold the URL, the HTTP method, the response buffer, a
DONE flag, the timeout timer and the timeout in seconds."
  url method buffer done timer timeout)

(defun openstack-api-response-header (response name)
  "Return the value of RESPONSE header NAME, or nil.
The lookup ignores case, so \"X-Subject-Token\" finds the header
the identity service spells that way."
  (declare (side-effect-free t))
  (cdr (assoc-string name (openstack-api-response-headers response) t)))

;;; Response parsing

(defun openstack-api--split-response (text)
  "Split response TEXT into a cons of header block and body.
Accept the CRLF line endings of the wire and the LF endings that
`url-http' leaves in the response buffer."
  (declare (pure t) (side-effect-free t))
  (save-match-data
    (cond
     ((string-match "\r\n\r\n" text)
      (cons (substring text 0 (match-beginning 0))
            (substring text (match-end 0))))
     ((string-match "\n\n" text)
      (cons (substring text 0 (match-beginning 0))
            (substring text (match-end 0))))
     (t (cons text "")))))

(defun openstack-api--parse-status (head)
  "Return the HTTP status code of header block HEAD, or nil.
HEAD starts with the status line, for example \"HTTP/1.1 200 OK\"."
  (declare (pure t) (side-effect-free t))
  (save-match-data
    (when (string-match "\\`HTTP/[0-9.]+[ \t]+\\([0-9][0-9][0-9]\\)" head)
      (string-to-number (match-string 1 head)))))

(defun openstack-api--parse-headers (head)
  "Return the headers of HEAD as an alist of lower-case names.
HEAD starts with the status line, which the result omits.  Header
names compare without case afterwards, so the caller writes them
in their natural spelling."
  (declare (pure t) (side-effect-free t))
  (save-match-data
    (let ((lines (cdr (split-string head "\r?\n" t))))
      (delq nil
            (mapcar
             (lambda (line)
               (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                 (cons (downcase (string-trim (match-string 1 line)))
                       (string-trim (match-string 2 line)))))
             lines)))))

(defun openstack-api--parse-response (text)
  "Return an `openstack-api-response' parsed from response TEXT."
  (declare (pure t) (side-effect-free t))
  (let* ((parts (openstack-api--split-response text))
         (head (car parts)))
    (openstack-api--make-response
     :status (openstack-api--parse-status head)
     :headers (openstack-api--parse-headers head)
     :body (cdr parts))))

(defun openstack-api--parse-json (body)
  "Return BODY parsed as JSON, or nil when BODY holds no content.
Signal an error when BODY is not valid JSON."
  (if (string-empty-p (string-trim body))
      nil
    (with-temp-buffer
      (insert body)
      (goto-char (point-min))
      (json-parse-buffer
       :object-type 'hash-table
       :array-type 'list
       :null-object nil
       :false-object nil))))

;;; Error construction

(defun openstack-api--error (request type &rest args)
  "Return the REQUEST error condition of TYPE with ARGS as data.
The condition carries the `:url' and `:method' of the request and
the data plist ARGS, for example `:status' and `:body'."
  (cons type
        (append (list :url (openstack-api-request-url request)
                      :method (openstack-api-request-method request))
                args)))

(defun openstack-api--http-error (request response)
  "Return the error condition for REQUEST answered with RESPONSE.
RESPONSE carries an HTTP status outside the 2xx range."
  (openstack-api--error request 'openstack-api-error
                        :status (openstack-api-response-status response)
                        :body (openstack-api-response-body response)))

;;; Lifecycle

(defun openstack-api--cancel-timer (request)
  "Cancel the timeout timer of REQUEST, when one runs."
  (when-let* ((timer (openstack-api-request-timer request)))
    (cancel-timer timer)
    (setf (openstack-api-request-timer request) nil)))

(defun openstack-api--close-buffer (buffer)
  "Close the socket of BUFFER and kill the buffer.
BUFFER holds the response of one request; `url-http' already
detached its process when the connection went back to the pool,
so a live process here means the request did not finish."
  (when (buffer-live-p buffer)
    (let ((process (get-buffer-process buffer)))
      (when (process-live-p process)
        (delete-process process)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun openstack-api--release (request)
  "Drop the timeout timer and the response buffer of REQUEST."
  (openstack-api--cancel-timer request)
  (let ((buffer (openstack-api-request-buffer request)))
    (setf (openstack-api-request-buffer request) nil)
    (openstack-api--close-buffer buffer)))

(defun openstack-api-cancel (request)
  "Cancel REQUEST.
Close its connection and run neither callback afterwards.  A
cancelled request leaves no state behind: the next request opens
a fresh connection.  Cancelling a finished request does nothing."
  (unless (openstack-api-request-done request)
    (setf (openstack-api-request-done request) t)
    (openstack-api--release request))
  nil)

(defun openstack-api--on-timeout (request error-fn)
  "Fail REQUEST after its timeout elapsed, calling ERROR-FN.
The condition type is `openstack-api-timeout', a subclass of
`openstack-api-error'."
  (unless (openstack-api-request-done request)
    (setf (openstack-api-request-done request) t)
    (openstack-api--release request)
    (funcall error-fn
             (openstack-api--error request 'openstack-api-timeout
                                   :timeout (openstack-api-request-timeout
                                             request)))))

(defun openstack-api--finish (request status success-fn error-fn)
  "Complete REQUEST with retrieval STATUS.
Run SUCCESS-FN with the `openstack-api-response' of a 2xx answer,
or ERROR-FN with an `openstack-api-error' condition.  STATUS is
the argument `url-retrieve' passes to its callback: nil on a
completed transfer, or a plist starting with `:error'."
  (unless (openstack-api-request-done request)
    (setf (openstack-api-request-done request) t)
    (openstack-api--cancel-timer request)
    (setf (openstack-api-request-buffer request) (current-buffer))
    (unwind-protect
        (let ((response
               (openstack-api--parse-response
                (buffer-substring-no-properties (point-min) (point-max)))))
          (cond
           ((null (openstack-api-response-status response))
            (funcall error-fn (openstack-api--error request
                                  'openstack-api-error
                                  :reason status)))
           ((<= 200 (openstack-api-response-status response) 299)
            (condition-case err
                (progn
                  (setf (openstack-api-response-data response)
                        (openstack-api--parse-json
                         (openstack-api-response-body response)))
                  (funcall success-fn response))
              (error
               (funcall error-fn (openstack-api--error
                                  request 'openstack-api-error
                                  :status (openstack-api-response-status
                                           response)
                                  :body (openstack-api-response-body response)
                                  :reason err)))))
           (t
            (funcall error-fn (openstack-api--http-error request response)))))
      (openstack-api--release request))))

;;; Asynchronous API

;;;###autoload
(cl-defun openstack-api-request (url success-fn error-fn
                                     &key method headers data
                                     (timeout openstack-api-timeout))
  "Fetch URL and run SUCCESS-FN or ERROR-FN with the result.
URL is an HTTP or HTTPS URL string.  SUCCESS-FN receives an
`openstack-api-response'; ERROR-FN receives an `openstack-api-error'
condition.

METHOD defaults to \"GET\".  HEADERS is an alist of header names
and values.  DATA is the request body.  TIMEOUT defaults to
`openstack-api-timeout'.

Return an `openstack-api-request' handle for `openstack-api-cancel'.
The callbacks run from the process filter, so they must not block."
  (unless (and (stringp url) (string-match-p "\\`https?://" url))
    (user-error "openstack-api: URL must start with http:// or https://"))
  (dolist (callback (list success-fn error-fn))
    (unless (functionp callback)
      (user-error "openstack-api: Both callbacks must be functions")))
  (let* ((request (openstack-api--make-request
                   :url url
                   :method (or method "GET")
                   :timeout timeout))
         (buffer
          (let ((url-request-method (or method "GET"))
                (url-request-extra-headers headers)
                (url-request-data data))
            (url-retrieve url
                          (lambda (&rest args)
                            (openstack-api--finish request (car args)
                                                   success-fn error-fn))
                          nil t nil))))
    (cond
     ((openstack-api-request-done request) request)
     ((not (buffer-live-p buffer))
      (setf (openstack-api-request-done request) t)
      (funcall error-fn (openstack-api--error request
                            'openstack-api-error
                            :reason 'retrieval-failed))
      request)
     (t
      (setf (openstack-api-request-buffer request) buffer)
      (unless (openstack-api-request-done request)
        (when (and timeout (> timeout 0))
          (setf (openstack-api-request-timer request)
                (run-at-time timeout nil #'openstack-api--on-timeout
                             request error-fn))))
      request))))

;;; Synchronous API

;;;###autoload
(cl-defun openstack-api-fetch (url &key method headers data
                                   (timeout openstack-api-timeout))
  "Fetch URL synchronously and return an `openstack-api-response'.
METHOD defaults to \"GET\".  HEADERS is an alist of header names
and values.  DATA is the request body.  TIMEOUT defaults to
`openstack-api-timeout'.

On a non-2xx answer, an unparseable body, a connection failure or
a timeout, signal the condition that `openstack-api-request'
passes to its error callback."
  (let (response failure done)
    (openstack-api-request
     url
     (lambda (result) (setq response result done t))
     (lambda (err) (setq failure err done t))
     :method method :headers headers :data data :timeout timeout)
    (let ((deadline (and timeout (> timeout 0)
                         (+ (float-time) timeout))))
      (while (and (not done)
                  (or (not deadline) (< (float-time) deadline)))
        (accept-process-output nil 0.05)))
    (cond
     (failure (signal (car failure) (cdr failure)))
     (response response)
     (t (signal 'openstack-api-timeout
                (list :url url :method (or method "GET")
                      :timeout timeout))))))

(provide 'openstack-api)
;;; openstack-api.el ends here
