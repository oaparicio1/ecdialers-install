# Changelog

All notable changes to the ECdialers ViciDial installer.

## [Unreleased]

### Fixed — AlmaLinux 9 Perl / DBD::mysql install
*Discovered during volfretail.ecdialers.com deploy, May 2026.*

Three related bugs that caused silent installer failure: the installer would
report success, but VICIdial cron jobs spammed `Can't locate DBD/mysql.pm`
every minute and Asterisk would not auto-start cleanly.

- **`perl-LWP-Protocol-https` was missing** from the dnf install list. Without
  it, `cpm` cannot fetch anything over HTTPS from CPAN. Symptom: cpm reported
  "ok" but DBD::mysql was never actually downloaded.

- **`MariaDB-devel` was never installed.** DBD::mysql needs `mariadb_config`
  to detect headers and link against the right MariaDB connector library.
  Adding `MariaDB-devel` directly hits a conflict with CRB's
  `mariadb-devel` and `MariaDB-common`; fix is `--allowerasing`.

- **`cpm install -g` failed silently.** No verification after the cpm step,
  so the installer continued past the broken step. Added hard verification
  using `perl -MDBD::mysql -e 'print $DBD::mysql::VERSION'`, with `cpanm`
  fallback if cpm didn't take, and a Perl-DBI connectivity test before
  proceeding.

### Added
- `patch_installer_perl_fixes.sh` — idempotent patch script that applies
  the three fixes above to any existing copy of `main-installer.sh`.
  Useful for servers installed before this fix landed (the patcher includes
  a backup + bash syntax check + automatic rollback on failure).

