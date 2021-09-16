#!/bin/sh
set -o pipefail

CONFIG_FILE=".deploy-now/deploy-now-config.yml"
DEPLOY_TYPE_BOOTSTRAP="bootstrap"
DEPLOY_TYPE_REGULAR="regular"

FORCE_BOOTSTRAP="false"
if [[ -f $CONFIG_FILE ]] ; then
  FB_FILTER=".deploy.force-bootstrap"
  if [[ $FB_FILTER -eq "true" ]] ; then
    FORCE_BOOTSTRAP="true"
  fi
fi

FORCE_REGULAR="false"
if [[ -f $CONFIG_FILE ]] ; then
  FR_FILTER=".deploy.force-regular"
  if [[ FR_FILTER -eq "true" ]] ; then
    FORCE_REGULAR="true"
  fi
fi

DEPLOY_TYPE=$DEPLOY_TYPE_REGULAR
if [[ $FORCE_BOOTSTRAP -eq "true" ]] | [[ $BOOTSTRAP_DEPLOY -eq "true" ]] ; then
  DEPLOY_TYPE=$DEPLOY_TYPE_BOOTSTRAP
fi
if [[ $FORCE_REGULAR -eq "true" ]] ; then
  DEPLOY_TYPE=$DEPLOY_TYPE_REGULAR
fi
echo "Used deployment type: ($DEPLOY_TYPE)"



EXCLUDE_DIRECTORIES=""
if [[ -f $CONFIG_FILE ]] ; then
  ED_FILTER=".deploy.excluded_directories"
  if [[ "$(yq e -o=json $CONFIG_FILE | jq $ED_FILTER)" != "null" ]] ; then
    CURRENT_IFS=$IFS
    IFS=$'\n'
    for LINE in $(yq e -o=json $CONFIG_FILE | jq $ED_FILTER | jq -r '.[]'); do
      EXCLUDE_DIRECTORIES="$EXCLUDE_DIRECTORIES --exclude=$LINE"
    done
    IFS=${CURRENT_IFS}
  fi
fi

deployment_size=$(du -s -B1 --exclude=.deploy-now --exclude=.git --exclude=.github $EXCLUDE_DIRECTORIES $DIST_FOLDER | cut -f 1)

if [[ $deployment_size -gt $STORAGE_QUOTA ]] ; then
  echo "The deployment is larger ($deployment_size) than the allowed quota ($STORAGE_QUOTA)"
  exit 1
fi



password=$(pwgen -s 30 1)

create_temporary_user() {
  counter=$1
  if [[ $counter -eq 0 ]] ; then
    echo "Failed to create temporary user" 1>&2
    exit 1
  fi
  username=$(http POST https://$SERVICE_HOST/v1/projects/$PROJECT/branches/$BRANCH_ID/users password=$password Authorization:"API-Key $API_KEY" --ignore-stdin --check-status | jq -r .username)

  if [[ $? -eq 5 ]] ; then
    echo "Retry creating temporary user in 1 second" 1>&2
    sleep 1
    create_temporary_user $(($counter - 1))
  fi
  echo $username
}
export USERNAME=$(create_temporary_user 3)

echo "Created temporary user: $USERNAME"

export SSHPASS=$password



if [[ -f $CONFIG_FILE ]] ; then
  PD_FILTER=".deploy.persistent_directories"
  if [[ "$(yq e -o=json $CONFIG_FILE | jq $PD_FILTER)" != "null" ]] ; then
    yq e -o=json $CONFIG_FILE | jq $PD_FILTER | jq -r '.[]' | rsync -av --rsh="/usr/bin/sshpass -e ssh -o StrictHostKeyChecking=no" --files-from=/dev/stdin -r --ignore-existing $DIST_FOLDER $USERNAME@$REMOTE_HOST:
  fi
fi

echo "rsync -av --delete --exclude=logs --rsh=\"/usr/bin/sshpass -e ssh -o StrictHostKeyChecking=no\" --exclude=.deploy-now --exclude=.git --exclude=.github $EXCLUDE_DIRECTORIES $DIST_FOLDER $USERNAME@$REMOTE_HOST:"
rsync -av --delete --exclude=logs --rsh="/usr/bin/sshpass -e ssh -o StrictHostKeyChecking=no" --exclude=.deploy-now --exclude=.git --exclude=.github $EXCLUDE_DIRECTORIES $DIST_FOLDER $USERNAME@$REMOTE_HOST:

if [[ $? -gt 0 ]] ; then
  echo "rsync Failure"
  exit 1
fi



if [[ -f $CONFIG_FILE ]] ; then
  RC_FILTER=".deploy.remote_commands"
  if [[ "$(yq e -o=json $CONFIG_FILE | jq $RC_FILTER)" != "null" ]] ; then
    set -o noglob
    yq e -o=json $CONFIG_FILE | jq $RC_FILTER | jq -r '.[]' | while read -r LINE
    do
      echo "Running the remote command: $LINE"
      /usr/bin/sshpass -e ssh -o StrictHostKeyChecking=no $USERNAME@$REMOTE_HOST "$LINE"
      if [[ $? -gt 0 ]] ; then
        echo "Error running the remote command"
        exit 1
      fi
    done
    set +o noglob
  fi
fi



http PUT https://$SERVICE_HOST/v1/projects/$PROJECT/branches/$BRANCH_ID/hooks/DEPLOYED Authorization:"API-Key $API_KEY"
