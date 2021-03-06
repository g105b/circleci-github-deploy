#!/bin/bash
if [ $# -lt 1 ];
then
	echo "Error: Not enough arguments."
	echo "Usage: deploy production|staging|issue"
	exit 1
fi

CFG_TMP_PATH="/tmp/deploy"
CFG_DEPLOY_BASE_PATH="/var/deploy"
CFG_DEPLOY_BASE_PATH_PROD="$CFG_DEPLOY_BASE_PATH"
CFG_FILES_PATH="/var/deploy/files"
CFG_FILES_PATH_PROD="$CFG_FILES_PATH"
CFG_CONFIG_PATH="/var/deploy/config"
CFG_CONFIG_PATH_PROD="$CFG_CONFIG_PATH"
: ${DISTRIBUTION_DIRECTORY:=$CIRCLE_PROJECT_REPONAME}
: ${CFG_LOCAL_PATH:="config.ini"}
: ${POST_COPY_COMMAND:="echo 'no post-copy command'"}

# Overwrite the configurable variables with any set in config.ini .
if [ -a $CFG_LOCAL_PATH ]; then
	VALUE=$(awk -F "=" '/deploy_tmp_path=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_TMP_PATH=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_base_path=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_DEPLOY_BASE_PATH=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_base_path_prod=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_DEPLOY_BASE_PATH_PROD=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_files_path=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_FILES_PATH=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_files_path_prod=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_FILES_PATH_PROD=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_config_path=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_CONFIG_PATH=$VALUE
	fi

	VALUE=$(awk -F "=" '/deploy_config_path_prod=/ {print $2}' $CFG_LOCAL_PATH)
	if [ ! -z $VALUE ]; then
		CFG_CONFIG_PATH_PROD=$VALUE
	fi
fi

DEPLOY_TYPE_TAG="deploy-type-tag"
DEPLOY_TYPE_BRANCH="deploy-type-branch"
DEPLOY_TYPE=""
DEPLOY_REF=""
DEPLOY_PATH="$CFG_DEPLOY_BASE_PATH/$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME"

case $1 in
"production")
	DEPLOY_TYPE=$DEPLOY_TYPE_TAG
	DEPLOY_REF="$CIRCLE_TAG"
	DEPLOY_PATH="$CFG_DEPLOY_BASE_PATH_PROD/$CIRCLE_PROJECT_REPONAME"
	CFG_FILES_PATH="$CFG_FILES_PATH_PROD"
	CFG_CONFIG_PATH="$CFG_CONFIG_PATH_PROD"
	;;
"staging")
	DEPLOY_TYPE=$DEPLOY_TYPE_BRANCH
	DEPLOY_REF="master"
	DEPLOY_PATH="$DEPLOY_PATH/$DEPLOY_REF"
	;;
"issue")
	DEPLOY_TYPE=$DEPLOY_TYPE_BRANCH
	DEPLOY_REF="$CIRCLE_BRANCH"
	DEPLOY_PATH="$DEPLOY_PATH/$DEPLOY_REF"
	;;
*)
	echo "Invalid deployment type '$1'."
	exit 1
	;;
esac

case $DEPLOY_TYPE in
$DEPLOY_TYPE_TAG)
	SSH_CONNECTION=$(awk -F "=" '/ssh_production/ {print $2}' $CFG_LOCAL_PATH)
	;;
$DEPLOY_TYPE_BRANCH)
	SSH_CONNECTION=$(awk -F "=" '/ssh_staging/ {print $2}' $CFG_LOCAL_PATH)
	;;
esac

# stream to tmp directory first; this avoids downtime during stream.
TMPDIR=$CFG_TMP_PATH
REMOTE_SSH_TAR_COMMAND="rm -rf $TMPDIR; mkdir -p $TMPDIR; cd $TMPDIR; tar xzf -"
CMD_SSH_TAR="ssh $SSH_CONNECTION '$REMOTE_SSH_TAR_COMMAND'"
# Circle will execute this script within the repo directory.
cd ..
# Perform tar stream. "-" file indicates a redirect via pipe.
echo "Executing: tar czf - '$DISTRIBUTION_DIRECTORY/' | eval $CMD_SSH_TAR"
tar czf - "$DISTRIBUTION_DIRECTORY/" | eval $CMD_SSH_TAR

# Copy any deployment files over the new deployment.
DEPLOY_FILES_PATH="$CFG_FILES_PATH/$CIRCLE_PROJECT_REPONAME"
CMD_SSH_FILES="cp -R $DEPLOY_FILES_PATH/* $TMPDIR/$CIRCLE_PROJECT_REPONAME"

# Replace any lines from config over the new deployment.
DEPLOY_CONFIG_PATH="$CFG_CONFIG_PATH/$CIRCLE_PROJECT_REPONAME"
CMD_CONFIG_REPLACE="wget -O $TMPDIR/replace-config.php https://raw.githubusercontent.com/g105b/github-deploy/master/replace-config.php && DEPLOY_REF=$DEPLOY_REF php $TMPDIR/replace-config.php $DEPLOY_CONFIG_PATH $TMPDIR/$CIRCLE_PROJECT_REPONAME && mv $TMPDIR/replace-config.php $TMPDIR/replace-config.php.old"

# In production, backup old directory is not used. Remove any old deployed files instead.
CMD_BACKUP="rm -rf $DEPLOY_PATH/*"
if [ "$1" != "production" ]; then
	CMD_BACKUP="if [ -d $DEPLOY_PATH ]; then rm -rf $DEPLOY_PATH.old; mv $DEPLOY_PATH $DEPLOY_PATH.old; fi"
fi

# Move the completed stream to the correct deploy path.
CMD_MOVE_DEPLOYMENT="mkdir -p $DEPLOY_PATH; cp -R $TMPDIR/$CIRCLE_PROJECT_REPONAME/* $DEPLOY_PATH"

MIGRATION_SCRIPT_PATH="$DEPLOY_PATH/vendor/bin/db-migrate"
CMD_MIGRATION="if [ -a $MIGRATION_SCRIPT_PATH ]; then $MIGRATION_SCRIPT_PATH; fi"
CMD_MIGRATION="echo 'skipping auto migration'"
SELF_PATH="$DEPLOY_PATH/deploy.sh"
CMD_SELF_DESTRUCT="if [ -a $SELF_PATH ]; then rm $SELF_PATH; fi"

echo "1: $CMD_SSH_FILES"
echo "1a: $POST_COPY_COMMAND"
echo "2: $CMD_BACKUP"
echo "3: $CMD_CONFIG_REPLACE"
echo "4: $CMD_MOVE_DEPLOYMENT"
#echo "5: $CMD_MIGRATION"
echo "SKIPPED: Migration step"
echo "6: $CMD_SELF_DESTRUCT"

CMD_FINAL="ssh $SSH_CONNECTION 'set -e; echo 1; $CMD_SSH_FILES; echo 1a; $POST_COPY_COMMAND; echo 2; $CMD_BACKUP; echo 3; $CMD_CONFIG_REPLACE; echo 4; $CMD_MOVE_DEPLOYMENT; echo 5; $CMD_MIGRATION; echo 6; $CMD_SELF_DESTRUCT'"

# Perform all commands in one connection to minimise downtime.
eval "$CMD_FINAL"
