#!/usr/bin/env bash

# Enable extended shell globbing
shopt -s extglob

##
# Tab completion
##
complete -W "assume-role clear help list-creds list-aliases mfa mfa-validate saml-login set-creds validate get-session-token" aws-helper;

##
# Main aws_helper function
##
function aws-helper() {
  local action="${1}";
  shift;

  case "${action}" in
    'assume-role')
      __aws_helper_assume_role ${@};
    ;;
    'clear')
      __aws_helper_clear_credentials ${@};
    ;;
    'get-session-token')
      __aws_helper_get_session_token ${@};
    ;;
    'list-creds')
      __aws_helper_list_credentials ${@};
    ;;
    'list-aliases')
      __aws_helper_list_aliases ${@};
    ;;
    'mfa')
      __aws_helper_mfa_authenticate ${@};
    ;;
    'mfa-validate')
      __aws_helper_mfa_validate ${@};
    ;;
    'saml-login')
      __aws_helper_saml_login ${@};
    ;;
    'set-creds')
      __aws_helper_set_credentials ${@};
    ;;
    'validate')
      __aws_helper_validate_credentials ${@};
    ;;
    'help'|*)
        echo -e "Use the syntax aws-helper [action] help to get further information on a command\n";
        ( cat <<EOF
Action|Summary
-----|-------
assume-role|Assume a role
get-session-token|Get temporary environment credentials from current profile
clear|Unset AWS credentials
help|This command
list-creds|Get list of credentials options in configuration file
mfa|Obtain an MFA STS session
mfa-validate|Validate current MFA session
saml-login|Login using saml2aws and set environment credentials
set-creds|Set AWS credentials in current shell
validate|Perform an STS get-caller-identity to validate current credentials
EOF
        ) | column -t -s "|";
    ;;
  esac
}

##
# Helper function to ensure log levels
# are reset on function exit
##
function __aws_helper_reset_log_level() {
  export AWS_HELPER_LOG_SILENT=0;
}

##
# Generic logging function
##
function __aws_helper_log() {
  local silent="${AWS_HELPER_LOG_SILENT:-0}"
  local level="$(echo "${1}" | awk '{print toupper($0)}')";
  local default_color='\033[0m';
  local color;

  if [[ silent -eq 1 ]]; then
    return 0;
  fi;

  case "${level}" in
    'INFO')
      color='\033[32m'
    ;;
    'ERROR')
      color='\033[31m'
    ;;
    'WARN')
      color='\033[33m'
    ;;
  esac

  echo ${3} -e "[AWS Helper] ${color}[${level}] $2${default_color}";
}

##
# Clear all AWS environment variables
##
function __aws_helper_clear_credentials() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Clear current environment credentials.

Usage: aws-helper clear
EOF
      return 0;
  fi

  __aws_helper_log 'info' 'Clearing environment credentials'
  
  unset AWS_ACCESS_KEY_ID;
  unset AWS_SECRET_ACCESS_KEY;
  unset AWS_SESSION_TOKEN;
  unset AWS_MFA_EXPIRY;
  unset AWS_ROLE;
  unset AWS_PROFILE;
  unset AWS_ACCOUNT_ID;
  unset AWS_ARN;
  unset AWS_SECURITY_TOKEN;

  __aws_helper_clear_prompt
}

##
# Get list of credentials from users config files
##
function __aws_helper_list_credentials() {
 if [ "${1}" == "help" ]; then
      cat <<EOF
List AWS environment credentials in user configuration

Usage: aws-helper list-creds [OPTIONS]

Options:
  --file <credentials filename>

  default = ~/.aws/credentials
EOF
      return 0;
  fi

  ## Do we have the tools

  local GREP=$(which ggrep  2>/dev/null || which grep 2>/dev/null) 
  if [ -z "$GREP" ]; then
    __aws_helper_log 'error' 'Cannot locate tool: grep';
    return 1
  fi
  
  local CUT=$(which cut 2>/dev/null) 
  if [ -z "$CUT" ]; then
    __aws_helper_log 'error' 'Cannot locate tool: cut';
    return 1
  fi
  
  local TR=$(which tr 2>/dev/null) 
  if [ -z "$TR" ]; then 
    __aws_helper_log 'error' 'Cannot locate tool: tr';
    return 1
  fi

  if [ "${1}" == "--file" ]; then
    CREDENTIALS="${2}"
  else
    CREDENTIALS="$HOME/.aws/credentials"
  fi

  $GREP "^\[" $CREDENTIALS |$CUT -d ']' -f 1 | $TR -d '['
}

