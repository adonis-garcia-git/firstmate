#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, how one of several declared Claude accounts is chosen for a
# launch, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh, bin/fm-control.sh, and bin/fm-login-check.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# config/claude-account takes one of two forms. The single-line form is one
# unnamed pin, exactly as before. The named form declares one account per
# line as `<name> | <root> | <weight>`, with blank lines and `#` comments
# ignored; names and roots are unique and the weight is a positive number
# giving the account's relative capacity (for example 20 for a Max 20x plan
# and 6.25 for a Team Premium seat, each a multiple of Pro). A Claude launch
# selects its account in this order:
#   1. an explicit --account <name>, which must name a declared account;
#   2. on a relaunch, the named Claude account the task's own record names
#      (account= plus account_root=), while it is still declared by name, its
#      root is usable, it is signed in, and, when another account is
#      declared, quota-axi does not read it as exhausted_now on the 5-hour or
#      weekly window; an unreadable or stale reading keeps it. Otherwise one
#      notice names the account and why the worker moves off it, and
#      selection continues below. A recorded unnamed root and a Pi record
#      (account_provider=) are never kept, so with no file a relaunch takes
#      the ambient account and with a single-line pin the current pin;
#   3. the only declared account (either form);
#   4. among several declared accounts, the one with the most weighted
#      remaining quota: weight x quota-axi's all-models effectivePercentRemaining,
#      which is the lower of the 5-hour session and weekly windows. Each root
#      is read with its own CLAUDE_CONFIG_DIR (unset for ordinary) in the same
#      cleared environment as the sign-in check, so an ambient account cannot
#      answer for another. A stale reading (quota-axi could not refresh)
#      ranks by its last known windows. An unusable root, an unreadable
#      reading, and an exhausted account are skipped and named; a tie goes to
#      the account declared first; the best candidate that also passes the
#      sign-in check wins. When none qualifies the launch refuses and names
#      every account's reason rather than guessing; --account still selects
#      one explicitly.
# The quota read never prompts for Keychain access; an account quota-axi
# cannot read names quota-axi's own remedy under that account's root.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}
FM_WORKER_ACCOUNT_QUOTA_SECONDS=${FM_WORKER_ACCOUNT_QUOTA_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# For Pi prints "declared<TAB>providers", where declared is `ordinary` or the
# absolute path. For Claude prints one "name<TAB>declared<TAB>weight" line per
# declared account, in file order; the single-line form prints one line with
# an empty name and weight. The final newline is optional; any other control
# byte, including a CR, is malformed. Parses bytes before the shell can drop
# NULs or trailing newlines; paths are literal, never shell expressions.
# Returns 0 on success, 3 when the file does not exist, 4 when it cannot be
# inspected (one error already printed), 5 when it is not a readable regular
# file, 6 when it is malformed, and 7 when a named Claude line is malformed
# (one error naming the line already printed).
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      if ($body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n?\z/) {
        print "\t", $1, "\t\n";
        exit 0;
      }
      (my $text = $body) =~ s/\n\z//;
      my @lines = split /\n/, $text, -1;
      # The named form is chosen by its separator; anything else is refused
      # as a malformed single-line form.
      grep({ /\|/ && !/\A[ \t]*#/ } @lines) or exit 6;
      my (%names, %roots, @out);
      my $n = 0;
      for my $line (@lines) {
        $n++;
        next if $line =~ /\A[ \t]*(?:#[^\x00-\x08\x0a-\x1f\x7f]*)?\z/;
        unless ($line =~ /\A[ \t]*([A-Za-z0-9][A-Za-z0-9._-]*)[ \t]*\|[ \t]*(ordinary|\/[^\x00-\x1f\x7f|]*?)[ \t]*\|[ \t]*([0-9]+(?:\.[0-9]+)?)[ \t]*\z/) {
          print STDERR "error: config/claude-account line $n must read <name> | <root> | <weight>, where root is ordinary or an absolute path and weight is a positive number, with no control characters: $f\n";
          exit 7;
        }
        my ($name, $root, $weight) = ($1, $2, $3);
        if ($weight !~ /[1-9]/) {
          print STDERR "error: config/claude-account line $n gives account $name weight $weight; a weight must be greater than zero: $f\n";
          exit 7;
        }
        if ($names{$name}++) {
          print STDERR "error: config/claude-account line $n declares account $name a second time; account names must be unique: $f\n";
          exit 7;
        }
        if ($roots{$root}++) {
          print STDERR "error: config/claude-account line $n declares root $root a second time; each account needs its own root: $f\n";
          exit 7;
        }
        push @out, "$name\t$root\t$weight\n";
      }
      print @out;
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_declared <harness> <config-dir>
# Prints the home's parsed pin file (fm_worker_account_read's output) for a
# pinnable runner. Prints nothing and returns 0 when the runner is not
# pinnable or the home has no pin. On refusal prints one error naming the file
# and returns 1.
fm_worker_account_declared() {
  local harness=$1 config=$2 file cfg token rc
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  token=$(fm_worker_account_read "$harness" "$cfg")
  rc=$?
  case "$rc" in
  0) ;;
  3) return 0 ;;
  4 | 7) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or one absolute path on a single line, or one '<name> | <root> | <weight>' line per account, with no control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
  printf '%s\n' "$token"
}

# fm_worker_account_root <harness> <declared>
# Prints the directory a launch selects for a declared account: empty for the
# ordinary Claude account (CLAUDE_CONFIG_DIR unset), $HOME/.pi/agent for the
# ordinary Pi account, otherwise the declared path. Returns 1, printing the
# directory it could not use, when that is not a readable, searchable
# existing directory.
fm_worker_account_root() {
  local harness=$1 declared=$2 root=$2
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  printf '%s\n' "$root"
  [ -z "$root" ] || { [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ]; }
}

# fm_worker_account_resolve <pi|pi-signed> <config-dir>
# Prints "declared<TAB>root<TAB>providers" for a valid Pi pin. Prints nothing
# and returns 0 when the home has no pin. On refusal prints one error naming
# the file and returns 1. Claude accounts resolve through
# fm_worker_account_select, because a Claude file may declare several.
fm_worker_account_resolve() {
  local harness=$1 config=$2 token declared root
  token=$(fm_worker_account_declared "$harness" "$config") || return 1
  [ -n "$token" ] || return 0
  declared=${token%%$'\t'*}
  if ! root=$(fm_worker_account_root "$harness" "$declared"); then
    # shellcheck disable=SC2088  # The fallback is literal text for the refusal.
    echo "error: config/pi-account must name a readable, searchable existing directory (ordinary means ~/.pi/agent): $config/pi-account -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_clean_env
# Sets FM_WORKER_ACCOUNT_ENV to the `env -i` prefix every account probe runs
# under: only HOME, PATH, TMPDIR, USER, and LOGNAME survive, so a credential
# variable in the caller cannot answer for a root that has no login.
fm_worker_account_clean_env() {
  local name
  FM_WORKER_ACCOUNT_ENV=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || FM_WORKER_ACCOUNT_ENV+=("$name=${!name}")
  done
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict
  local -a clean
  fm_worker_account_clean_env
  clean=("${FM_WORKER_ACCOUNT_ENV[@]}")
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_claude_hint <root>
# Prints the command prefix that selects a Claude root: CLAUDE_CONFIG_DIR=<root>,
# or `env -u CLAUDE_CONFIG_DIR` for the ordinary account.
fm_worker_account_claude_hint() {
  if [ -n "$1" ]; then
    printf 'CLAUDE_CONFIG_DIR=%s\n' "$1"
  else
    printf '%s\n' 'env -u CLAUDE_CONFIG_DIR'
  fi
}

# fm_worker_account_claude_raw_guard <raw-command>
# Refuses a raw Claude launch command whose leading assignments set
# CLAUDE_CONFIG_DIR or a shed credential, because it runs after the selected
# root and shed credentials are applied and would override the account.
fm_worker_account_claude_raw_guard() {
  local word
  for word in $1; do
    case "$word" in
    [A-Za-z_]*=*)
      case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
      *" ${word%%=*} "*)
        echo "error: this Claude launch runs on a selected worker account, but the raw launch command sets ${word%%=*}, which would override that account; remove ${word%%=*} from the raw command, or change or remove config/claude-account" >&2
        return 1
        ;;
      esac
      ;;
    *) break ;;
    esac
  done
}

