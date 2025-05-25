#!/usr/bin/env bash

DEBUG="${DEBUG:-0}"
CI=${CI:-}

# When CI is not set, we assume we are running locally and set DRY_RUN to true
# its still possible to to set DRY_RUN=0 to disable dry run
if [[ -n "$CI" ]]; then
  DRY_RUN="${DRY_RUN:-0}"
else
  DRY_RUN="${DRY_RUN:-1}"
fi

continue_on_any_key () {
  echo "${1:-Press any key to continue...}"
  read -n 1 -s
}

echo "DRY_RUN=$DRY_RUN"
echo "CI=$CI"
echo "DEBUG=$DEBUG"

continue_on_any_key

cleanup () {
  dry_run_echo "GITHUB_STEP_SUMMARY" "$(cat $GITHUB_STEP_SUMMARY)"
  dry_run_echo "GITHUB_OUTPUT" "$(cat $GITHUB_OUTPUT)"
  echo "GITHUB_OUTPUT=$GITHUB_OUTPUT"
  echo "GITHUB_STEP_SUMMARY=$GITHUB_STEP_SUMMARY"
}

# Cleanup before exit
trap 'cleanup' EXIT

__dirname="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

FLY_ORG=${FLY_ORG:-"forge42-base-stack-development"}
echo "FLY_ORG=$FLY_ORG"
FLY_REGION=${FLY_REGION:-"fra"}
echo "FLY_REGION=$FLY_REGION"

# Those are the inputs to our action:
echo "INPUTS:"
declare -rg INPUT_APP_NAME_PREFIX="${INPUT_APP_NAME_PREFIX:-}"
echo "INPUT_APP_NAME_PREFIX=$INPUT_APP_NAME_PREFIX"
declare -rg INPUT_WORKSPACE_NAME="${INPUT_WORKSPACE_NAME:-}"
echo "INPUT_WORKSPACE_NAME=$INPUT_WORKSPACE_NAME"
declare -rg INPUT_APP_NAME="${INPUT_APP_NAME:-}"
echo "INPUT_APP_NAME=$INPUT_APP_NAME"
declare -rg INPUT_CONFIG_FILE_PATH="${INPUT_CONFIG_FILE_PATH:-}"
echo "INPUT_CONFIG_FILE_PATH=$INPUT_CONFIG_FILE_PATH"
declare -rg INPUT_ATTACH_CONSUL="${INPUT_ATTACH_CONSUL:-}"
echo "INPUT_ATTACH_CONSUL=$INPUT_ATTACH_CONSUL"
declare -rg INPUT_USE_ISOLATED_WORKSPACE="${INPUT_USE_ISOLATED_WORKSPACE:-}"
echo "INPUT_USE_ISOLATED_WORKSPACE=$INPUT_USE_ISOLATED_WORKSPACE"
declare -rg INPUT_ENV_VARS="${INPUT_ENV_VARS:-}"
echo "INPUT_ENV_VARS=$INPUT_ENV_VARS"
declare -rg INPUT_SECRETS="${INPUT_SECRETS:-}"
echo "INPUT_SECRETS=$INPUT_SECRETS"
declare -rg INPUT_BUILD_ARGS="${INPUT_BUILD_ARGS:-}"
echo "INPUT_BUILD_ARGS=$INPUT_BUILD_ARGS"
declare -rg INPUT_BUILD_SECRETS="${INPUT_BUILD_SECRETS:-}"
echo "INPUT_BUILD_SECRETS=$INPUT_BUILD_SECRETS"
continue_on_any_key

# Create some temporary files so we can test and see the output locally
declare -g GITHUB_OUTPUT="${GITHUB_OUTPUT:-$(mktemp)}"
declare -g GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-$(mktemp)}"

# Set some required defaults when running locally.
# These are set by the GitHub Actions environment usually.
# @see: https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/store-information-in-variables#default-environment-variables
echo "Setting up environment variables for local testing..."
declare -rg GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-pull_request}"
echo "GITHUB_EVENT_NAME=$GITHUB_EVENT_NAME"
declare -rg GITHUB_REF_NAME="${GITHUB_REF_NAME:-some-feature-branch}"
echo "GITHUB_REF_NAME=$GITHUB_REF_NAME"
declare -rg GITHUB_REF_TYPE="${GITHUB_REF_TYPE:-branch}"
echo "GITHUB_REF_TYPE=$GITHUB_REF_TYPE"
declare -rg GITHUB_SHA="${GITHUB_SHA:-abcde42eee4d0b74fcae7adf4b00a08c9cd9e122}"
echo "GITHUB_SHA=$GITHUB_SHA"
# GITHUB_EVENT_PATH is the path to the event payload file, which is usually set by GitHub Actions. We use a mock file for testing.
declare -rg GITHUB_EVENT_PATH="${GITHUB_EVENT_PATH:-"${__dirname}/mocks/${GITHUB_EVENT_NAME}.json"}"
echo "GITHUB_EVENT_PATH=$GITHUB_EVENT_PATH"
declare -rg GITHUB_WORKSPACE="$(pwd)"
echo "GITHUB_WORKSPACE=$GITHUB_WORKSPACE"
continue_on_any_key "Continue with running the actual deployment script?"

source "$__dirname/../entrypoint.sh"
