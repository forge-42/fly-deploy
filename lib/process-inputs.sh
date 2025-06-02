
process_inputs () {
  group "Prepare deploy variables"

  # Enable globstar to allow ** globs which is needed in this function
  shopt -s globstar

  # When workspace_name is not set, we assume the current "root" directory of the repository is the workspace_path
  # and we use the "name" from the package.json in that directory as workspace_name.
  if [[ -z "$INPUT_WORKSPACE_NAME" ]]; then
    notice "workspace_name not set. Using current working directory '.' as workspace_path and 'name' from ./package.json as workspace_name"
    local workspace_path_relative="."
    local workspace_path="$(pwd)"
    local workspace_name="$(jq -rS '.name' ./package.json)"

  # When workspace_name is set, we search in any package.json for the given name and use the directory of that package.json as workspace_path.
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
  debug "GITHUB_SHA=$GITHUB_SHA"

  # Handle if the user wants to set a custom prefix (like $GITHUB_REPOSITORY_OWNER or $GITHUB_REPOSITORY) for the app name
  local default_app_name_prefix=""
  if [[ -n "$INPUT_APP_NAME_PREFIX" ]]; then
    default_app_name_prefix="${INPUT_APP_NAME_PREFIX,,}"
  fi
  debug "default_app_name_prefix=$default_app_name_prefix"

  # Handle if the user wants to set a custom suffix (like "production", "pre-production", etc.) for the app name
  local default_app_name_suffix=""
  if [[ -n "$INPUT_APP_NAME_SUFFIX" ]]; then
    default_app_name_suffix="${INPUT_APP_NAME_SUFFIX,,}"
  fi
  debug "default_app_name_suffix=$default_app_name_suffix"

  if [[ "${GITHUB_EVENT_NAME,,}" == "pull_request" ]]; then
    local pr_number=$(jq -r .number $GITHUB_EVENT_PATH)
    local default_app_name="${workspace_name}-pr-${pr_number}"
  elif [[ "${GITHUB_EVENT_NAME,,}" == "push" || "${GITHUB_EVENT_NAME,,}" == "create" ]]; then
    # <workspace_name>-<ref_type>-<ref_name>
    # e.g. base-stack-branch-bug/some-bugfix
    # e.g. base-stack-branch-main
    # e.g. base-stack-tag-v1.0.0
    local default_app_name="${workspace_name}-${GITHUB_REF_TYPE}-${GITHUB_REF_NAME}"
  elif [[ "${GITHUB_EVENT_NAME,,}" == "workflow_dispatch" ]]; then
    local default_app_name="${workspace_name}"
  else
    if [[ -z "$INPUT_APP_NAME" ]]; then
      # If no app_name is set, we show a warning that even is unhandled and generated default app_name might not be what the user expects.
      warning "Unhandled GITHUB_EVENT_NAME '${GITHUB_EVENT_NAME}'. Considering setting 'app_name' as input."
    fi
    local default_app_name="${workspace_name}-${GITHUB_EVENT_NAME}"
  fi

  # If the user has set a prefix for the app name, we prepend it to the beginning of default app name.
  if [[ -n "$default_app_name_prefix" ]]; then
    default_app_name="${default_app_name_prefix}-${default_app_name}"
  fi

  # If the user has set a suffix for the app name, we append it to the end of the default app name.
  if [[ -n "$default_app_name_suffix" ]]; then
    default_app_name="${default_app_name}-${default_app_name_suffix}"
  fi
  debug "default_app_name=$default_app_name"

  local raw_app_name="${INPUT_APP_NAME:-$default_app_name}"
  # Just a sanity check that we have any value for raw_app_name, should not happen at this point, but better safe than sorry.
  if [[ -z "$raw_app_name" ]]; then
    error "Default for 'app_name' could not be generated for github event '${GITHUB_EVENT_NAME}'. Please set 'app_name' as input."
    return 1
  fi

  # Replace all dots, slashes and underscores with dashes, remove all other non-alphanumeric characters and convert to lowercase.
  # This is needed to ensure the app_name is valid for Fly.io and does not contain any invalid characters.
  # In the end app_name needs to be a valid URL subdomain: <app_name>.fly.dev
  # for example:
  # base-stack-tag-v1.0.0 gets converted to base-stack-tag-v1-0-0
  # base-stack-branch-bug/some-bugfix gets converted to base-stack-branch-bug-some-bugfix
  local app_name="$(echo $raw_app_name | sed 's/[\.\/_]/-/g; s/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]')"

  # Sanity check if the final app_name contains the pull request number when the event is a pull request.
  # This is needed to ensure the app_name is unique for each pull request and does not conflict with other branches or tags.
  if [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
    local pr_number=$(jq -r .number $GITHUB_EVENT_PATH)
    debug "pr_number=$pr_number"
    if [[ $app_name != *"$pr_number"* ]]; then
      error "For pull requests, the 'app_name' must contain the pull request number."
      return 1
    fi
  fi
  debug "app_name=$app_name"

  # config file path is relative to the workspace_path, so we need to resolve it to an absolute path.
  if [[ -z "$INPUT_CONFIG_FILE_PATH" ]]; then
    local raw_config_file_path="$workspace_path/fly.toml"
    notice "config_file_path NOT set. Trying to use fallback '${workspace_path_relative}/fly.toml'."
  else
    local raw_config_file_path="$workspace_path/$INPUT_CONFIG_FILE_PATH"
  fi

  # realpath -e resolves the path to an absolute path and actually checks if the file really exists, not just if the path is valid.
  local config_file_path="$(realpath -e "$raw_config_file_path")"
  if [[ -z "$config_file_path" ]]; then
    error "Could not resolve config_file_path: '$raw_config_file_path'"
    return 1
  fi
  debug "config_file_path=$config_file_path"

  if [ "${GITHUB_EVENT_NAME,,}" == "pull_request" ]; then
    local pr_event_type=$(jq -r .action $GITHUB_EVENT_PATH)
    if [[ "$pr_event_type" == "closed" ]]; then
      error "PR closed event not supported by this action. Use 'https://github.com/forge-42/fly-destroy' action instead."
      exit 1
    fi
    local pull_request_head_sha=$(jq -r .pull_request.head.sha $GITHUB_EVENT_PATH)
    # We need the HEAD commit SHA of the pull request, which is the commit that is being tested in the pull request.
    local git_sha="${pull_request_head_sha}"
  else
    local git_sha="${GITHUB_SHA}"
  fi
  debug "git_sha=$git_sha"

  if [[ "${INPUT_ATTACH_CONSUL,,}" != "true" ]]; then
    local attach_consul="false"
  else
    local attach_consul="true"
  fi

  # Isolated workspace is used if your actual deployment is in a subdirectory of the repository and should
  # be treated as a separate workspace. This is useful for docs, or example apps that are in a subdirectory of the repository.
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
  local nx_version=$(truncate_semver $(jq -r '.dependencies.nx // ""' $package_json_path))

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
  if [[ -n "$nx_version" ]]; then
    build_args_arguments+="--build-arg NX_VERSION=$nx_version "
  fi

  # This is not the fly.io app name. The user might want to use this for other purposes, whenever they need a unique identifier for the app during the build.
  build_args_arguments+="--build-arg APP_NAME=$app_name "
  build_args_arguments+="--build-arg WORKSPACE_NAME=$workspace_name "
  build_args_arguments+="--build-arg WORKSPACE_PATH=$workspace_path_relative "
  build_args_arguments+="--build-arg GIT_SHA=$git_sha "

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

  local deploy_wait_timeout_argument=""
  if [[ "$INPUT_DEPLOY_WAIT_TIMEOUT" =~ ^[0-9]+$ ]];then
    deploy_wait_timeout_argument="--wait-timeout ${INPUT_DEPLOY_WAIT_TIMEOUT}m"
  fi

  local deploy_strategy_argument=""
  if [[ "${INPUT_DEPLOY_IMMEDIATELY,,}" == "true" ]];then
    deploy_strategy_argument="--strategy immediate"
  fi

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
  declare -rg DEPLOY_WAIT_TIMEOUT_ARGUMENT="$deploy_wait_timeout_argument"
  declare -rg DEPLOY_STRATEGY_ARGUMENT="$deploy_strategy_argument"
  declare -rg FLY_DEPLOY_RETRIES="3"

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
  debug "USE_ISOLATED_WORKSPACE=$USE_ISOLATED_WORKSPACE"
  debug "CONFIG_FILE_PATH=$CONFIG_FILE_PATH"
  debug "DEPLOY_WAIT_TIMEOUT_ARGUMENT=$DEPLOY_WAIT_TIMEOUT_ARGUMENT"
  debug "DEPLOY_STRATEGY_ARGUMENT=$DEPLOY_STRATEGY_ARGUMENT"
  debug "FLY_DEPLOY_RETRIES=$FLY_DEPLOY_RETRIES"

  group_end
}
