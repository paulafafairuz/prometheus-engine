#!/usr/bin/env bash
# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail
set -o nounset

if [[ -n "${DEBUG_MODE:-}" ]]; then
	set -o xtrace
fi

SCRIPT_DIR="$(
	cd -- "$(dirname "$0")" >/dev/null 2>&1
	pwd -P
)"

# Extended regular expressions (ERE) regex matching paths to exclude from the fork commit.
# NOTE: # ^\..+ means all hidden files (e.g. changes to .golangci.yaml .gitignore or CI).
# TODO(bwplotka): Consider moving to globs with dotglob and extglob settings.. or Go (:
export RELEASE_LIB_EXCLUDE_RE="^\..+
^README\.md
^CHANGELOG\.md
^MAINTAINERS\.md
^CONTRIBUTING\.md
^RELEASE\.md
^Dockerfile
^docs/.*
^documentation/.*
^google/.*
^.*go\..*
^.*\.gitignore
^.*package.json
^.*package-lock.json
^Makefile.*
^.*vendor/.*
^VERSION
^.*node_modules/.*"

# Extended regular expressions (ERE) regex matching paths from EXCLUDE_RE that should be included.
# This is needed as it's simpler than implementing RE negative matchers.
# NOTE: For Prometheus the two specific documentation files are imported in Google Managed Prometheus docs, so keep those.
export RELEASE_LIB_DOCUMENTATION_INCLUDE_RE="^documentation/examples/prometheus-agent\.y.?ml
^documentation/examples/prometheus\.y.?ml"

release-lib::confirm() {
	local prompt_message="${1:-Are you sure?}"

	# -p: Display the prompt string.
	# -r: Prevents backslash interpretation.
	# -n 1: Read only one character.
	read -p "$prompt_message [y/n/CTR+C]: " -r -n 1 response
	echo # Ensures the cursor moves to the next line after input.
	case "$response" in
	[yY])
		return 0
		;;
	[nN])
		echo "❌  The action has been cancelled as requested."
		return 1
		;;
	*)
		echo "Invalid input. Exiting script." >&2
		exit 1
		;;
	esac
}

# clone clones the $REMOTE_URL to $clone_dir at $source_branch version, then
# creates $target_branch from it, if set.
#
# Idempotence: If the $clone_dir exists, skip cloning and check if
# the $clone_dir is a git repo on the desired branch.
# TODO: Cloning takes time, consider resetting repo if present.
release-lib::idemp::clone() {
	local clone_dir="${1}"
	if [[ -z "${clone_dir}" ]]; then
		echo "❌  clone_dir arg is not set." >&2
		return 1
	fi
	local source_branch="${2}" # Branch to fetch when cloning, base for $target_branch
	if [[ -z "${source_branch}" ]]; then
		echo "❌  source_branch arg is not set." >&2
		return 1
	fi
	local target_branch="${3}" # Branch to create from source_branch,
	if [[ -z "${target_branch}" ]]; then
		target_branch="${source_branch}"
	fi

	if [[ -z "${REMOTE_URL}" ]]; then
		echo "❌  REMOTE_URL environment variable is not set." >&2
		return 1
	fi

	if [[ ! -d "${clone_dir}" ]]; then
		git clone -b "${source_branch}" "${REMOTE_URL}" "${clone_dir}"
		if [[ "${source_branch}" != "${target_branch}" ]]; then
			pushd "${clone_dir}"
			git checkout -b "${target_branch}"
			popd
		fi
	else
		if ! release-lib::confirm "The repository clone on ${clone_dir} exists. Do you want to reuse this directory without resetting? 'n' will attempt a hard reset on the repo (quicker then re-clone)."; then
			git checkout "${source_branch}"
			git reset --hard "origin/${source_branch}"
			git branch --merged | grep -v "\*|${source_branch}" | xargs git branch -D
			# TODO: Remove tags?
		fi
	fi

	pushd "${clone_dir}"
	if [[ "$(git symbolic-ref --short HEAD)" != "${target_branch}" ]]; then
		echo "❌  Malformed ${DIR}; expected ${target_branch} got $(git symbolic-ref --short HEAD); remove or fix manually the ${clone_dir} and rerun." >&2
		return 1
	fi
	popd
}

