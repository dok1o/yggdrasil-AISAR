# Toolchain Provisioning

**Date measured:** 2026-09-26
**Status:** ❌ **Cannot provision Elixir/OTP in the current sandbox** — network egress is restricted.

---

## 1. Summary

The specification's implementer role (§66) targets Elixir. This environment has no BEAM
toolchain, and none can be installed, because every distribution channel for Erlang/OTP is
outside the sandbox's egress allowlist.

`scripts/install-toolchain.sh` is written and verified; it will provision a pinned,
user-space OTP + Elixir (no root) the moment it runs somewhere with normal egress.

---

## 2. Host state

| Property | Value |
|---|---|
| OS | Debian GNU/Linux 12 (bookworm) |
| Arch | `x86_64` |
| glibc | 2.36 |
| Disk free | ~20 G |
| Root / `sudo` | ❌ unavailable (no passwordless sudo) |

### Toolchain present

| Tool | Status |
|---|---|
| `python3` | ✅ `/usr/bin/python3` |
| `gcc`, `g++`, `make`, `perl`, `unzip`, `curl`, `tar` | ✅ present |
| `elixir`, `mix`, `erl` | ❌ absent |
| `autoconf`, `m4` | ❌ absent |
| ncurses headers (`ncurses.h` / `curses.h`) | ❌ absent |
| OpenSSL headers (`openssl/ssl.h`) | ❌ absent |
| zlib headers (`zlib.h`) | ❌ absent |

---

## 3. Network reachability matrix

Measured with `curl -s -o /dev/null -w '%{http_code}'`. `000` = connection failed.

| Host | Code | Reachable | Relevance |
|---|---|---|---|
| `github.com` | 200 | ✅ | git operations |
| `api.github.com` | 200 | ✅ | `gh` CLI metadata |
| `codeload.github.com` | 301 | ✅ | repo source tarballs |
| `pypi.org` | 200 | ✅ | Python packages |
| `files.pythonhosted.org` | 404¹ | ✅ | Python wheels |
| `release-assets.githubusercontent.com` | — | ❌ | **GitHub release binaries** |
| `objects.githubusercontent.com` | 000 | ❌ | **GitHub release binaries (legacy)** |
| `raw.githubusercontent.com` | 000 | ❌ | raw file fetch |
| `builds.hex.pm` | 000 | ❌ | **precompiled OTP + Elixir** |
| `repo.hex.pm` | 000 | ❌ | Hex package deps |
| `elixir-lang.org` | 000 | ❌ | Elixir distribution |
| `deb.debian.org` | 000 | ❌ | **apt packages** |
| `conda.anaconda.org` | 000 | ❌ | conda-forge `erlang` |
| `repo.anaconda.com` | 000 | ❌ | conda installer |
| `prefix.dev`, `micro.mamba.pm` | 000 | ❌ | micromamba |

¹ `404` on the bare root path is expected; the host itself resolves and serves.

---

## 4. Installation routes evaluated

Every standard route is blocked. Each was tested, not assumed.

| # | Route | Outcome |
|---|---|---|
| 1 | `apt-get install elixir` | ❌ `E: Unable to locate package elixir` — and `deb.debian.org` unreachable, so `apt update` cannot fix the index. No root regardless. |
| 2 | Precompiled OTP + Elixir from `builds.hex.pm` (the `erlef/setup-beam` source) | ❌ host unreachable. **This is the route `install-toolchain.sh` implements** — it is the correct one, just blocked here. |
| 3 | GitHub release assets (`gh release download elixir-lang/elixir`) | ❌ `api.github.com` resolves the asset, then the download redirects to `release-assets.githubusercontent.com`, which fails with `EOF`. |
| 4 | Build OTP from source via `codeload.github.com` tarball | ❌ the git tree needs `./otp_build autoconf` → **no `autoconf`, no `m4`**. Even past that, `crypto` needs OpenSSL headers and the shell needs ncurses — **both absent**, and uninstallable without apt. |
| 5 | conda-forge `erlang` / `elixir` via micromamba (user-space, no root) | ❌ all conda channels and the micromamba distribution hosts unreachable. |
| 6 | PyPI-hosted BEAM distribution | ❌ no such package exists. |

Route 4 deserves emphasis: even with unlimited build time, OTP's `crypto` application
cannot compile without OpenSSL development headers. Since `crypto` is exactly what this
project needs for prefix derivation and checksums (§17, §19), a source build would be
useless even if it completed.

---

## 5. `scripts/install-toolchain.sh`

Written, syntax-checked (`bash -n`), and executed end-to-end — it correctly detects the
blocked host and exits with an actionable diagnostic rather than a stack trace:

```
$ ./scripts/install-toolchain.sh
ERR cannot reach https://builds.hex.pm/builds — network egress appears restricted.
     See docs/TOOLCHAIN.md for the reachability matrix measured in this sandbox.
```

Design notes:

- **User-space.** Installs to `$BEAM_PREFIX` (default `~/.local/beam`). Never needs root.
- **Version discovery, not hardcoding.** Resolves the latest stable OTP from the
  per-arch/per-OS `builds.txt`, then picks the newest Elixir built against that OTP
  *major* — so the pair can never be mismatched. Both overridable via `OTP_VERSION` /
  `ELIXIR_VERSION`.
- **Runs OTP's `Install`** to rewrite the absolute paths baked into precompiled trees, a
  step that is easy to miss and produces confusing runtime failures when skipped.
- **glibc-aware.** Defaults to the `ubuntu-22.04` build (glibc 2.35) because it is
  forward-compatible with this host's glibc 2.36.
- **Idempotent.** Re-running skips anything already installed.
- **Emits `$BEAM_PREFIX/activate`** which sets `ERLANG_HOME`, `PATH`, and redirects
  `MIX_HOME`/`HEX_HOME` into the prefix to avoid polluting `$HOME`.
- **Not tracked by git.** The prefix lives outside the repo; only the script is committed.

To use once egress permits:

```sh
./scripts/install-toolchain.sh
source ~/.local/beam/activate
elixir --version
```

---

## 6. Knock-on effect: Hex dependencies

Note that `repo.hex.pm` is *also* blocked. Even with a working compiler, `mix deps.get`
would fail. An Elixir implementation of this spec plausibly needs at least a bencode
library for KRPC (§3) and an HTTP client for web scraping (§38–§39) — though both could be
written dependency-free if necessary (`:gen_udp`, `:httpc`, and `:crypto` are all in OTP).

**Recommendation:** whatever environment ends up hosting the implementation should
allowlist `builds.hex.pm` **and** `repo.hex.pm` together.

---

## 7. Impact on the spec pipeline

This is a **secondary** blocker. The primary one is the protocol spec gap
(see [`SPEC_FREEZE.md`](SPEC_FREEZE.md)): even with a perfect toolchain, §70 forbids
implementing the encoding layer until the binary unknowns are resolved.

The two blockers are independent and can be cleared in parallel:

| Blocker | Cleared by |
|---|---|
| Protocol spec gap (primary) | supplying `b_pf_new/`, a reference impl, or test vectors |
| No BEAM toolchain (secondary) | allowlisting `builds.hex.pm` + `repo.hex.pm`, then running `scripts/install-toolchain.sh` |
