#!/usr/bin/env bash
# Opt-in live guard for the Claude Code PreCompact handoff hook
# (bin/fm-precompact-handoff.sh).
#
# Four facts here come from the vendor, not from Firstmate, so a stub can only
# confirm the assumption already written into the stub:
#
#   (a) the tracked `.claude/settings.json` PreCompact entry runs the committed
#       hook, executable as checked out, before a manual `/compact` and before
#       an automatic compaction, and hands it the trigger, the transcript path,
#       and the /compact instructions;
#   (b) an interactive session's transcript marks the captain's typed turns
#       with `origin.kind` `human`, so the hook can quote them verbatim, and
#       marks a typed firstmate doorbell the same way, so the hook must drop it
#       (tests/fm-precompact-handoff.test.sh pins the parsing portably against
#       hand-built records of the same shape);
#   (c) the compaction still proceeds after the hook ran;
#   (d) the primary is the interactive TUI, and headless `claude -p` or
#       stream-json transcripts carry no `origin` field at all, so this guard
#       drives the real TUI through a pty rather than print mode.
#
# It builds a throwaway Firstmate-shaped lab outside the repo carrying the
# TRACKED Claude settings and the real hook copied with its committed mode, so a
# registration that stops firing or a hook that lost its executable bit fails
# here; the other tracked hook scripts get executable no-op stubs. Every
# inherited CLAUDE* variable is cleared first: a session launched from inside
# another Claude session inherits CLAUDE_CODE_CHILD_SESSION and saves no
# transcript. The lab's workspace-trust dialog is answered "Yes" for that
# throwaway path only.
# The automatic case lowers the auto-compact threshold for one session through
# Claude Code's CLAUDE_CODE_AUTO_COMPACT_WINDOW (floor 100000 tokens) and
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE; a lab session is too small for the summary
# itself to succeed, and the guard asserts only that the hook fired with the
# automatic trigger before it and quoted the captain's words.
#
# Run it after every Claude Code upgrade and before trusting refreshed evidence
# in docs/verification/supervision.md:
#
#   FM_PRECOMPACT_HANDOFF_LIVE_E2E=1 tests/fm-precompact-handoff-live-e2e.test.sh
#
# It costs a few small model turns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRECOMPACT_HANDOFF_LIVE_E2E claude jq python3 git

unset NO_MISTAKES_GATE FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE

LAB=$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)/fm-precompact-handoff-live-e2e.$$
DRIVER="$LAB/drive.py"
trap 'rm -rf "$LAB"' EXIT INT TERM
mkdir -p "$LAB"
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
MODEL=${FM_PRECOMPACT_HANDOFF_LIVE_MODEL:-haiku}
VERSION=$(claude --version 2>/dev/null | head -n 1)
note() { printf '# %s\n' "$1"; }
note "claude: ${VERSION:-unknown version}"

# The lab gets each script's working-tree content at its git index mode, never a
# chmod of its own, so a script that lost its executable bit in git fails here.
make_lab() {  # <dir>
  local lab=$1 script mode
  mkdir -p "$lab/bin" "$lab/state" "$lab/data" "$lab/.claude"
  git init -q -b main "$lab"
  printf '# Firstmate lab\n' > "$lab/AGENTS.md"
  cp "$ROOT/.claude/settings.json" "$lab/.claude/settings.json"
  for script in fm-precompact-handoff.sh fm-gate-refuse-lib.sh fm-primary-scope-lib.sh \
    fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh fm-timeout-lib.sh \
    fm-operational-input.sh; do
    cat "$ROOT/bin/$script" > "$lab/bin/$script"
    mode=$(git -C "$ROOT" ls-files -s "bin/$script" | cut -d' ' -f1)
    [ "$mode" != 100755 ] || chmod +x "$lab/bin/$script"
  done
  for script in fm-sessionstart-run.sh fm-turnend-guard.sh fm-claude-stop-autoarm.sh \
    fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh \
    fm-host-mirror.sh fm-tasks-axi.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/bin/$script"
    chmod +x "$lab/bin/$script"
  done
  git -C "$lab" add -A >/dev/null 2>&1
  git -C "$lab" -c user.email=fmtest@example.invalid -c user.name=fmtest commit -q -m init >/dev/null 2>&1 || true
}

