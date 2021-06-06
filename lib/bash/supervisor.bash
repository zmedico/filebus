#!/usr/bin/env bash

# @FUNCTION: filebus-supervisor_lib-init
# @DESCRIPTION:
# Library init function.
filebus-supervisor_lib-init() {
	if ! declare -f filebus-bash-import_lib-init >/dev/null; then
		# shellcheck disable=SC1090
		source "${BASH_SOURCE[0]%/*}"/bash-import.bash || return
		filebus-bash-import_lib-init || return
	fi

	filebus-bash-import_import log
}

# @FUNCTION: filebus-supervisor_wait-error
# @DESCRIPTION:
# Supervisor loop with jobs exit callback. The callback may return a non-zero status in order to terminate the loop.
filebus-supervisor_wait() {
	local retval=0
	# shellcheck disable=SC2031
	while (( ${#supervisor_jobs[@]} > 0 )); do
		wait -n
		job_status=$?
		for pid in "${!supervisor_jobs[@]}"; do
			if [[ " $(jobs -p | read -r -d ''
				# shellcheck disable=SC2086
				echo $REPLY) " != *" $pid "* ]]; then
				if { "${@}" "$job_status"; retval=$?; (( retval != 0 )); } then
					filebus-log_line "debug" "callback for \"${supervisor_jobs[$pid]}\" returned non-zero value"
					return $retval
				fi
				unset "supervisor_jobs[$pid]" || return
			fi
		done

	done
	return $retval
}

# @FUNCTION: filebus-supervisor_first-error
# @DESCRIPTION:
# Supervisor loop callback that returns for the first error.
filebus-supervisor_first-error() {
	[[ $1 == 0 ]]
}

# @FUNCTION: filebus-supervisor_wait-error
# @DESCRIPTION:
# Supervisor loop that returns for the first error.
# The loop keeps running when jobs exit with successful exit status.
filebus-supervisor_wait-error() {
	filebus-supervisor_wait filebus-supervisor_first-error
}

# @FUNCTION: filebus-supervisor_cleanup-jobs
# @DESCRIPTION:
# Kill background jobs before exit. Beware that it may be necessary
# to disown processes prior to starting background jobs, since those
# jobs may have been inherited from a parent process:
#
#  # shellcheck disable=SC2046
#  disown $(jobs -p) 2>/dev/null
filebus-supervisor_cleanup-jobs() {
	local jobs unchanging_loops=0 previous
	while true; do
		previous="${jobs[*]}"
		readarray -t jobs < <(jobs -p) || return
		if [[ $previous == "${jobs[*]}" ]]; then
			(( unchanging_loops++ ))
			if (( unchanging_loops > 1 )); then
				return 1
			fi
		fi
		# Jobs may have exited by they time we try to kill them, so kill error messages are ignored.
		{ [[ ${#jobs[@]} -eq 0 ]] || kill "${jobs[@]}" 2>/dev/null; } && break
	done
}
