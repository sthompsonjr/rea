#!/usr/bin/env bash
# Install REA, its deep-analysis providers, and the Claude Code integration.
#
# Installs (Linux x86_64/arm64):
#   - JDK 21+ (system package, only when no JDK 21+ is found)
#   - procps (system package, only when `ps` is missing)
#   - rea-agents (npm, into a private prefix; no global npm writes)
#   - Ghidra 12.1.4 (official release zip, SHA-256 verified)
#   - jadx-headless-mcp 0.7.1 JAR (SHA-256 verified)
#   - Kuna 1.990 (SHA-256 verified)
#   - Hopper demo, through `rea setup --install-hopper` (x86_64, supported distros)
# Then registers REA with the selected agent and runs `rea doctor`.
#
# IDA Pro and JEB are commercial and license-bound; they are reported, not installed.
#
# Usage: install-rea.sh [--plan | --yes] [options]
#   --plan             Print the planned changes and exit (default)
#   --yes              Apply the plan
#   --no-hopper        Skip the Hopper demo
#   --no-ghidra | --no-jadx | --no-kuna   Skip that provider
#   --prefix DIR       Install directory (default: ~/.local/share/rea-tools)
#   --client NAME      rea setup client (default: claude_code); repeatable
#   --rea-version V    rea-agents version (default: latest)
set -euo pipefail

MODE=plan
PREFIX="${REA_TOOLS_PREFIX:-$HOME/.local/share/rea-tools}"
REA_VERSION=latest
CLIENTS=()
WANT_HOPPER=1 WANT_GHIDRA=1 WANT_JADX=1 WANT_KUNA=1

while [ $# -gt 0 ]; do
  case "$1" in
    --plan|--dry-run) MODE=plan ;;
    --yes|-y) MODE=apply ;;
    --no-hopper) WANT_HOPPER=0 ;;
    --no-ghidra) WANT_GHIDRA=0 ;;
    --no-jadx) WANT_JADX=0 ;;
    --no-kuna) WANT_KUNA=0 ;;
    --prefix) PREFIX="$2"; shift ;;
    --client) CLIENTS+=("$2"); shift ;;
    --rea-version) REA_VERSION="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ ${#CLIENTS[@]} -eq 0 ] && CLIENTS=(claude_code)
case "$PREFIX" in /*) ;; *) echo "--prefix must be absolute" >&2; exit 2 ;; esac

# ---- Pinned releases --------------------------------------------------------
GHIDRA_VER=12.1.4
GHIDRA_ZIP=ghidra_12.1.4_PUBLIC_20260921.zip
GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/$GHIDRA_ZIP
GHIDRA_SHA=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
GHIDRA_DIR=$PREFIX/ghidra_${GHIDRA_VER}_PUBLIC

JADX_JAR=jadx-headless-mcp-0.7.1-all.jar
JADX_URL=https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/$JADX_JAR
JADX_SHA=6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75
JADX_PATH=$PREFIX/jadx/$JADX_JAR

KUNA_VER=1.990
KUNA_DIR=$PREFIX/kuna-$KUNA_VER

REA_DIR=$PREFIX/rea
REA_BIN=$REA_DIR/node_modules/.bin/rea
ENV_FILE=$PREFIX/rea-env.sh
MARK_BEGIN="# >>> rea-tools >>>"
MARK_END="# <<< rea-tools <<<"

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- Host checks ------------------------------------------------------------
[ "$(uname -s)" = Linux ] || die "this installer supports Linux only (found $(uname -s))"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KUNA_TGZ=kuna-v1.990-linux-x86_64.tar.gz
          KUNA_SHA=4860603084da39dcdebeb9155116a886f8294003af54cecdb6a687529f0b5f54 ;;
  aarch64|arm64) KUNA_TGZ=kuna-v1.990-linux-arm64.tar.gz
          KUNA_SHA=8492ccd011c51aeac670435ab00ac3166400ad65f41b0198b6d9689ef2c147b9
          # Hopper ships x86_64 Linux packages only; official Ghidra zips may lack
          # the linux_arm_64 decompiler (rea doctor will report it).
          WANT_HOPPER=0 ;;
  *) die "unsupported architecture: $ARCH" ;;
esac
KUNA_URL=https://github.com/Noelo-Lab/kuna/releases/download/v$KUNA_VER/$KUNA_TGZ

if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif command -v sudo >/dev/null; then SUDO="sudo"; else SUDO=none; fi
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v pacman >/dev/null; then PKG=pacman
else PKG=none; fi

pkg_install() { # $1=apt name $2=dnf name $3=pacman name
  [ "$SUDO" = none ] && die "need root or sudo to install $1"
  case "$PKG" in
    apt) $SUDO apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade "$1" ;;
    dnf) $SUDO dnf install -y "$2" ;;
    pacman) $SUDO pacman -S --needed --noconfirm "$3" ;;
    *) die "no supported package manager to install $1" ;;
  esac
}

# Node.js must already satisfy rea-agents' engines (^22.23.4 || ^24.22.1 || >=26.12.1).
command -v node >/dev/null || die "Node.js is required (22.23.4+, 24.22.1+ or 26.12.1+); install it first"
command -v npm >/dev/null || die "npm is required"
node -e '
  const [a,b,c]=process.versions.node.split(".").map(Number), v=a*1e6+b*1e3+c;
  const ok=(a===22&&v>=22023004)||(a===24&&v>=24022001)||v>=26012001;
  process.exit(ok?0:1)' || die "Node.js $(node -v) is too old for rea-agents"
for t in curl unzip tar sha256sum; do command -v "$t" >/dev/null || die "missing required tool: $t"; done

jdk_home() { # prints JAVA_HOME of a full JDK >= 21, or nothing
  local cands=() j
  [ -n "${JAVA_HOME:-}" ] && cands+=("$JAVA_HOME")
  command -v javac >/dev/null && cands+=("$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")")
  for j in /usr/lib/jvm/*; do [ -d "$j" ] && cands+=("$j"); done
  for j in "${cands[@]}"; do
    [ -x "$j/bin/javac" ] && [ -x "$j/bin/java" ] || continue
    local major
    major=$("$j/bin/javac" -version 2>&1 | sed -n 's/^javac \([0-9]*\).*/\1/p' | head -1)
    [ -n "$major" ] && [ "$major" -ge 21 ] && { echo "$j"; return; }
  done
}

