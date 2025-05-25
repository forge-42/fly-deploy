#!/usr/bin/env bash
# Deploy the app to fly.io

DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"

# Debug mode: Show commands and fail on any unbound variables
if [[ "$DEBUG" == "1" ]]; then
  set -xu -eE -o pipefail
  echo "DEBUG MODE: ON"
  echo "flyctl VERSION: $(flyctl --version)"
  echo "ENVIRONMENT VARIABLES: $(env | sort)"
else
  # Non-debug mode: Exit on any failure
  set -eE -o pipefail
fi

__dirname="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$__dirname/lib/helper.sh"
source "$__dirname/lib/process-inputs.sh"
source "$__dirname/lib/retry.sh"

# Process all the "inputs" like env vars set by GitHub Actions (GITHUB_*) and action inputs (INPUT_*)
# this will also set the output variables for the the actual action logic in this file.
process_inputs

# Some sanity checks.
# If those output variables are empty, we exit with an error, since we can't proceed anyways.
if [[
     -z "$WORKSPACE_NAME"
  || -z "$WORKSPACE_PATH_RELATIVE"
  || -z "$WORKSPACE_PATH"
  || -z "$FLY_ORG"
  || -z "$APP_NAME"
  || -z "$CONFIG_FILE_PATH"
  || -z "$ATTACH_CONSUL"
  || -z "$USE_ISOLATED_WORKSPACE"
  || -z "$PRIVATE"
  ]]; then
  error "Something went wrong processing the necessary information needed for the deployment."
  exit 1
fi

if ! does_fly_app_exist "$APP_NAME"; then
  declare -rg fly_apps_create_command="flyctl apps create $APP_NAME --org $FLY_ORG"
  retry 3 3 "Create fly app '$APP_NAME'" $fly_apps_create_command
else
  notice "App '$APP_NAME' already exists, skipping creation."
fi

if [[ -n "$SECRETS" ]]; then
  group "Set '$SECRETS_COUNT' secrets on $APP_NAME: '$SECRETS_NAMES'"
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_echo "flyctl secrets import" "$SECRETS_NAMES"
  else
    echo "$SECRETS" | flyctl secrets import --stage --app "$APP_NAME";
  fi
  group_end
else
  warning "No secrets set for '$APP_NAME', will not attach any secrets therefore. If thats intentional, its safe to ignore this warning.";
fi

# Attach a consul cluster if requested (required when using SQLite with litefs)
if [[ "$ATTACH_CONSUL" == "true" ]]; then
  declare -rg fly_consul_attach_command="flyctl consul attach --app $APP_NAME"
  retry 3 3 "Attaching a consul cluster to $APP_NAME" $fly_consul_attach_command
fi

if [[ "$USE_ISOLATED_WORKSPACE" == "true" ]]; then
  notice "Setting current working directory to '$WORKSPACE_PATH_RELATIVE' (effectively: '$WORKSPACE_PATH')"
  cd "$WORKSPACE_PATH"
fi

if [[ -n "$ENV_VARS_ARGUMENTS" ]]; then
  notice "Will set '$ENV_VARS_COUNT' environment variables on '$APP_NAME': '$ENV_VARS_NAMES'"
fi

if [[ -n "$BUILD_ARGS_ARGUMENTS" ]]; then
  notice "Will add '$BUILD_ARGS_COUNT' additional custom build-args on '$APP_NAME': '$BUILD_ARGS_NAMES'"
fi

if [[ -n "$BUILD_SECRETS_ARGUMENTS" ]]; then
  notice "Will add '$BUILD_SECRETS_COUNT' custom build-secrets on '$APP_NAME': '$BUILD_SECRETS_NAMES'"
fi

if [[ "$PRIVATE" == "true" ]]; then
  notice "Will deploy as private flycast app. The app will not be reachable from the internet, without a WireGuard connection to the flycast network."
fi

