#!/bin/bash

# Failsafe: Stop on errors and unset variables.
set -eu

# Env file
# AWS_S3_ENVFILE=${AWS_S3_ENVFILE:-""}

_verbose() {
  if [ "$S3FS_DEBUG" = "1" ]; then
    printf %s\\n "$1" >&2
  fi
}

_error() {
  printf %s\\n "$1" >&2
  exit 1
}

# This function checks for the existence of a specified Samba user and group. If the user does not exist, 
# it creates a new user with the provided username, user ID (UID), group name, group ID (GID), and password. 
# If the user already exists, it updates the user's UID and group association as necessary, 
# and updates the password in the Samba database. The function ensures that the group also exists, 
# creating it if necessary, and modifies the group ID if it differs from the provided value.
add_user() {
    local cfg="$1"
    local username="$2"
    local uid="$3"
    local groupname="$4"
    local gid="$5"
    local password="$6"
    local homedir="$7"

    # Check if the smb group exists, if not, create it
    if ! getent group "$groupname" &>/dev/null; then
        [[ "$groupname" != "smb" ]] && echo "Group $groupname does not exist, creating group..."
        groupadd -o -g "$gid" "$groupname" > /dev/null || { echo "Failed to create group $groupname"; return 1; }
    else
        # Check if the gid right,if not, change it
        local current_gid
        current_gid=$(getent group "$groupname" | cut -d: -f3)
        if [[ "$current_gid" != "$gid" ]]; then
            [[ "$groupname" != "smb" ]] && echo "Group $groupname exists but GID differs, updating GID..."
            groupmod -o -g "$gid" "$groupname" > /dev/null || { echo "Failed to update GID for group $groupname"; return 1; }
        fi
    fi

    # Check if the user already exists, if not, create it
    if ! id "$username" &>/dev/null; then
        [[ "$username" != "$SAMBA_USER" ]] && echo "User $username does not exist, creating user..."
        extra_args=()
        # Check if home directory already exists, if so do not create home during user creation
        if [ -d "$homedir" ]; then
          extra_args=("${extra_args[@]}" -H)
        fi
        adduser "${extra_args[@]}" -S -D -h "$homedir" -s /sbin/nologin -G "$groupname" -u "$uid" -g "Samba User" "$username" || { echo "Failed to create user $username"; return 1; }
    else
        # Check if the uid right,if not, change it
        local current_uid
        current_uid=$(id -u "$username")
        if [[ "$current_uid" != "$uid" ]]; then
            echo "User $username exists but UID differs, updating UID..."
            usermod -o -u "$uid" "$username" > /dev/null || { echo "Failed to update UID for user $username"; return 1; }
        fi

        # Update user's group
        usermod -g "$groupname" "$username" > /dev/null || { echo "Failed to update group for user $username"; return 1; }
    fi

    # Check if the user is a samba user
    pdb_output=$(pdbedit -s "$cfg" -L)  #Do not combine the two commands into one, as this could lead to issues with the execution order and proper passing of variables. 
    if echo "$pdb_output" | grep -q "^$username:"; then
        # If the user is a samba user, update its password in case it changed
        echo -e "$password\n$password" | smbpasswd -c "$cfg" -s "$username" > /dev/null || { echo "Failed to update Samba password for $username"; return 1; }
    else
        # If the user is not a samba user, create it and set a password
        echo -e "$password\n$password" | smbpasswd -a -c "$cfg" -s "$username" > /dev/null || { echo "Failed to add Samba user $username"; return 1; }
        [[ "$username" != "$SAMBA_USER" ]] && echo "User $username has been added to Samba and password set."
    fi

    return 0
}

SAMBA_ROOTDIR=${SAMBA_ROOTDIR:-"/opt/s3fs"}
SAMBA_SHARE=${SAMBA_SHARE:-"${SAMBA_ROOTDIR%/}/bucket"}
SAMBA_CONFIG=${SAMBA_CONFIG:-"/etc/samba/smb.conf"}
USERS_FILE=${USERS_FILE:-"/etc/samba/users.conf"}

# Check if config file is not a directory
if [ -d "$SAMBA_CONFIG" ]; then
    echo "The bind $SAMBA_CONFIG maps to a file that does not exist!"
    exit 1
fi

# Check if an external config file was supplied
if [ -f "$SAMBA_CONFIG" ] && [ -s "$SAMBA_CONFIG" ]; then

    # Inform the user we are using a custom configuration file.
    echo "Using provided configuration file: $SAMBA_CONFIG."