##
# Get list of aliases in ./aws-helper/config
##
function __aws_helper_list_aliases() {
 if [ "${1}" == "help" ]; then
      cat <<EOF
List AWS Helper aliases configured in ~/.aws-helper/config

Usage: aws-helper list-aliases
EOF
      return 0;
  fi
  
  if [ ! -f ~/.aws-helper/config ]; then
     __aws_helper_log 'info' 'No config file found at ~/.aws-helper/config';

     return 0;
  fi;
  
  grep -A1 "\[" ~/.aws-helper/config | sed "/^\[/! s/^/  /";
}

##
# Confirm valid environment credentials
##
function __aws_helper_validate_credentials() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Validate current AWS environment credentials

Usage: aws-helper validate [OPTIONS]

Options:
  --silent  Suppress stdout & stderr
EOF
      return 0;
  fi

  if [ "${1}" == "--silent" ]; then
    export AWS_HELPER_LOG_SILENT=1;
    trap __aws_helper_reset_log_level RETURN
  fi

  local caller_identity;
  caller_identity=($(aws sts get-caller-identity --output text 2>/dev/null));
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Unable to validate credentials';
    return 1; 
  fi;

  local account_id="${caller_identity[0]}";
  local arn="${caller_identity[1]}";
  local user_id="${caller_identity[2]}";

  if [[ -n "${account_id}" && -n "${arn}" && -n "${user_id}" ]]; then
    __aws_helper_log 'info' "AWS Profile: ${AWS_PROFILE}";
    __aws_helper_log 'info' "Account ID: ${account_id}";
    __aws_helper_log 'info' "ARN: ${arn}";
    __aws_helper_log 'info' "User ID: ${user_id}";

    export AWS_ACCOUNT_ID="${account_id}";
    export AWS_ARN="${arn}";

    return 0;
  else
    __aws_helper_log 'error' 'Error checking credentials';
    return 1;
  fi;
}

##
# Set AWS credentials based on profile
##
function __aws_helper_set_credentials() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Set AWS_PROFILE environment variable and validate credentials.

Usage: aws-helper set-creds [PROFILE]

Notes: If profile is not provided then stdin is used.
EOF
      return 0;
  fi

  __aws_helper_clear_credentials;
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Unable to clear credentials';
    return 1; 
  fi;

  if [ -n "${1}" ]; then
    AWS_PROFILE="${1}";
  else
    __aws_helper_log 'info' 'Enter AWS profile: ' '-n'
    read -r AWS_PROFILE;
  fi;

  export AWS_PROFILE;
  
  __aws_helper_validate_credentials;
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Error setting credentials'
    return 1;
  fi;

  __aws_helper_update_prompt "Profile" "${AWS_PROFILE}";
}

function __aws_helper_clear_prompt() {
  stripped_ps1="$(echo $PS1 | sed 's|\\\[\\033\[36m\\]\[AWS[^]]*]\\\[\\033\[0m\\]:||g')";
  PS1="${stripped_ps1} "
}

function __aws_helper_update_prompt() {
  __aws_helper_clear_prompt;

  PS1="\[\033[36m\][AWS ${1}: ${2}]\[\033[0m\]:${PS1}";
}


##
# Get session token for IAM user
##
function __aws_helper_get_session_token() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN environment variables using current profile.

Usage: aws-helper get-session-token

Options:
  --duration VALUE  Duration, in seconds, that credentials should remain valid.
                    Valid ranges are 900 to 129600. Default is 43,200 seconds (12 hours).