field() {  # <lab> <key>
  sed -n "s/^$2=//p" "$1/state/.precompact-handoff" 2>/dev/null
}

# drive.py <lab> <script-file>: runs the interactive TUI in a pty and plays a
# script of lines, one step per line:
#   type <text>        type the text and press Enter
#   await-reply        wait until the transcript holds a new assistant reply
#   await-file <path>  wait until <path> exists
#   pause <seconds>
# It answers the workspace-trust dialog, exits the session at the end, and
# prints the transcript path it found. It fails with the screen tail on a
# timeout.
cat > "$DRIVER" <<'PY'
import glob, json, os, pty, re, select, signal, struct, sys, time, fcntl, termios

lab, script = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
env["TERM"] = "xterm-256color"
extra = os.environ.get("FM_LIVE_DRIVER_ENV", "")
for pair in extra.split():
    k, _, v = pair.partition("=")
    env[k] = v
model = os.environ.get("FM_LIVE_DRIVER_MODEL", "haiku")
ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>78]")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(lab)
    os.execvpe("claude", ["claude", "--model", model, "--tools", ""], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
buf = b""

def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                return

def screen():
    return ANSI.sub(b"", buf[-40000:]).decode("utf-8", "replace")

def die(msg):
    sys.stderr.write("drive: %s\n--- screen tail ---\n%s\n" % (msg, screen()[-3000:]))
    os.kill(pid, signal.SIGKILL)
    sys.exit(1)

def send(data, gap=0.0):
    # An escape sequence must arrive in one write, or the TUI reads a bare Esc.
    if gap == 0.0:
        os.write(fd, data.encode())
        return
    for ch in data:
        os.write(fd, ch.encode())
        time.sleep(gap)

def transcripts():
    # Claude Code names a project's transcript folder after its path with every
    # non-alphanumeric character replaced by a dash; match that folder exactly,
    # never a substring another lab's folder could share.
    folder = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(lab))
    return glob.glob(os.path.join(os.path.expanduser("~/.claude/projects"), folder, "*.jsonl"))

def replies():
    n = 0
    for p in transcripts():
        with open(p, errors="replace") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") == "assistant" and any(
                        isinstance(b, dict) and b.get("type") == "text"
                        for b in (e.get("message", {}).get("content") or [])):
                    n += 1
    return n

deadline = time.time() + 60
while time.time() < deadline:
    pump(1)
    s = screen().replace(" ", "")
    if "Itrustthisfolder" in s:
        send("\x1b[B")
        pump(0.5)
        send("\r")
        pump(3)
        break
    if "?forshortcuts" in s:
        break
pump(3)
seen = replies()
for raw in open(script):
    step, _, arg = raw.rstrip("\n").partition(" ")
    if step == "type":
        send(arg, 0.01)
        pump(1)
        send("\r")
        pump(2)
    elif step == "await-reply":
        end = time.time() + 180
        while replies() <= seen:
            if time.time() > end:
                die("no assistant reply arrived")
            pump(1)
        seen = replies()
        pump(2)
    elif step == "await-file":
        end = time.time() + 240
        while not os.path.exists(arg):
            if time.time() > end:
                die("never appeared: " + arg)
            pump(1)
        pump(5)
    elif step == "pause":
        pump(float(arg))
send("/exit")
pump(1)
send("\r")
pump(4)
try:
    os.kill(pid, signal.SIGKILL)
except OSError:
    pass
found = transcripts()
print(found[0] if found else "")
PY

# The doorbell names a record that does not exist, as an old pruned one would.
doorbell() {  # <lab>
  printf "%s%s/state/operational-inbox/1790000000-%s.msg%s" \
    ": Firstmate operational input waiting: read '" "$1" "$NONCE" \
    "' and handle its contents as Firstmate operational input."
}

