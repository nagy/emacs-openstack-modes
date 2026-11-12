;;; openstack-resource-test.el --- Tests for openstack-resources -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The resource show and list modes all come from one macro, so their
;; tests come from one table.  `openstack-resource-test--fixtures'
;; holds, per resource type, a client answer for `RESOURCE show' and
;; one for `RESOURCE list', plus the names the test asserts.  The
;; macro `openstack-resource-test--def-type-tests' turns each body into
;; one ERT test per fixture, so a failure still names its resource.

;;; Code:

(require 'ert)
(require 'openstack-test-helper)
(require 'openstack-resources)

(eval-and-compile
  (defconst openstack-resource-test--fixtures
    `(("server"
       :show-id "abc-123"
       :show-json
       ,(concat "{\"id\": \"abc-123\", \"name\": \"web-1\", "
                "\"status\": \"ACTIVE\", "
                "\"flavor\": {\"id\": \"1\", \"name\": \"m1.small\"}, "
                "\"addresses\": {\"public\": [{\"addr\": \"10.0.0.5\"}]}, "
                "\"custom_field\": \"x\", \"aaa_first\": \"early\", "
                "\"zzz_last\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("host_status" "image" "updated_at")
       :show-nested (("flavor" . "{\"id\":\"1\",\"name\":\"m1.small\"}"))
       :show-blocks (("addresses" . "^  public: +10\\.0\\.0\\.5$"))
       :show-unlisted ("aaa_first" "custom_field" "zzz_last")
       :list-json
       ,(concat "[{\"ID\": \"id-1\", \"Name\": \"web-1\", "
                "\"Status\": \"ACTIVE\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}, "
                "{\"ID\": \"id-2\", \"Name\": \"web-2\", "
                "\"Status\": \"SHUTOFF\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Alpha" "Zebra")
       :list-rows ("^id-1 +web-1 +ACTIVE +early +late"
                   "^id-2 +web-2 +SHUTOFF +early +late")
       :list-first-id "id-1")

      ("volume"
       :show-id "vol-1"
       :show-json
       ,(concat "{\"id\": \"vol-1\", \"name\": \"data-1\", "
                "\"status\": \"in-use\", \"size\": 20, "
                "\"volume_type\": \"__DEFAULT__\", "
                "\"bootable\": \"false\", "
                "\"attachments\": [{\"server_id\": \"srv-1\", "
                "\"device\": \"/dev/vdb\"}], "
                "\"availability_zone\": \"nova\", "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-blocks (("attachments" . "^    server_id: srv-1$"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"vol-1\", \"Name\": \"data-1\", "
                "\"Status\": \"in-use\", \"Size\": 20, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"vol-2\", \"Name\": \"\", "
                "\"Status\": \"available\", \"Size\": 10, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Size" "Alpha" "Zebra")
       :list-rows ("^vol-1 +data-1 +in-use +20 +early +late"
                   "^vol-2 +- +available +10 +early +late")
       :list-first-id "vol-1")

      ("image"
       :show-id "img-1"
       :show-json
       ,(concat "{\"id\": \"img-1\", \"name\": \"ubuntu-24.04\", "
                "\"status\": \"active\", "
                "\"visibility\": \"public\", "
                "\"disk_format\": \"qcow2\", "
                "\"container_format\": \"bare\", "
                "\"size\": 234881024, \"virtual_size\": 241172480, "
                "\"owner\": \"a1b2c3d4e5f60718293a4b5c6d7e8f90\", "
                "\"tags\": [\"latest\"], \"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("tags" . "latest"))
       :show-unlisted ("zzz_extra")
       :show-values (("size" . "224M") ("virtual_size" . "230M"))
       :list-json
       ,(concat "[{\"ID\": \"img-1\", \"Name\": \"ubuntu-24.04\", "
                "\"Status\": \"active\", "
                "\"Size\": \"234881024\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}, "
                "{\"ID\": \"img-2\", \"Name\": \"debian-12\", "
                "\"Status\": \"active\", "
                "\"Size\": \"117440512\", \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Size" "Alpha" "Zebra")
       :list-rows ("^img-1 +ubuntu-24\\.04 +active +234881024 +early +late"
                   "^img-2 +debian-12 +active +117440512 +early +late")
       :list-first-id "img-1")

      ("network"
       :show-id "net-1"
       :show-json
       ,(concat "{\"id\": \"net-1\", \"name\": \"provider\", "
                "\"status\": \"ACTIVE\", "
                "\"admin_state_up\": true, \"shared\": true, "
                "\"router:external\": false, "
                "\"subnets\": [\"subnet-1\", \"subnet-2\"], "
                "\"provider:network_type\": \"vxlan\", "
                "\"provider:segmentation_id\": 42, "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("subnets" . "subnet-1"))
       :show-references (("subnets" . ("subnet-1" "subnet-2")))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"net-1\", \"Name\": \"provider\", "
                "\"Status\": \"ACTIVE\", "
                "\"Subnets\": \"subnet-1\", \"Shared\": true, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"net-2\", \"Name\": \"\", "
                "\"Status\": \"DOWN\", \"Subnets\": \"\", "
                "\"Shared\": false, \"Zebra\": \"late\", "
                "\"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "Subnets" "Shared"
                      "Alpha" "Zebra")
       :list-rows ("^net-1 +provider +ACTIVE +subnet-1 +true +early +late"
                   "^net-2 +- +DOWN +- +- +early +late")
       :list-first-id "net-1")

      ("project"
       :show-id "proj-1"
       :show-json
       ,(concat "{\"id\": \"proj-1\", \"name\": \"demo\", "
                "\"enabled\": true, "
                "\"description\": \"Demo project\", "
                "\"domain_id\": \"default\", "
                "\"parent_id\": \"default\", "
                "\"tags\": [\"team-a\", \"team-b\"], "
                "\"options\": {}, "
                "\"zzz_extra\": \"late\"}")
       :show-missing ("is_domain")
       :show-nested (("tags" . "team-a, team-b")
                     ("options" . "{}"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"proj-1\", \"Name\": \"demo\", "
                "\"Enabled\": true, \"Domain ID\": \"default\", "
                "\"Description\": \"demo project\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"proj-2\", \"Name\": \"\", "
                "\"Enabled\": false, \"Domain ID\": \"default\", "
                "\"Description\": \"\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Enabled" "Domain ID"
                      "Description" "Alpha" "Zebra")
       :list-rows ("^proj-1 +demo +true +default +demo project +early +late"
                   "^proj-2 +- +- +default +- +early +late")
       :list-first-id "proj-1")

      ("container"
       :show-id "logs"
       :show-json
       ,(concat "{\"container\": \"logs\", \"bytes_used\": 4096, "
                "\"object_count\": 2, "
                "\"account\": \"v1/AUTH_demo\", "
                "\"read_acl\": \".r:*\", \"write_acl\": \"\", "
                "\"storage_policy\": \"default\", "
                "\"zzz_extra\": \"late\", "
                "\"properties\": {\"owner\": \"ops\"}}")
       :show-missing ("sync_to" "sync_key")
       :show-unlisted ("zzz_extra")
       :show-properties (("owner" . "ops"))
       :list-json
       ,(concat "[{\"Name\": \"logs\", \"Bytes\": 4096, "
                "\"Count\": 2}, "
                "{\"Name\": \"backups\", \"Bytes\": 1048576, "
                "\"Count\": 12}]")
       :list-columns ("Name" "Bytes" "Count")
       :list-rows ("^logs +4096 +2"
                   "^backups +1048576 +12")
       :list-first-id "logs")

      ("subnet"
       :show-id "subnet-1"
       :show-json
       ,(concat "{\"id\": \"subnet-1\", \"name\": \"private-subnet\", "
                "\"network_id\": \"net-1\", "
                "\"cidr\": \"10.0.0.0/24\", "
                "\"gateway_ip\": \"10.0.0.1\", \"ip_version\": 4, "
                "\"enable_dhcp\": true, "
                "\"dns_nameservers\": [\"8.8.8.8\", \"1.1.1.1\"], "
                "\"subnetpool_id\": \"pool-1\", "
                "\"allocation_pools\": [{\"start\": \"10.0.0.10\", "
                "\"end\": \"10.0.0.99\"}], "
                "\"host_routes\": [], "
                "\"project_id\": \"proj-1\", "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("dns_nameservers" . "8.8.8.8, 1.1.1.1"))
       :show-blocks (("allocation_pools" . "^  - end: +10\\.0\\.0\\.99$"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"subnet-1\", \"Name\": \"private-subnet\", "
                "\"Network\": \"net-1\", \"Subnet\": \"10.0.0.0/24\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"subnet-2\", \"Name\": \"\", "
                "\"Network\": \"net-1\", \"Subnet\": \"10.0.1.0/24\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Network" "Subnet" "Alpha" "Zebra")
       :list-rows ("^subnet-1 +private-subnet +net-1 +10\\.0\\.0\\.0/24 +early +late"
                   "^subnet-2 +- +net-1 +10\\.0\\.1\\.0/24 +early +late")
       :list-first-id "subnet-1")

      ("port"
       :show-id "port-1"
       :show-json
       ,(concat "{\"id\": \"port-1\", \"name\": \"\", "
                "\"status\": \"ACTIVE\", "
                "\"mac_address\": \"fa:16:3e:00:00:01\", "
                "\"fixed_ips\": [{\"ip_address\": \"10.0.0.5\", "
                "\"subnet_id\": \"subnet-1\"}], "
                "\"device_owner\": \"compute:nova\", "
                "\"device_id\": \"srv-1\", "
                "\"network_id\": \"net-1\", "
                "\"security_group_ids\": [\"sg-1\", \"sg-2\"], "
                "\"admin_state_up\": true, "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-references (("security_group_ids" . ("sg-1" "sg-2")))
       :show-blocks (("fixed_ips" . "^  - ip_address: 10\\.0\\.0\\.5$"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"port-1\", \"Name\": \"\", "
                "\"MAC Address\": \"fa:16:3e:00:00:01\", "
                "\"Fixed IP Addresses\": \"10.0.0.5\", "
                "\"Status\": \"ACTIVE\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"port-2\", \"Name\": \"dhcp\", "
                "\"MAC Address\": \"fa:16:3e:00:00:02\", "
                "\"Fixed IP Addresses\": \"10.0.0.6\", "
                "\"Status\": \"DOWN\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "MAC Address" "Fixed IP Addresses"
                      "Status" "Alpha" "Zebra")
       :list-rows ("^port-1 +- +fa:16:3e:00:00:01 +10\\.0\\.0\\.5 +ACTIVE +early +late"
                   "^port-2 +dhcp +fa:16:3e:00:00:02 +10\\.0\\.0\\.6 +DOWN +early +late")
       :list-first-id "port-1")

      ("router"
       :show-id "router-1"
       :show-json
       ,(concat "{\"id\": \"router-1\", \"name\": \"main\", "
                "\"status\": \"ACTIVE\", \"admin_state_up\": true, "
                "\"ha\": true, \"distributed\": true, "
                "\"external_gateway_info\": {\"network_id\": \"net-ext\", "
                "\"enable_snat\": true}, "
                "\"interfaces_info\": [{\"port_id\": \"port-1\", "
                "\"ip_address\": \"10.0.0.1\", "
                "\"subnet_id\": \"subnet-1\"}], "
                "\"routes\": [{\"destination\": \"0.0.0.0/0\", "
                "\"nexthop\": \"10.0.0.1\"}], "
                "\"project_id\": \"proj-1\", "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("external_gateway_info" . "{\"network_id\""))
       :show-blocks (("interfaces_info" . "^  - ip_address: 10\\.0\\.0\\.1$")
                     ("routes" . "^  - destination: 0\\.0\\.0\\.0/0$"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"router-1\", \"Name\": \"main\", "
                "\"Status\": \"ACTIVE\", \"State\": \"UP\", "
                "\"Project\": \"proj-1\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"router-2\", \"Name\": \"edge\", "
                "\"Status\": \"DOWN\", \"State\": \"DOWN\", "
                "\"Project\": \"proj-1\", "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Status" "State" "Project"
                      "Alpha" "Zebra")
       :list-rows ("^router-1 +main +ACTIVE +UP +proj-1 +early +late"
                   "^router-2 +edge +DOWN +DOWN +proj-1 +early +late")
       :list-first-id "router-1")

      ("flavor"
       :show-id "flavor-1"
       :show-json
       ,(concat "{\"id\": \"flavor-1\", \"name\": \"m1.small\", "
                "\"vcpus\": 1, \"ram\": 2048, \"disk\": 20, "
                "\"ephemeral\": 0, \"swap\": 0, "
                "\"rxtx_factor\": 1.0, \"is_public\": true, "
                "\"extra_specs\": {\"hw:cpu_policy\": \"dedicated\"}, "
                "\"description\": \"\", "
                "\"zzz_extra\": \"late\"}")
       :show-missing ("updated_at")
       :show-nested (("extra_specs" . "{\"hw:cpu_policy\""))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"flavor-1\", \"Name\": \"m1.small\", "
                "\"RAM\": 2048, \"Disk\": 20, \"Ephemeral\": 0, "
                "\"VCPUs\": 1, \"Is Public\": true, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"flavor-2\", \"Name\": \"m2.large\", "
                "\"RAM\": 512, \"Disk\": 40, \"Ephemeral\": 0, "
                "\"VCPUs\": 2, \"Is Public\": false, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "RAM" "Disk" "Ephemeral" "VCPUs"
                      "Is Public" "Alpha" "Zebra")
       :list-rows ("^flavor-1 +m1\\.small +2048 +20 +0 +1 +true +early +late"
                   "^flavor-2 +m2\\.large + +512 +40 +0 +2 +- +early +late")
       :list-first-id "flavor-1")

      ("security-group"
       :show-id "sg-1"
       :show-json
       ,(concat "{\"id\": \"sg-1\", \"name\": \"default\", "
                "\"description\": \"Default security group\", "
                "\"project_id\": \"proj-1\", \"shared\": false, "
                "\"stateful\": true, \"tags\": [\"team-a\"], "
                "\"rules\": [{\"id\": \"rule-1\", "
                "\"direction\": \"ingress\", \"protocol\": \"tcp\", "
                "\"port_range_min\": 22, \"port_range_max\": 22, "
                "\"remote_ip_prefix\": \"0.0.0.0/0\"}], "
                "\"zzz_extra\": \"late\", "
                "\"created_at\": \"2026-01-01T00:00:00Z\"}")
       :show-missing ("updated_at")
       :show-nested (("tags" . "team-a"))
       :show-blocks (("rules" . "^  - direction: +ingress$"))
       :show-unlisted ("zzz_extra")
       :list-json
       ,(concat "[{\"ID\": \"sg-1\", \"Name\": \"default\", "
                "\"Description\": \"Default security group\", "
                "\"Project\": \"proj-1\", \"Tags\": \"team-a\", "
                "\"Shared\": false, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}, "
                "{\"ID\": \"sg-2\", \"Name\": \"web\", "
                "\"Description\": \"\", \"Project\": \"proj-1\", "
                "\"Tags\": \"\", \"Shared\": true, "
                "\"Zebra\": \"late\", \"Alpha\": \"early\"}]")
       :list-columns ("ID" "Name" "Description" "Project" "Tags"
                      "Shared" "Alpha" "Zebra")
       :list-rows ("^sg-1 +default +Default security group +proj-1 +team-a +- +early +late"
                   "^sg-2 +web +- +proj-1 +- +true +early +late")
       :list-first-id "sg-1"))
    "Client answers and expected texts, one entry per resource type.
Each entry is a list of the type string and a plist.  The plist
holds the ID, JSON and expectations of the show mode (:show-*) and
of the list mode (:list-*).  The first row of the list JSON names
:list-first-id, the row identity the table must report."))

(defmacro openstack-resource-test--def-type-tests (suffix &rest body)
  "Define SUFFIX tests, one per fixture in the fixture table.
Each test is named `openstack-TYPE-SUFFIX' and runs BODY with
`type' bound to the type string and `fixture' to its plist."
  (declare (indent 1) (debug (symbolp body)))
  `(progn
     ,@(mapcar
        (lambda (entry)
          (let ((type (car entry)))
            `(ert-deftest ,(intern (format "openstack-%s-%s" type suffix)) ()
               ,(format "Check `%s' against its fixture." type)
               (let ((type ,type)
                     (fixture ',(cdr entry)))
                 (ignore fixture)
                 ,@body))))
        openstack-resource-test--fixtures)))

;;; Helpers

(defun openstack-resource-test--parse (json)
  "Parse JSON into hash tables, lists and nil for false."
  (with-temp-buffer
    (insert json)
    (goto-char (point-min))
    (json-parse-buffer :object-type 'hash-table
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun openstack-resource-test--definition (type)
  "Return the resource definition plist of TYPE."
  (openstack-resource-definition type))

(defun openstack-resource-test--name (type format)
  "Return the symbol of TYPE with FORMAT applied to it.
FORMAT holds one `%s' for the type string."
  (intern (format format type)))

(defun openstack-resource-test--title (type)
  "Return the show table title of TYPE."
  (or (plist-get (openstack-resource-definition type) :title)
      (capitalize type)))

(defun openstack-resource-test--show-buffer (type fixture)
  "Return the display buffer name of TYPE for FIXTURE."
  (format "%s <%s>"
          (symbol-value (openstack-resource-test--name
                         type "openstack-%s-buffer-name"))
          (plist-get fixture :show-id)))

(defun openstack-resource-test--fixture-script (fixture)
  "Return a client script answering FIXTURE's `show' and `list'.
The script reads the action from the command words, so a resource
whose client command takes two words, as the `security group'
command does, answers too."
  (format (concat "case \"$*\" in\n"
                  "  *\" show\"*) echo '%s' ;;\n"
                  "  *\" list\"*) echo '%s' ;;\n"
                  "esac\n")
          (plist-get fixture :show-json)
          (plist-get fixture :list-json)))

(defun openstack-resource-test--wait-rendered (buffer)
  "Wait until BUFFER finishes its fetch and renders data."
  (openstack-test--wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and openstack--rendered (not openstack--pending)))))))

(defun openstack-resource-test--wait-idle (buffer)
  "Wait until BUFFER has no fetch in flight."
  (openstack-test--wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer (not openstack--pending))))))

(defun openstack-resource-test--positions (fields text)
  "Return (FIELD . POSITION) for the field lines of FIELDS in TEXT."
  (delq nil
        (mapcar (lambda (field)
                  (let ((pos (string-match
                              (concat "^" (regexp-quote field) ": ") text)))
                    (and pos (cons field pos))))
                fields)))

;;; Tests

(openstack-resource-test--def-type-tests mode-is-derived
  (let ((mode (openstack-resource-test--name type "openstack-%s-mode"))
        (definition (openstack-resource-test--definition type)))
    (with-temp-buffer
      (funcall mode)
      (should (derived-mode-p 'openstack-mode))
      (should (eq openstack-fetch-function
                  (openstack-resource-test--name type "openstack-%s--fetch")))
      (should (eq openstack-render-function
                  (openstack-resource-test--name type "openstack-%s--render")))
      (should (equal openstack-id-prefix (plist-get definition :id-prefix)))
      (should (equal openstack-url-suffix
                     (or (plist-get definition :url-suffix) "")))
      ;; The base mode's ID handling survives.
      (setq-local openstack--id (plist-get fixture :show-id))
      (should (equal (openstack--resource-id t) (plist-get fixture :show-id))))))

(openstack-resource-test--def-type-tests mode-dashboard-url
  (let ((mode (openstack-resource-test--name type "openstack-%s-mode"))
        (definition (openstack-resource-test--definition type))
        (openstack-web-base-url "https://horizon.example.org")
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (funcall mode)
      (should (equal (openstack-dashboard-url id)
                     (format "https://horizon.example.org/%s/%s%s"
                             (plist-get definition :id-prefix)
                             id
                             (or (plist-get definition :url-suffix) "")))))))

(openstack-resource-test--def-type-tests fetch-calls-async-request
  (let ((fetch (openstack-resource-test--name type "openstack-%s--fetch"))
        (cli (plist-get (openstack-resource-test--definition type) :cli))
        (id (plist-get fixture :show-id))
        (args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (funcall fetch id (lambda (_data) nil) (lambda (_err) nil))
                  :process-handle))
      (should (equal args-seen
                     (append (split-string cli) (list "show" id))))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(openstack-resource-test--def-type-tests render-shows-ordered-fields
  (let ((render (openstack-resource-test--name type "openstack-%s--render"))
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render id
                 (openstack-resource-test--parse
                  (plist-get fixture :show-json))))
      (let* ((text (buffer-string))
             (fields (plist-get (openstack-resource-test--definition type)
                                :fields))
             (positions (openstack-resource-test--positions fields text)))
        (should (string-match-p
                 (concat "^" (openstack-resource-test--title type) ": ")
                 text))
        (should (string-match-p (concat "^ID: " (regexp-quote id) "$")
                                text))
        ;; Listed fields keep their order.
        (should (> (length positions) 1))
        (should (equal (mapcar #'cdr positions)
                       (sort (mapcar #'cdr positions) #'<)))
        ;; Unlisted fields follow the listed ones, sorted by name.
        (let ((last-listed (apply #'max (mapcar #'cdr positions)))
              (unlisted nil))
          (dolist (field (plist-get fixture :show-unlisted))
            (let ((pos (string-match
                        (concat "^" (regexp-quote field) ": ") text)))
              (should pos)
              (should (> pos last-listed))
              (push pos unlisted)))
          (should (equal unlisted (sort unlisted #'<)))
          ;; A hash-table `properties' value closes the table as an
          ;; indented, sorted block instead of a JSON dump.
          (when-let* ((properties (plist-get fixture :show-properties)))
            (let ((first-property nil)
                  (previous nil)
                  (last-body (apply #'max
                                    (append (mapcar #'cdr positions)
                                            unlisted))))
              (should (string-match-p "^properties:$" text))
              (dolist (entry properties)
                (let ((pos (string-match
                            (concat "^  " (regexp-quote (car entry)) ": +"
                                    (regexp-quote (cdr entry)) "$")
                            text)))
                  (should pos)
                  (if previous
                      (should (> pos previous))
                    (setq first-property pos))
                  (setq previous pos)))
              (should (> first-property last-body))
              (should-not (string-match-p "^properties: {" text)))))
        ;; A field formatter rewrites the show value only.
        (dolist (entry (plist-get fixture :show-values))
          (should (string-match-p
                   (concat "^" (regexp-quote (car entry)) ": +"
                           (regexp-quote (cdr entry)) "$")
                   text)))
        ;; Missing fields are skipped.
        (dolist (field (plist-get fixture :show-missing))
          (should-not (string-match-p
                       (concat "^" (regexp-quote field) ": ") text)))
        ;; Nested values render as JSON, a list of plain values as
        ;; comma-separated text.
        (dolist (entry (plist-get fixture :show-nested))
          (should (string-match-p
                   (concat "^" (regexp-quote (car entry)) ": +"
                           (regexp-quote (cdr entry)))
                   text)))
        ;; A block field prints a heading and indented records.
        (dolist (entry (plist-get fixture :show-blocks))
          (should (string-match-p (cdr entry) text)))))))

(openstack-resource-test--def-type-tests render-non-hash-data
  (let ((render (openstack-resource-test--name type "openstack-%s--render"))
        (id (plist-get fixture :show-id)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render id nil))
      (should (string-match-p
               (concat "^" (openstack-resource-test--title type) ": "
                       (regexp-quote id) "$")
               (buffer-string))))))

