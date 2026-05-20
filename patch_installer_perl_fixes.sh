#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# patch_installer_perl_fixes.sh
# ────────────────────────────────────────────────────────────────────────────
#   Idempotent patch for main-installer.sh that fixes 3 bugs discovered
#   during the volfretail.ecdialers.com install (May 2026):
#
#   BUG 1 — perl-LWP-Protocol-https missing:
#     cpm fails silently to download anything over HTTPS without it.
#     Symptom: cron jobs spam "Can't locate DBD/mysql.pm" after install.
#
#   BUG 2 — MariaDB-devel not installed before cpm:
#     cpm/cpanm need mariadb_config (provided by MariaDB-devel) to compile
#     DBD::mysql. Without it, DBD::mysql build silently skips.
#     Default repos try to install mariadb-devel from CRB which conflicts
#     with MariaDB-common from the official repo. Need --allowerasing.
#
#   BUG 3 — cpm install -g doesn't fail loud:
#     If cpm fails to install DBD::mysql, the script keeps going and the
#     installation looks "complete" but Asterisk + cron jobs are broken.
#     Need a hard verification after cpm.
#
# Safe: idempotent, makes backup, runs php -l equivalent (bash -n) before
# committing, restores on failure.
# ════════════════════════════════════════════════════════════════════════════
set -uo pipefail

TARGET="${1:-/usr/src/ecdialers-install/main-installer.sh}"

if [ ! -f "$TARGET" ]; then
    echo "✗ ERROR: $TARGET not found"
    echo "  Usage: $0 [/path/to/main-installer.sh]"
    exit 1
fi

# Idempotency check
if grep -q "perl-LWP-Protocol-https" "$TARGET" && \
   grep -q "MariaDB-devel --allowerasing" "$TARGET" && \
   grep -q "verify DBD::mysql install" "$TARGET"; then
    echo "✓ Patch already applied — nothing to do"
    exit 0
fi

BACKUP="${TARGET}.bak.$(date +%Y%m%d_%H%M%S)"
cp -p "$TARGET" "$BACKUP"
echo "✓ Backup created: $BACKUP"

python3 - "$TARGET" << 'PY_EOF'
import sys, re

TARGET = sys.argv[1]
with open(TARGET, 'r') as f:
    content = f.read()

# ── FIX 1+2: Add perl-LWP-Protocol-https + MariaDB-devel before cpm ─────────
needle_1 = """hr; log "Installing Perl base modules via dnf"
# --exclude=mysql* evita que cualquier dep chain jale mysql-common
# que conflictua con MariaDB-common ya instalado
dnf install -y --exclude=mysql* \\
    perl-CPAN perl-YAML perl-CPAN-DistnameInfo perl-libwww-perl \\
    perl-GD perl-Env perl-Term-ReadLine-Gnu perl-SelfLoader perl-open"""

new_1 = """hr; log "Installing Perl base modules via dnf"
# --exclude=mysql* evita que cualquier dep chain jale mysql-common
# que conflictua con MariaDB-common ya instalado
dnf install -y --exclude=mysql* \\
    perl-CPAN perl-YAML perl-CPAN-DistnameInfo perl-libwww-perl \\
    perl-LWP-Protocol-https \\
    perl-GD perl-Env perl-Term-ReadLine-Gnu perl-SelfLoader perl-open \\
    perl-App-cpanminus perl-devel perl-ExtUtils-MakeMaker

# MariaDB-devel — required for DBD::mysql to find mariadb_config and link
# against the right connector library. Use --allowerasing because the
# CRB-provided mariadb-devel collides with MariaDB-common from the official
# MariaDB repo we installed earlier.
hr; log "Installing MariaDB-devel (provides mariadb_config for DBD::mysql)"
dnf install -y MariaDB-devel --allowerasing
which mariadb_config >/dev/null 2>&1 || die "mariadb_config still missing after MariaDB-devel install"
log "mariadb_config OK: $(mariadb_config --version)\""""

if needle_1 in content:
    content = content.replace(needle_1, new_1, 1)
    print("✓ Patch 1+2 applied (perl-LWP-Protocol-https + MariaDB-devel)")
else:
    print("✗ Patch 1+2 needle not found — installer may have been modified")
    sys.exit(2)

# ── FIX 3: Hard verification after cpm install ──────────────────────────────
needle_2 = """hr; log "Installing Perl CPAN modules via CPM (includes DBD::MySQL)"
# CPM instala DBD::MySQL sin depender de mysql-common del sistema
curl -fsSL https://raw.githubusercontent.com/skaji/cpm/main/cpm | perl - install -g App::cpm
cd "${INSTALLER_DIR}" && /usr/local/bin/cpm install -g"""

new_2 = """hr; log "Installing Perl CPAN modules via CPM (includes DBD::MySQL)"
# CPM instala DBD::MySQL sin depender de mysql-common del sistema
curl -fsSL https://raw.githubusercontent.com/skaji/cpm/main/cpm | perl - install -g App::cpm
cd "${INSTALLER_DIR}" && /usr/local/bin/cpm install -g

# verify DBD::mysql install — fail loud if it didn't take
hr; log "Verifying DBD::mysql installation"
DBD_VER=$(perl -MDBD::mysql -e 'print $DBD::mysql::VERSION' 2>/dev/null || echo "")
if [ -z "$DBD_VER" ]; then
    warn "cpm did not install DBD::mysql -- attempting cpanm fallback"
    cpanm --notest DBD::mysql@4.050 2>&1 | tail -20
    DBD_VER=$(perl -MDBD::mysql -e 'print $DBD::mysql::VERSION' 2>/dev/null || echo "")
fi
[ -n "$DBD_VER" ] || die "DBD::mysql install failed — VICIdial cron jobs will not work"
log "DBD::mysql VERSION: $DBD_VER (expected: 4.050)"

# verify DB connectivity through Perl-DBI before continuing
perl -e '
use DBI;
my $dbh = DBI->connect("DBI:mysql:database=mysql;host=localhost", "root", "")
    or die "DBI->connect failed: $DBI::errstr";
my ($v) = $dbh->selectrow_array("SELECT VERSION()");
print "Perl-DBI -> MariaDB OK ($v)\\n";
$dbh->disconnect;
' || die "Perl-DBI cannot connect to MariaDB — check MariaDB-devel and DBD::mysql"
"""

if needle_2 in content:
    content = content.replace(needle_2, new_2, 1)
    print("✓ Patch 3 applied (hard verification after cpm)")
else:
    print("✗ Patch 3 needle not found")
    sys.exit(3)

with open(TARGET, 'w') as f:
    f.write(content)

print("✓ All patches written")
PY_EOF

RC=$?
if [ "$RC" -ne 0 ]; then
    echo "✗ Python patcher failed (rc=$RC) — restoring backup"
    cp -p "$BACKUP" "$TARGET"
    exit "$RC"
fi

# Bash syntax check
echo ""
echo "── Bash syntax check ──"
if bash -n "$TARGET"; then
    echo "✓ Bash syntax OK"
else
    echo "✗ Bash syntax broken — restoring backup"
    cp -p "$BACKUP" "$TARGET"
    exit 4
fi

chmod 755 "$TARGET"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  ✅ main-installer.sh patched successfully"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Backup:        $BACKUP"
echo "  Target:        $TARGET"
echo "  Diff summary:"
diff "$BACKUP" "$TARGET" | head -50
echo ""
echo "  Revert with:   cp $BACKUP $TARGET"
echo ""