release-lib::remote_url_from_branch() {
	local branch=$1
	# Check if the BRANCH environment variable is set.
	if [[ -z "${branch}" ]]; then
		echo "❌  branch is required." >&2
		return 1
	fi

	if [[ "${branch}" =~ release-(2|3)\.[0-9]+\.[0-9]+-gmp$ ]]; then
		echo "git@github.com:GoogleCloudPlatform/prometheus.git"
	elif [[ "${branch}" =~ release-0\.[0-9]+\.[0-9]+-gmp$ ]]; then
		echo "git@github.com:GoogleCloudPlatform/alertmanager.git"
	elif [[ "${branch}" =~ release/0\.[0-9]+$ ]]; then
		echo "git@github.com:GoogleCloudPlatform/prometheus-engine.git"
	else
		echo "❌  No matching remote URL found for branch=${branch}" >&2
		return 1
	fi
}

release-lib::upstream_remote_url() {
	local project=$1
	if [[ -z "${project}" ]]; then
		echo "❌  project is required." >&2
		return 1
	fi

	if [[ "${project}" == "prometheus" ]]; then
		echo "git@github.com:prometheus/prometheus.git"
	elif [[ "${project}" == "alertmanager" ]]; then
		echo "git@github.com:prometheus/alertmanager.git"
	else
		echo "❌  No matching remote URL found for project='${project}'" >&2
		return 1
	fi
}

