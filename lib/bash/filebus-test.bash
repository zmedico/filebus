#!/usr/bin/env bash

filebus-test_lib-init() {
	local import_path

	FILEBUS_TEST_IMPORT_SEARCH_PATHS=(
		"${BASH_SOURCE[0]%/*}"
	)

	if ! declare -f filebus-bash-import_lib-init >/dev/null; then
		for import_path in "${FILEBUS_TEST_IMPORT_SEARCH_PATHS[@]}"; do
			[[ -e $import_path/bash-import.bash ]] || continue
			# shellcheck disable=SC1090
			source "$import_path/bash-import.bash" || return
			filebus-bash-import_lib-init || return
			break
		done
	fi

	filebus-bash-import_search-paths-set "${FILEBUS_TEST_IMPORT_SEARCH_PATHS[@]}" || return
	filebus-bash-import_import log signal supervisor

	FILEBUS_TEST_CMD_ACTIONS="test"
}

# @FUNCTION: filebus
# @DESCRIPTION:
# Call filebus (bash implementation).
filebus() {
	"${BASH}" "${BASH_SOURCE[0]%/*}/filebus.bash" "${@}" || return
}

# @FUNCTION: filebus-test_setup
# @DESCRIPTION:
# Setup sel test program.
filebus-test_setup() {
	local mock_state
	FILEBUS_TEST_TEMPDIR=$(mktemp -d) || return
	FILEBUS_TEST_DATA_DIR=$FILEBUS_TEST_TEMPDIR/run/brd-tms-conf/filebus || return
	FILEBUS_TEST_SUPERVISOR_RESULT=12
	FILEBUS_TEST_DATA_FILE=$FILEBUS_TEST_DATA_DIR/data
	FILEBUS_TEST_MOCK_STATE_DIR=$FILEBUS_TEST_TEMPDIR/mock-state
	mkdir -p "$FILEBUS_TEST_DATA_DIR" "$FILEBUS_TEST_TEMPDIR/bin" "$FILEBUS_TEST_MOCK_STATE_DIR".state{1..3} || return

	FILEBUS_TEST_MOCK_STATES=(
		state1
		state2
		state3
	)
	FILEBUS_TEST_MOCK_STATES_SEQUENCE=(
		state1
		state2
		state3
		state2
		state3
		state1
	)

	for mock_state in "${FILEBUS_TEST_MOCK_STATES[@]}"; do
		printf -- '%s\n' "$mock_state" > "$FILEBUS_TEST_MOCK_STATE_DIR.$mock_state/state" || return
	done
	_filebus-test_mutate-mock-state state1 || return

	cat <<-EOF >"$FILEBUS_TEST_TEMPDIR/bin/mock-data-source"
	#!$BASH
	exec "$BASH" "${BASH_SOURCE[0]%/*}/filebus.bash" --filename "$FILEBUS_TEST_MOCK_STATE_DIR/state" consumer || exit $?
	EOF
	chmod a+x "$FILEBUS_TEST_TEMPDIR/bin/mock-data-source" || return

	FILEBUS_TEST_STATE_MONITOR_COMMAND=("$FILEBUS_TEST_TEMPDIR/bin/mock-data-source")

	export PATH=$FILEBUS_TEST_TEMPDIR/bin:$PATH

	filebus-test_lib-init

	FILEBUS_TEST_WAIT_EXPECTED_COMMAND=(filebus --filename "$FILEBUS_TEST_DATA_FILE" consumer)

	true > "$FILEBUS_TEST_DATA_FILE" || return
}

# @FUNCTION: filebus-test-cleanup
# @DESCRIPTION:
# Self test program.
filebus-test-cleanup() {
	rm -rf "$FILEBUS_TEST_TEMPDIR"
}

# @FUNCTION: filebus-test_process
# @DESCRIPTION:
# Self test process.
filebus-test_process() {
	local failures=0 mock_state retval=$FILEBUS_TEST_SUPERVISOR_RESULT

	filebus-signal_propagate SIGTERM SIGINT
	trap filebus-supervisor_cleanup-jobs EXIT || return

	for mock_state in "${FILEBUS_TEST_MOCK_STATES_SEQUENCE[@]}"; do
		_filebus-test_mutate-mock-state "$mock_state" || return
		_filebus-test_wait-for-expected "$mock_state"  || return
	done

	if (( ( retval != 0 && retval != FILEBUS_TEST_SUPERVISOR_RESULT ) || failures != 0 )); then
		filebus-log_line error "retval: $retval failures: $failures"
		return 1
	fi

	return "$retval"
}