Notes: If profile is not provided then stdin is used.
EOF
      return 0;
  fi;

  local sts_token;
  local sts_duration=43200; 

  while (($#)); do
    case "${1}" in
      '--duration')
        sts_duration="${2}";
        shift 2;
      ;;
    esac;
  done

  sts_token=($(aws sts get-session-token --duration-seconds "${sts_duration}" --output text));
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed to get STS token';
    return 1;
  fi;

  AWS_ACCESS_KEY_ID="${sts_token[1]}";
  AWS_SECRET_ACCESS_KEY="${sts_token[3]}";
  AWS_SESSION_TOKEN="${sts_token[4]}";

  if [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" && -n "${AWS_SESSION_TOKEN}" ]]; then
    export AWS_ACCESS_KEY_ID;
    export AWS_SECRET_ACCESS_KEY;
    export AWS_SESSION_TOKEN;
    export AWS_MFA_EXPIRY;

    __aws_helper_update_prompt 'Environment' "${AWS_PROFILE}";

    unset AWS_PROFILE;

    __aws_helper_log 'info' 'Token vend successful';
    return 0;
  else
    __aws_helper_log 'error' 'Token vend failed';
    return 1;
  fi;
}

#
# Get session token for IAM user
##
function __aws_helper_saml_login() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
A very simple wrapper around saml2aws.

Usage: aws-helper saml-login [OPTIONS]

Options:
  --duration VALUE  Duration, in seconds, that credentials should remain valid.
                    Valid ranges are 900 to 129600. Default is 28800 seconds (8 hours).
EOF
      return 0;
  fi;
  __aws_helper_clear_credentials;
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Unable to clear credentials';
    return 1; 
  fi;

  local session_duration="28800"

  while (($#)); do
    case "${1}" in
      '--duration')
        session_duration="${2}";
        shift 2;
      ;;
    esac;
  done

  { login_repsonse=$(set -o pipefail && saml2aws --session-duration=${session_duration} login --force --quiet | tee /dev/fd/3 | col -b); } 3>&1
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed saml2aws login';
    return 1;
  fi;

  local env_vars="$(saml2aws script)";
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed to get saml2aws environment credentials';
    return 1;
  fi;

  eval ${env_vars};

  account_name=$(echo ${login_repsonse} | sed 's|.*: \(.*\) (.*|\1|');
  role_name=$(echo ${login_repsonse} | sed 's|.* / \(.*\)0m|\1|');

  __aws_helper_update_prompt 'Role' "${account_name}/${role_name}";

  __aws_helper_log 'info' 'Token vend successful';
}

##
# Authenticate MFA devices
##
function __aws_helper_mfa_authenticate() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Obtain STS token using MFA and set environment variables accordingly.

Usage: aws-helper mfa [MFA TOKEN] [OPTIONS]

Options:
  --duration VALUE  Duration, in seconds, that credentials should remain valid.
                    Valid ranges are 900 to 129600. Default is 43,200 seconds (12 hours).

Notes: If token is not provided then stdin is used.
EOF
      return 0;
  fi

  local mfa_serial;
  local mfa_token;
  local sts_token;
  local iam_user_name;
  local sts_duration=43200;

  while (($#)); do
    case "${1}" in
      '--duration')
        sts_duration="${2}";
        shift 2;
      ;;
      +([0-9]))
        mfa_token="${1}"
        shift;
      ;;
    esac;
  done

  __aws_helper_validate_credentials --silent;
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'No valid credentials present - Use aws-helper set-creds';
    return 1;
  fi;

  if [[ -n "${AWS_SESSION_TOKEN}" ]]; then
    __aws_helper_log 'error' 'STS token already present - Use aws-helper clear';
    return 1;
  fi;

  iam_user_name="$(echo ${AWS_ARN} | sed 's|[^/]*/||g')";
  mfa_serial="arn:aws:iam::${AWS_ACCOUNT_ID}:mfa/${iam_user_name}";

  if [ -z "${mfa_token}" ]; then
    __aws_helper_log 'info' 'Enter MFA token: ' '-n';
    read -r mfa_token;
  fi;

  sts_token=($(aws sts get-session-token --duration-seconds "${sts_duration}" --token-code "${mfa_token}" --serial-number "${mfa_serial}" --output text));
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed to get STS token';
    return 1;
  fi;

  AWS_ACCESS_KEY_ID="${sts_token[1]}";
  AWS_SECRET_ACCESS_KEY="${sts_token[3]}";
  AWS_SESSION_TOKEN="${sts_token[4]}";
  AWS_MFA_EXPIRY="${sts_token[2]}";

  if [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" && -n "${AWS_SESSION_TOKEN}" ]]; then
    export AWS_ACCESS_KEY_ID;
    export AWS_SECRET_ACCESS_KEY;
    export AWS_SESSION_TOKEN;
    export AWS_MFA_EXPIRY;

    __aws_helper_log 'info' 'MFA successful';
    return 0;
  else
    __aws_helper_log 'error' 'MFA failed';
    return 1;
  fi;
}

##
# Check MFA validity
##
function __aws_helper_mfa_validate() {
  if [ "${1}" == "help" ]; then 
      cat <<EOF
Validate current AWS STS MFA credentials

Usage: aws-helper mfa-validate [OPTIONS]

Options:
  --silent  Suppress stdout & stderr
EOF
      return 0;
  fi

  if [ "${1}" == "--silent" ]; then
    export AWS_HELPER_LOG_SILENT=1;
    trap __aws_helper_reset_log_level RETURN
  fi

  if [[ -z "${AWS_SESSION_TOKEN}" || -z "${AWS_MFA_EXPIRY}" ]]; then
    __aws_helper_log 'error' 'No STS session present - Use aws-helper mfa to obtain one';
    return 1;
  fi

  local expiry_epoch;

  # Workaround for OSX date
  if [ "$(uname)" == "Darwin" ]; then
    expiry_epoch="$(date -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"${AWS_MFA_EXPIRY}\" +%s)";
  else
    expiry_epoch="$(date -d ${AWS_MFA_EXPIRY} +%s)";
  fi

  local current_epoch="$(date -u +%s)";
  local delta=$((expiry_epoch - current_epoch));

  if [[ $delta -gt 0 ]]; then
    __aws_helper_log 'info' "MFA session valid for next ${delta} seconds";
    return 0;
  else
    __aws_helper_log 'error' 'MFA session expired';
    return 1;
  fi
}

##
# Assume a cross account role
##
function __aws_helper_assume_role() {
  if [[ "${1}" == "help" ]]; then 
      cat <<EOF
Assume a role. Provide either a role name and account or the role arn. If no account
is provided then the current account is implicitly assumed.

Usage: aws-helper assume-role (ROLE-ARN) OR (ROLE-NAME [ROLE-ACCOUNT]) [OPTIONS]

Options:
  --external-id ID  External ID to use if required
  --mfa TOKEN       For roles that require MFA to be present
  --duration VALUE  Duration, in seconds, that credentials should remain valid.
                    Valid ranges are 900 to 129600. Default is 3,600 seconds (1 hour).

EOF
      return 0;
  fi

  __aws_helper_validate_credentials --silent;
  if [[ ${?} -ne 0 ]]; then
    __aws_helper_log 'error' 'No valid credentials present - Use aws-helper set-creds';
    return 1;
  fi;

  local session_name;
  local target_role_arn;
  local target_account;
  local target_role;
  local target_external_id;
  local sts_mfa;
  local sts_duration="--duration-seconds 3600";

  if [ -f ~/.aws-helper/config ]; then
    __aws_helper_log 'info' 'AWS Config file found.';

    local alias="$(sed -n "/\[$1\]/{n;p;}" ~/.aws-helper/config 2>/dev/null)";

    if [ ! -z "${alias}" ]; then
      __aws_helper_log 'info' "Matching Alias found for [${1}]";

      set -- $alias;
    fi
  fi

  while (($#)); do
    case "${1}" in
      '--mfa')
        sts_mfa="--serial-number $(aws iam list-mfa-devices --query 'MFADevices[*].SerialNumber' --output text) --token-code ${2}";
        shift 2;
      ;;
      '--external-id')
        target_external_id="--external-id ${2}";
        shift 2;
      ;;
      '--duration')
        sts_duration="--duration-seconds ${2}";
        shift 2;
      ;;
      arn:aws:iam::*:role/*)
        target_role_arn="${1}";
        shift;
      ;;
      +([0-9]))
        target_account="${1}";
        shift;
      ;;
      *)
        target_role="${1}";
        shift;
    esac;
  done

  if [ -z $target_role_arn ]; then
    if [[ -z $target_role ]]; then
      __aws_helper_log 'error' 'No role ARN provided and insufficient information to construct arn';
      return 1;
    fi;
    target_role_arn="arn:aws:iam::${target_account:-${AWS_ACCOUNT_ID}}:role/${target_role}";
     __aws_helper_log 'info' "No explicit role ARN provided. Inferred role ARN: ${target_role_arn}";
  else
     __aws_helper_log 'info' "Role ARN: ${target_role_arn}";
  fi;

  session_name=$(echo "${AWS_ARN//[:\/]/-}" | cut -c 1-64);
  sts_token=($(aws sts assume-role ${sts_duration} ${target_external_id} ${sts_mfa} --role-arn "${target_role_arn}" --role-session-name "${session_name}" --query Credentials --output text));
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed to get STS token';
    return 1;
  fi;

  AWS_ACCESS_KEY_ID="${sts_token[0]}";
  AWS_SECRET_ACCESS_KEY="${sts_token[2]}";
  AWS_SESSION_TOKEN="${sts_token[3]}";

  if [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" && -n "${AWS_SESSION_TOKEN}" ]]; then
    export AWS_ACCESS_KEY_ID;
    export AWS_SECRET_ACCESS_KEY;
    export AWS_SESSION_TOKEN;
    export AWS_ROLE="${target_role_arn}"

    local prompt_role_name="$(echo ${target_role_arn} | sed 's|arn:aws:iam::||g ; s|role/||g')";

    __aws_helper_update_prompt 'Role' "${prompt_role_name}";

    __aws_helper_log 'info' 'Role assumption successful';
    return 0;
  else
    __aws_helper_log 'error' 'Role assumption failed';
    return 1;
  fi;
}
