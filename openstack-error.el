;;; openstack-error.el --- The OpenStack error condition -*- lexical-binding: t; -*-

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

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Every error of the package derives from `openstack-error', so a
;; caller catches one condition and sees them all.  The transport
;; layers keep their own children (`openstack-cli-error',
;; `openstack-api-error') with their own data, and a timeout is a
;; child of the layer that raised it.
;;
;; The condition lives in its own file: the transport layers require
;; it, and the data layer requires the transport, so the parent must
;; not depend on either.

;;; Code:

(define-error 'openstack-error "OpenStack error")

(provide 'openstack-error)
;;; openstack-error.el ends here