# @FUNCTION: _filebus-test_mutate-mock-state
# @DESCRIPTION:
# Self test process.
_filebus-test_mutate-mock-state() {
	filebus-log_line info "mutate-mock-state: $1"
	ln -snf "mock-state.$1" "$FILEBUS_TEST_MOCK_STATE_DIR" || return
}

# @FUNCTION: _filebus-test_wait-for-expected
# @DESCRIPTION:
# Wait for an expected state to occur.
_filebus-test_wait-for-expected() {
	local line expected=$1
	filebus-log_line info "wait-for-expected: expected $expected"
	while read -r line; do
		if [[ $line == "$expected" ]]; then
			break
		fi
		filebus-log_line info "wait-for-expected: got $line"
		filebus-log_line info "wait-for-expected: expected $expected"
	done < <("${FILEBUS_TEST_WAIT_EXPECTED_COMMAND[@]}")
}

# @FUNCTION: _filebus-test_supervisor-callback
# @DESCRIPTION:
# Self test process.
# shellcheck disable=SC2031
_filebus-test_supervisor-callback() {
	local status=$1
	filebus-log_line "info" "supervisor callback: ${supervisor_jobs[$pid]} exited with status ${status/${FILEBUS_TEST_SUPERVISOR_RESULT}/FILEBUS_TEST_SUPERVISOR_RESULT}"
	if [[ ${supervisor_jobs[$pid]} == test_process ]]; then
		case $status in
			# Accept 143 for SIGTERM.
			"$FILEBUS_TEST_SUPERVISOR_RESULT"|143|0)
				return "$FILEBUS_TEST_SUPERVISOR_RESULT"
				;;
		esac
		return 1
	elif [[ $status == 141 ]]; then
		# SIGPIPE is expected.
		if [[ ${supervisor_jobs[$pid]} == pipe_input_loop ]]; then
			return "$FILEBUS_TEST_SUPERVISOR_RESULT"
		fi
		return 0
	fi
	[[ $status == 0 ]]
}


# @FUNCTION: _filebus-test_set-action
# @DESCRIPTION:
# Set program action.
_filebus-test_set-action() {
	[[ -z ${filebus_test_args[action]:-} ]] || die "Multiple actions specified:" "${filebus_test_args[action]:-}" "${1}"
	filebus_test_args[action]="${1}"
}

# @FUNCTION: _filebus-test_set-output-format
# @DESCRIPTION:
# Set program output format.
_filebus-test_set-output-format() {
	[[ -z ${filebus_test_args[output_format]:-} ]] || die "Multiple output formats specified:" "${filebus_test_args[output_format]:-}" "${1}"
	filebus_test_args[output_format]="${1}"
}

# @FUNCTION: _filebus-test_print-usage
# @DESCRIPTION:
# Print program usage instructions.
_filebus-test_print-usage() {
	printf -- 'usage: filebus %s\n' "$FILEBUS_TEST_CMD_ACTIONS"
	printf -- '\n'
	printf -- 'filebus test\n'
	printf -- '\n'
	printf -- 'Options:\n'
	printf -- '  -f, --follow             Follow query topic\n'
}

# @FUNCTION: _filebus-test_print-usage-query
# @DESCRIPTION:
# Print query usage instructions.
_filebus-test_print-usage-query() {
	printf -- 'usage: query\n'
	printf -- '\n'
	printf -- 'query data\n'
	printf -- '\n'
	printf -- 'Options:\n'
	printf -- '  -f, --follow             follow data stream\n'
}

# @FUNCTION: filebus-test_state-monitor-loop
# @DESCRIPTION:
# State monitor loop.
filebus-test_state-monitor-loop() {
	local digest line
	mkdir -p "${FILEBUS_TEST_DATA_FILE%/*}" || return
	"${FILEBUS_TEST_STATE_MONITOR_COMMAND[@]}" metrics --follow | while read -r line; do
		[[ -n $line ]] || continue
		mkdir -p "${FILEBUS_TEST_DATA_FILE%/*}" || return
		filebus --filename "$FILEBUS_TEST_DATA_FILE" producer <<< "$line" || return
	done
}

# @FUNCTION: _filebus-test_command-perform-query
# @DESCRIPTION:
# Perform query command.
_filebus-test_command-perform-query() {
	if [[ -n ${follow:-} ]]; then
		mkdir -p "${FILEBUS_TEST_DATA_FILE%/*}" || return
		[[ -e "$FILEBUS_TEST_DATA_FILE" ]] || true >> "$FILEBUS_TEST_DATA_FILE" || return
		filebus --filename "$FILEBUS_TEST_DATA_FILE" consumer || return
		return
	fi
	cat "$FILEBUS_TEST_DATA_FILE" || return
	return
}