declare -rg fly_deploy_command="flyctl deploy \
    --deploy-retries=3 \
    --config $CONFIG_FILE_PATH \
    --app $APP_NAME \
    $ENV_VARS_ARGUMENTS \
    $BUILD_ARGS_ARGUMENTS \
    $BUILD_SECRETS_ARGUMENTS \
    $PRIVATE_ARGUMENTS \
    --remote-only \
    --yes"

# Deploy the app to fly.io
retry 3 3 "Deploy the app" $fly_deploy_command

if [[ "$DRY_RUN" == "0" ]]; then
  declare -rg fly_status_file="./fly-status.json"
  declare -rg fly_ips_list_file="./fly-ips-list.json"
  flyctl status --app "$APP_NAME" --json > $fly_status_file
  flyctl ips list --app "$APP_NAME" --json > $fly_ips_list_file
else
  declare -rg fly_status_file="$__dirname/test/mocks/fly-status.json"
  declare -rg fly_ips_list_file="$__dirname/test/mocks/fly-ips-list.json"
fi

if [[ "$PRIVATE" == "true" ]]; then
  declare -rg app_hostname="$APP_NAME.flycast"
  declare -rg app_url="http://$app_hostname"
else
  declare -rg app_hostname=$(jq -r '.Hostname' $fly_status_file)
  declare -rg app_url="https://$app_hostname"
fi

declare -rg app_id=$(jq -r '.ID' $fly_status_file)
declare -rg machine_names=$(jq -r '[.Machines[].name] | join(",")' $fly_status_file)
declare -rg machine_ids=$(jq -r '[.Machines[].id] | join(",")' $fly_status_file)

declare -rg public_ips=$(jq -r '[.[] | select(.Type == "shared_v4" or .Type == "v4" or .Type == "v6") | .Address] | join(",")' $fly_ips_list_file)
declare -rg private_ips=$(jq -r '[.[] | select(.Type == "private_v6") | .Address] | join(",")' $fly_ips_list_file)

notice app_hostname=$app_hostname
echo "app_hostname=$app_hostname" >> $GITHUB_OUTPUT

notice app_url=$app_url
echo "app_url=https://$app_hostname" >> $GITHUB_OUTPUT

notice app_id=$app_id
echo "app_id=$app_id" >> $GITHUB_OUTPUT

notice machine_names=$machine_names
echo "machine_names=$machine_names" >> $GITHUB_OUTPUT

notice machine_ids=$machine_ids
echo "machine_ids=$machine_ids" >> $GITHUB_OUTPUT

notice public_ips=$public_ips
echo "public_ips=$public_ips" >> $GITHUB_OUTPUT

notice private_ips=$private_ips
echo "private_ips=$private_ips" >> $GITHUB_OUTPUT

notice app_name=$APP_NAME
echo "app_name=$APP_NAME" >> $GITHUB_OUTPUT

notice workspace_name=$WORKSPACE_NAME
echo "workspace_name=$WORKSPACE_NAME" >> $GITHUB_OUTPUT

notice workspace_path=$WORKSPACE_PATH_RELATIVE
echo "workspace_path=$WORKSPACE_PATH_RELATIVE" >> $GITHUB_OUTPUT

echo "### Deployed ${APP_NAME} :rocket:" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo "App URL: $app_url" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo "Fly Dashboard: https://fly.io/apps/$APP_NAME" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo "Live Logs: https://fly.io/apps/$APP_NAME/monitoring" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo -e "\`\`\`\nfly logs --app $APP_NAME\n\`\`\`\n" >> $GITHUB_STEP_SUMMARY
if [[ "$PRIVATE" == "true" ]]; then
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "This is a private network only app. To access it, you need to create a WireGuard connection to '$FLY_ORG' by running \`fly wireguard create\`." >> $GITHUB_STEP_SUMMARY
  echo -e "\`\`\`\nfly wireguard create \"$FLY_ORG\" \"$FLY_REGION\" \"\$(whoami)-\$(hostname -s')-${FLY_ORG}\" \"\$(whoami)-\$(hostname -s)-${FLY_ORG}-wireguard.conf\"\n\`\`\`\n" >> $GITHUB_STEP_SUMMARY
fi