release-lib::idemp::vulnlist() {
	local dir="${1}"
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi
	local vuln_file="${2}"
	if [[ -z "${vuln_file}" ]]; then
		echo "❌  vuln_file arg is required." >&2
		return 1
	fi
	if [[ "${vuln_file}" != /* ]]; then
		echo "❌  vuln_file arg must point to an absolute file path." >&2
		return 1
	fi

	if [[ -f "${vuln_file}" && ! -z $(cat "${vuln_file}") ]]; then
		if ! release-lib::confirm "Found previous "${vuln_file}". Do you want to reuse this file? 'n' will re-run Go vulnlist check."; then
			release-lib::vulnlist "${dir}" "${vuln_file}"
		else
			echo "⚠️ Using existing ${vuln_file}"
		fi
	else
		release-lib::vulnlist "${dir}" "${vuln_file}"
	fi
}

release-lib::dockerfiles() {
	local dir="${1}"
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi
	find "${dir}" -name "Dockerfile" | grep -v "/third_party/" | grep -v "/examples/" | grep -v "/hack/"
}

release-lib::vulnlist() {
	local dir="${1}"
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi
	local vuln_file="${2}"
	if [[ -z "${vuln_file}" ]]; then
		echo "❌  vuln_file arg is required." >&2
		return 1
	fi
	if [[ "${vuln_file}" != /* ]]; then
		echo "❌  vuln_file arg must point to an absolute file path." >&2
		return 1
	fi

	readarray -t DOCKERFILES < <(release-lib::dockerfiles "${DIR}")
	local go_version=$(release-lib::dockerfile_go_version "${DOCKERFILES[0]}")
	if [[ -z "${go_version}" ]]; then
		echo "❌  can't find any golang image in ${DOCKERFILES[0]}" >&2
		return 1
	fi

	echo "🔄  Detecting Go ${go_version} vulnerabilities to fix..."
	pushd "${SCRIPT_DIR}/vulnupdatelist/"
	if [[ ! -f "./api.text" ]]; then
		echo "❌  $(pwd)/api.text file not found in your filesystem. Please create it with your NVD API key. See https://nvd.nist.gov/developers/request-an-api-key" >&2
		return 1
	fi

	go run "./..." \
		-go-version=${go_version} \
		-only-fixed \
		-dir="${dir}" \
		-nvd-api-key="$(cat "./api.text")" | tee "${vuln_file}"
	if [[ -z $(cat "${vuln_file}") ]]; then
		# Print this, otherwise error on the above might keep this file mistakenly empty.
		echo "no vulnerabilities" >"${vuln_file}"
	fi
	popd
}

release-lib::gomod_vulnfix() {
	local dir=${1}
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	local vuln_file="${2}"
	if [[ -z "${vuln_file}" ]]; then
		echo "❌  vuln_file arg is required." >&2
		return 1
	fi
	if [[ ! -f "${vuln_file}" ]]; then
		echo "❌  no ${vuln_file} file found" >&2
		return 1
	fi

	if [[ "no vulnerabilities" == $(cat "${vuln_file}") ]]; then
		echo "❌  ${vuln_file} shows no vulnerabilities" >&2
		return 1
	fi

	# Read the vulnerability file line by line.
	# The `|| [[ -n "$line" ]]` part handles the case where the last line doesn't have a newline.
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip any empty lines in the input file.
		if [ -z "$line" ]; then
			continue
		fi

		mod=$(echo "$line" | awk '{print $2}')
		mod_path=$(echo "${mod}" | cut -d'@' -f1)
		desired_version=$(echo "${mod}" | cut -d'@' -f2)

		if [[ -z "${mod_path}" ]] || [[ -z "${desired_version}" ]]; then
			echo "⚠️ Skipping malformed line: $line"
			continue
		fi

		echo "🔄 Updating module '${mod_path}' to version '${desired_version}'..."
		gsed -i.bak "s|\(	${mod_path} \).*|\1${desired_version}|" "${dir}/go.mod"
	done <"${vuln_file}"
	echo "🔄 Resolving ${dir}/go.mod..."
	pushd "${dir}"
	go mod tidy
	popd
}

release-lib::idemp::git_commit_amend_match() {
	# Anything staged?
	if ! git diff-index --quiet --cached HEAD; then
		release-lib::git_commit_amend_match "${1}"
	fi
}

release-lib::git_commit_amend_match() {
	local message="${1}"
	if [[ -z "${message}" ]]; then
		echo "❌  message is required." >&2
		return 1
	fi
	if [[ "$(git log -1 --pretty=%s)" == "${message}" ]]; then
		git commit -s --amend -m "${message}"
	else
		git commit -sm "${message}"
	fi
}

release-lib::needs_push() {
	local branch_to_push="${1}"
	if [[ -z "${branch_to_push}" ]]; then
		echo "❌  branch_to_push environment variable is not set." >&2
		return 1
	fi
	local base_branch_to_diff="${2}"
	if [[ -z "${base_branch_to_diff}" ]]; then
		echo "❌  base_branch_to_diff environment variable is not set." >&2
		return 1
	fi
	git checkout "${branch_to_push}"

	# TODO: Fix edge case - deleting branch remotely does not delete it locally (origin ref).
	if upstream_head=$(git fetch && git rev-parse "origin/${branch_to_push}"); then
		if [[ "$(git rev-parse HEAD)" == "${upstream_head}" ]]; then
			echo "⚠️ Nothing to push; origin/${branch_to_push} is all up to date"
			return 1
		fi
		git --no-pager log --oneline "${upstream_head}"...HEAD
		return 0
	fi
	# Likely "origin/${branch_to_push}" does not exists yet, so definitely something to
	# push (full $branch_to_push). Assuming the $branch_to_push will be proposed to be merged to
	# $base_branch_to_diff, so showing a full diff vs $base_branch_to_diff.
	if upstream_base_head=$(git fetch && git rev-parse "origin/${base_branch_to_diff}"); then
		if [[ "$(git rev-parse HEAD)" == "${upstream_base_head}" ]]; then
			echo "⚠️ Nothing to push, even the base origin/${base_branch_to_diff} is up to date; did you expect that?"
			return 1
		fi
		git --no-pager log --oneline "${upstream_base_head}"...HEAD
		return 0
	fi
}

release-lib::exclude_changes_from_last_commit() {
	local exclude_regexes=$1
	if [[ -z "${exclude_regexes}" ]]; then
		echo "❌  exclude_regexes is required." >&2
		return 1
	fi
	local include_regexes=$2
	if [[ -z "${include_regexes}" ]]; then
		echo "❌  include_regexes is required." >&2
		return 1
	fi
	local commit_title=$3
	if [[ -z "${commit_title}" ]]; then
		echo "❌  commit_title is required." >&2
		return 1
	fi

	# Get all files touched by a git commit, delimited by space.
	changed_files=$(git show --pretty="" --name-only "$(git rev-parse --verify HEAD)")
	if [ -z "${changed_files}" ]; then
		echo "❌  suspicious HEAD commit, no files changed." >&2
		return 1
	fi

	# Change to \n delimit (needed for grep to work) and exclude/include lines.
	tmp_to_exclude=$(echo "${changed_files}" | tr ' ' '\n' | grep -E "${exclude_regexes}" | grep -v -E "${include_regexes}")

	# Group node_module and vendor changes, we know we want to get rid of full directories here -- too many of those files slowing things down and obscuring the summary in git commit -- git restore supports globs.
	to_exclude=$(echo "${tmp_to_exclude}" | gsed -e 's|vendor/.*$|vendor/*|' -e 's|node_modules/.*$|node_modules/*|' | sort -u | tr ' ' '\n')
	if [ -z "${to_exclude}" ]; then
		# Nothing to exclude.
		return 0
	fi

	echo "🔄 Excluding the following files from the fork squash commit: ${to_exclude}; appending this information to the git commit message"
	curr_msg=$(git log --format=%B -n1)

	# Get all changes to be in stage area.
	git reset --soft HEAD~1
	while IFS= read -r exclude_path; do
		git restore -S "${exclude_path}"
	done <<<"${to_exclude}"
	# Commit after unstaging exclusions.
	# TODO(bwplotka): Handle nothing to commit after exclusion case.
	git commit -m "${commit_title}" -m "${curr_msg}" -m "Excluded files:
${to_exclude}
"
	git restore .
	git clean -fd
}

release-lib::idemp::dockerfile_update_go_version() {
	local dockerfile=${1}
	if [[ -z "${dockerfile}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	if [ ! -f "${dockerfile}" ]; then
		echo "❌ File not found: $DOCKERFILE"
		return 1
	fi

	# TODO test if dockerfile without Go image will fail as expected.
	local go_version=$(release-lib::dockerfile_go_version "${dockerfile}")

	local golang_tags=$(go tool gcrane ls "google-go.pkg.dev/golang" --json | jq --raw-output '.tags[]' | sort -V)
	if [[ -z "${INCLUDE_RC:-}" ]]; then
		golang_tags=$(echo "${golang_tags}" | grep -v "rc.*")
	fi
	if [[ -n "${LATEST_MINOR:-}" ]]; then
		golang_tags=$(echo "${golang_tags}" | grep "${LATEST_MINOR}.*")
	fi
	local latest_golang_tag=$(echo "${golang_tags}" | tail -n1)
	if [[ "${go_version}" == "${latest_golang_tag}" ]]; then
		echo "✅  Nothing to do; ${dockerfile} already uses ${go_version}"
		return 0
	fi

	# Upgrade.
	local latest_golang_digest=$(crane digest "google-go.pkg.dev/golang:${latest_golang_tag}")
	local latest_golang_image="google-go.pkg.dev/golang:${latest_golang_tag}@${latest_golang_digest}"
	echo "🔄  Ensuring ${latest_golang_image} on ${dockerfile}..."
	if ! gsed -i -E "s#google-go\.pkg\.dev/golang:([0-9]+\.[0-9]+\.[0-9+][^@ ]*)?(@sha256:[0-9a-f]+)?#${latest_golang_image}#g" "${dockerfile}"; then
		echo "❌  sed didn't replace?"
		return 1
	fi

	echo "✅  Done!"
	return 0
}

release-lib::dockerfile_go_version() {
	local dockerfile=${1}
	if [[ -z "${dockerfile}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	if [ ! -f "${dockerfile}" ]; then
		echo "❌ File not found: $DOCKERFILE"
		return 1
	fi

	# 1. Find all 'FROM' lines.
	# 2. Use sed to:
	#    - Remove the 'FROM ' prefix.
	#    - Remove the optional '--platform=[...]' flag.
	#    - Remove the optional 'AS [...]' stage name at the end of the line.
	# 3. Read each resulting full image string line by line.
	local go_tag=$(grep '^FROM ' "${dockerfile}" |
		sed -e 's/^FROM //' \
			-e 's/--platform=[^ ]* //' \
			-e 's/ AS [^ ]*$//' |
		while read -r full_image_string; do
			# Initialize variables for each line
			image_name=""
			tag=""
			sha=""

			# --- 1. Extract SHA ---
			# Check if the string contains a SHA digest (delimited by '@')
			if [[ "$full_image_string" == *@* ]]; then
				# Use cut to split the string at the '@'
				image_and_tag=$(echo "$full_image_string" | cut -d'@' -f1)
				sha=$(echo "$full_image_string" | cut -d'@' -f2)
			else
				# No SHA found
				image_and_tag="$full_image_string"
				sha="<none>"
			fi

			# --- 2. Extract Tag ---
			# A tag is the part after the *last* colon.
			# We must check that this part doesn't contain a '/',
			# which would mean it's part of a port number (e.g., localhost:5000/my-image)

			# Get the part after the last colon
			last_part="${image_and_tag##*:}"

			if [[ "$last_part" == "$image_and_tag" || "$last_part" == */* ]]; then
				# Case 1: No colon found (e.g., "alpine")
				#    Here, last_part == image_and_tag
				# Case 2: Colon is part of a port/path (e.g., "my.registry:5000/image")
				#    Here, last_part == "5000/image", which matches */*
				image_name="$image_and_tag"
				tag="<none>"
			else
				# Case 3: A valid tag was found (e.g., "alpine:latest")
				#    Here, last_part == "latest"
				image_name="${image_and_tag%:*}"
				tag="$last_part"
			fi

			if [[ "${image_name}" == "google-go.pkg.dev/golang" ]]; then
				go_tag="${tag}"
				echo "${go_tag}"
				break
			fi
		done)

	if [[ -z "${go_tag}" ]]; then
		echo "❌ Could not find golang image in Dockerfile: ${dockerfile}"
		return 1
	fi

	echo "${go_tag}"
	return 0
}

