#!/bin/bash
# shellcheck shell=bash
# lib-sql.sh: render conf/sql templates from shell scripts.
#
# Source this file, then:
#   sql_render <template> [NAME=VALUE ...]
#
# <template> is relative to conf/sql/ (or absolute). Requires REPO_ROOT.
#
# Template variable syntax (shared with sqlfluff via conf/sql/_macros.jinja):
#   {{NAME}}                  scalar; resolved from a NAME=VALUE argument,
#                             then SQL_<NAME> in the environment, then
#                             conf/sql/VARS.
#   {{time_filter('col')}}    grafana: $__timeFilter(col)  lint: predicate
#   {{gf_num('v')}}           grafana: ${v}                lint: 10
#   {{gf_str('v')}}           grafana: ${v:singlequote}    lint: 'sample'
#   {{gf_str_multi('v')}}     grafana: ${v:singlequote}    lint: 'sample'
#
# Rendering mode: SQL_RENDER_MODE=grafana emits Grafana $__/${} macros;
# anything else (default) emits lint/runtime-valid SQL. Rendering fails if
# any template variable cannot be resolved.

: "${REPO_ROOT:?lib-sql.sh requires REPO_ROOT}"

SQL_ROOT="${REPO_ROOT}/conf/sql"

# sql_render <template> [NAME=VALUE ...]
sql_render() {
	local tmpl="$1"; shift
	local file
	case "$tmpl" in
		/*) file="$tmpl" ;;
		*) file="${SQL_ROOT}/${tmpl}" ;;
	esac
	if [ ! -f "$file" ]; then
		printf '[sql] ERROR: no such template: %s\n' "$file" >&2
		return 1
	fi

	# NAME=VALUE args override; SQL_<NAME> env is picked up inside awk.
	local pairs="" kv name
	for kv in "$@"; do
		name="${kv%%=*}"
		[ -n "$name" ] || { printf '[sql] ERROR: bad override: %s\n' "$kv" >&2; return 2; }
		pairs="${pairs}${name}=${kv#*=}"$'\037'
	done

	local out
	if ! out="$(awk -v mode="${SQL_RENDER_MODE:-raw}" \
		-v pairs="$pairs" -v vfile="${SQL_ROOT}/VARS" '
		BEGIN {
			FS = "\037"
			# Precedence: NAME=VALUE args > SQL_<NAME> env > conf/sql/VARS.
			while ((getline ln < vfile) > 0) {
				if (ln ~ /^[[:space:]]*#/ || ln !~ /=/) continue
				pos = index(ln, "=")
				V[substr(ln, 1, pos-1)] = substr(ln, pos+1)
			}
			close(vfile)
			for (e in ENVIRON) {
				if (e ~ /^SQL_/) V[substr(e, 5)] = ENVIRON[e]
			}
			n = split(pairs, kv, "\037")
			for (i = 1; i <= n; i++) {
				pos = index(kv[i], "=")
				if (pos > 0) V[substr(kv[i], 1, pos-1)] = substr(kv[i], pos+1)
			}
		}
		function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
		function args_of(tok,   a) {
			sub(/^[^(]*\(/, "", tok)
			sub(/\)[ \t]*$/, "", tok)
			gsub(/[\047 \t]/, "", tok)
			return tok
		}
		{
			line = $0
			out = ""
			while ((i = index(line, "{{")) > 0) {
				rest = substr(line, i+2)
				j = index(rest, "}}")
				if (j == 0) break
				tok = trim(substr(rest, 1, j-1))
				pre = substr(line, 1, i-1)
				line = substr(rest, j+2)
				if (tok ~ /^gf_num\(/) {
					split(args_of(tok), p, ",")
					rep = (mode == "grafana") ? "${" p[1] "}" : "10"
				} else if (tok ~ /^gf_str_multi\(/) {
					split(args_of(tok), p, ",")
					rep = (mode == "grafana") ? "${" p[1] ":singlequote}" : "\047sample\047"
				} else if (tok ~ /^gf_str\(/) {
					split(args_of(tok), p, ",")
					rep = (mode == "grafana") ? "${" p[1] ":singlequote}" : "\047sample\047"
				} else if (tok ~ /^time_filter\(/) {
					a = args_of(tok)
					rep = (mode == "grafana") ? "$__timeFilter(" a ")" : a " >= now() - INTERVAL 1 DAY"
				} else if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (tok in V)) {
					rep = V[tok]
				} else {
					rep = "{{" tok "}}"
				}
				out = out pre rep
			}
			print out line
		}
	' "$file")"; then
		printf '[sql] ERROR: render failed: %s\n' "$file" >&2
		return 1
	fi

	if printf '%s' "$out" | grep -q '{{'; then
		printf '[sql] ERROR: unresolved template variable in %s\n' "$file" >&2
		return 1
	fi
	printf '%s\n' "$out"
}
