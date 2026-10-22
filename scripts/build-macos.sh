#!/bin/bash
# Builds the sealed PHP 5.6.40+sp1 CLI for macOS (arm64 or x86_64, whichever the runner is) as a
# self-contained bundle: bin/php plus every non-system dylib it needs under lib/, rewritten to
# @executable_path/../lib. Extension set follows the shivammathur/php php@5.6 Homebrew formula
# (minus apache2handler, fpm and phpdbg, which are not CLI), built from the pristine php.net tarball.
set -euo pipefail

VERSION=5.6.40
SEAL_VERSION=5.6.40+sp1
TARBALL_URL=https://www.php.net/distributions/php-$VERSION.tar.xz
TARBALL_SHA256=1369a51eee3995d7fbd1c5342e5cc917760e276d561595b6052b21ace2656d1c
# PHP 5.6 only builds against OpenSSL 1.0.x; 1.0.2u is the last 1.0.2 release.
OPENSSL_VERSION=1.0.2u
OPENSSL_URL=https://www.openssl.org/source/old/1.0.2/openssl-$OPENSSL_VERSION.tar.gz
OPENSSL_SHA256=ecd0c6ffb493dd06707d38b14bb4d8c2288bb7033735606569d8f90f89669d16

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
ARCH=$(uname -m)
WORKDIR=$REPO_DIR/work
CODE_DIR=$WORKDIR/php-$VERSION
OPENSSL_PREFIX=$WORKDIR/openssl
PREFIX=/opt/seal/php-$SEAL_VERSION
INSTALL_ROOT=$WORKDIR/install
BUNDLE_NAME=php-$SEAL_VERSION-macos-$ARCH
BUNDLE_DIR=$WORKDIR/$BUNDLE_NAME
OUT_DIR=$REPO_DIR/out
JOBS=$(sysctl -n hw.ncpu)

export MACOSX_DEPLOYMENT_TARGET=15.0

function setup() {
    brew install autoconf bison re2c pkgconf dylibbundler \
        freetype jpeg libpng gmp icu4c@78 gettext tidy-html5 aspell freetds unixodbc libpq
    mkdir -p "$WORKDIR" "$OUT_DIR"
}

function brew_prefix() {
    brew --prefix "$1"
}

function build_openssl() {
    pushd "$WORKDIR"
    curl -fsSL -o openssl.tar.gz "$OPENSSL_URL"
    echo "$OPENSSL_SHA256  openssl.tar.gz" | shasum -a 256 -c -
    tar -xzf openssl.tar.gz
    cd openssl-$OPENSSL_VERSION
    local target=darwin64-x86_64-cc
    if [ "$ARCH" = arm64 ]; then
        # 1.0.2 predates Apple Silicon: add the darwin64-arm64-cc target (no assembler) next to x86_64.
        perl -0pi -e 's/("darwin64-x86_64-cc".*\n)/$1"darwin64-arm64-cc","cc:-arch arm64 -O3 -DL_ENDIAN -Wall::-D_REENTRANT:MACOSX:-Wl,-search_paths_first%:SIXTY_FOUR_BIT_LONG RC4_CHAR RC4_CHUNK DES_INT DES_UNROLL BF_PTR:\\\${no_asm}:dlfcn:darwin-shared:-fPIC -fno-common:-arch arm64 -dynamiclib:.\\\$(SHLIB_MAJOR).\\\$(SHLIB_MINOR).dylib",\n/' Configure
        target=darwin64-arm64-cc
    fi
    # Static, so the bundle carries no libssl dylib; /private/etc/ssl/cert.pem is the macOS CA bundle.
    ./Configure $target no-shared no-ssl2 no-ssl3 --prefix="$OPENSSL_PREFIX" --openssldir=/private/etc/ssl
    make depend
    make -j"$JOBS"
    make install_sw
    popd
}

function extract_source() {
    pushd "$WORKDIR"
    curl -fsSL -o php-$VERSION.tar.xz "$TARBALL_URL"
    echo "$TARBALL_SHA256  php-$VERSION.tar.xz" | shasum -a 256 -c -
    rm -rf "$CODE_DIR"
    tar -xJf php-$VERSION.tar.xz
    popd
}

