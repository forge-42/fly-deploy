
process_inputs () {
  group "Prepare deploy variables"

  # Enable globstar to allow ** globs which is needed in this function
  shopt -s globstar

  if [[ -z "$INPUT_WORKSPACE_NAME" ]]; then
    notice "workspace_name not set. Using current directory as workspace_path and 'name' from ./package.json as workspace_name"
    local workspace_path_relative="."
    local workspace_path="$(pwd)"
    local workspace_name="$(jq -rS '.name' ./package.json)"
  else
    local found_workspace="$(grep -rls "\"name\":.*\"$INPUT_WORKSPACE_NAME\"" **/package.json | xargs -I {} dirname {})"
    if [[ -z "$found_workspace" ]]; then
      error "No workspace with name '$INPUT_WORKSPACE_NAME' found."
      return 1
    fi
    local workspace_path_relative="$found_workspace"
    local workspace_path="$(cd "$found_workspace" && pwd)"
    local workspace_name="$INPUT_WORKSPACE_NAME"
  fi

  debug "workspace_name=$workspace_name"
  debug "workspace_path=$workspace_path"
  debug "workspace_path_relative=$workspace_path_relative"

  debug "GITHUB_EVENT_NAME=$GITHUB_EVENT_NAME"
  debug "GITHUB_REF_TYPE=$GITHUB_REF_TYPE"
  debug "GITHUB_REF_NAME=$GITHUB_REF_NAME"
  debug "GITHUB_EVENT_PATH=$GITHUB_EVENT_PATH"
  debug "GITHUB_REPOSITORY=$GITHUB_REPOSITORY"
  debug "GITHUB_SHA=$GITHUB_SHA"
  debug "GITHUB_WORKSPACE=$GITHUB_WORKSPACE"

  # GITHUB_REPOSITORY is the full owner and repository in the form of "owner/repository-name"
  local default_app_name_prefix="${GITHUB_REPOSITORY}"

  # If the workspace is in the root of the repository, use only the repository owner part as prefix instead of owner/repository
  # This is to avoid conflicts with the package.json name and the repository owner/repository name
  if [[ "${workspace_path_relative}" == "." ]]; then
    default_app_name_prefix="${GITHUB_REPOSITORY_OWNER}"
  fi

  if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
    local pr_number=$(jq -r .number $GITHUB_EVENT_PATH)
    local default_app_name="${default_app_name_prefix}-${workspace_name}-pr-${pr_number}"
  elif [[ "${GITHUB_EVENT_NAME}" == "push" || "${GITHUB_EVENT_NAME}" == "create" ]]; then
    local default_app_name="${default_app_name_prefix}-${workspace_name}-${GITHUB_REF_TYPE}-${GITHUB_REF_NAME}"
  else
    warning "Unhandled GITHUB_EVENT_NAME '${GITHUB_EVENT_NAME}'. Considering setting 'app_name' as input."
    local default_app_name="${default_app_name_prefix}-${workspace_name}-${GITHUB_EVENT_NAME}"
  fi
  debug "default_app_name=$default_app_name"

  local raw_app_name="${INPUT_APP_NAME:-$default_app_name}"
  if [[ -z "$raw_app_name" ]]; then
    error "Default for 'app_name' could not be generated for github event '${GITHUB_EVENT_NAME}'. Please set 'app_name' as input."
    return 1
  fi

  local app_name="$(echo $raw_app_name | sed 's/[\.\/_]/-/g; s/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]')"
  if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
    local pr_number=$(jq -r .number $GITHUB_EVENT_PATH)
    debug "pr_number=$pr_number"
    if [[ $app_name != *"$pr_number"* ]]; then
      error "For pull requests, the 'app_name' must contain the pull request number."
      return 1
    fi
  fi
  debug "app_name=$app_name"

  if [[ -z "$INPUT_CONFIG_FILE_PATH" ]]; then
    notice "config_file_path NOT set. Using workspace_path='$workspace_path' and 'fly.toml' as default."
    local raw_config_file_path="$workspace_path/fly.toml"
  else
    local raw_config_file_path="$workspace_path/$INPUT_CONFIG_FILE_PATH"
  fi

  local config_file_path="$(realpath -e "$raw_config_file_path")"
  if [[ -z "$config_file_path" ]]; then
    error "Could not resolve config_file_path: '$raw_config_file_path'"
    return 1
  fi
  debug "config_file_path=$config_file_path"

  if [ "${GITHUB_EVENT_NAME}" == "pull_request" ]; then
    local pr_event_type=$(jq -r .action $GITHUB_EVENT_PATH)
    if [[ "$pr_event_type" == "closed" ]]; then
      error "PR closed event not supported by this action yet."
      exit 1
    fi
    local pull_request_head_sha=$(jq -r .pull_request.head.sha $GITHUB_EVENT_PATH)
    local git_commit_sha="${pull_request_head_sha}"
  else
    local git_commit_sha="${GITHUB_SHA}"
  fi
  debug "git_commit_sha=$git_commit_sha"

  git config --global --add safe.directory $GITHUB_WORKSPACE
  local git_commit_sha_short="$(git rev-parse --short $git_commit_sha)"
  debug "git_commit_sha_short=$git_commit_sha_short"

  if [[ "${INPUT_ATTACH_CONSUL,,}" != "true" ]]; then
    local attach_consul="false"
  else
    local attach_consul="true"
  fi

  # If no postgres attach is requested, we default to false
  local attach_existing_postgres=""
  local attach_postgres="false"
  local attach_postgres_name=""

  # Attaching an existing postgres cluster takes precedence over creating a new one
  if [[ -n "$INPUT_ATTACH_EXISTING_POSTGRES" ]]; then
    attach_existing_postgres="${INPUT_ATTACH_EXISTING_POSTGRES,,}" # lowercase postgres fly app name
  elif [[ "${INPUT_ATTACH_POSTGRES,,}" == "true" ]]; then
    attach_postgres="true"
    attach_postgres_name="${app_name,,}-postgres"
  fi

  if [[ -z "$INPUT_USE_ISOLATED_WORKSPACE" ]]; then
    local use_isolated_workspace="false"
  else
    local use_isolated_workspace="${INPUT_USE_ISOLATED_WORKSPACE,,}"
  fi

  if [[ "${INPUT_PRIVATE,,}" == "true" ]]; then
    local private="true"
    local private_arguments="--flycast --no-public-ips"
  else
    local private="false"
    local private_arguments=""
  fi

  if [[ -n "$INPUT_SECRETS" ]]; then
    # We intentionally separate each secret by a new line, thats how fly secrets import expects it
    local secrets="$(echo "$INPUT_SECRETS" | tr ' ' '\n' | tr -s '[:space:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local secrets_count="$(echo $secrets | tr ' ' '\n' | wc -l)"
    local secrets_names="$(echo "$secrets" | tr '\n' ' ' | sed 's/=[^ ]*//g')"
    debug "secrets='${secrets}'"
    debug "secrets_count='${secrets_count}'"
    debug "secrets_names='${secrets_names}'"
  else
    local secrets=""
    local secrets_count="0"
    local secrets_names=""
  fi

  if [[ -n "$INPUT_ENV_VARS" ]]; then
    local env_vars="$(echo "$INPUT_ENV_VARS" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local env_vars_count="$(echo $env_vars | tr ' ' '\n' | wc -l)"
    local env_vars_names="$(echo "$env_vars" | sed 's/=[^ ]*//g')"
    debug "env_vars='${env_vars}'"
    debug "env_vars_count='${env_vars_count}'"
    debug "env_vars_names='${env_vars_names}'"

    local env_vars_arguments=""
    # Split the input string into an array
    IFS=" " read -r -a env_vars_arguments_array <<< "$env_vars"
    # Loop through each element in the array
    for element in "${env_vars_arguments_array[@]}"; do
      # Append '--env ' and the element to the output string
      env_vars_arguments+="--env $element " # dont remove the trailing space here, or the world will end
    done
    # Trim the trailing space
    env_vars_arguments="${env_vars_arguments% }"
    debug "env_vars_arguments=$env_vars_arguments"
  else
    local env_vars=""
    local env_vars_count="0"
    local env_vars_names=""
    local env_vars_arguments=""
  fi

  local package_json_path="./package.json"
  if [[ "$use_isolated_workspace" == "true" ]]; then
    package_json_path="$WORKSPACE_PATH/package.json"
  fi

  local node_version=$(truncate_semver $(jq -r '.engines.node // ""' $package_json_path))
  local npm_version=$(truncate_semver $(jq -r '.engines.npm // ""' $package_json_path))
  local pnpm_version=$(truncate_semver $(jq -r '.engines.pnpm // ""' $package_json_path))
  local yarn_version=$(truncate_semver $(jq -r '.engines.yarn // ""' $package_json_path))
  local turbo_version=$(truncate_semver $(jq -r '.devDependencies.turbo // ""' $package_json_path))

  local build_args_arguments=""
  if [[ -n "$node_version" ]]; then
    build_args_arguments+="--build-arg NODE_VERSION=$node_version "
  fi
  if [[ -n "$npm_version" ]]; then
    build_args_arguments+="--build-arg NPM_VERSION=$npm_version "
  fi
  if [[ -n "$pnpm_version" ]]; then
    build_args_arguments+="--build-arg PNPM_VERSION=$pnpm_version "
  fi
  if [[ -n "$yarn_version" ]]; then
    build_args_arguments+="--build-arg YARN_VERSION=$yarn_version "
  fi
  if [[ -n "$turbo_version" ]]; then
    build_args_arguments+="--build-arg TURBO_VERSION=$turbo_version "
  fi

  build_args_arguments+="--build-arg WORKSPACE_NAME=$workspace_name "
  build_args_arguments+="--build-arg WORKSPACE_PATH=$workspace_path_relative "
  build_args_arguments+="--build-arg GIT_COMMIT_SHA=$git_commit_sha "
  build_args_arguments+="--build-arg GIT_COMMIT_SHA_SHORT=$git_commit_sha_short "

  if [[ -n "$INPUT_BUILD_ARGS" ]]; then
    local build_args="$(echo "$INPUT_BUILD_ARGS" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local build_args_count="$(echo $build_args | tr ' ' '\n' | wc -l)"
    local build_args_names="$(echo "$build_args" | sed 's/=[^ ]*//g')"
    debug "build_args='${build_args}'"
    debug "build_args_count='${build_args_count}'"
    debug "build_args_names='${build_args_names}'"

    # Split the input string into an array
    IFS=" " read -r -a build_args_arguments_array <<< "$build_args"
    # Loop through each element in the array
    for element in "${build_args_arguments_array[@]}"; do
      # Append '--build-arg ' and the element to the output string
      build_args_arguments+="--build-arg $element " # dont remove the trailing space here, or a zombie apocalypse will begin
    done
  else
    local build_args=""
    local build_args_count="0"
    local build_args_names=""
  fi

  # Trim the trailing space
  build_args_arguments="${build_args_arguments% }"
  debug "build_args_arguments=$build_args_arguments"


  if [[ -n "$INPUT_BUILD_SECRETS" ]]; then
    local build_secrets="$(echo "$INPUT_BUILD_SECRETS" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local build_secrets_count="$(echo $build_secrets | tr ' ' '\n' | wc -l)"
    local build_secrets_names="$(echo "$build_secrets" | sed 's/=[^ ]*//g')"
    debug "build_secrets='${build_secrets}'"
    debug "build_secrets_count='${build_secrets_count}'"
    debug "build_secrets_names='${build_secrets_names}'"

    # Split the input string into an array
    IFS=" " read -r -a build_secrets_arguments_array <<< "$build_secrets"
    # Loop through each element in the array
    for element in "${build_secrets_arguments_array[@]}"; do
      # Append '--build-arg ' and the element to the output string
      build_secrets_arguments+="--build-secret $element " # dont remove the trailing space here, or a zombie apocalypse will begin
    done
  else
    local build_secrets=""
    local build_secrets_count="0"
    local build_secrets_names=""
  fi

  # Trim the trailing space
  build_secrets_arguments="${build_secrets_arguments% }"
  debug "build_secrets_arguments=$build_secrets_arguments"

  # Disable globstar again to avoid problems with the ** glob
  shopt -u globstar

  # After processing all "inputs" like env vars set by GitHub Actions (GITHUB_*) and action inputs (INPUT_*)
  # we can now set the "outputs" for the the actual action logic (entrypoint.sh).
  # These are readonly but globally available in the entrypoint.sh script, and you should only use these.
  declare -rg WORKSPACE_NAME="$workspace_name"
  declare -rg WORKSPACE_PATH="$workspace_path"
  declare -rg WORKSPACE_PATH_RELATIVE="$workspace_path_relative"
  declare -rg APP_NAME="$app_name"
  declare -rg ATTACH_CONSUL="$attach_consul"
  declare -rg PRIVATE="$private"
  declare -rg PRIVATE_ARGUMENTS="$private_arguments"
  declare -rg ATTACH_POSTGRES="$attach_postgres"
  declare -rg ATTACH_POSTGRES_NAME="$attach_postgres_name"
  declare -rg ATTACH_EXISTING_POSTGRES="$attach_existing_postgres"
  declare -rg SECRETS="$secrets"
  declare -rg SECRETS_COUNT="$secrets_count"
  declare -rg SECRETS_NAMES="$secrets_names"
  declare -rg ENV_VARS_COUNT="$env_vars_count"
  declare -rg ENV_VARS_NAMES="$env_vars_names"
  declare -rg ENV_VARS_ARGUMENTS="$env_vars_arguments"
  declare -rg BUILD_ARGS_COUNT="$build_args_count"
  declare -rg BUILD_ARGS_NAMES="$build_args_names"
  declare -rg BUILD_ARGS_ARGUMENTS="$build_args_arguments"
  declare -rg BUILD_SECRETS_COUNT="$build_secrets_count"
  declare -rg BUILD_SECRETS_NAMES="$build_secrets_names"
  declare -rg BUILD_SECRETS_ARGUMENTS="$build_secrets_arguments"
  declare -rg USE_ISOLATED_WORKSPACE="$use_isolated_workspace"
  declare -rg CONFIG_FILE_PATH="$config_file_path"

  debug "WORKSPACE_NAME=$WORKSPACE_NAME"
  debug "WORKSPACE_PATH=$WORKSPACE_PATH"
  debug "WORKSPACE_PATH_RELATIVE=$WORKSPACE_PATH_RELATIVE"
  debug "FLY_ORG=$FLY_ORG"
  debug "SECRETS_COUNT=$SECRETS_COUNT"
  debug "SECRETS_NAMES=$SECRETS_NAMES"
  debug "ENV_VARS_COUNT=$ENV_VARS_COUNT"
  debug "ENV_VARS_NAMES=$ENV_VARS_NAMES"
  debug "ENV_VARS_ARGUMENTS=$ENV_VARS_ARGUMENTS"
  debug "BUILD_ARGS_COUNT=$BUILD_ARGS_COUNT"
  debug "BUILD_ARGS_NAMES=$BUILD_ARGS_NAMES"
  debug "BUILD_ARGS_ARGUMENTS=$BUILD_ARGS_ARGUMENTS"
  debug "BUILD_SECRETS_COUNT=$BUILD_SECRETS_COUNT"
  debug "BUILD_SECRETS_NAMES=$BUILD_SECRETS_NAMES"
  debug "APP_NAME=$APP_NAME"
  debug "ATTACH_CONSUL=$ATTACH_CONSUL"
  debug "PRIVATE=$PRIVATE"
  debug "PRIVATE_ARGUMENTS=$PRIVATE_ARGUMENTS"
  debug "ATTACH_POSTGRES=$ATTACH_POSTGRES"
  debug "ATTACH_POSTGRES_NAME=$ATTACH_POSTGRES_NAME"
  debug "ATTACH_EXISTING_POSTGRES=$ATTACH_EXISTING_POSTGRES"
  debug "USE_ISOLATED_WORKSPACE=$USE_ISOLATED_WORKSPACE"
  debug "CONFIG_FILE_PATH=$CONFIG_FILE_PATH"

  group_end
}
