#!/usr/bin/env bash

##
# Tab completion
##
complete -W "clear help mfa mfa-validate set-creds validate" aws-helper;

##
# Main aws_helper function
##
function aws-helper() {
  local action="${1}";
  shift;

  case "${action}" in
    'clear')
      __aws_helper_clear_credentials ${@};
    ;;
    'mfa')
      __aws_helper_mfa_authenticate ${@};
    ;;
    'mfa-validate')
      __aws_helper_mfa_validate ${@};
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
clear|Unset AWS credentials
help|This command
mfa|Obtain an MFA STS session
mfa-validate|Validate current MFA session
set-creds|Set AWS credentials in current shell
validate|Perform an STS get-caller-identity to validate current credentials
EOF
        ) | column -t -s "|";
    ;;
  esac
}
export -f aws-helper

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
  local -A colours;

  if [[ silent -eq 1 ]]; then
    return 0;
  fi;

  colours['INFO']='\033[32m';   # Green
  colours['WARN']='\033[33m';   # Yellow
  colours['ERROR']='\033[31m';  # Red
  colours['DEFAULT']='\033[0m'; # Default

  echo ${3} -e "[AWS Helper] ${colours[${level}]}[${level}] $2${colours['DEFAULT']}";
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
  unset AWS_SESSION_EXPIRY;
  unset AWS_ROLE;
  unset AWS_PROFILE;
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

  mfa_serial="$(aws iam list-mfa-devices --query 'MFADevices[*].SerialNumber' --output text)";
  if [ ${?} -ne 0 ]; then
    __aws_helper_log 'error' 'Failed to retrieve MFA devices';
    return 1;
  fi;

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
  fi;

  local expiry_epoch="$(date -d ${AWS_MFA_EXPIRY} +%s)"
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