function apply_patches() {
    pushd "$CODE_DIR"
    patch -p1 --fuzz=0 < "$REPO_DIR/patches/CVE-2026-109618+CVE-2026-109619.patch"
    patch -p1 --fuzz=0 < "$REPO_DIR/patches/build/macos-sdk-paths-and-ex-tmp-var.patch"
    popd
}

function build() {
    pushd "$CODE_DIR"
    local sdk
    sdk=$(xcrun --show-sdk-path)
    export PATH="$(brew_prefix bison)/bin:$PATH"
    # Same compiler workarounds as the Homebrew formula (Xcode 12+ / 15.3+, ICU 61+ / 75+).
    export CFLAGS="-O2 -Wno-implicit-function-declaration -Wno-incompatible-function-pointer-types -Wno-implicit-int -Wno-int-conversion -std=gnu99 -DU_DEFINE_FALSE_AND_TRUE=1"
    export CXXFLAGS="-O2 -DU_DEFINE_FALSE_AND_TRUE=1"
    export CPPFLAGS="-DU_USING_ICU_NAMESPACE=1"
    export CXX="clang++ -std=c++17"
    export lt_cv_path_SED=sed
    # acinclude.m4 is patched, so configure has to be regenerated.
    ./buildconf --force
    ./configure \
        --prefix="$PREFIX" \
        --with-config-file-path="$PREFIX/etc" \
        --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
        --without-pear \
        --enable-bcmath --enable-calendar --enable-dba --enable-exif --enable-ftp --enable-intl \
        --enable-mbregex --enable-mbstring --enable-mysqlnd --enable-opcache --enable-pcntl \
        --enable-shmop --enable-soap --enable-sockets --enable-sysvmsg --enable-sysvsem \
        --enable-sysvshm --enable-wddx --enable-zip \
        --with-bz2="$sdk/usr" \
        --with-curl="$sdk/usr" \
        --with-freetype-dir="$(brew_prefix freetype)" \
        --with-gd \
        --with-gettext="$(brew_prefix gettext)" \
        --with-gmp="$(brew_prefix gmp)" \
        --with-iconv="$sdk/usr" \
        --with-icu-dir="$(brew_prefix icu4c@78)" \
        --with-jpeg-dir="$(brew_prefix jpeg)" \
        --with-png-dir="$(brew_prefix libpng)" \
        --with-ldap="$sdk/usr" \
        --with-ldap-sasl="$sdk/usr" \
        --with-libedit="$sdk/usr" \
        --with-libxml-dir="$sdk/usr" \
        --with-mhash \
        --with-mysql-sock=/tmp/mysql.sock \
        --with-mysql=mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
        --with-openssl="$OPENSSL_PREFIX" \
        --with-pdo-dblib="$(brew_prefix freetds)" \
        --with-pdo-odbc=unixODBC,"$(brew_prefix unixodbc)" \
        --with-unixODBC="$(brew_prefix unixodbc)" \
        --with-pdo-pgsql="$(brew_prefix libpq)" \
        --with-pgsql="$(brew_prefix libpq)" \
        --with-pdo-sqlite \
        --with-sqlite3 \
        --with-pspell="$(brew_prefix aspell)" \
        --with-tidy="$(brew_prefix tidy-html5)" \
        --with-xmlrpc \
        --with-xsl="$sdk/usr" \
        --with-zlib="$sdk/usr" \
        --with-pic
    make -j"$JOBS"
    make install INSTALL_ROOT="$INSTALL_ROOT"
    popd
}

# Minimal CGI builds of the pristine and the sealed tree, only for running .phpt tests; never shipped.
function build_test_trees() {
    local name
    for name in pristine sealed; do
        local dir=$WORKDIR/test-$name
        rm -rf "$dir"
        mkdir -p "$dir"
        tar -xJf "$WORKDIR/php-$VERSION.tar.xz" -C "$dir"
        pushd "$dir/php-$VERSION"
        patch -p1 --fuzz=0 < "$REPO_DIR/patches/build/macos-sdk-paths-and-ex-tmp-var.patch"
        if [ $name = sealed ]; then
            patch -p1 --fuzz=0 < "$REPO_DIR/patches/CVE-2026-109618+CVE-2026-109619.patch"
        fi
        ./buildconf --force
        ./configure --disable-all --enable-session --enable-cgi --enable-cli
        make -j"$JOBS"
        popd
    done
}

