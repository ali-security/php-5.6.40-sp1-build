# php-5.6.40-sp1-build

CI build of Seal's sealed PHP 5.6.40+sp1 CLI for CVE-2026-109618 and CVE-2026-109619 ("php2shell"),
for macOS (Sequoia, Tahoe; arm64, x86_64) and Windows (x64, x86, NTS, VC11).

- `patches/CVE-2026-109618+CVE-2026-109619.patch`: Seal's 5.6 port of PHP's EOL minimal mitigation
  ([712e60f9](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2)), as
  shipped in `sealed-libraries` `APK/php5/5.6.38-r00`.
- `patches/build/`: macOS build-only fixes from the shivammathur/php `php@5.6` formula (SDK library
  paths, arm64-safe `EX_TMP_VAR`). Not security changes.
- `scripts/build-macos.sh`, `scripts/build-windows.ps1`: build from the pristine php.net tarball.
- `scripts/verify-bundle.{sh,ps1}`: checks run on every target runner.

Built bundles are attached to each workflow run and committed to
`seal-sec/sealed-libraries` under `Binary/php/5.6.40+sp1/`.
