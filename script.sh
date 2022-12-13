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

get_user_name() {
    log "Getting all users" >>logs.txt
    aws iam list-users \
    --query 'Users[].UserName' \
    --output text
}

access_key_status() {
    log "Getting access key status [${user}]" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user "${user}" \
    --query 'AccessKeyMetadata[].Status' \
    --output text
}

auto_rotation_tag() {
    log "Looking for AutoRotation:yes tag [${user}]" >>logs.txt
    aws iam list-user-tags \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'Tags[?Key==`AutoRotation`].Value' \
    --output text
}

active_access_keys() {
    log "Looking for active access keys [${user}]" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
    --output text
}

inactive_access_keys() {
    log "Looking for inactive access keys [${user}]" >>logs.txt
    aws iam list-access-keys \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --query 'AccessKeyMetadata[?Status==`Inactive`].AccessKeyId' \
    --output text
}

create_new_access_key() {
    log "Creating new access keys [${user}]" >>logs.txt
    echo $(
        aws iam create-access-key \
        --profile ${aws_profile} \
        --user-name "${user}"
    ) >./temp
    log_success "Creating new access keys [${user}]" >>logs.txt
}

set_gh_secrets() {
    log "Setting GitHub secrets [${user}]" >>logs.txt
    new_access_key_id=$(grep -o '"AccessKeyId": "[^"]*' ./temp | grep -o '[^"]*$')
    new_secret_access_key=$(grep -o '"SecretAccessKey": "[^"]*' ./temp | grep -o '[^"]*$')
    gh secret set --org ${github_org} ${env_prefix}AWS_ACCESS_KEY_ID --body ${new_access_key_id}
    gh secret set --org ${github_org} ${env_prefix}AWS_SECRET_ACCESS_KEY --body ${new_secret_access_key}
    log_success "Setting GitHub secrets [${user}]" >>logs.txt
}

backup_to_s3_bucket() {
    if [ -z "$aws_bucket" ]; then
        log_error "No S3 bucket is set!" >>logs.txt
    else
        log "Backup to S3 bucket [${user}]" >>logs.txt
        file_name=${env_prefix}${user}_$(date +%F_%T).txt
        echo -e "[${user}]\n${env_prefix}AWS_ACCESS_KEY_ID = ${new_access_key_id}\n${env_prefix}AWS_SECRET_ACCESS_KEY = ${new_secret_access_key}" >./$file_name
        aws s3 cp --profile ${aws_profile} ./$file_name s3://${aws_bucket}/$file_name
        log_success "Backup to S3 bucket [${user}]" >>logs.txt
        rm $file_name
    fi
}

deactivate_old_access_key() {
    log_warning "Deactivating old access key [$1] for the user [${user}]" >>logs.txt
    aws iam update-access-key \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --access-key-id "$1" \
    --status Inactive
    log_success "Deactivating old access key [$1] for the user [${user}]" >>logs.txt
}

delete_old_access_key() {
    log_warning "Deleting old access key [$1] for the user [${user}]" >>logs.txt
    aws iam delete-access-key \
    --profile ${aws_profile} \
    --user-name "${user}" \
    --access-key-id "$1"
    log_success "Deleting old access key [$1] for the user [${user}]" >>logs.txt
}

log "----------------| Sart |----------------" >>logs.txt
for user in $(get_user_name); do
    if [ "$(auto_rotation_tag)" = "Yes" ]; then
        log "Tag AutoRotation:yes found for user [${user}]" >>logs.txt
        if [[ "$(access_key_status)" == *"Inactive"* ]]; then
            log "Inactive access key found for user [${user}]" >>logs.txt
            inactive_access_key="$(inactive_access_keys)"
            delete_old_access_key "${inactive_access_key}"
        fi
        if [[ "$(access_key_status)" == *"Active"* ]]; then
            log "Active access key found for user [${user}]" >>logs.txt
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
log "----------------| Done |----------------" >>logs.txt
