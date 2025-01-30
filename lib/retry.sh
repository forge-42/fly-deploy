# Exponential backoff retry function
# retry <retries:integer> <base sleep time in seconds:integer> <"group name":string> <command...>
retry () {
  local retries=$1
  shift
  local base=$1
  shift
  local group_name=$1
  shift

  local count=1

  group "Try '$group_name ($count/$retries)'."
  if [[ "$DRY_RUN" == "1" ]]; then
    dry_run_echo "$group_name ($count/$retries)" $@
  else
    echo -e "Using command: '$@'"
    until "$@"; do
      local exit=$?

      error "'$group_name ($count/$retries)' exited with '$exit'."
      group_end

      count=$(($count + 1))
      local wait=$(($base ** $count))

      if [ $count -le $retries ]; then
        warning "Retry '$group_name ($count/$retries)' in '$wait' seconds."
        sleep $wait
        group "Retry '$group_name ($count/$retries)'."
        debug "Using command: '$@'"
      else
        # ($retries/$retries) is not a bug, it is on purpose, since the else branch is executed only if $count is greater than $retries
        error "No more retries left for '$group_name ($retries/$retries)'. Exiting with exit code '$exit'."
        return $exit
      fi
    done
  fi

  notice "'$group_name ($count/$retries)' succeeded."

  group_end

  return 0
}