# @FUNCTION: _filebus-test_command-parser-query
# @DESCRIPTION:
# Parser for query command arguments.
_filebus-test_command-parser-query() {
	local consumed_args=0
	while (( $# > 0 )); do
		if [[ $1 =~ ^(-h|--help|help) ]]; then
			_filebus-test_print-usage-query || return 1
			return 0
		else
			# break for first unconsumed argument
			break
		fi
	done

	# status
	# 0       immediate successful exit
	# 1       immediate failure
	# 2+      status = consumed_args + 2
	return $(( consumed_args + 2 ))
}

# @FUNCTION: filebus-test_main
# @DESCRIPTION:
# Main program.
filebus-test_main() {
	local arg data_dir follow line output_format pipe pipestatus sub_parser sub_parser_status query_topic
	local -A filebus_test_args
	shopt -s lastpipe

	params=$(getopt -o "dfho:" -l "data-dir:,debug,help,follow,output:" --name "${0##*/}" -- "${@}") || exit $?
	eval set -- "${params}"

	for arg in "${@}"; do
		case $arg in
			query|test)
				if declare -f "_filebus-test_command-parser-$arg" >/dev/null; then
					sub_parser=_filebus-test_command-parser-$arg
				fi
				break
				;;
		esac
	done

	while [[ ${#} -gt 0 ]]; do

		if [[ -n ${sub_parser:-} ]]; then
			"$sub_parser" "$@"
			sub_parser_status=$?

			# account for any consumed arguments
			while (( sub_parser_status > 2 )); do
				(( sub_parser_status-- ))
				shift
			done

			case $sub_parser_status in
				0)
					# immediate success
					return 0
					;;
				1)
					# immediate failure
					return 1
					;;
				2)
					# status = consumed_args + 2
					;;
			esac
		fi

		(( $# > 0 )) || break

		case $1 in
			--data-dir)
				data_dir=${2}
				shift
				;;
			-d|--debug)
				filebus-log_set-level debug
				;;
			-f|--follow)
				follow=1
				;;
			-h|--help|help)
				_filebus-test_print-usage
				exit 0
				;;
			-o|--output)
				_filebus-test_set-output-format "${2}"
				shift
				;;
			--)
				;;
			query|test)
				_filebus-test_set-action "${1}"
				;;
			*)
				die "Unexpected argument: $1"
				;;
		esac
		shift
	done

	if [[ -z ${filebus_test_args[action]:-} ]]; then
		_filebus-test_print-usage
		die "Missing required action: $FILEBUS_TEST_CMD_ACTIONS"
	fi

	if [[ -n ${data_dir:-} ]]; then
		FILEBUS_TEST_DATA_DIR=$data_dir
		filebus-test_lib-init
	fi


	cd /
	filebus-signal_propagate SIGTERM SIGINT

	filebus-log_line "debug" "action: ${filebus_test_args[action]:-}"

	case ${filebus_test_args[action]:-} in
		query)
			_filebus-test_command-perform-query || return
			return
			;;
		test)
			;;
		*)
			die "Unknown action: ${filebus_test_args[action]:-}"
	esac

	[[ ${filebus_test_args[action]} == test ]] && filebus-test_setup

	# shellcheck disable=SC2046
	disown $(jobs -p) 2>/dev/null
	trap filebus-supervisor_cleanup-jobs EXIT || return

	local -A supervisor_jobs

	filebus-test_state-monitor-loop &
	supervisor_jobs[$!]=state-monitor-loop || return

	filebus-test_process &
	supervisor_jobs[$!]=test_process || return
	supervisor_callback=_filebus-test_supervisor-callback

	filebus-supervisor_wait "$supervisor_callback"
	pipestatus=("${PIPESTATUS[@]}")

	case ${filebus_test_args[action]:-} in
		test)
			[[ ${pipestatus[*]} == "$FILEBUS_TEST_SUPERVISOR_RESULT" ]]
			return
			;;
		*)
			[[ ${pipestatus[*]} == "0" ]]
			return
			;;
	esac
}

if [[ $0 == "${BASH_SOURCE[0]}" ]]; then
	set -u -o pipefail

	if [[ ${BASH_SOURCE[0]} != /* ]]; then
		canonical_source=$(realpath --canonicalize-missing "${BASH_SOURCE[0]}")
		cd /
		exec "$BASH" "$canonical_source" "${@}" || exit 1
	fi

	filebus-test_lib-init
	filebus-test_main "$@"
fi