else

    SAMBA_CONFIG="/etc/samba/smb.tmp"
    template="/etc/samba/smb.default"

    if [ ! -f "$template" ]; then
      echo "Your /etc/samba directory does not contain a valid smb.conf file!"
      exit 1
    fi

    # Generate a config file from template
    rm -f "$SAMBA_CONFIG"
    cp "$template" "$SAMBA_CONFIG"

    # Set custom display name if provided
    if [ -n "$NAME" ] && [[ "${NAME,,}" != "data" ]]; then
      sed -i "s/\[Data\]/\[$NAME\]/" "$SAMBA_CONFIG"    
    fi

    # Update force user and force group in smb.conf
    sed -i "s/^\(\s*\)force user =.*/\1force user = $SAMBA_USER/" "$SAMBA_CONFIG"
    sed -i "s/^\(\s*\)force group =.*/\1force group = $SAMBA_GROUP/" "$SAMBA_CONFIG"

    # Verify if the RW variable is equal to false (indicating read-only mode) 
    if [[ "$RW" == [Ff0]* ]]; then
        # Adjust settings in smb.conf to set share to read-only
        sed -i "s/^\(\s*\)writable =.*/\1writable = no/" "$SAMBA_CONFIG"
        sed -i "s/^\(\s*\)read only =.*/\1read only = yes/" "$SAMBA_CONFIG"
    fi

fi


# Check if users file is not a directory
if [ -d "$USERS_FILE" ]; then

    echo "The file $USERS_FILE does not exist, please check that you mapped it to a valid path!"
    exit 1

fi

# Check if multi-user mode is enabled
if [ -f "$USERS_FILE" ] && [ -s "$USERS_FILE" ]; then

    while IFS= read -r line || [[ -n ${line} ]]; do

        # Skip lines that are comments or empty
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        # Split each line by colon and assign to variables
        IFS=':' read -r username uid groupname gid password homedir <<< "$line"

        # Check if all required fields are present
        if [[ -z "$username" || -z "$uid" || -z "$groupname" || -z "$gid" || -z "$password" ]]; then
            echo "Skipping incomplete line: $line"
            continue
        fi

        # Default homedir if not explicitly set for user
        [[ -z "$homedir" ]] && homedir="$SAMBA_SHARE"

        # Call the function with extracted values
        add_user "$SAMBA_CONFIG" "$username" "$uid" "$groupname" "$gid" "$password" "$homedir" || { echo "Failed to add user $username"; exit 1; }

    done < <(tr -d '\r' < "$USERS_FILE")

else

    add_user "$SAMBA_CONFIG" "$SAMBA_USER" "$SAMBA_UID" "$SAMBA_GROUP" "$SAMBA_GID" "$SAMBA_PASS" "$SAMBA_SHARE" || { echo "Failed to add user $SAMBA_USER"; exit 1; }

    if [[ "$RW" != [Ff0]* ]]; then
        # Set permissions for share directory if new (empty), leave untouched if otherwise
        if [ -z "$(ls -A "$SAMBA_SHARE")" ]; then
            chmod 0770 "$SAMBA_SHARE" || { echo "Failed to set permissions for directory $SAMBA_SHARE"; exit 1; }
            chown "$SAMBA_USER:$SAMBA_GROUP" "$SAMBA_SHARE" || { echo "Failed to set ownership for directory $SAMBA_SHARE"; exit 1; }
        fi
    fi

fi

# Store configuration location for Healthcheck
ln -sf "$SAMBA_CONFIG" /etc/samba.conf

# Set directory permissions
[ -d /run/samba/msg.lock ] && chmod -R 0755 /run/samba/msg.lock
[ -d /var/log/samba/cores ] && chmod -R 0700 /var/log/samba/cores
[ -d /var/cache/samba/msg.lock ] && chmod -R 0755 /var/cache/samba/msg.lock

_verbose "Executing smbd with config file $SAMBA_CONFIG"
smbd --configfile="$SAMBA_CONFIG" &

# # Read the content of the environment file, i.e. a file used to set the value of
# # all/some variables.
# if [ -n "$AWS_S3_ENVFILE" ]; then
#     # Read and export lines that set variables in all-caps and starting with
#     # S3FS_ or AWS_ from the configuration file. This is a security measure to
#     # crudly protect against evaluating some evil code (but it will still
#     # evaluate code as part of the value, so use it with care!)
#     _verbose "Reading configuration from $AWS_S3_ENVFILE"
#     while IFS= read -r line; do
#         eval export "$line"
#     done <<EOF
# $(grep -E '^(S3FS|AWS_S3)_[A-Z_]+=' "$AWS_S3_ENVFILE")
# EOF
# fi

# Debug
S3FS_DEBUG=${S3FS_DEBUG:-"0"}

# S3 main URL
AWS_S3_URL=${AWS_S3_URL:-"https://s3.amazonaws.com"}

# Root directory for settings and bucket.
AWS_S3_ROOTDIR=${AWS_S3_ROOTDIR:-"/opt/s3fs"}

