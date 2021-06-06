#!/usr/bin/env bash

# @FUNCTION: import_lib-init
# @DESCRIPTION:
# Library init function.
filebus-bash-import_lib-init() {
	filebus-bash-import_search-paths-reset
	filebus-bash-import_lib-init-patterns-reset
}

# @FUNCTION: filebus-bash-import_import
# @DESCRIPTION:
# Import bash libs and call their lib-init functions if those functions
# are not yet defined in the current environment.
filebus-bash-import_import() {
	local dir lib match pattern
	for lib in "$@"; do
		match=0
		for pattern in "${FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS[@]}"; do
			if eval "declare -f \"$pattern\"" >/dev/null; then
				match=1
				break
			fi
		done
		if (( match != 1 )); then
			for dir in "${FILEBUS_BASH_IMPORT_SEARCH_PATHS[@]}"; do
				[[ -f $dir/${lib}.bash ]] || continue
				# shellcheck disable=SC1090
				source "$dir/$lib.bash" || return
				for pattern in "${FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS[@]}"; do
					if eval "declare -f \"$pattern\"" >/dev/null; then
						match=1
						eval "$pattern" || return
						break
					fi
				done
				if (( match != 1 )); then
					echo "Failed to init $lib lib" >&2; return 1
				fi
				break
			done
		fi
	done
}

# @FUNCTION: filebus-bash-import_search-paths-extend
# @DESCRIPTION:
# Extend FILEBUS_BASH_IMPORT_SEARCH_PATHS.
filebus-bash-import_search-paths-extend() {
	FILEBUS_BASH_IMPORT_SEARCH_PATHS+=("$@")
}

# @FUNCTION: filebus-bash-import_search-paths-list
# @DESCRIPTION:
# List current FILEBUS_BASH_IMPORT_SEARCH_PATHS, delimited by newlines.
filebus-bash-import_search-paths-list() {
	printf -- '%s\n' "${FILEBUS_BASH_IMPORT_SEARCH_PATHS[@]}"
}

# @FUNCTION: filebus-bash-import_search-paths-reset
# @DESCRIPTION:
# Reset FILEBUS_BASH_IMPORT_SEARCH_PATHS to defaults.
filebus-bash-import_search-paths-reset() {
	declare -g -a FILEBUS_BASH_IMPORT_SEARCH_PATHS=("${BASH_SOURCE[0]%/*}")
}

# @FUNCTION: filebus-bash-import_search-paths-set
# @DESCRIPTION:
# Set FILEBUS_BASH_IMPORT_SEARCH_PATHS from arguments.
filebus-bash-import_search-paths-set() {
	declare -g -a FILEBUS_BASH_IMPORT_SEARCH_PATHS=("$@")
}

# @FUNCTION: filebus-bash-import_lib-init-patterns-extend
# @DESCRIPTION:
# Extend FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS.
filebus-bash-import_lib-init-patterns-extend() {
	FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS+=("$@")
}

# @FUNCTION: filebus-bash-import_lib-init-patterns-list
# @DESCRIPTION:
#List FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS, delimited by newlines.
filebus-bash-import_lib-init-patterns-list() {
	printf -- '%s\n' "${FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS[@]}"
}

# @FUNCTION: filebus-bash-import_lib-init-patterns-reset
# @DESCRIPTION:
# Reset FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS to defaults.
filebus-bash-import_lib-init-patterns-reset() {
	declare -g -a FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS=('filebus-${lib#filebus-}_lib-init')
}

# @FUNCTION: filebus-bash-import_lib-init-patterns-set
# @DESCRIPTION:
# Set FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS from arguments.
filebus-bash-import_lib-init-patterns-set() {
	declare -g -a FILEBUS_BASH_IMPORT_LIB_INIT_PATTERNS=("$@")
}
