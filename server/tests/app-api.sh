#!/usr/bin/env bash
# API test of the NextDesk Nextcloud app (server/app/nextdesk) against disposable Nextcloud
# containers: settings pages, device policy, admin API, enrollment, device token reports and
# secrets, app password check-in, one-time browser login, computers API, occ commands, access
# checks for a non-admin user, and errors in nextcloud.log.
#
#   server/tests/app-api.sh                 # Nextcloud 30, 34 and 35
#   VERSIONS="35" server/tests/app-api.sh   # one version
#   KEEP=1 server/tests/app-api.sh          # leave the containers running afterwards
#
# Needs docker, curl and python3. Containers nd-nc<version> listen on port 81<version>.
# Works in Git Bash on Windows too (paths for docker and curl go through cygpath).
set -u
export MSYS_NO_PATHCONV=1
native() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else echo "$1"; fi; }
APP=$(native "$(cd "$(dirname "$0")/../app/nextdesk" && pwd)")
TMP=$(native "$(mktemp -d)")
PY=$(command -v python3 || command -v python)
A=admin:Test-pass-123; B=bob:User-pass-123
MID=0123456789abcdef0123456789abcdef
pass=0; fail=0
ok()  { echo "   PASS $*"; pass=$((pass+1)); }
bad() { echo "   FAIL $*"; fail=$((fail+1)); }
# check <description> <expected> <actual>
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi; }
j() { "$PY" -c "import json,sys
d=json.load(sys.stdin); d=d.get('ocs',{}).get('data',d) if isinstance(d,dict) else d
for k in sys.argv[1].split('.'):
    d=d[int(k)] if isinstance(d,list) else d.get(k) if isinstance(d,dict) else None
print(json.dumps(d) if isinstance(d,(dict,list)) else d)" "$1" 2>/dev/null; }
ocs() { local m=$1 u=$2 auth=$3; shift 3; curl -s -X $m ${auth:+-u $auth} -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$@" "$BASE/ocs/v2.php/apps/nextdesk/api/v1$u"; }
code() { local m=$1 u=$2 auth=$3; shift 3; curl -s -o /dev/null -w '%{http_code}' -X $m ${auth:+-u $auth} -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$@" "$BASE/ocs/v2.php/apps/nextdesk/api/v1$u"; }

for v in ${VERSIONS:-30 34 35}; do
  docker rm -f -v nd-nc$v >/dev/null 2>&1
  docker run -d --name nd-nc$v -p 81$v:80 -e SQLITE_DATABASE=nc -e NEXTCLOUD_ADMIN_USER=admin \
    -e NEXTCLOUD_ADMIN_PASSWORD=Test-pass-123 -e NEXTCLOUD_TRUSTED_DOMAINS="localhost localhost:81$v" \
    -v "$APP:/usr/src/nextdesk:ro" nextcloud:$v-apache >/dev/null || exit 1
done

for v in ${VERSIONS:-30 34 35}; do
  c=nd-nc$v; BASE=http://localhost:81$v; occ() { docker exec -u www-data $c php occ "$@"; }
  echo "################ NC $v"
  for i in $(seq 1 120); do occ status 2>/dev/null | grep -q 'installed: true' && break; sleep 5; done
  occ status | grep versionstring
  docker exec $c sh -c 'rm -rf /var/www/html/custom_apps/nextdesk && cp -r /usr/src/nextdesk /var/www/html/custom_apps/nextdesk && chown -R www-data: /var/www/html/custom_apps/nextdesk'
  out=$(occ app:enable nextdesk 2>&1 | tail -1); echo "   $out"
  check "app enabled" "yes" "$(occ app:list --enabled | grep -q ' nextdesk:' && echo yes)"
  OC_PASS=User-pass-123 docker exec -e OC_PASS -u www-data $c php occ user:add --password-from-env bob >/dev/null 2>&1

  echo "-- admin settings pages"
  check "security page shows NextDesk settings" "yes" "$(curl -s -u $A "$BASE/index.php/settings/admin/security" | grep -qi 'nextdesk' && echo yes)"
  check "computers section page" "200" "$(curl -s -o /dev/null -w '%{http_code}' -u $A "$BASE/index.php/settings/admin/nextdesk-computers")"

  echo "-- public device policy + admin APIs"
  check "public device-policy url (unset)" "None" "$(ocs GET /device-policy '' | j url)"
  check "admin sets device policy url" "200" "$(code PUT /admin/device-policy $A --data-urlencode url=https://repo.example.org/policy/test.json)"
  check "public device-policy url" "https://repo.example.org/policy/test.json" "$(ocs GET /device-policy '' | j url)"
  check "non-admin can't set device policy" "403" "$(code PUT /admin/device-policy $B --data-urlencode url=https://evil.example/x.json)"
  check "http:// url rejected" "400" "$(code PUT /admin/device-policy $A --data-urlencode url=http://insecure.example/x.json)"
  check "admin sets global policy" "200" "$(code PUT /admin/policy $A -H 'Content-Type: application/json' --data '{"scope":"global","policy":{"offline_grace_days":7}}')"
  check "admin reads policy" "200" "$(code GET /admin/policy $A)"
  check "non-admin can't read admin policy" "403" "$(code GET /admin/policy $B)"
  check "occ nextdesk:policy runs" "0" "$(occ nextdesk:policy >/dev/null 2>&1; echo $?)"
  check "occ nextdesk:recovery-key runs" "0" "$(occ nextdesk:recovery-key >/dev/null 2>&1; echo $?)"

  echo "-- enrollment"
  ET=$(ocs POST /admin/enrollment-tokens $A | j token)
  check "admin creates enrollment token" "yes" "$([ -n "$ET" ] && [ "$ET" != None ] && echo yes)"
  check "non-admin can't create token" "403" "$(code POST /admin/enrollment-tokens $B)"
  check "enroll/check valid token" "True" "$(ocs POST /enroll/check '' --data-urlencode enrollment_token=$ET | j valid)"
  check "enroll/check wrong token" "403" "$(code POST /enroll/check '' --data-urlencode enrollment_token=wrong)"
  DT=$(ocs POST /enroll '' --data-urlencode enrollment_token=$ET --data-urlencode machine_id=$MID --data-urlencode hostname=test-pc --data-urlencode version=0.25.2 | j token)
  check "enroll returns device token" "yes" "$([ -n "$DT" ] && [ "$DT" != None ] && echo yes)"

  echo "-- machine reports with its device token"
  check "contact with device token" "True" "$(ocs POST /contact '' --data-urlencode machine_id=$MID --data-urlencode token=$DT --data-urlencode version=0.25.2 | j ok)"
  check "contact with wrong token" "403" "$(code POST /contact '' --data-urlencode machine_id=$MID --data-urlencode token=wrong)"
  check "device-secrets stored" "True" "$(ocs POST /device-secrets '' --data-urlencode machine_id=$MID --data-urlencode token=$DT --data-urlencode recovery_key=cbdefghi-jklnrtuv-cbdefghi-jklnrtuv-cbdefghi-jklnrtuv-cbdefghi-jklnrtuv --data-urlencode disk_uuid=1234 --data-urlencode admin_user=localadmin --data-urlencode admin_password=Local-admin-pass-0123456789 | j stored)"

  echo "-- computers page API"
  check "computers list total" "1" "$(ocs GET /computers $A | j total)"
  check "non-admin can't list computers" "403" "$(code GET /computers $B)"
  check "read recovery key" "cbdefghi-jklnrtuv-cbdefghi-jklnrtuv-cbdefghi-jklnrtuv-cbdefghi-jklnrtuv" "$(ocs GET /computers/$MID/recovery-key $A | j recovery_key)"
  check "read admin password" "Local-admin-pass-0123456789" "$(ocs GET /computers/$MID/admin-password $A | j admin_password)"

  echo "-- device with a user's app password"
  AP=$(docker exec -u www-data -e NC_PASS=Test-pass-123 $c php occ user:add-app-password --password-from-env admin 2>/dev/null | grep -oE '[A-Za-z0-9]{72}' | head -1)
  [ -z "$AP" ] && AP=$(occ user:auth-tokens:add admin 2>/dev/null | grep -oE '[A-Za-z0-9]{72}' | head -1)
  check "app password created" "yes" "$([ -n "$AP" ] && echo yes)"
  check "policy with app password (user id)" "admin" "$(ocs GET /policy admin:$AP | j user.id)"
  check "check-in with app password" "True" "$(ocs POST /check-in admin:$AP --data-urlencode machine_id=$MID --data-urlencode hostname=test-pc | j ok)"
  check "check-in refused with normal password" "403" "$(code POST /check-in $A --data-urlencode machine_id=$MID)"
  URL=$(ocs POST /session-token admin:$AP --data-urlencode redirect=/apps/files/ | j url)
  check "session-token gives login URL" "yes" "$(echo "$URL" | grep -q '/apps/nextdesk/login' && echo yes)"
  URL=${URL/http:\/\/localhost/$BASE}; URL=${URL/$BASE:81$v/$BASE}
  jar="$TMP/jar$v"
  loc=$(curl -s -c $jar -o /dev/null -w '%{redirect_url}' "$URL")
  check "one-time login redirects to files" "yes" "$(echo "$loc" | grep -q '/apps/files/' && echo yes)"
  check "session is logged in" "200" "$(curl -s -b $jar -o /dev/null -w '%{http_code}' "$BASE/index.php/apps/files/")"
  check "login token can't be reused" "yes" "$(curl -s -o /dev/null -w '%{redirect_url}' "$URL" | grep -q '/login' && echo yes)"

  echo "-- cleanup API"
  check "delete computer" "200" "$(code DELETE /computers/$MID $A)"
  check "computers list empty" "0" "$(ocs GET /computers $A | j total)"

  echo "-- nextcloud.log errors"
  errs=$(docker exec $c sh -c 'grep -iE "nextdesk" /var/www/html/data/nextcloud.log 2>/dev/null | grep -E "\"level\":[34]" | cut -c1-400')
  if [ -z "$errs" ]; then ok "no nextdesk errors in nextcloud.log"; else bad "errors:"; echo "$errs" | tail -3; fi
done
rm -rf "$TMP"
[ -z "${KEEP:-}" ] && for v in ${VERSIONS:-30 34 35}; do docker rm -f -v nd-nc$v >/dev/null; done
echo "======== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
