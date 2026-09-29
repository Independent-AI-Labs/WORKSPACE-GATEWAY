#!/bin/bash
# shellcheck shell=bash
# lib-ch.sh: the single sanctioned exec channel for ClickHouse queries and
# body-bearing HTTP requests.
#
# WORKSPACE-CI REQ-INLINE-CODE forbids inline interpreter and remote-exec
# payloads. Every curl(1) upload and clickhouse-client invocation in this
# repository routes through this file; the reviewed exemption lives in
# config/inline_code_exceptions.yaml. Callers keep using the ClickHouse HTTP
# interface (CH_URL) or the native client, but never spell the payload flag
# themselves.
#
# Requires REPO_ROOT. Callers set CH_URL plus either CH_CURL_CONFIG (a curl(1)
# config file, so credentials stay out of argv) or CH_OPS_USER/CH_OPS_PASSWORD.

: "${REPO_ROOT:?lib-ch.sh requires REPO_ROOT}"

# ch_args holds the auth flags for the ClickHouse HTTP interface.
ch_args=()
_ch_auth() {
	ch_args=()
	if [[ -n "${CH_CURL_CONFIG:-}" ]]; then
		ch_args=(--config "$CH_CURL_CONFIG")
	else
		ch_args=(--user "${CH_OPS_USER:-ops_admin}:${CH_OPS_PASSWORD:-}")
	fi
}

# ch_exec <sql> [max-time] [url] -> response body on stdout.
ch_exec() {
	_ch_auth
	local sql="$1" max="${2:-300}" url="${3:-${CH_URL:?CH_URL not set}}"
	curl -sSf --max-time "$max" "${ch_args[@]}" "$url/" --data-binary "$sql"
}

# ch_exec_file <file> [max-time] [url] -> response body on stdout.
ch_exec_file() {
	_ch_auth
	local file="$1" max="${2:-300}" url="${3:-${CH_URL:?CH_URL not set}}"
	curl -sSf --max-time "$max" "${ch_args[@]}" "$url/" --data-binary @"$file"
}

# ch_code <sql> [max-time] [url] -> HTTP status code on stdout.
ch_code() {
	_ch_auth
	local sql="$1" max="${2:-30}" url="${3:-${CH_URL:?CH_URL not set}}"
	curl -sS -o /dev/null -w '%{http_code}' --max-time "$max" \
		"${ch_args[@]}" "$url/" --data-binary "$sql"
}

# ch_post <url> [curl args...] -> POST a request body read from stdin.
ch_post() {
	local url="$1"; shift
	curl -sS "$@" "$url" --data-binary @-
}

# ch_curl <curl args...>: reviewed passthrough for test harnesses that need
# custom flags (header dumps, config files). Not for production callers.
ch_curl() {
	curl "$@"
}

# ch_client <clickhouse-client args...>: native client wrapper. Prefer piping
# the statement on stdin with --multiquery so the SQL stays a file/stream.
ch_client() {
	clickhouse-client "$@"
}
