#!/bin/bash
# Bash strict mode: http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -eo pipefail


tabname() {
  printf "\e]1;$1\a"
}

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
NC=$(tput sgr0) # No Color

print_manual_instructions(){
  COMMAND=$1
  echo -e "\nTo inspect the now running dev environment open a new tab/terminal and run:"
  echo "    $COMMAND"
}

PRINT_WARNING=true
new_tab() {
  TAB_NAME=$1
  COMMAND=$2

  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [ -x "$(command -v gnome-terminal)" ]; then
      gnome-terminal \
      --tab --title="$TAB_NAME" --working-directory="$(pwd)" -- /bin/bash -c "$COMMAND"
    else
      if $PRINT_WARNING; then
          echo -e "\n${YELLOW}./dev.sh WARNING${NC}: gnome-terminal is the only currently supported way of opening
          multiple tabs/terminals for linux by this script, add support for your setup!"
          PRINT_WARNING=false
      fi
      print_manual_instructions "$COMMAND"
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    osascript \
        -e "tell application \"Terminal\"" \
        -e "tell application \"System Events\" to keystroke \"t\" using {command down}" \
        -e "do script \"printf '\\\e]1;$TAB_NAME\\\a'; $COMMAND\" in front window" \
        -e "end tell" > /dev/null
  else
    if $PRINT_WARNING; then
        echo -e "\n${WARNING}./dev.sh WARNING${NC}: The OS '$OSTYPE' is not supported yet for creating tabs to setup
        baserow's dev environment, please add support!"
        PRINT_WARNING=false
    fi
    print_manual_instructions "$COMMAND"
  fi
}

launch_tab_and_attach(){
  tab_name=$1
  service_name=$2
  container_name=$(docker inspect -f '{{.Name}}' "$(docker-compose ps -q "$service_name")" | cut -c2-)
  command="docker logs $container_name && docker attach $container_name"
  new_tab "$tab_name" "$command"
}

launch_tab_and_exec(){
  tab_name=$1
  service_name=$2
  exec_command=$3
  container_name=$(docker inspect -f '{{.Name}}' "$(docker-compose ps -q "$service_name")" | cut -c2-)
  command="docker exec -it $container_name $exec_command"
  new_tab "$tab_name" "$command"
}

show_help() {
    echo """
./dev.sh wraps a docker-compose command with the correct config files and environment
variables for running Baserow in dev mode. It provides a few extra custom flags but
all other arguments will be passed through to docker-compose.

Example usage:
- ./dev.sh up --build
- ./dev.sh da build
- ./dev.sh da run --no-deps -T backend lint

By default ./dev.sh will also attempt to open terminal tabs which are attached to
the running dev containers, use the da flag to disable this.

Usage: ./dev.sh [optional custom dev.sh flags] [commands passed to docker-compose]

The ./dev.sh custom flags are:
dont_attach     : Don't attach to the running dev containers after starting them.
da              : Shortcut for dont_attach.
dont_migrate    : Disable automatic database migration on baserow startup.
dont_sync       : Disable automatic template sync on baserow startup.
ignore_ownership: Don't exit if there are files in the repo owned by a different user.
help            : Show this message.
"""
}

dont_attach=false
up=true
migrate=true
sync_templates=true
exit_if_other_owners_found=true
delete_db_volume=false
up_down_restart=false
while true; do
case "${1:-noneleft}" in
    dont_migrate)
        echo "./dev.sh: Automatic migration on startup has been disabled."
        shift
        migrate=false
    ;;
    dont_sync)
        echo "./dev.sh: Automatic template syncing on startup has been disabled."
        shift
        sync_templates=false
    ;;
    dont_attach | da)
        echo "./dev.sh: Configured to not attach to running dev containers."
        shift
        dont_attach=true
    ;;
    wipe_db)
        echo "./dev.sh: Will wipe baserow's postgres database volume pg_data if exists."
        shift
        delete_db_volume=true
    ;;
    restart)
        echo "./dev.sh: Will restart baserow using separate up and down commands, any extra parameters will only be passed to the up."
        shift
        up_down_restart=true
    ;;
    restart_wipe)
        echo "./dev.sh: Will restart and wipe baserow's postgres database volume pg_data if exists."
        shift
        delete_db_volume=true
        up_down_restart=true
    ;;
    ignore_ownership)
        echo "./dev.sh: Continuing if files in repo are not owned by $USER."
        shift
        exit_if_other_owners_found=false
    ;;
    help)
        show_help
        exit 0
    ;;
    *)
        break
    ;;