JDK=$(jdk_home || true)
HAVE_PS=1; command -v ps >/dev/null || HAVE_PS=0

# ---- Plan -------------------------------------------------------------------
plan_line() { printf '  %-8s %s\n' "$1" "$2"; }
echo "REA install plan (host: Linux $ARCH, prefix: $PREFIX)"
[ "$HAVE_PS" = 1 ] && plan_line keep "procps: ps already present" || plan_line install "procps via $PKG"
[ -n "$JDK" ] && plan_line keep "JDK 21+: $JDK" || plan_line install "OpenJDK 21 via $PKG"
plan_line install "rea-agents@$REA_VERSION into $REA_DIR (symlink ~/.local/bin/rea)"
if [ $WANT_GHIDRA = 1 ]; then
  [ -f "$GHIDRA_DIR/Ghidra/application.properties" ] && plan_line keep "Ghidra $GHIDRA_VER: $GHIDRA_DIR" \
    || plan_line install "Ghidra $GHIDRA_VER (~500 MB) -> $GHIDRA_DIR"
fi
if [ $WANT_JADX = 1 ]; then
  [ -f "$JADX_PATH" ] && plan_line keep "JADX MCP JAR: $JADX_PATH" || plan_line install "jadx-headless-mcp 0.7.1 -> $JADX_PATH"
fi
if [ $WANT_KUNA = 1 ]; then
  [ -x "$KUNA_DIR/kuna" ] && plan_line keep "Kuna: $KUNA_DIR/kuna" || plan_line install "Kuna $KUNA_VER -> $KUNA_DIR/kuna"
fi
plan_line write "$ENV_FILE (provider variables) and a marked source line in ~/.bashrc and ~/.profile (backed up first)"
plan_line run "rea setup --client ${CLIENTS[*]} --yes$([ $WANT_HOPPER = 1 ] && echo ' --install-hopper')"
[ $WANT_HOPPER = 1 ] && plan_line note "Hopper demo is commercial software with vendor limits; rea setup verifies and installs its official package"
plan_line skip "IDA Pro and JEB: commercial, bring-your-own (see docs/providers/ida-provider.md, docs/providers/jeb-analysis.md)"
plan_line run "rea doctor --skill to verify"

if [ "$MODE" = plan ]; then
  echo
  echo "Plan only; nothing was changed. Re-run with --yes to apply."
  exit 0
fi

# ---- Apply ------------------------------------------------------------------
mkdir -p "$PREFIX" "$HOME/.local/bin"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rea-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fetch() { # $1=url $2=sha256 $3=dest
  log "Downloading $(basename "$3")"
  curl -fL --retry 3 --retry-delay 2 -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --quiet - || { rm -f "$3.part"; die "SHA-256 mismatch for $1"; }
  mv "$3.part" "$3"
}

if [ "$HAVE_PS" = 0 ]; then log "Installing procps"; pkg_install procps procps-ng procps-ng; fi

if [ -z "$JDK" ]; then
  log "Installing OpenJDK 21"
  pkg_install openjdk-21-jdk-headless java-21-openjdk-devel jdk21-openjdk
  JDK=$(jdk_home) || true
  [ -n "$JDK" ] || die "JDK 21+ still not found after install"
fi
log "Using JDK $JDK"

log "Installing rea-agents@$REA_VERSION"
mkdir -p "$REA_DIR"
[ -f "$REA_DIR/package.json" ] || echo '{"private":true}' > "$REA_DIR/package.json"
npm install --prefix "$REA_DIR" --no-fund --no-audit "rea-agents@$REA_VERSION"
[ -x "$REA_BIN" ] || die "rea binary missing at $REA_BIN"
ln -sfn "$REA_BIN" "$HOME/.local/bin/rea"