release-lib::idemp::manifests_bash_image_bump() {
	local dir=${1}
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	local values_file="${dir}/charts/values.global.yaml"
	# TODO: Not enough, this has to check actual manifests.
	local bash_tag=$(go tool yq '.images.bash.tag' "${values_file}")

	local latest_bash_tag=$(go tool gcrane ls "gke.gcr.io/gke-distroless/bash" --json | jq --raw-output '.tags[]' | grep "gke_distroless_" | sort -V | tail -n1)
	if [[ "${bash_tag}" == "${latest_bash_tag}" ]]; then
		echo "✅  Nothing to do; ${values_file} already uses ${latest_bash_tag}"
		return 0
	fi

	# Upgrade.
	echo "🔄  Ensuring ${latest_bash_tag} on ${values_file}..."
	if ! gsed -i -E "s#tag: ${bash_tag}#tag: ${latest_bash_tag}#g" "${values_file}"; then
		# TODO: This is flaky, no failing actually on no match. Common bug is
		echo "❌  sed didn't replace?"
		return 1
	fi

	# Regen only what's needed.
	release-lib::manifests_regen "${dir}"
	echo "✅  Done!"
	return 0
}

release-lib::manifests_regen() {
	local dir=${1}
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	source "${dir}/.bingo/variables.env"
	YQ="${YQ:-}" HELM="${HELM}" ADDLICENSE="${ADDLICENSE:-}" bash "${dir}/hack/presubmit.sh" manifests
	echo "✅  Manifests regenerated"
	return 0
}