(openstack-resource-test--def-type-tests render-references-per-line
  (let ((render (openstack-resource-test--name type "openstack-%s--render"))
        (id (plist-get fixture :show-id)))
    (when-let* ((references (plist-get fixture :show-references)))
      (with-temp-buffer
        (let ((inhibit-read-only t))
          (funcall render id
                   (openstack-resource-test--parse
                    (plist-get fixture :show-json))))
        (dolist (entry references)
          (let ((field (car entry))
                (values (cdr entry))
                (text (buffer-string)))
            (should (string-match-p
                     (concat "^" (regexp-quote field) ": +"
                             (regexp-quote (car values)) "$")
                     text))
            (should-not (string-match-p (concat "^" (regexp-quote field)
                                                ": .*,")
                                        text))
            ;; Every ID of the list starts its own line, and the later
            ;; ones line up under the first.
            (goto-char (point-min))
            (search-forward (car values))
            (let ((column (current-column)))
              (dolist (value (cdr values))
                (should (string-match-p (concat "^ +"
                                                (regexp-quote value)
                                                "$")
                                        text))
                (goto-char (point-min))
                (search-forward value)
                (should (= (current-column) column))))
            (dolist (value values)
              (goto-char (point-min))
              (search-forward value)
              (should (equal (get-text-property (match-beginning 0)
                                                'openstack-id)
                             value)))))))))

(openstack-resource-test--def-type-tests display-renders-from-real-client
  (let ((display (openstack-resource-test--name type "openstack-%s-display"))
        (mode (openstack-resource-test--name type "openstack-%s-mode"))
        (id (plist-get fixture :show-id)))
    (openstack-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall display id)
               (let ((buf (get-buffer
                           (openstack-resource-test--show-buffer type fixture))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (should (derived-mode-p mode))
                   (should (string-match-p
                            (concat "^" (openstack-resource-test--title type)
                                    ": ")
                            (buffer-string)))
                   (should (null openstack--last-error)))))
           (let ((buf (get-buffer
                       (openstack-resource-test--show-buffer type fixture))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests display-reports-client-error
  (let ((display (openstack-resource-test--name type "openstack-%s-display"))
        (id (plist-get fixture :show-id)))
    (openstack-test--with-fixture-program
     "printf '%s' 'not json'\n"
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall display id)
               (let ((buf (get-buffer
                           (openstack-resource-test--show-buffer type fixture))))
                 (should buf)
                 (openstack-resource-test--wait-idle buf)
                 (with-current-buffer buf
                   (should openstack--last-error))))
           (let ((buf (get-buffer
                       (openstack-resource-test--show-buffer type fixture))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests list-mode-is-derived
  (let ((list-mode
         (openstack-resource-test--name type "openstack-%s-list-mode"))
        (definition (openstack-resource-test--definition type)))
    (with-temp-buffer
      (funcall list-mode)
      (should (derived-mode-p 'openstack-list-mode))
      (should (derived-mode-p 'tabulated-list-mode))
      (should openstack-collection)
      (should openstack-render-manages-buffer)
      (should (equal openstack-list--noun (plist-get definition :noun)))
      (should (eq openstack-fetch-function
                  (openstack-resource-test--name
                   type "openstack-%s-list--fetch")))
      (should (eq openstack-render-function
                  (openstack-resource-test--name
                   type "openstack-%s-list--render")))
      ;; RET on a row opens the resource's show buffer.
      (should (eq openstack-show-command
                  (openstack-resource-test--name type "openstack-%s-display")))
      ;; A collection has no resource ID: the ID commands error.
      (should-error (openstack--resource-id t) :type 'user-error))))

(openstack-resource-test--def-type-tests list-fetch-runs-list
  (let ((fetch (openstack-resource-test--name type "openstack-%s-list--fetch"))
        (definition (openstack-resource-test--definition type))
        (args-seen nil)
        (success-seen nil)
        (error-seen nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (setq args-seen args
                                    success-seen success-fn
                                    error-seen error-fn)
                              :process-handle))))
      (should (eq (funcall fetch nil (lambda (_data) nil)
                           (lambda (_err) nil))
                  :process-handle))
      (should (equal args-seen
                     (append (split-string (plist-get definition :cli))
                             (list "list")
                             (plist-get definition :list-arguments))))
      (should (functionp success-seen))
      (should (functionp error-seen)))))

(ert-deftest openstack-image-list-prefix-adds-all ()
  "A prefix argument makes the image list ask the client for --all.
The prefix arguments follow the `openstack-image-list-arguments'
defcustom, and a call without a prefix drops them again."
  (let ((args-seen nil)
        (openstack-image-list-arguments '("--long"))
        (buf nil))
    (cl-letf (((symbol-function 'openstack-cli-async-request)
               (cl-function (lambda (args &key success-fn error-fn)
                              (ignore success-fn error-fn)
                              (setq args-seen args)
                              :process-handle))))
      (unwind-protect
          (progn
            (openstack-image-list-display '(4))
            (setq buf (get-buffer openstack-image-list-buffer-name))
            (should (equal args-seen
                           '("image" "list" "--long" "--all")))
            (with-current-buffer buf
              (should (equal openstack-list--prefix-arguments '("--all"))))
            (openstack-image-list-display)
            (should (equal args-seen '("image" "list" "--long")))
            (with-current-buffer buf
              (should-not openstack-list--prefix-arguments)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(openstack-resource-test--def-type-tests list-columns-ordered
  (let ((columns (openstack-resource-test--name
                  type "openstack-%s-list--columns")))
    (should (equal (funcall columns
                            (openstack-resource-test--parse
                             (plist-get fixture :list-json)))
                   (plist-get fixture :list-columns)))))

(openstack-resource-test--def-type-tests list-render-table
  (let ((list-mode
         (openstack-resource-test--name type "openstack-%s-list-mode"))
        (render (openstack-resource-test--name type "openstack-%s-list--render")))
    (with-temp-buffer
      (funcall list-mode)
      (funcall render nil
               (openstack-resource-test--parse
                (plist-get fixture :list-json)))
      (let ((header (prin1-to-string header-line-format))
            (text (buffer-string)))
        (dolist (column (plist-get fixture :list-columns))
          (should (string-match-p (regexp-quote column) header)))
        (dolist (row (plist-get fixture :list-rows))
          (should (string-match-p row text)))
        ;; The first row is the row at point, with its resource ID.
        (should (equal (tabulated-list-get-id)
                       (plist-get fixture :list-first-id)))))))

(openstack-resource-test--def-type-tests list-render-empty
  (let ((render (openstack-resource-test--name type "openstack-%s-list--render"))
        (noun (plist-get (openstack-resource-test--definition type) :noun)))
    (with-temp-buffer
      (let ((inhibit-read-only t))
        (funcall render nil nil))
      (should (string-match-p (concat "(no " (regexp-quote noun) ")")
                              (buffer-string))))))

(openstack-resource-test--def-type-tests list-display-renders-from-real-client
  (let ((list-display
         (openstack-resource-test--name type "openstack-%s-list-display"))
        (list-buffer (openstack-resource-test--name
                      type "openstack-%s-list-buffer-name")))
    (openstack-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5))
         (unwind-protect
             (progn
               (funcall list-display)
               (let ((buf (get-buffer (symbol-value list-buffer))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (should openstack-collection)
                   (should (null openstack--id))
                   (should (string-match-p
                            "Name" (prin1-to-string header-line-format)))
                   (dolist (row (plist-get fixture :list-rows))
                     (should (string-match-p row (buffer-string))))
                   (should (null openstack--last-error)))))
           (let ((buf (get-buffer (symbol-value list-buffer))))
             (when buf (kill-buffer buf)))))))))

(openstack-resource-test--def-type-tests list-RET-opens-show
  (let ((list-display
         (openstack-resource-test--name type "openstack-%s-list-display"))
        (list-buffer (openstack-resource-test--name
                      type "openstack-%s-list-buffer-name"))
        (first-id (plist-get fixture :list-first-id))
        (show-buffer-name
         (openstack-resource-test--name type "openstack-%s-buffer-name")))
    (openstack-test--with-fixture-program
     (openstack-resource-test--fixture-script fixture)
     (lambda (program)
       (let ((openstack-program program)
             (openstack-cli-timeout 5)
             (expected (format "%s <%s>" (symbol-value show-buffer-name)
                               first-id)))
         (unwind-protect
             (progn
               (funcall list-display)
               (let ((buf (get-buffer (symbol-value list-buffer))))
                 (should buf)
                 (openstack-resource-test--wait-rendered buf)
                 (with-current-buffer buf
                   (re-search-forward (regexp-quote first-id))
                   (goto-char (match-beginning 0))
                   (openstack-display-at-point))
                 (let ((show (get-buffer expected)))
                   (should show)
                   (openstack-resource-test--wait-rendered show)
                   (with-current-buffer show
                     (should (null openstack--last-error))))))
           (dolist (name (list (symbol-value list-buffer) expected))
             (let ((buf (get-buffer name)))
               (when buf (kill-buffer buf))))))))))

(ert-deftest openstack-resource-tests-cover-registry ()
  "Every registered resource type has a fixture, in registry order."
  (should (equal (mapcar #'car openstack-resource-test--fixtures)
                 (mapcar #'car openstack-resource-definitions))))

(provide 'openstack-resource-test)
;;; openstack-resource-test.el ends here
