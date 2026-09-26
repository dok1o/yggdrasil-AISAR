#!/usr/bin/env bash
#
# Provision a user-space Erlang/OTP + Elixir toolchain. No root required.
#
# Installs precompiled builds from builds.hex.pm (the same source erlef/setup-beam
# uses in CI) into $BEAM_PREFIX, defaulting to ~/.local/beam.
#
# Usage:
#   ./scripts/install-toolchain.sh                 # latest stable OTP + matching Elixir
#   OTP_VERSION=27.2 ELIXIR_VERSION=1.18.1 ./scripts/install-toolchain.sh
#   BEAM_PREFIX=/opt/beam ./scripts/install-toolchain.sh
#
# Then:
#   source ~/.local/beam/activate
#   elixir --version
#
# NOTE: this sandbox currently blocks builds.hex.pm (see docs/TOOLCHAIN.md).
# The script is written to succeed in any environment with normal egress.

set -euo pipefail

BEAM_PREFIX="${BEAM_PREFIX:-$HOME/.local/beam}"
# Debian 12 ships glibc 2.36; the ubuntu-22.04 builds (glibc 2.35) are compatible.
OTP_OS="${OTP_OS:-ubuntu-22.04}"
OTP_ARCH="${OTP_ARCH:-$(uname -m)}"
BASE="https://builds.hex.pm/builds"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need curl
need tar
need unzip

# --- preflight: is the build host reachable at all? -------------------------
if ! curl -sSf -o /dev/null --max-time 20 "$BASE/otp/$OTP_ARCH/$OTP_OS/builds.txt"; then
  die "cannot reach $BASE — network egress appears restricted.
     See docs/TOOLCHAIN.md for the reachability matrix measured in this sandbox.
     Provision the toolchain in an environment that permits builds.hex.pm,
     or install Erlang/Elixir via your distro package manager."
fi

mkdir -p "$BEAM_PREFIX" "$BEAM_PREFIX/.dl"

# --- resolve OTP version ----------------------------------------------------
if [ -z "${OTP_VERSION:-}" ]; then
  log "resolving latest stable OTP for $OTP_ARCH/$OTP_OS"
  OTP_VERSION="$(
    curl -sSf --max-time 30 "$BASE/otp/$OTP_ARCH/$OTP_OS/builds.txt" \
      | awk '{print $1}' \
      | grep -E '^OTP-[0-9]+\.[0-9]+(\.[0-9]+)?$' \
      | sed 's/^OTP-//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1
  )"
  [ -n "$OTP_VERSION" ] || die "could not resolve an OTP version from builds.txt"
fi
OTP_MAJOR="${OTP_VERSION%%.*}"
log "OTP version: $OTP_VERSION (major $OTP_MAJOR)"

# --- resolve Elixir version (must match the OTP major) ----------------------
if [ -z "${ELIXIR_VERSION:-}" ]; then
  log "resolving latest stable Elixir built against OTP $OTP_MAJOR"
  ELIXIR_REF="$(
    curl -sSf --max-time 30 "$BASE/elixir/builds.txt" \
      | awk '{print $1}' \
      | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+-otp-${OTP_MAJOR}$" \
      | sed 's/^v//;s/-otp-.*//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1
  )"
  [ -n "$ELIXIR_REF" ] || die "no Elixir build found for OTP $OTP_MAJOR"
  ELIXIR_VERSION="$ELIXIR_REF"
fi
log "Elixir version: $ELIXIR_VERSION (otp-$OTP_MAJOR)"

# --- install OTP ------------------------------------------------------------
OTP_DIR="$BEAM_PREFIX/otp-$OTP_VERSION"
if [ -x "$OTP_DIR/bin/erl" ]; then
  log "OTP $OTP_VERSION already installed, skipping"
else
  tarball="$BEAM_PREFIX/.dl/OTP-$OTP_VERSION.tar.gz"
  log "downloading OTP $OTP_VERSION"
  curl -sSfL --max-time 900 -o "$tarball" \
    "$BASE/otp/$OTP_ARCH/$OTP_OS/OTP-$OTP_VERSION.tar.gz"
  rm -rf "$OTP_DIR"; mkdir -p "$OTP_DIR"
  log "extracting OTP"
  tar -xzf "$tarball" -C "$OTP_DIR" --strip-components=1
  # Precompiled OTP embeds absolute build paths; Install rewrites them.
  if [ -x "$OTP_DIR/Install" ]; then
    log "running OTP Install (rewrites embedded paths)"
    (cd "$OTP_DIR" && ./Install -minimal "$OTP_DIR" >/dev/null)
  fi
  rm -f "$tarball"
fi
export PATH="$OTP_DIR/bin:$PATH"
"$OTP_DIR/bin/erl" -noshell -eval 'io:format("OTP ~s ok~n",[erlang:system_info(otp_release)]),halt().' \
  || die "OTP install is not runnable (missing shared libs?)"

# --- install Elixir ---------------------------------------------------------
ELIXIR_DIR="$BEAM_PREFIX/elixir-$ELIXIR_VERSION-otp-$OTP_MAJOR"
if [ -x "$ELIXIR_DIR/bin/elixir" ]; then
  log "Elixir $ELIXIR_VERSION already installed, skipping"
else
  zipfile="$BEAM_PREFIX/.dl/elixir-$ELIXIR_VERSION-otp-$OTP_MAJOR.zip"
  log "downloading Elixir $ELIXIR_VERSION"
  curl -sSfL --max-time 600 -o "$zipfile" \
    "$BASE/elixir/v$ELIXIR_VERSION-otp-$OTP_MAJOR.zip"
  rm -rf "$ELIXIR_DIR"; mkdir -p "$ELIXIR_DIR"
  log "extracting Elixir"
  unzip -qo "$zipfile" -d "$ELIXIR_DIR"
  chmod +x "$ELIXIR_DIR"/bin/*
  rm -f "$zipfile"
fi

# --- activation shim --------------------------------------------------------
cat > "$BEAM_PREFIX/activate" <<EOF
# shellcheck shell=sh
# source this file to put the pinned BEAM toolchain on PATH
export ERLANG_HOME="$OTP_DIR"
export PATH="$OTP_DIR/bin:$ELIXIR_DIR/bin:\$PATH"
# keep build caches inside the prefix so they don't pollute \$HOME
export MIX_HOME="$BEAM_PREFIX/.mix"
export HEX_HOME="$BEAM_PREFIX/.hex"
EOF

# shellcheck source=/dev/null
. "$BEAM_PREFIX/activate"

log "verifying"
erl -noshell -eval 'io:format("erl  : OTP ~s~n",[erlang:system_info(otp_release)]),halt().'
elixir --version | sed 's/^/elixir: /'

log "installing hex + rebar3 (local, non-interactive)"
mix local.hex --force --if-missing >/dev/null 2>&1 || warn "mix local.hex failed (hex.pm blocked?)"
mix local.rebar --force --if-missing >/dev/null 2>&1 || warn "mix local.rebar failed"

cat <<EOF

Done. Activate with:

    source $BEAM_PREFIX/activate

Installed under $BEAM_PREFIX (user-space, no root, not tracked by git).
EOF