# --- manual /compact -----------------------------------------------------------
MANUAL="$LAB/manual"
make_lab "$MANUAL"
PHRASE="Remember the manual codeword MANUAL-$NONCE and reply with just OK."
{
  printf 'type %s\n' "$PHRASE"
  printf 'await-reply\n'
  printf 'type %s\n' "$(doorbell "$MANUAL")"
  printf 'await-reply\n'
  printf 'type /compact keep ARG-%s\n' "$NONCE"
  printf 'await-file %s\n' "$MANUAL/state/.precompact-handoff"
  printf 'pause 20\n'
} > "$LAB/manual.steps"
DRIVE_RC=0
TRANSCRIPT=$(FM_LIVE_DRIVER_MODEL="$MODEL" python3 "$DRIVER" "$MANUAL" "$LAB/manual.steps") || DRIVE_RC=$?
[ -f "$MANUAL/state/.precompact-handoff" ] \
  || fail "claude $VERSION: the tracked PreCompact entry did not run the hook on /compact (is bin/fm-precompact-handoff.sh executable in git?)"
[ "$DRIVE_RC" -eq 0 ] || fail "claude $VERSION: the interactive manual session could not be driven"
[ "$(field "$MANUAL" status)" = ok ] \
  || fail "claude $VERSION: the manual handoff was not ok: $(cat "$MANUAL/state/.precompact-handoff")"
[ "$(field "$MANUAL" trigger)" = manual ] || fail "claude $VERSION: /compact did not report trigger=manual"
NOTE=$(cat "$MANUAL/data/session-handoff.md")
assert_contains "$NOTE" "> $PHRASE" "claude $VERSION: the captain's words were not quoted verbatim from the real transcript"
assert_contains "$NOTE" "> keep ARG-$NONCE" "claude $VERSION: the /compact instructions did not reach the hook"
assert_not_contains "$NOTE" "1790000000-$NONCE" "claude $VERSION: a typed firstmate doorbell was quoted as the captain's words"
jq -e --arg n "1790000000-$NONCE" 'select(.type == "user" and .origin.kind == "human")
  | (.message.content | if type == "string" then . else ([.[]? | .text? // empty] | join(" ")) end)
  | select(contains($n))' "$TRANSCRIPT" >/dev/null 2>&1 \
  || fail "claude $VERSION: the typed doorbell was not recorded as a human turn, so the exclusion went untested"
grep -q '"compact_boundary"' "$TRANSCRIPT" 2>/dev/null \
  || fail "claude $VERSION: the compaction did not proceed after the hook ran"
pass "claude $VERSION: interactive /compact runs the committed hook with trigger=manual, quotes the captain verbatim, drops a doorbell, and proceeds"

# --- automatic compaction ------------------------------------------------------
AUTO="$LAB/auto"
make_lab "$AUTO"
AUTO_PHRASE="Remember the automatic codeword AUTO-$NONCE and write two sentences about apples."
{
  printf 'type %s\n' "$AUTO_PHRASE"
  printf 'await-reply\n'
  printf 'type Write two sentences about pears.\n'
  printf 'await-file %s\n' "$AUTO/state/.precompact-handoff"
} > "$LAB/auto.steps"
DRIVE_RC=0
FM_LIVE_DRIVER_MODEL="$MODEL" \
  FM_LIVE_DRIVER_ENV="CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=5" \
  python3 "$DRIVER" "$AUTO" "$LAB/auto.steps" >/dev/null || DRIVE_RC=$?
[ -f "$AUTO/state/.precompact-handoff" ] \
  || fail "claude $VERSION: the tracked PreCompact entry did not run the hook before an automatic compaction"
[ "$DRIVE_RC" -eq 0 ] || fail "claude $VERSION: the interactive automatic-compaction session could not be driven"
[ "$(field "$AUTO" trigger)" = auto ] || fail "claude $VERSION: an automatic compaction did not report trigger=auto"
assert_contains "$(cat "$AUTO/data/session-handoff.md")" "> $AUTO_PHRASE" \
  "claude $VERSION: the automatic handoff did not quote the captain's words verbatim"
pass "claude $VERSION: an interactive automatic compaction runs the handoff first with trigger=auto and verbatim captain words"
