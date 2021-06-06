#!/usr/bin/env bash

# @FUNCTION: filebus-log_lib-init
# @DESCRIPTION:
# Library init function.
filebus-log_lib-init() {
	FILEBUS_LOG_LEVEL=${FILEBUS_LOG_LEVEL:-20}
}

if ! declare -f die >/dev/null; then
	die() {
		printf -- '%s\n' "${*}" 1>&2
		exit 1
	}
fi

# @FUNCTION: filebus-log_level
# @DESCRIPTION:
# Translate a log level name to an integer value.
filebus-log_level() {
	case ${1} in
		debug) echo 10;;
		info) echo 20;;
		warn) echo 30;;
		error) echo 40;;
		fatal) echo 50;;
		*) die "Unexpected argument: ${1}";;
	esac
}

# @FUNCTION: filebus-log_set-level
# @DESCRIPTION:
# Set log level
filebus-log_set-level() {
	FILEBUS_LOG_LEVEL=$(filebus-log_level "$1")
}

# @FUNCTION: filebus-log_check-level
# @DESCRIPTION:
# Check if a message is desired for the given level.
filebus-log_check-level() {
	[[ $(filebus-log_level "${1}") -ge ${FILEBUS_LOG_LEVEL} ]]
}

# @FUNCTION: filebus-log_line
# @DESCRIPTION:
# Log one line.
filebus-log_line() {
	local level=${1}
	shift

	if filebus-log_check-level "${level}"; then
		printf -- '[%s] [%s] %s\n' "$(date -u +%s.%N)" "${level}" "${*}" 1>&2
	fi
}

# @FUNCTION: filebus-log_lines-prefixed
# @DESCRIPTION:
# Log multiple prefixed lines for a log level.
filebus-log_lines-prefixed() {
	local date level=$1 line prefix=$2
	shift 2

	date=$(date -u +%s.%N) || return
	if filebus-log_check-level "${level}"; then
		for line in "${@}"; do
			printf -- '[%s] [%s] %s%s\n' "${date}" "${level}" "$prefix" "$line" 1>&2
		done
		printf -- '[%s] [%s] %s%s\n' "${date}" "${level}" "$prefix" "---" 1>&2
	fi
}