esac
done

OWNERS=$(find . ! -user "$USER")

if [[ $OWNERS ]]; then
if [[ "$exit_if_other_owners_found" = true ]]; then
echo "${RED}./dev.sh ERROR${NC}: Files not owned by your current user: $USER found in this repo.
This will cause file permission errors when Baserow starts up.

They are probably build files created by the old Baserow Docker images owned by root.
Run the following command to show which files are causing this:
  find . ! -user $USER

Please run the following command to fix file permissions in this repository before using ./dev.sh:
  ${GREEN}sudo chown $USER -R .${NC}

OR you can ignore this check by running with the ignore_ownership arg:
  ${YELLOW}./dev.sh ignore_ownership ...${NC}"
exit;
else

echo "${YELLOW}./dev.sh WARNING${NC}: Files not owned by your current user: $USER found in this repo.
Continuing as 'ignore_ownership' argument provided."
fi

fi

# Set various env variables to sensible defaults if they have not already been set by
# the user.
if [[ -z "$UID" ]]; then
UID=$(id -u)
fi
export UID

if [[ -z "$GID" ]]; then
GID=$(id -g)
fi
export GID


if [[ -z "${MIGRATE_ON_STARTUP:-}" ]]; then
if [ "$migrate" = true ] ; then
export MIGRATE_ON_STARTUP="true"
else
# Because of the defaults set in the docker-compose file we need to explicitly turn
# this off as just not setting it will get the default "true" value.
export MIGRATE_ON_STARTUP="false"
fi
else
  echo "./dev.sh Using the already set value for the env variable MIGRATE_ON_STARTUP = $MIGRATE_ON_STARTUP"
fi

if [[ -z "${SYNC_TEMPLATES_ON_STARTUP:-}" ]]; then
if [ "$sync_templates" = true ] ; then
export SYNC_TEMPLATES_ON_STARTUP="true"
else
# Because of the defaults set in the docker-compose file we need to explicitly turn
# this off as just not setting it will get the default "true" value.
export SYNC_TEMPLATES_ON_STARTUP="false"
fi
else
  echo "./dev.sh Using the already set value for the env variable SYNC_TEMPLATES_ON_STARTUP = $SYNC_TEMPLATES_ON_STARTUP"
fi

# Enable buildkit for faster builds with better caching.
export COMPOSE_DOCKER_CLI_BUILD=1
export DOCKER_BUILDKIT=1

echo "./dev.sh running docker-compose commands:
------------------------------------------------
"

ARGS=$*
if [ "$ARGS" = down ] ; then
  echo "${YELLOW}./dev.sh Replacing down with 'rm --stop -v --force' to clean up any anonymous volumes.${NC}"
  ARGS="rm --stop -v --force"
fi

if [ "$dont_attach" != true ] ; then
  if [[ "$ARGS" = up* ]] || [[ "$ARGS" = start* ]] || [[ "$up_down_restart" = true ]]; then
    if [[ ! "$ARGS" = .*" -d ".* ]] ; then
      echo "${YELLOW}./dev.sh appending -d, disable with dont_attach.${NC}"
      # Ensure we are upping/starting in detached mode so we can attach correctly.
      ARGS="$ARGS -d"
    fi
  else
    # Don't attempt to attach if we aren't doing a start or up
    dont_attach=true
  fi
fi

if [[ "$up_down_restart" = true ]] ; then
  docker-compose -f docker-compose.yml -f docker-compose.dev.yml rm --stop -v --force
  ARGS="up $ARGS"
fi

if [ "$delete_db_volume" = true ] ; then
  docker volume rm baserow_pgdata || true;
fi

set -x
# shellcheck disable=SC2086
docker-compose -f docker-compose.yml -f docker-compose.dev.yml $ARGS
set +x

if [ "$dont_attach" != true ]; then

  launch_tab_and_attach "backend" "backend"
  launch_tab_and_attach "web frontend" "web-frontend"
  launch_tab_and_attach "celery" "celery"
  launch_tab_and_attach "export worker" "celery-export-worker"
  launch_tab_and_attach "beat worker" "celery-beat-worker"

  launch_tab_and_exec "web frontend lint" \
          "web-frontend" \
          "/bin/bash /baserow/web-frontend/docker/docker-entrypoint.sh lint-fix"
  launch_tab_and_exec "backend lint" \
          "backend" \
          "/bin/bash /baserow/backend/docker/docker-entrypoint.sh lint-shell"
fi
