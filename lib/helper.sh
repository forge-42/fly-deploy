group () { echo "${CI:+::group::}$1"; }
group_end () { echo "${CI:+::endgroup::}"; }
debug () { echo "${CI:+::debug::}$1"; }
notice () { echo "${CI:+::notice::}$1"; }
warning () { echo "${CI:+::warning::}$1"; }
error () { echo "${CI:+::error::}$1"; }
dry_run_echo () {
  local message="$1"
  shift
  echo -e "\n👇👇 $message 👇👇"
  echo -e "$@"
  echo -e "👆👆 $message 👆👆\n"
}
continue_on_any_key () {
  echo "${1:-Press any key to continue...}"
  read -n 1 -s
}

list_assoc_array () {
  local -n assoc_array_ref=$1
  local key
  echo "$1 (${#assoc_array_ref[@]}):"
  for key in "${!assoc_array_ref[@]}"
  do
    echo -e "  $key: '${assoc_array_ref[$key]}'"
  done
}

json_to_assoc_array () {
  local assoc_array_name=$1
  local -n assoc_array_ref=$1
  local json="${2}"
  local assoc_array_def=$(echo "$json" | jq -r '. | paths(type == "string" or type == "number" or type == "boolean") as $p | [($p|map(tostring)|join("_")), getpath($p)] | { (.[0]): .[1] }' | jq -rs "add | to_entries | map(\"${assoc_array_name}[\\\"\(.key)\\\"]=\\\"\(.value)\\\";\") | .[]")
  eval "$assoc_array_def"
}

# Truncate a semver to a specific part
# truncate_semver "1.2.3" "patch"      # 1.2.0
# truncate_semver "1.2.3" "minor"      # 1.0.0
# truncate_semver "~1.2.3" "minor"     # 1.0.0
# truncate_semver "^1.2.3" "minor"     # 1.0.0
# truncate_semver ">=1.2.3" "minor"    # 1.0.0
# truncate_semver "~1.2.3"             # 1.2.3
# truncate_semver "^1.2.3"             # 1.2.3
# truncate_semver ">= 1.2.3"           # 1.2.3
truncate_semver () {
  local truncate_part=${2:-}
  truncate_part=${truncate_part,,}
  local version="$(echo $1 | sed 's/^[^0-9]*//')"
  if [[ -z "$version" ]]; then
    echo $1
    return 0
  fi
  local IFS='.'
  read -r major minor patch <<< "$version"
  if [[ "$truncate_part" == "patch" ]]; then
    echo "$major.$minor.0"
  elif [[ "$truncate_part" == "minor" ]]; then
    echo "$major.0.0"
  else
    echo "$major.$minor.$patch"
  fi
  return 0
}

# Check if the app already exists
does_fly_app_exist () {
  flyctl status --app "$1" > /dev/null 2>&1
  return $?
}