# fm_worker_account_claude_quota <root>
# Reads one Claude root's quota through quota-axi under the cleared probe
# environment plus that root (none for the ordinary account). Prints
# "known<TAB>percent<TAB>runway<TAB>session<TAB>weekly" for a readable
# reading, where percent is the all-models effectivePercentRemaining (the
# lower of the session and weekly windows) and session and weekly are the
# five_hour and seven_day windows' own remaining percentages (? when absent).
# When quota-axi could not refresh (state.stale, for example a rate-limited
# quota endpoint) but still holds both windows, prints
# "stale<TAB>percent<TAB>reason<TAB>session<TAB>weekly", where percent is the
# lower of the two stale windows. Otherwise prints
# "unreadable<TAB>reason<TAB>remedy", where remedy is quota-axi's own remedy
# command or empty.
fm_worker_account_claude_quota() {
  local root=$1 out rc
  fm_worker_account_clean_env
  [ -z "$root" ] || FM_WORKER_ACCOUNT_ENV+=("CLAUDE_CONFIG_DIR=$root")
  out=$(fm_run_timed "$FM_WORKER_ACCOUNT_QUOTA_SECONDS" "${FM_WORKER_ACCOUNT_ENV[@]}" \
    quota-axi --provider claude --json 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" = 124 ]; then
    printf 'unreadable\tquota-axi timed out after %ss\t\n' "$FM_WORKER_ACCOUNT_QUOTA_SECONDS"
    return 0
  fi
  if ! printf '%s\n' "$out" | fm_quota_json_valid; then
    printf 'unreadable\tquota-axi printed no valid quota snapshot (exit %s)\t\n' "$rc"
    return 0
  fi
  printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if $row == null then "unreadable\tquota-axi reported no claude row\t"
      else
        ([$row.quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")] | first) as $all
        | ([$row.windows[]? | select(.id == "five_hour") | .percentRemaining | numbers] | first) as $session
        | ([$row.windows[]? | select(.id == "seven_day") | .percentRemaining | numbers] | first) as $weekly
        | if $all != null and $all.status == "known" then
            "known\t\($all.effectivePercentRemaining)\t\($all.runway.status)\t\($session // "?")\t\($weekly // "?")"
          elif $row.state.stale == true and $session != null and $weekly != null then
            "stale\t\([$session, $weekly] | min)\t\($row.state.error // "stale reading")\t\($session)\t\($weekly)"
          else
            "unreadable\t\($row.state.error // $row.state.status // "no all-models reading")\t\($row.state.remedyCommand // "")"
          end
      end'
}

# fm_worker_account_claude_choose <executable> <declared-lines>
# Step 4 of the header's selection order, among two or more named accounts
# given as fm_worker_account_read lines. Prints "name<TAB>declared<TAB>root"
# for the chosen account, which has passed the sign-in check, and one notice
# on stderr naming every account's reading. A stale reading ranks by its last
# known windows, so a rate-limited quota endpoint does not refuse the spawn,
# and the notice marks it stale. When no account qualifies prints
# one error naming each account's reason and returns 1.
fm_worker_account_claude_choose() {
  local executable=$1 lines=$2 line name declared weight root reading kind pct runway session weekly
  local reason remedy score index=0 chosen='' notice
  local -a ranked=() readings=() skipped=()
  if ! command -v quota-axi >/dev/null 2>&1; then
    echo "error: config/claude-account declares several Claude accounts, and choosing among them needs quota-axi, which is not installed; install it, or pass --account <name> to choose one" >&2
    return 1
  fi
  while IFS= read -r line; do
    index=$((index + 1))
    name=${line%%$'\t'*}
    declared=${line#*$'\t'}
    weight=${declared#*$'\t'}
    declared=${declared%%$'\t'*}
    if ! root=$(fm_worker_account_root claude "$declared"); then
      skipped+=("$name: $root is not a readable, searchable existing directory")
      continue
    fi
    reading=$(fm_worker_account_claude_quota "$root")
    kind=${reading%%$'\t'*}
    if [ "$kind" != known ] && [ "$kind" != stale ]; then
      reason=${reading#*$'\t'}
      remedy=${reason#*$'\t'}
      reason=${reason%%$'\t'*}
      if [ -n "$remedy" ]; then
        skipped+=("$name: quota unreadable ($reason; remedy: $(fm_worker_account_claude_hint "$root") $remedy)")
      else
        skipped+=("$name: quota unreadable ($reason)")
      fi
      continue
    fi
    IFS=$'\t' read -r kind pct runway session weekly <<<"$reading"
    if [ "$runway" = exhausted_now ] ||
      ! score=$(LC_ALL=C awk -v w="$weight" -v p="$pct" 'BEGIN { s = w * p; printf "%.6f\t%g", s, s; exit !(s > 0) }'); then
      skipped+=("$name: out of quota (session $session%, week $weekly%)")
      continue
    fi
    if [ "$kind" = stale ]; then
      readings+=("$name $weight x $pct% = ${score#*$'\t'} (stale: $runway; session $session%, week $weekly%)")
    else
      readings+=("$name $weight x $pct% = ${score#*$'\t'} (session $session%, week $weekly%)")
    fi
    ranked+=("${score%%$'\t'*}"$'\t'"$index"$'\t'"$name"$'\t'"$declared"$'\t'"$root")
  done <<<"$lines"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=${line#*$'\t'}
    line=${line#*$'\t'}
    name=${line%%$'\t'*}
    declared=${line#*$'\t'}
    root=${declared#*$'\t'}
    declared=${declared%%$'\t'*}
    if fm_worker_account_check claude "$declared" "$root" "$executable" 2>/dev/null; then
      chosen=$name$'\t'$declared$'\t'$root
      break
    fi
    skipped+=("$name: not signed in (sign in with $(fm_worker_account_claude_hint "$root") claude, then /login)")
  done < <(printf '%s\n' "${ranked[@]+"${ranked[@]}"}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n)
  if [ -z "$chosen" ]; then
    reason=$(printf '%s; ' "${skipped[@]}")
    echo "error: config/claude-account declares several Claude accounts, but none can take this worker: ${reason%; }; fix the account named, or pass --account <name> to choose one explicitly" >&2
    return 1
  fi
  notice="notice: chose Claude account ${chosen%%$'\t'*} by weighted remaining quota (weight x the lower of its session and weekly remaining): $(printf '%s; ' "${readings[@]}")"
  notice=${notice%; }
  [ "${#skipped[@]}" -eq 0 ] || notice="$notice; skipped: $(printf '%s; ' "${skipped[@]}")"
  echo "${notice%; }" >&2
  printf '%s\n' "$chosen"
}

# fm_worker_account_claude_recorded_reason <executable> <declared-lines> <recorded-name>
# Step 2 of the header's selection order. Prints nothing when the recorded
# named account may keep the worker: it is still declared by name, its root is
# usable, it is signed in, and, when another account is declared, its quota
# reading is not exhausted_now. Otherwise prints why the worker moves off it.
# An unreadable or stale quota reading is not evidence of exhaustion.
fm_worker_account_claude_recorded_reason() {
  local executable=$1 lines=$2 rec=$3 line declared root reading kind pct runway session weekly
  line=$(printf '%s\n' "$lines" | awk -F '\t' -v n="$rec" '$1 != "" && $1 == n { print; exit }')
  if [ -z "$line" ]; then
    echo "is no longer declared by name in config/claude-account"
    return 0
  fi
  declared=${line#*$'\t'}
  declared=${declared%%$'\t'*}
  if ! root=$(fm_worker_account_root claude "$declared"); then
    echo "names $root, which is not a readable, searchable existing directory"
    return 0
  fi
  if ! fm_worker_account_check claude "$declared" "$root" "$executable" 2>/dev/null; then
    echo "is not signed in (claude auth status)"
    return 0
  fi
  [ "$(printf '%s\n' "$lines" | awk 'END { print NR }')" -gt 1 ] && command -v quota-axi >/dev/null 2>&1 || return 0
  reading=$(fm_worker_account_claude_quota "$root")
  [ "${reading%%$'\t'*}" = known ] || return 0
  IFS=$'\t' read -r kind pct runway session weekly <<<"$reading"
  LC_ALL=C awk -v r="$runway" -v p="$pct" -v s="$session" -v w="$weekly" 'BEGIN {
    if (r != "exhausted_now" && p + 0 > 0) exit
    if (w == "?" || (s != "?" && s + 0 <= w + 0)) win = "5-hour"
    else win = "weekly"
    printf "is exhausted_now on the %s window (session %s%%, week %s%%)\n", win, s, w
  }'
}

# fm_worker_account_select_claude <config-dir> <executable> <raw-command> <account> <recorded-account> <recorded-account-root> <recorded-account-provider>
# fm_worker_account_select's Claude branch; see that function and the header.
fm_worker_account_select_claude() {
  local config=$1 executable=$2 raw=$3 explicit=$4 rec_account=$5 rec_root=$6 rec_provider=$7
  local cfg="$config/claude-account" list line name declared root how label names reason
  list=$(fm_worker_account_declared claude "$config") || return 1
  if [ -n "$explicit" ]; then
    line=$(printf '%s\n' "$list" | awk -F '\t' -v n="$explicit" '$1 != "" && $1 == n { print; exit }')
    if [ -z "$line" ]; then
      names=$(printf '%s\n' "$list" | awk -F '\t' '$1 != "" { printf "%s%s", sep, $1; sep = ", " }')
      if [ -n "$names" ]; then
        echo "error: --account '$explicit' is not one of the Claude accounts config/claude-account declares ($names)" >&2
      else
        echo "error: --account '$explicit' names a Claude account, but config/claude-account declares none by name; drop --account, or declare each account as a '<name> | <root> | <weight>' line" >&2
      fi
      return 1
    fi
    how=explicit
  else
    if [ -n "$rec_account" ] && [ -n "$rec_root" ] && [ -z "$rec_provider" ]; then
      reason=$(fm_worker_account_claude_recorded_reason "$executable" "$list" "$rec_account")
      if [ -z "$reason" ]; then
        line=$(printf '%s\n' "$list" | awk -F '\t' -v n="$rec_account" '$1 == n { print; exit }')
        declared=${line#*$'\t'}
        declared=${declared%%$'\t'*}
        root=$(fm_worker_account_root claude "$declared")
        fm_worker_account_claude_raw_guard "$raw" || return 1
        printf '%s\t%s\t\t%s\trecorded\n' "$declared" "$root" "$rec_account"
        return 0
      fi
      echo "notice: moving this worker off its recorded Claude account $rec_account, which $reason" >&2
    fi
    if [ -z "$list" ]; then
      return 0
    elif [ "$(printf '%s\n' "$list" | awk 'END { print NR }')" -gt 1 ]; then
      fm_worker_account_claude_raw_guard "$raw" || return 1
      line=$(fm_worker_account_claude_choose "$executable" "$list") || return 1
      name=${line%%$'\t'*}
      declared=${line#*$'\t'}
      root=${declared#*$'\t'}
      declared=${declared%%$'\t'*}
      printf '%s\t%s\t\t%s\tquota\n' "$declared" "$root" "$name"
      return 0
    fi
    line=$list
    how=pin
  fi
  name=${line%%$'\t'*}
  declared=${line#*$'\t'}
  declared=${declared%%$'\t'*}
  label=$declared
  [ -z "$name" ] || label="$name ($declared)"
  fm_worker_account_claude_raw_guard "$raw" || return 1
  if ! root=$(fm_worker_account_root claude "$declared"); then
    if [ -n "$name" ]; then
      echo "error: config/claude-account account $name names $root, which is not a readable, searchable existing directory: $cfg" >&2
    else
      # shellcheck disable=SC2088  # The fallback is literal text for the refusal.
      echo "error: config/claude-account must name a readable, searchable existing directory (ordinary means ~/.claude with CLAUDE_CONFIG_DIR unset): $cfg -> $root" >&2
    fi
    return 1
  fi
  if [ "$how" = pin ]; then
    fm_worker_account_check claude "$declared" "$root" "$executable" || return 1
  elif ! fm_worker_account_check claude "$declared" "$root" "$executable" 2>/dev/null; then
    echo "error: --account '$name' selects Claude account $label, which is not signed in (claude auth status); sign in with $(fm_worker_account_claude_hint "$root") claude, then /login" >&2
    return 1
  fi
  printf '%s\t%s\t\t%s\t%s\n' "$declared" "$root" "$name" "$how"
}

# fm_worker_account_select <harness> <config-dir> <model> <executable> [<raw-command> [<account> [<recorded-account> <recorded-account-root> <recorded-account-provider>]]]
# The whole launch-time decision. Prints nothing for an unpinned launch, so
# the caller keeps today's launch unchanged. Otherwise prints
# "declared<TAB>root<TAB>provider<TAB>name<TAB>how" after the model guard and
# the sign-in check pass: provider is the Pi launch model's own (empty for
# Claude), name is the named Claude account (empty otherwise), and how is
# pin, explicit, recorded, or quota (the header's selection order). <account>
# is an explicit --account, which only a Claude launch accepts; the recorded
# fields are a relaunching task record's account=, account_root=, and
# account_provider= values. On refusal prints one error and returns 1.
# bin/fm-spawn.sh runs it before any endpoint exists, and bin/fm-control.sh
# before a relaunch stops the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 model=$3 executable=$4 raw=${5:-} explicit=${6:-} selection declared root providers provider=
  if [ -n "$explicit" ] && [ "$harness" != claude ]; then
    echo "error: --account '$explicit' chooses among the Claude accounts config/claude-account declares, so it applies only to a claude launch, not $harness" >&2
    return 1
  fi
  if [ "$harness" = claude ]; then
    fm_worker_account_select_claude "$config" "$executable" "$raw" "$explicit" "${7:-}" "${8:-}" "${9:-}"
    return
  fi
  selection=$(fm_worker_account_resolve "$harness" "$config") || return 1
  [ -n "$selection" ] || return 0
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ -n "$raw" ]; then
    echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
    return 1
  fi
  provider=$(fm_worker_account_pi_provider "$model") || {
    echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
    return 1
  }
  case " $providers " in
  *" $provider "*) ;;
  *)
    echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
    return 1
    ;;
  esac
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\t\tpin\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
