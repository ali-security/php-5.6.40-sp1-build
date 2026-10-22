#!/bin/bash
# Verifies a sealed PHP 5.6.40+sp1 CLI bundle: version, modules, the CVE-2026-109618 OOM exit and the
# multipart limits through the built-in server (php -S). Usage: verify-bundle.sh <path/to/bin/php>
set -euo pipefail

PHP=$1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
TESTS=$REPO_DIR/tests
TMP=$(mktemp -d)
PORT=8089
REQUIRED_MODULES="bcmath bz2 calendar Core ctype curl date dba dom exif fileinfo filter ftp gd gettext gmp hash iconv intl json ldap libxml mbstring mcrypt mysql mysqli mysqlnd openssl pcntl pcre PDO pdo_dblib pdo_mysql PDO_ODBC pdo_pgsql pdo_sqlite pgsql Phar posix pspell readline Reflection session shmop SimpleXML soap sockets SPL sqlite3 standard sysvmsg sysvsem sysvshm tidy tokenizer wddx xml xmlreader xmlrpc xmlwriter xsl zip zlib"
# mcrypt needs libmcrypt, which Homebrew no longer ships; it is not in the formula's set either.
REQUIRED_MODULES=${REQUIRED_MODULES/ mcrypt/}

function fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "== php -v"
"$PHP" -n -v
"$PHP" -n -v | grep -q '^PHP 5\.6\.40 ' || fail "unexpected version"

echo "== php -m"
"$PHP" -n -m | tee "$TMP/modules"
for m in $REQUIRED_MODULES; do
    grep -qx "$m" "$TMP/modules" || fail "module $m missing"
done

echo "== sealed INI default"
[ "$("$PHP" -n -r 'echo ini_get("max_multipart_body_parts");')" = "-1" ] || fail "max_multipart_body_parts missing"

echo "== OpenSSL"
"$PHP" -n -r 'echo OPENSSL_VERSION_TEXT, "\n";'
"$PHP" -n -r 'exit(strlen(file_get_contents("https://www.php.net/")) > 0 ? 0 : 1);' || fail "https request failed"

echo "== OOM: memory_limit exhaustion must _exit(1) without running shutdown functions"
set +e
"$PHP" -n -d memory_limit=4M "$TESTS/oom.php" >"$TMP/oom.out" 2>"$TMP/oom.err"
rc=$?
set -e
cat "$TMP/oom.out" "$TMP/oom.err"
[ "$rc" -eq 1 ] || fail "expected exit 1 on memory_limit, got $rc"
grep -q 'Allowed memory size of' "$TMP/oom.err" || fail "OOM message missing"
! grep -q 'shutdown ran' "$TMP/oom.out" || fail "shutdown function ran after OOM"

echo "== php -S: multipart body parts limit and duplicate part headers"
mkdir -p "$TMP/docroot"
cp "$TESTS/post.php" "$TMP/docroot/post.php"
"$PHP" -n -d max_multipart_body_parts=3 -d display_errors=0 -d log_errors=1 -d error_log="$TMP/server.log" \
    -S 127.0.0.1:$PORT -t "$TMP/docroot" >"$TMP/server.out" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
    curl -s -o /dev/null http://127.0.0.1:$PORT/ && break
    sleep 0.2
done
out=$(curl -fsS -H 'Content-Type: multipart/form-data; boundary=sealboundary' \
    --data-binary @"$TESTS/multipart-body.bin" http://127.0.0.1:$PORT/post.php)
kill $server
wait $server 2>/dev/null || true
echo "response: $out"
cat "$TMP/server.out" "$TMP/server.log" 2>/dev/null || true
[ "$out" = '{"post":["a","b"],"files":{"f":"text\/plain"}}' ] || fail "unexpected php -S response"
cat "$TMP/server.out" "$TMP/server.log" 2>/dev/null | grep -q 'Multipart body parts limit exceeded 3' \
    || fail "body parts warning missing"

echo "verify-bundle: OK"
