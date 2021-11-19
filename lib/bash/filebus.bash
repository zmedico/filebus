#!/usr/bin/env bash

filebus_lib-init() {
	local import_path

	FILEBUS_IMPORT_SEARCH_PATHS=(
		"${BASH_SOURCE[0]%/*}"
	)

	if ! declare -f filebus-bash-import_lib-init >/dev/null; then
		for import_path in "${FILEBUS_IMPORT_SEARCH_PATHS[@]}"; do
			[[ -e $import_path/bash-import.bash ]] || continue
			# shellcheck disable=SC1090
			source "$import_path/bash-import.bash" || return
			filebus-bash-import_lib-init || return
			break
		done
	fi

	filebus-bash-import_search-paths-set "${FILEBUS_IMPORT_SEARCH_PATHS[@]}" || return
	filebus-bash-import_import log signal supervisor

	FILEBUS_CMD_ACTIONS="consumer|producer"
	declare -g -A FILEBUS_DEFAULTS
	FILEBUS_DEFAULTS[back_pressure]=0
	FILEBUS_DEFAULTS[block_size]=4096
	FILEBUS_DEFAULTS[blocking_read]=0
	FILEBUS_DEFAULTS[file_monitoring]=1
	FILEBUS_DEFAULTS[sleep_interval]=0.1
	FILEBUS_DEFAULTS[verbosity]=0
}

# @FUNCTION: _filebus_set-action
# @DESCRIPTION:
# Set program action.
_filebus_set-action() {
	[[ -z ${filebus_args[action]:-} ]] || die "Multiple actions specified:" "${filebus_args[action]:-}" "${1}"
	filebus_args[action]="${1}"
}

# @FUNCTION: _filebus_print-usage
# @DESCRIPTION:
# Print program usage instructions.
_filebus_print-usage() {
	printf -- 'usage: filebus [-h] [--back-pressure] [--block-size N] [--lossless] [--no-file-monitoring] [--filename FILE] [--sleep-interval N] [-v] {producer,consumer} ...\n'
	printf -- '\n'
	printf -- '  filebus VERSION (bash implementation)\n'
	printf -- '  A user space multicast named pipe implementation backed by a regular file\n'
	printf -- '\n'
	printf -- 'positional arguments:\n'
	printf -- '  {producer,consumer}\n'
	printf -- '    producer            connect producer side of stream\n'
	printf -- '    consumer            connect consumer side of stream\n'
	printf -- '\n'
	printf -- 'optional arguments:\n'
	printf -- '  -h, --help            show this help message and exit\n'
	printf -- '  --back-pressure       enable lossless back pressure protocol (unconsumed chunks cause producers to block)\n'
	printf -- '  --block-size N        maximum block size in units of bytes\n'
	printf -- '  --lossless            an alias for --back-pressure\n'
	printf -- '  --no-file-monitoring  disable filesystem event monitoring\n'
	printf -- '  --filename FILE       path of the data file (the producer updates it via atomic rename)\n'
	printf -- '  --sleep-interval N    check for new messages at least once every N seconds\n'
	printf -- '  -v, --verbose         verbose logging (each occurence increases verbosity)\n'
}

# @FUNCTION: _filebus_print-usage-producer
# @DESCRIPTION:
# Producer usage instructions.
_filebus_print-usage-producer() {
	printf -- 'usage: filebus producer [-h] [--blocking-read]\n'
	printf -- '\n'
	printf -- 'optional arguments:\n'
	printf -- '  -h, --help       show this help message and exit\n'
	printf -- '  --blocking-read  blocking read from input (clear the O_NONBLOCK flag)\n'
}

