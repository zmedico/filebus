#!/usr/bin/env bash

# @FUNCTION: filebus-signal_lib-init
# @DESCRIPTION:
# Library init function.
filebus-signal_lib-init() { true; }

# @FUNCTION: filebus-signal_propagate-SIGTERM
# @DESCRIPTION:
# SIGTERM handler that forwards it to the process group.
filebus-signal_propagate-SIGTERM() {
	trap - SIGTERM
	kill -s SIGTERM 0
}

# @FUNCTION: filebus-signal_propagate-SIGINT
# @DESCRIPTION:
# SIGINT handler that forwards it to the process group.
filebus-signal_propagate-SIGINT() {
	trap - SIGINT
	kill -s SIGINT 0
}

# @FUNCTION:filebus-signal_propagate
# @DESCRIPTION:
# Signal handler that forwards it to the process group.
filebus-signal_propagate() {
	local signal
	for signal in "${@}"; do
        # shellcheck disable=SC2064
		trap "filebus-signal_propagate-$signal" "$signal"
	done
}
