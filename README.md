# Auto Rotation Script v0.1

This script will rotate the AWS Access Keys automatically, which should be rotated regularly for security and compliance reasons.



**Before Running the script, we need to:**

1. Run the script in secure environment.
2. AWSCLI installed.
3. Run the script with a user that have `AdministratorAccess` policy.
4. Added the tag `AutoRotation:yes` to all IAM users that we want to run the script on.
5. Make sure that user has one active access key only.

**The idea behind the script is simple:**

1. Looking for the users with the tag `AutoRotation:yes`.
2. Delete the inactive (old) access key (if exist).
3. Create a new access key.
4. Set the old access key as inactive.



> - The script will only delete the inactive access keys.
> - The script will only rotate the access key for the users with tag `AutoRotation:yes`.



```sh
#!/bin/bash

# This script will rotate AWS Access Keys automatically, which should be rotated regularly for security and compliance reasons

get_user_name() {
    aws iam list-users \
        --query 'Users[].UserName' \
        --output text
}

access_key_status() {
    aws iam list-access-keys \
        --user "$1" \
        --query 'AccessKeyMetadata[].Status' \
        --output text
}

auto_rotation_tag() {
    aws iam list-user-tags \
        --user-name "$1" \
        --query 'Tags[?Key==`AutoRotation`].Value' \
        --output text
}

active_access_keys() {
    aws iam list-access-keys \
        --user-name "$1" \
        --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
        --output text
}

inactive_access_keys() {
    aws iam list-access-keys \
        --user-name "$1" \
        --query 'AccessKeyMetadata[?Status==`Inactive`].AccessKeyId' \
        --output text
}

create_new_access_key() {
    aws iam create-access-key \
        --user-name "$1" \
        --query '[AccessKey.AccessKeyId,AccessKey.SecretAccessKey]' \
        --output text | awk '{ print "AWS_ACCESS_KEY_ID=\"" $1 "\"\n" "AWS_SECRET_ACCESS_KEY=\"" $2 "\"" }'
}

deactivate_old_access_key() {
    aws iam update-access-key \
        --user-name "$1" \
        --access-key-id "$2" \
        --status Inactive
}

delete_old_access_key() {
    aws iam delete-access-key \
        --user-name "$1" \
        --access-key-id "$2"
}

set -euo pipefail

for user in $(get_user_name); do
    if [ "$(auto_rotation_tag "${user}")" = "Yes" ]; then
        if [[ "$(access_key_status "${user}")" == *"Inactive"* ]]; then
            inactive_access_key="$(inactive_access_keys "${user}")"
            echo "Inactive Access Keys"
            echo "${user}"
            echo "${inactive_access_key}"
            delete_old_access_key "${user}" "${inactive_access_key}"
            echo "Deleting old access key..."
        fi
        if [[ "$(access_key_status "${user}")" == *"Active"* ]]; then
            active_access_key="$(active_access_keys "${user}")"
            echo "Active Access Keys"
            echo "${user}"
            echo "${active_access_key}"
            create_new_access_key "${user}"
            deactivate_old_access_key "${user}" "${active_access_key}"
        fi
    fi
done
```

V0.1