# @FUNCTION: _filebus_command-perform-producer
# @DESCRIPTION:
# Producer command.
_filebus_command-perform-producer() {
	local result
	mkdir -p "${filebus_args[filename]%/*}" || return

	while true; do
		if (( filebus_args[back_pressure] == 1 )); then
			while [[ -e ${filebus_args[filename]} ]]; do
				sleep "${filebus_args[sleep_interval]}" || return
			done
		fi
		buffer=()
		buffer_len=0
		! [[ -f /dev/fd/0 ]]
		regular_file=$?
		while true; do
			if (( regular_file == 1 )) || read -r -t 0; then
				read_ready=1
				read -r
				eof=$?
				if (( eof != 1 )); then
					buffer+=("${REPLY}")
					(( buffer_len += ${#REPLY} ))
					(( buffer_len++ )) # count newline
				fi
			else
				read_ready=0
				eof=0
			fi

			# Exit before the lock when possible (not possible when back pressure protocol is enabled).
			if (( filebus_args[back_pressure] == 0 && eof == 1 && read_ready == 1 && buffer_len == 0 )); then
				return 0
			fi

			if (( eof == 1 )) || (( read_ready == 0 && buffer_len > 0 )) || (( buffer_len >= filebus_args[block_size] )); then
				while true; do
					if (( filebus_args[back_pressure] == 1 )); then
						while [[ -e ${filebus_args[filename]} ]]; do
							sleep "${filebus_args[sleep_interval]}" || return
						done
					fi
					# shellcheck disable=SC2094
					({
						flock --exclusive 200 || exit 1
						[[ "${filebus_args[filename]}.lock" -ef /dev/fd/200 ]] || exit 1
						if (( filebus_args[back_pressure] == 1 )) && [[ -e ${filebus_args[filename]} ]]; then
							exit 3 # back pressure blocking
						fi
						(
							for line in "${buffer[@]}"; do
								printf -- '%s\n' "$line" || exit 1
							done
						) > "${filebus_args[filename]}.__new__" || exit 1
						mv "${filebus_args[filename]}"{.__new__,} || exit 1
						if (( filebus_args[back_pressure] == 0 )); then
							exit 0
						elif [[ ! -s ${filebus_args[filename]} ]]; then
							exit 2 # back pressure protocol EOF marker
						fi
						exit 0
					} 200>"${filebus_args[filename]}.lock")
					case $? in
						0)
							buffer=()
							buffer_len=0
							break
							;;
						1)
							return 1
							;;
						2)	# back pressure protocol EOF marker
							return 0
							;;
						3)	# back pressure blocking
							sleep "${filebus_args[sleep_interval]}" || return
							continue
							;;
					esac
				done
			fi
			if (( buffer_len == 0 )); then
				sleep "${filebus_args[sleep_interval]}" || return
			fi
		done
	done
}