if [ $WANT_GHIDRA = 1 ] && [ ! -f "$GHIDRA_DIR/Ghidra/application.properties" ]; then
  fetch "$GHIDRA_URL" "$GHIDRA_SHA" "$TMP/$GHIDRA_ZIP"
  log "Extracting Ghidra"
  rm -rf "$TMP/ghidra"; unzip -q "$TMP/$GHIDRA_ZIP" -d "$TMP/ghidra"
  src=$(find "$TMP/ghidra" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -f "$src/Ghidra/application.properties" ] || die "unexpected Ghidra archive layout"
  mv "$src" "$GHIDRA_DIR"
  rm -f "$TMP/$GHIDRA_ZIP"
fi

if [ $WANT_JADX = 1 ] && [ ! -f "$JADX_PATH" ]; then
  mkdir -p "$(dirname "$JADX_PATH")"
  fetch "$JADX_URL" "$JADX_SHA" "$JADX_PATH"
fi

if [ $WANT_KUNA = 1 ] && [ ! -x "$KUNA_DIR/kuna" ]; then
  fetch "$KUNA_URL" "$KUNA_SHA" "$TMP/$KUNA_TGZ"
  rm -rf "$TMP/kuna"; mkdir -p "$TMP/kuna"
  tar -xzf "$TMP/$KUNA_TGZ" -C "$TMP/kuna"
  bin=$(find "$TMP/kuna" -type f -name kuna | head -1)
  [ -n "$bin" ] || die "kuna executable not found in $KUNA_TGZ"
  mkdir -p "$KUNA_DIR"; install -m 0755 "$bin" "$KUNA_DIR/kuna"
fi

log "Writing $ENV_FILE"
{
  echo "# Generated by install-rea.sh; safe to re-generate."
  echo "export JAVA_HOME=\"$JDK\""
  [ $WANT_GHIDRA = 1 ] && echo "export GHIDRA_INSTALL_DIR=\"$GHIDRA_DIR\""
  [ $WANT_JADX = 1 ] && echo "export REA_JADX_MCP_JAR=\"$JADX_PATH\""
  [ $WANT_KUNA = 1 ] && echo "export REA_KUNA_COMMAND=\"$KUNA_DIR/kuna\""
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
} > "$ENV_FILE"

for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  if [ -f "$rc" ] && grep -qF "$MARK_BEGIN" "$rc"; then continue; fi
  [ -f "$rc" ] && cp -p "$rc" "$rc.rea-tools.backup"
  printf '\n%s\n[ -f "%s" ] && . "%s"\n%s\n' "$MARK_BEGIN" "$ENV_FILE" "$ENV_FILE" "$MARK_END" >> "$rc"
done

# shellcheck disable=SC1090
. "$ENV_FILE"

SETUP_ARGS=(setup --yes)
for c in "${CLIENTS[@]}"; do SETUP_ARGS+=(--client "$c"); done
[ $WANT_HOPPER = 1 ] && SETUP_ARGS+=(--install-hopper)
log "Running rea ${SETUP_ARGS[*]}"
set +e
"$REA_BIN" "${SETUP_ARGS[@]}" --format json > "$TMP/setup.json"
SETUP_RC=$?
set -e

log "Verifying with rea doctor"
DOCTOR_ARGS=(doctor --skill --format json)
for c in "${CLIENTS[@]}"; do DOCTOR_ARGS+=(--client "$c"); done
"$REA_BIN" "${DOCTOR_ARGS[@]}" > "$TMP/doctor.json" 2>/dev/null || true

node - "$TMP/setup.json" "$TMP/doctor.json" "$SETUP_RC" <<'EOF'
const fs = require("fs");
const read = p => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
const setup = read(process.argv[2]), doc = read(process.argv[3]);
console.log(`\nrea setup: ${setup?.status ?? "unreadable output"} (exit ${process.argv[4]})`);
for (const [k, v] of Object.entries(setup?.clients ?? {})) console.log(`  client ${k}: ${v.status}`);
const d = doc?.doctor ?? doc ?? {};
const insp = d.providerInspections ?? setup?.doctor?.providerInspections ?? [];
console.log("providers:");
for (const p of insp) {
  const bad = (p.checks ?? []).filter(c => !c.ok).map(c => c.detail).join("; ");
  console.log(`  ${p.id.padEnd(7)} ${p.available ? "available" : "unavailable"}${p.providerVersion ? " " + p.providerVersion : ""}${bad ? "  (" + bad + ")" : ""}`);
}
const id = d.identity ?? setup?.doctor?.identity;
if (id) {
  console.log(`skill: ${id.skill?.state}`);
  for (const r of id.registrations ?? []) console.log(`registration ${r.client}: ${r.state}`);
}
EOF

echo
echo "Done. Restart your agent so it loads the REA MCP server."
echo "For CLI use in this shell: . \"$ENV_FILE\""