# Where are we going to mount the remote bucket resource in our container.
AWS_S3_MOUNT=${AWS_S3_MOUNT:-"${AWS_S3_ROOTDIR%/}/bucket"}

# Authorisation details
AWS_S3_ACCESS_KEY_ID=${AWS_S3_ACCESS_KEY_ID:-""}
AWS_S3_SECRET_ACCESS_KEY=${AWS_S3_SECRET_ACCESS_KEY:-""}
AWS_S3_AUTHFILE=${AWS_S3_AUTHFILE:-""}

# Check variables and defaults
if [ -z "$AWS_S3_ACCESS_KEY_ID" ] && \
    [ -z "$AWS_S3_SECRET_ACCESS_KEY" ] && \
    [ -z "$AWS_S3_AUTHFILE" ]; then
    _error "You need to provide some credentials!!"
fi
if [ -z "${AWS_S3_BUCKET}" ]; then
    _error "No bucket name provided!"
fi

# Create or use authorisation file
if [ -z "${AWS_S3_AUTHFILE}" ]; then
    AWS_S3_AUTHFILE=${AWS_S3_ROOTDIR%/}/passwd-s3fs
    echo "${AWS_S3_ACCESS_KEY_ID}:${AWS_S3_SECRET_ACCESS_KEY}" > "${AWS_S3_AUTHFILE}"
    chmod 600 "${AWS_S3_AUTHFILE}"
fi

# Forget about the secret once done (this will have proper effects when the
# PASSWORD_FILE-version of the setting is used)
if [ -n "${AWS_S3_ACCESS_KEY_ID}" ]; then
    unset AWS_S3_ACCESS_KEY_ID
fi

# Forget about the secret once done (this will have proper effects when the
# PASSWORD_FILE-version of the setting is used)
if [ -n "${AWS_S3_SECRET_ACCESS_KEY}" ]; then
    unset AWS_S3_SECRET_ACCESS_KEY
fi

# Create destination directory if it does not exist.
if [ ! -d "$AWS_S3_MOUNT" ]; then
    mkdir -p "$AWS_S3_MOUNT"
fi

# Add a group, default to naming it after the GID when not found
GROUP_NAME=$(getent group "$GID" | cut -d":" -f1)
if [ "$GID" -gt 0 ] && [ -z "$GROUP_NAME" ]; then
    _verbose "Add group $GID"
    addgroup -g "$GID" -S "$GID"
    GROUP_NAME=$GID
fi

# Add a user, default to naming it after the UID.
RUN_AS=${RUN_AS:-""}
if [ "$UID" -gt 0 ]; then
    USER_NAME=$(getent passwd "$UID" | cut -d":" -f1)
    if [ -z "$USER_NAME" ]; then
        _verbose "Add user $UID, turning on rootless-mode"
        adduser -u "$UID" -D -G "$GROUP_NAME" "$UID"
    else
        _verbose "Running as user $UID, turning on rootless-mode"
    fi
    RUN_AS=$UID
    chown "${UID}:${GID}" "$AWS_S3_MOUNT" "${AWS_S3_AUTHFILE}" "$AWS_S3_ROOTDIR"
fi

# Debug options
DEBUG_OPTS=
if [ "$S3FS_DEBUG" = "1" ]; then
    DEBUG_OPTS="-d -d"
fi

# Additional S3FS options
if [ -n "$S3FS_ARGS" ]; then
    S3FS_ARGS="-o $S3FS_ARGS"
fi

# Start the Samba daemon with the following options:
#  --configfile: Location of the configuration file.
#  --foreground: Run in the foreground instead of daemonizing.
#  --debug-stdout: Send debug output to stdout.
#  --debuglevel=1: Set debug verbosity level to 1.
#  --no-process-group: Don't create a new process group for the daemon.
#  --foreground --debug-stdout --debuglevel=1 --no-process-group

# Mount as the requested used.
_verbose "Mounting bucket ${AWS_S3_BUCKET} onto ${AWS_S3_MOUNT}, owner: $UID:$GID"
su - $RUN_AS -c "s3fs $DEBUG_OPTS ${S3FS_ARGS} \
    -o passwd_file=${AWS_S3_AUTHFILE} \
    -o "url=${AWS_S3_URL}" \
    -o uid=$UID \
    -o gid=$GID \
    -o use_path_request_style \
    ${AWS_S3_BUCKET} ${AWS_S3_MOUNT}"

# s3fs can claim to have a mount even though it didn't succeed. Doing an
# operation actually forces it to detect that and remove the mount.
su - $RUN_AS -c "stat ${AWS_S3_MOUNT}"

if healthcheck.sh; then
    echo "Mounted bucket ${AWS_S3_BUCKET} onto ${AWS_S3_MOUNT}"
    exec "$@"
else
    _error "Mount failure"
fi
