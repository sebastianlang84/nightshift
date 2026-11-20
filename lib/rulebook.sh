# shellcheck shell=bash
# The one Bash reader of the rulebook. `lib/parse_rulebook.py` validates the file; this loader turns
# the result into values addressed by NAME, so no caller knows an output position.
#
#   rulebook_load FILE   parse FILE; fill RB and RB_REPOS. Parser errors pass through on stderr and
#                        the status is non-zero, so each caller keeps its own fail-closed message.
#   RB[key]              every string of the parsed rulebook, keyed by its dotted path:
#                        RB[branch_prefix], RB[limits.max_open_branches], RB[agent.primary],
#                        RB[dimensions.0], RB[repos.2.test_cmd], RB[repos.2.protected_paths.0] …
#   RB_REPOS             the number of repos (`repos.0` … `repos.$((RB_REPOS-1))`)
#   rb_list VAR KEY      VAR=(RB[KEY.0] RB[KEY.1] …), for the rulebook's string lists
#
# Transport: `parse_rulebook.py --pairs` writes the pair count, then each key and value, every item
# terminated by a NUL byte, and `readarray -d ''` splits on exactly that byte. Bash strings cannot
# hold NUL, so it is the one delimiter no value can contain (the parser refuses a value that does);
# nothing is word-split, glob-expanded, unescaped or eval'd, and empty values stay empty.
# Reading a missing key under `set -u` aborts the caller, so a misspelled name cannot read as "".

rulebook_load() { # file
  local _rb_i _rb_n
  local -a _rb_kv
  declare -gA RB=()   # a failed load leaves nothing behind from an earlier one
  RB_REPOS=0
  # Process substitution hides the parser's exit status, so it travels as one more item at the end
  # (`|| _rb_rc=$?` because the subshell inherits a caller's errexit); the leading count catches
  # output that stops early.
  readarray -d '' -t _rb_kv < <(
    _rb_rc=0
    python3 "$NIGHTSHIFT_HOME/lib/parse_rulebook.py" --pairs "$1" || _rb_rc=$?
    printf 'rc=%d\0' "$_rb_rc"
  )
  [ "${#_rb_kv[@]}" -gt 0 ] && [ "${_rb_kv[${#_rb_kv[@]} - 1]}" = rc=0 ] || return 1
  unset '_rb_kv[${#_rb_kv[@]}-1]'
  _rb_n="${_rb_kv[0]:-}"
  if ! [[ "$_rb_n" =~ ^[0-9]+$ ]] || [ "${#_rb_kv[@]}" -ne $((2 * _rb_n + 1)) ]; then
    echo "rulebook: cannot read the parser's output for $1" >&2
    return 1
  fi
  for ((_rb_i = 1; _rb_i < ${#_rb_kv[@]}; _rb_i += 2)); do
    RB["${_rb_kv[_rb_i]}"]="${_rb_kv[_rb_i + 1]}"
  done
  while [ -n "${RB[repos.$RB_REPOS.path]+set}" ]; do RB_REPOS=$((RB_REPOS + 1)); done
}

rb_list() { # var key
  local -n _rb_out="$1"
  local _rb_i=0
  _rb_out=()
  while [ -n "${RB[$2.$_rb_i]+set}" ]; do
    _rb_out+=("${RB[$2.$_rb_i]}")
    _rb_i=$((_rb_i + 1))
  done
}