# Accepts "FORCE_NEW_PATCH_VERSION"
release-lib::next_release_tag() {
	local dir=${1}
	if [[ -z "${dir}" ]]; then
		echo "❌  dir arg is required." >&2
		return 1
	fi

	pushd "${dir}"

	# Get the latest tag from the current branch's history
	# `git describe --tags --abbrev=0` finds the closest tag in the ancestry.
	local LATEST_TAG=""
	if ! LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null); then
		echo "❌ Error: No reachable tags found on this branch's history." >&2
		echo "Please ensure you have tags and have fetched them." >&2
		return 1
	fi

	# Apply bumping logic
	NEW_TAG=""
	if [[ "${LATEST_TAG}" == *"-rc."* && -z "${FORCE_NEW_PATCH_VERSION:-}" ]]; then
		# Get the part before "-rc." (e.g., "v1.2.3")
		BASE_VERSION="${LATEST_TAG%-rc.*}"
		# Get the part after "-rc." (e.g., "4")
		RC_NUMBER="${LATEST_TAG##*-rc.}"
		# Increment the RC number
		NEW_RC_NUMBER=$((RC_NUMBER + 1))

		NEW_TAG="${BASE_VERSION}-rc.${NEW_RC_NUMBER}"
	else
		# Preserve the 'v' prefix if it exists
		PREFIX=""
		if [[ "$LATEST_TAG" == v* ]]; then
			PREFIX="v"
		fi
		# Remove 'v' prefix for parsing (e.g., "1.2.3")
		VERSION_ONLY="${LATEST_TAG#v}"
		# Remove rc suffix, if exists.
		VERSION_ONLY="${VERSION_ONLY%-rc.*}"

		# Read major, minor, and patch into variables
		# We use a default of 0 for missing components
		IFS='.' read -r major minor patch <<<"$VERSION_ONLY"
		major=${major:-0}
		minor=${minor:-0}
		patch=${patch:-0}

		# Check that the patch version is a valid number
		if ! [[ "$patch" =~ ^[0-9]+$ ]]; then
			echo "❌ Error: Latest tag '$LATEST_TAG' does not have a numeric patch version (x.y.Z)." >&2
			return 1
		fi
		# Increment the patch number
		NEW_PATCH=$((patch + 1))
		NEW_TAG="${PREFIX}${major}.${minor}.${NEW_PATCH}-rc.0"
	fi

	popd

	echo "${NEW_TAG}"
	return 0
}