# @FUNCTION: _filebus_command-parser-producer
# @DESCRIPTION:
# Parser for producer command arguments.
_filebus_command-parser-producer() {
	local consumed_args=0
	while (( $# > 0 )); do
		if [[ $1 =~ ^(-h|--help) ]]; then
			_filebus_print-usage-producer || return 1
			return 0
		elif [[ $1 == "--blocking-read" ]]; then
			filebus_args[blocking_read]=1
			(( consumed_args += 1 ))
			shift
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

# @FUNCTION: _filebus_print-usage-consumer
# @DESCRIPTION:
# Consumer usage instructions.
_filebus_print-usage-consumer() {
	printf -- 'usage: filebus consumer [-h]\n'
	printf -- '\n'
	printf -- 'optional arguments:\n'
	printf -- '  -h, --help       show this help message and exit\n'
}

# @FUNCTION: _filebus_command-perform-consumer
# @DESCRIPTION:
# Consumer command.
_filebus_command-perform-consumer() {
	local data status
	mkdir -p "${filebus_args[filename]%/*}" 2>/dev/null
	while true; do
		if [[ ! -e ${filebus_args[filename]} ]]; then
			sleep "${filebus_args[sleep_interval]}" || return
			continue
		fi
		if (( filebus_args[back_pressure] == 1 )); then
			# shellcheck disable=SC2094
			(
				{
					flock --exclusive 200 || exit 1
					[[ "${filebus_args[filename]}.lock" -ef /dev/fd/200 ]] || exit 1
					if [[ ! -e "${filebus_args[filename]}" ]]; then
						exit 0
					fi
					[[ -s ${filebus_args[filename]} ]]
					eof=$?
					cat "${filebus_args[filename]}" || exit 1
					rm -f "${filebus_args[filename]}" || exit 1
					case $eof in
						0)
							exit 2
							;;
						1)
							exit 3
							;;
						*)
							exit 1
					esac
				} 200>"${filebus_args[filename]}.lock"
			)
			case $? in
				1)
					return 1
					;;
				0|2)
					continue
					;;
				3)
					return 0
			esac
		else
			(
				if ! exec < "${filebus_args[filename]}"; then
					if [[ ! -d ${filebus_args[filename]%/*} ]]; then
						exit 1
					fi
					sleep "${filebus_args[sleep_interval]}" || exit 1
					exit 0
				fi
				while read -r; do
					printf -- '%s\n' "$REPLY" || exit 1
				done
				while [[ ${filebus_args[filename]} -ef /dev/fd/0 ]]; do
					sleep "${filebus_args[sleep_interval]}" || exit 1
				done
				exit 0
			) || return
		fi
	done
}

# @FUNCTION: _filebus_command-parser-consumer
# @DESCRIPTION:
# Parser for query command arguments.
_filebus_command-parser-consumer() {
	local consumed_args=0
	while (( $# > 0 )); do
		if [[ $1 =~ ^(-h|--help) ]]; then
			_filebus_print-usage-consumer || return 1
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

# @FUNCTION: filebus_main
# @DESCRIPTION:
# Main program.
filebus_main() {
	local arg sub_parser sub_parser_status
	local -A filebus_args
	filebus_args[back_pressure]=${FILEBUS_DEFAULTS[back_pressure]}
	filebus_args[block_size]=${FILEBUS_DEFAULTS[block_size]}
	filebus_args[blocking_read]=${FILEBUS_DEFAULTS[blocking_read]}
	filebus_args[file_monitoring]=${FILEBUS_DEFAULTS[file_monitoring]}
	filebus_args[sleep_interval]=${FILEBUS_DEFAULTS[sleep_interval]}
	filebus_args[verbosity]=${FILEBUS_DEFAULTS[verbosity]}
	shopt -s lastpipe

	params=$(getopt -o "fhv" -l "back-pressure,block-size:,blocking-read,filename:,help,impl:,implementation:,lossless,no-file-monitoring,sleep-interval:,verbose" --name "${0##*/}" -- "${@}") || exit $?
	eval set -- "${params}"

	for arg in "${@}"; do
		if [[ $arg =~ ^($FILEBUS_CMD_ACTIONS)$ ]]; then
			if declare -f "_filebus_command-parser-$arg" >/dev/null; then
				sub_parser=_filebus_command-parser-$arg
			fi
			break
		fi
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
			-v|--verbose)
				FILEBUS_DEFAULTS[verbosity]=$(( FILEBUS_DEFAULTS[verbosity] + 1 ))
				if (( FILEBUS_DEFAULTS[verbosity] > 1 )); then
					filebus-log_set-level debug
				fi
				;;
			-h|--help)
				_filebus_print-usage
				exit 0
				;;
			--impl|--implementation)
				case $2 in
					bash)
						shift
						;;
					*)
						die "Not implemented: $1=$2"
				esac
				;;
			--back-pressure|--lossless)
				filebus_args[back_pressure]=1
				;;
			--block-size)
				filebus_args[block_size]=$2
				shift
				;;
			--filename)
				filebus_args[filename]=$2
				shift
				;;
			--no-file-monitoring)
				unset "filebus_args[file_monitoring]"
				;;
			--sleep-interval)
				filebus_args[sleep_interval]=$2
				shift
				;;
			--)
				;;
			producer|consumer)
				_filebus_set-action "${1}"
				;;
			*)
				die "Unexpected argument: $1"
				;;
		esac
		shift
	done

	if [[ -z ${filebus_args[action]:-} ]]; then
		_filebus_print-usage
		die "Missing required action: $FILEBUS_CMD_ACTIONS"
	fi

	if [[ -z ${filebus_args[filename]:-} ]]; then
		_filebus_print-usage
		die "Missing required --filename argument"
	fi

	cd /
	filebus-signal_propagate SIGTERM SIGINT

	filebus-log_line "debug" "action: ${filebus_args[action]:-}"

	"_filebus_command-perform-${filebus_args[action]}" || return
}

if [[ $0 == "${BASH_SOURCE[0]}" ]]; then
	set -u -o pipefail

	if [[ ${BASH_SOURCE[0]} != /* ]]; then
		canonical_source=$(realpath --canonicalize-missing "${BASH_SOURCE[0]}")
		cd /
		exec "$BASH" "$canonical_source" "${@}" || exit 1
	fi

	filebus_lib-init
	filebus_main "$@"
fi