function run_phpt() {
    local name=$1
    shift
    local dir=$WORKDIR/test-$name/php-$VERSION
    pushd "$dir"
    echo "== phpt: $name: $*"
    TEST_PHP_EXECUTABLE=$dir/sapi/cli/php TEST_PHP_CGI_EXECUTABLE=$dir/sapi/cgi/php-cgi NO_INTERACTION=1 \
        "$dir/sapi/cli/php" -n run-tests.php -n -q "$@" | tee "$WORKDIR/phpt-$name.log" || true
    grep -E '^(FAIL|SKIP)' "$WORKDIR/phpt-$name.log" | sed 's/ \[.*//' | sort > "$WORKDIR/phpt-$name.results" || true
    popd
}

function verify_source_tests() {
    run_phpt pristine ext/session/tests Zend/tests tests
    run_phpt sealed ext/session/tests Zend/tests tests
    echo "== phpt results only in sealed (new failures/skips):"
    comm -13 "$WORKDIR/phpt-pristine.results" "$WORKDIR/phpt-sealed.results" | tee "$OUT_DIR/phpt-sealed-only-$ARCH.txt"
    echo "== phpt results only in pristine (fixed by the seal):"
    comm -23 "$WORKDIR/phpt-pristine.results" "$WORKDIR/phpt-sealed.results" | tee "$OUT_DIR/phpt-pristine-only-$ARCH.txt"
    cp "$WORKDIR/phpt-pristine.log" "$OUT_DIR/phpt-pristine-$ARCH.log"
    cp "$WORKDIR/phpt-sealed.log" "$OUT_DIR/phpt-sealed-$ARCH.log"
}

function bundle() {
    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR/bin" "$BUNDLE_DIR/lib" "$BUNDLE_DIR/etc/conf.d"
    cp "$INSTALL_ROOT$PREFIX/bin/php" "$BUNDLE_DIR/bin/php"
    local ext_dir
    ext_dir=$(find "$INSTALL_ROOT$PREFIX/lib/php/extensions" -name 'no-debug-non-zts-*' -type d)
    mkdir -p "$BUNDLE_DIR/lib/php/extensions"
    cp -R "$ext_dir" "$BUNDLE_DIR/lib/php/extensions/"
    cp "$CODE_DIR/php.ini-development" "$CODE_DIR/php.ini-production" "$BUNDLE_DIR/etc/"
    cp "$CODE_DIR/LICENSE" "$BUNDLE_DIR/LICENSE"
    cp "$REPO_DIR/patches/CVE-2026-109618+CVE-2026-109619.patch" "$BUNDLE_DIR/"
    # Copy every Homebrew dylib (recursively) into lib/ and point the loader at it; re-signs ad hoc.
    dylibbundler -od -b -cd -ns \
        -x "$BUNDLE_DIR/bin/php" \
        $(find "$BUNDLE_DIR/lib/php/extensions" -name '*.so' -exec echo -x {} \;) \
        -d "$BUNDLE_DIR/lib/" -p @executable_path/../lib/
    find "$BUNDLE_DIR" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -exec codesign --force -s - {} \;
    echo "== linked libraries:"
    otool -L "$BUNDLE_DIR/bin/php"
    if otool -L "$BUNDLE_DIR/bin/php" "$BUNDLE_DIR"/lib/*.dylib | grep -E '/(opt/homebrew|usr/local)/'; then
        echo "bundle still references Homebrew paths" >&2
        exit 1
    fi
    tar -C "$WORKDIR" -czf "$OUT_DIR/$BUNDLE_NAME.tar.gz" "$BUNDLE_NAME"
    shasum -a 256 "$OUT_DIR/$BUNDLE_NAME.tar.gz" | tee "$OUT_DIR/$BUNDLE_NAME.tar.gz.sha256"
}

function main() {
    setup
    build_openssl
    extract_source
    apply_patches
    build
    bundle
    "$REPO_DIR/scripts/verify-bundle.sh" "$BUNDLE_DIR/bin/php"
    build_test_trees
    verify_source_tests
}

main "$@"
