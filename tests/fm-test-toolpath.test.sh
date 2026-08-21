#!/usr/bin/env bash
# tests/fm-test-toolpath.test.sh - bounded per-user tool resolution installed
# by tests/lib.sh (fm_test_extend_tool_path) and the canonical optional-tool
# gate (fm_test_need_tool). Covers: a tool under $HOME/.npm-global/bin
# resolving in a minimal daemon-like PATH after sourcing lib.sh, the
# NPM_CONFIG_PREFIX bin dir taking part, append semantics never shadowing an
# existing PATH entry, absent tool dirs leaving PATH untouched, no duplicate
# append when the dir is already on PATH, and the need-tool gate returning the
# canonical `skip:` line that names the exact install command instead of
# inviting a filesystem hunt.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-toolpath)

# A daemon-like base PATH: system dirs only, no per-user npm prefix.
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

# in_clean_env <home> <path> [VAR=val ...] -- <bash -c script>
# Runs the script in a scrubbed environment so only the given HOME/PATH (plus
# any extra assignments) shape lib.sh's source-time PATH extension. Uses the
# same bash binary that runs this test.
in_clean_env() {
  local home=$1 path=$2
  shift 2
  local -a extra=()
  while [ "$1" != "--" ]; do
    extra+=("$1")
    shift
  done
  shift
  env -i HOME="$home" PATH="$path" ${extra[@]+"${extra[@]}"} "$BASH" -c "$1"
}

make_tool() {  # <dir> <name>
  mkdir -p "$1"
  printf '#!/bin/sh\necho %s\n' "$2" > "$1/$2"
  chmod +x "$1/$2"
}

# --- 1: a tool under $HOME/.npm-global/bin resolves in a minimal PATH --------

home1="$TMP_ROOT/home1"
make_tool "$home1/.npm-global/bin" faketool
resolved=$(in_clean_env "$home1" "$BASE_PATH" -- \
  ". '$ROOT/tests/lib.sh'; command -v faketool")
[ "$resolved" = "$home1/.npm-global/bin/faketool" ] \
  || fail "npm-global tool did not resolve under a minimal PATH (got '$resolved')"
pass "sourcing lib.sh makes \$HOME/.npm-global/bin tools resolvable in a daemon-like PATH"

# --- 2: NPM_CONFIG_PREFIX's bin dir takes part -------------------------------

prefix2="$TMP_ROOT/prefix2"
home2="$TMP_ROOT/home2"
mkdir -p "$home2"
make_tool "$prefix2/bin" prefixtool
resolved=$(in_clean_env "$home2" "$BASE_PATH" NPM_CONFIG_PREFIX="$prefix2" -- \
  ". '$ROOT/tests/lib.sh'; command -v prefixtool")
[ "$resolved" = "$prefix2/bin/prefixtool" ] \
  || fail "NPM_CONFIG_PREFIX/bin tool did not resolve (got '$resolved')"
pass "an explicit NPM_CONFIG_PREFIX bin dir is also resolvable"

# --- 3: append semantics never shadow an existing PATH entry -----------------

home3="$TMP_ROOT/home3"
sysbin3="$TMP_ROOT/sysbin3"
make_tool "$home3/.npm-global/bin" sharedtool
make_tool "$sysbin3" sharedtool
resolved=$(in_clean_env "$home3" "$BASE_PATH:$sysbin3" -- \
  ". '$ROOT/tests/lib.sh'; command -v sharedtool")
[ "$resolved" = "$sysbin3/sharedtool" ] \
  || fail "per-user tool dir shadowed an existing PATH entry (got '$resolved')"
pass "the per-user tool dir is appended, never shadowing existing PATH entries"

# --- 4: absent tool dirs leave PATH untouched --------------------------------

home4="$TMP_ROOT/home4"
mkdir -p "$home4"
after=$(in_clean_env "$home4" "$BASE_PATH" -- \
  ". '$ROOT/tests/lib.sh'; printf %s \"\$PATH\"")
[ "$after" = "$BASE_PATH" ] \
  || fail "PATH changed although no per-user tool dir exists (got '$after')"
pass "a home without per-user tool dirs leaves PATH untouched"

# --- 5: an already-listed tool dir is not appended twice ---------------------

home5="$TMP_ROOT/home5"
make_tool "$home5/.npm-global/bin" oncetool
after=$(in_clean_env "$home5" "$BASE_PATH:$home5/.npm-global/bin" -- \
  ". '$ROOT/tests/lib.sh'; printf %s \"\$PATH\"")
[ "$after" = "$BASE_PATH:$home5/.npm-global/bin" ] \
  || fail "an already-listed tool dir was appended again (got '$after')"
pass "a tool dir already on PATH is not duplicated"

# --- 6: fm_test_need_tool passes silently for a resolvable tool --------------

out=$(fm_test_need_tool bash) || fail "fm_test_need_tool failed for a present tool"
[ -z "$out" ] || fail "fm_test_need_tool printed output for a present tool: '$out'"
pass "fm_test_need_tool is silent and successful for a present tool"

# --- 7: the absent-tool gate emits the canonical install-or-skip line --------

rc=0
out=$(fm_test_need_tool fm-no-such-tool-xyz fm-no-such-package) || rc=$?
expect_code 1 "$rc" "fm_test_need_tool on an absent tool"
case "$out" in
  "skip: fm-no-such-tool-xyz not found"*) : ;;
  *) fail "absent-tool gate did not start with the canonical skip line: '$out'" ;;
esac
assert_contains "$out" 'npm install -g fm-no-such-package' \
  "absent-tool gate must name the exact install command"
assert_contains "$out" 'never search the filesystem' \
  "absent-tool gate must forbid filesystem hunts"
pass "an absent tool yields the canonical skip line with the install command"
