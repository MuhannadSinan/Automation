# AWS Access Keys Auto Rotation Script v0.2

This script will rotate the AWS Access Keys automatically, which should be rotated regularly for security and compliance reasons.



**Before Running the script, we need to:**

1. Run the script in secure environment.
2. [`AWS CLI`](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and [`GitHub CLI`](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) installed.
3. Run the script with an IAM user that have `AdministratorAccess` policy.
4. Add the tag `AutoRotation:yes` to ONLY one IAM user that we want to rotate the Access Keys automatically.
5. Make sure that user has ONLY one active access key only. *(An error will occur if the user has more than two active keys)*
6. GitHub access token with `admin` rights to update the organization secrets.
7. A new secured S3 bucket. 

**The idea behind the script is simple:**

1. Looking for the user with the tag `AutoRotation:yes`.
2. Delete the inactive (old) access key (if exist).
3. Create a new access key.
4. Update the GitHub organization secrets with the new access key.
5. Set the old access key as inactive and keep it inactive until the next run.  *(this will help if we want to roll back to the old credentials)*
6. Backup the new access key to S3 bucket.
7. Clean the temporary local files.

> - The script will only rotate the access key for the user with tag `AutoRotation:yes`.
> - The user should have only a one active access key.
> - The script will only delete the inactive access keys.



```sh
#!/usr/bin/env bash
source <(curl -s https://raw.githubusercontent.com/fredpalmer/log4bash/master/log4bash.sh)

# This script will rotate AWS Access Keys automatically, which should be rotated regularly for security and compliance reasons
#
# usage: ./script.sh [-e PROD] [-o ResalApps] [-p default] [-b awsbucketname]
#
# optional arguments:
#   -e <UPPERCASE>  Enviromint prefix, this will be in GitHub secret name (e.g. PROD_AWS_ACCESS_KEY_ID)
#   -o              GitHub organization account, this will set organization secrets
#   -p              AWS profile, specify the profile that will run the commands
#   -b              AWS bucket name

# Default arguments, this will be used by default if you don't pass your arguments.
env_prefix=""
github_org="ResalApps"
aws_profile="default"
aws_bucket=""

# You can pass arguments, this will be used instead of the default arguments.
while getopts e:o:p:b: option; do
    case "${option}" in
    e) env_prefix=${OPTARG}_ ;;
    o) github_org=${OPTARG} ;;
    p) aws_profile=${OPTARG} ;;
    b) aws_bucket=${OPTARG} ;;
    esac
done

# TODO:
# - Add condition to check if the user have more than two active keys
# - add an option to pass the user name as an argument run bypass get_user_name() function
# - Add notification system

get_user_name() {
    log "Getting all users" >>logs.txt
    aws iam list-users \
    --query 'Users[].UserName' \
    --output text
}

access_key_status() {
    log "Getting access keys status" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user "${user}" \
    --query 'AccessKeyMetadata[].Status' \
    --output text
}

auto_rotation_tag() {
    log "Looking for AutoRotation:yes tag [ ${user} ]" >>logs.txt
    aws iam list-user-tags \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'Tags[?Key==`AutoRotation`].Value' \
    --output text
}

active_access_keys() {
    log "Looking for active access keys" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
    --output text
}

inactive_access_keys() {
    log "Looking for inactive access keys" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'AccessKeyMetadata[?Status==`Inactive`].AccessKeyId' \
    --output text
}

create_new_access_key() {
    log "Creating new access keys" >>logs.txt
    echo $(
        aws iam create-access-key \
        --profile ${aws_profile} \
        --user-name "${user}"
    ) >./temp
    log_success "A new access keys created successfully for the user ${user}" >>logs.txt
}

set_gh_secrets() {
    log "Setting GitHub secrets" >>logs.txt
    new_access_key_id=$(grep -o '"AccessKeyId": "[^"]*' ./temp | grep -o '[^"]*$')
    new_secret_access_key=$(grep -o '"SecretAccessKey": "[^"]*' ./temp | grep -o '[^"]*$')
    gh secret set --org ${github_org} ${env_prefix}AWS_ACCESS_KEY_ID --body ${new_access_key_id}
    gh secret set --org ${github_org} ${env_prefix}AWS_SECRET_ACCESS_KEY --body ${new_secret_access_key}
    log_success "GitHub secrets updated for the user ${user}" >>logs.txt
}

backup_to_s3_bucket() {
    if [ -z "$aws_bucket" ]; then
        log_error "No S3 bucket is set!" >>logs.txt
    else
        log "Backup the new AWS Access Key to S3 bucket" >>logs.txt
        file_name=${env_prefix}${user}_$(date +%F_%T).txt
        echo -e "[${user}]\n${env_prefix}AWS_ACCESS_KEY_ID = ${new_access_key_id}\n${env_prefix}AWS_SECRET_ACCESS_KEY = ${new_secret_access_key}" >./$file_name
        aws s3 cp --profile ${aws_profile} ./$file_name s3://${aws_bucket}/$file_name
        log_success "Backup file uploaded to S3 bucket for the user ${user}" >>logs.txt
        rm $file_name
    fi
}

deactivate_old_access_key() {
    log_warning "Deactivating the old access key [$1]" >>logs.txt
    aws iam update-access-key \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --access-key-id "$1" \
    --status Inactive
    log_success "The old access key [$1] is deactivated for the user ${user}" >>logs.txt
}

delete_old_access_key() {
    log_warning "Deleting old access key [$1]" >>logs.txt
    aws iam delete-access-key \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --access-key-id "$1"
    log_success "The old access key [$1] is Deleted for the user ${user}" >>logs.txt
}

# The Magic Starts Here!
log "-------------------| Sart |-------------------" >>logs.txt
for user in $(get_user_name); do
    if [ "$(auto_rotation_tag)" = "Yes" ]; then
        log "--------------[ ${user} ]--------------" >>logs.txt
        if [[ "$(access_key_status)" == *"Inactive"* ]]; then
            log "Inactive access key found for user ${user}" >>logs.txt
            inactive_access_key="$(inactive_access_keys)"
            delete_old_access_key "${inactive_access_key}"
        fi
        if [[ "$(access_key_status)" == *"Active"* ]]; then
            log "Active access key found for user ${user}" >>logs.txt
            active_access_key="$(active_access_keys)"
            create_new_access_key
            set_gh_secrets
            deactivate_old_access_key "${active_access_key}"
            backup_to_s3_bucket
        fi
    fi
done

# Cleanup
log "Cleanup" >>logs.txt
rm temp
log "-------------------| Done |-------------------" >>logs.txt

```

V0.2