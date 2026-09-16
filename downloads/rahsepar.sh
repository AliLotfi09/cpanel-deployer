#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Rahsepar - Production Linux/macOS client
# Requires: bash, jq, curl, zip. --watch additionally requires inotifywait (Linux).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${DEPLOY_CONFIG:-$SCRIPT_DIR/config.json}"
DEBUG="${DEBUG:-0}"
NO_COLOR="${NO_COLOR:-0}"

PROJECT_ROOT=""
BUILD_FOLDER="dist"
ZIP_FILE_NAME="politest.ir.zip"
FTP_HOST=""
REMOTE_USER=""
FTP_PASSWORD=""
REMOTE_PATH="."
EXTRACT_SCRIPT_URL=""
TOKEN=""
HEALTH_URL=""
BUILD_COMMAND="bun run build"
UPLOAD_RETRIES=3
REQUEST_TIMEOUT_SECONDS=300
HEALTH_TIMEOUT_SECONDS=20
STATUS_POLL_SECONDS=2
STATUS_TIMEOUT_SECONDS=330
KEEP_LOCAL_ARCHIVE=false
ALLOW_INSECURE_HTTP=false

RUN_ID=""
DEPLOY_ID=""
LOG_FILE=""
LOCK_DIR=""
APP_NAME="Rahsepar"
START_EPOCH=0
CURRENT_STAGE="startup"
ARCHIVE_SHA=""

if [[ -t 1 && "$NO_COLOR" != "1" ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_GRAY=""
fi

now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
now_time() { date '+%H:%M:%S'; }

strip_ansi() {
    sed -E $'s/\x1B\[[0-9;]*[mK]//g'
}

write_log_file() {
    [[ -n "$LOG_FILE" ]] || return 0
    printf '%s\n' "$1" | strip_ansi >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    local level="$1" message="$2" color="$C_GRAY" icon="•"
    case "$level" in
        INFO)    color="$C_BLUE";   icon="●" ;;
        SUCCESS) color="$C_GREEN";  icon="✔" ;;
        WARNING) color="$C_YELLOW"; icon="▲" ;;
        ERROR)   color="$C_RED";    icon="✖" ;;
        DEBUG)   color="$C_CYAN";   icon="◆" ;;
    esac
    local line="${C_GRAY}[$(now_time)]${C_RESET} ${color}${icon} ${level}${C_RESET}  ${message}"
    printf '%b\n' "$line"
    write_log_file "[$(now_iso)] [$level] $message"
}

info() { log INFO "$1"; }
success() { log SUCCESS "$1"; }
warn() { log WARNING "$1"; }
error() { log ERROR "$1"; }
debug() { [[ "$DEBUG" == "1" ]] && log DEBUG "$1" || true; }

section() {
    local title="$1"
    printf "\n%b╭────────────────────────────────────────────────────────────╮%b\n" "$C_CYAN" "$C_RESET"
    printf "%b│%b %b%-58s%b %b│%b\n" "$C_CYAN" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "%b╰────────────────────────────────────────────────────────────╯%b\n" "$C_CYAN" "$C_RESET"
    write_log_file "[$(now_iso)] [SECTION] $title"
}

kv() {
    printf '  %b%-22s%b %s\n' "$C_DIM" "$1" "$C_RESET" "$2"
    write_log_file "[$(now_iso)] [CONFIG] $1=$2"
}

human_bytes() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN { split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) {b/=1024; i++} printf "%.2f %s", b, u[i] }'
}

duration_text() {
    local total="$1" h m s
    h=$((total/3600)); m=$(((total%3600)/60)); s=$((total%60))
    if (( h > 0 )); then printf '%dh %02dm %02ds' "$h" "$m" "$s";
    elif (( m > 0 )); then printf '%dm %02ds' "$m" "$s";
    else printf '%ds' "$s"; fi
}

fatal() {
    error "$1"
    if [[ -n "$LOG_FILE" ]]; then
        info "Log file: $LOG_FILE"
    fi
    exit "${2:-1}"
}

on_error() {
    local code=$? line=${BASH_LINENO[0]:-${LINENO}} cmd=${BASH_COMMAND:-unknown}
    error "Stage '$CURRENT_STAGE' failed (exit=$code, line=$line)."
    debug "Command: $cmd"
    exit "$code"
}
trap on_error ERR

cleanup_runtime() {
    [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_runtime EXIT INT TERM

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command '$1' is not installed." 10
}

require_core_dependencies() {
    require_cmd jq
    require_cmd curl
    require_cmd zip
}

abs_dir() {
    local p="$1"
    [[ -d "$p" ]] || return 1
    (cd "$p" && pwd -P)
}

json_bool() {
    [[ "$1" == "true" || "$1" == "1" ]] && printf 'true' || printf 'false'
}

normalize_zip_name() {
    [[ "$ZIP_FILE_NAME" == *.zip ]] || ZIP_FILE_NAME="${ZIP_FILE_NAME}.zip"
}

config_value() {
    local filter="$1" default="$2" value
    value="$(jq -r "$filter // empty" "$CONFIG_FILE")"
    [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1

    PROJECT_ROOT="$(config_value '.ProjectRoot' '.')"
    local config_dir
    config_dir="$(cd -- "$(dirname -- "$CONFIG_FILE")" && pwd -P)"
    if [[ "$PROJECT_ROOT" != /* ]]; then
        PROJECT_ROOT="$config_dir/$PROJECT_ROOT"
    fi
    BUILD_FOLDER="$(config_value '.BuildFolder' 'dist')"
    ZIP_FILE_NAME="$(config_value '.ZipFileName' 'politest.ir.zip')"
    FTP_HOST="$(config_value '.FtpHost' '')"
    REMOTE_USER="$(config_value '.RemoteUser' '')"
    FTP_PASSWORD="${DEPLOY_FTP_PASSWORD:-$(config_value '.FtpPassword' '')}"
    REMOTE_PATH="$(config_value '.RemotePath' '.')"
    EXTRACT_SCRIPT_URL="$(config_value '.ExtractScriptUrl' '')"
    TOKEN="${DEPLOY_TOKEN:-$(config_value '.Token' '')}"
    HEALTH_URL="$(config_value '.HealthUrl' '')"
    BUILD_COMMAND="$(config_value '.BuildCommand' 'bun run build')"
    UPLOAD_RETRIES="$(config_value '.UploadRetries' '3')"
    REQUEST_TIMEOUT_SECONDS="$(config_value '.RequestTimeoutSeconds' '300')"
    HEALTH_TIMEOUT_SECONDS="$(config_value '.HealthTimeoutSeconds' '20')"
    STATUS_POLL_SECONDS="$(config_value '.StatusPollSeconds' '2')"
    STATUS_TIMEOUT_SECONDS="$(config_value '.StatusTimeoutSeconds' '330')"
    KEEP_LOCAL_ARCHIVE="$(config_value '.KeepLocalArchive' 'false')"
    ALLOW_INSECURE_HTTP="$(config_value '.AllowInsecureHttp' 'false')"

    PROJECT_ROOT="$(abs_dir "$PROJECT_ROOT")" || fatal "Project root not found: $PROJECT_ROOT" 11
    normalize_zip_name
    validate_config
    return 0
}

validate_uint() {
    [[ "$2" =~ ^[0-9]+$ ]] || fatal "$1 must be a non-negative integer." 12
}

validate_config() {
    [[ -n "$FTP_HOST" ]] || fatal "FtpHost is empty." 12
    [[ -n "$REMOTE_USER" ]] || fatal "RemoteUser is empty." 12
    [[ -n "$FTP_PASSWORD" ]] || fatal "FTP password is empty. Set FtpPassword or DEPLOY_FTP_PASSWORD." 12
    [[ -n "$EXTRACT_SCRIPT_URL" ]] || fatal "ExtractScriptUrl is empty." 12
    [[ -n "$TOKEN" ]] || fatal "Deploy token is empty. Set Token or DEPLOY_TOKEN." 12
    validate_uint UploadRetries "$UPLOAD_RETRIES"
    validate_uint RequestTimeoutSeconds "$REQUEST_TIMEOUT_SECONDS"
    validate_uint HealthTimeoutSeconds "$HEALTH_TIMEOUT_SECONDS"
    validate_uint StatusPollSeconds "$STATUS_POLL_SECONDS"
    validate_uint StatusTimeoutSeconds "$STATUS_TIMEOUT_SECONDS"

    if [[ "$EXTRACT_SCRIPT_URL" != https://* && "$(json_bool "$ALLOW_INSECURE_HTTP")" != "true" ]]; then
        fatal "ExtractScriptUrl must use HTTPS. Set AllowInsecureHttp=true only for a trusted development environment." 12
    fi
}

save_config() {
    local tmp="${CONFIG_FILE}.tmp.$$"
    jq -n \
        --arg projectRoot "$PROJECT_ROOT" \
        --arg buildFolder "$BUILD_FOLDER" \
        --arg zipFileName "$ZIP_FILE_NAME" \        --arg ftpHost "$FTP_HOST" \
        --arg remoteUser "$REMOTE_USER" \
        --arg ftpPassword "$FTP_PASSWORD" \
        --arg remotePath "$REMOTE_PATH" \
        --arg extractScriptUrl "$EXTRACT_SCRIPT_URL" \
        --arg token "$TOKEN" \
        --arg healthUrl "$HEALTH_URL" \
        --arg buildCommand "$BUILD_COMMAND" \
        --argjson uploadRetries "$UPLOAD_RETRIES" \
        --argjson requestTimeout "$REQUEST_TIMEOUT_SECONDS" \
        --argjson healthTimeout "$HEALTH_TIMEOUT_SECONDS" \
        --argjson statusPoll "$STATUS_POLL_SECONDS" \
        --argjson statusTimeout "$STATUS_TIMEOUT_SECONDS" \
        --argjson keepArchive "$(json_bool "$KEEP_LOCAL_ARCHIVE")" \
        --argjson allowInsecureHttp "$(json_bool "$ALLOW_INSECURE_HTTP")" \
        '{
            ProjectRoot:$projectRoot,
            BuildFolder:$buildFolder,
            ZipFileName:$zipFileName,            FtpHost:$ftpHost,
            RemoteUser:$remoteUser,
            FtpPassword:$ftpPassword,
            RemotePath:$remotePath,
            ExtractScriptUrl:$extractScriptUrl,
            Token:$token,
            HealthUrl:$healthUrl,
            BuildCommand:$buildCommand,
            UploadRetries:$uploadRetries,
            RequestTimeoutSeconds:$requestTimeout,
            HealthTimeoutSeconds:$healthTimeout,
            StatusPollSeconds:$statusPoll,
            StatusTimeoutSeconds:$statusTimeout,
            KeepLocalArchive:$keepArchive,
            AllowInsecureHttp:$allowInsecureHttp
        }' > "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

prompt_secret() {
    local prompt="$1" value
    read -rsp "$prompt" value
    printf '\n' >&2
    printf '%s' "$value"
}

prompt_config() {
    section "Rahsepar · First-time configuration"
    local v

    read -rp "Project root [$PWD]: " v; PROJECT_ROOT="${v:-$PWD}"
    read -rp "Build folder [dist]: " v; BUILD_FOLDER="${v:-dist}"
    read -rp "ZIP filename [politest.ir.zip]: " v; ZIP_FILE_NAME="${v:-politest.ir.zip}"
        read -rp "FTP host: " FTP_HOST
    read -rp "FTP username: " REMOTE_USER
    FTP_PASSWORD="$(prompt_secret 'FTP password: ')"
    read -rp "Remote path [.]: " v; REMOTE_PATH="${v:-.}"
    read -rp "Extraction script URL (HTTPS): " EXTRACT_SCRIPT_URL
    TOKEN="$(prompt_secret 'Deploy token: ')"
    read -rp "Application health URL [optional]: " HEALTH_URL
    read -rp "Build command [bun run build]: " v; BUILD_COMMAND="${v:-bun run build}"

    PROJECT_ROOT="$(abs_dir "$PROJECT_ROOT")" || fatal "Project root not found: $PROJECT_ROOT" 11
    normalize_zip_name
    validate_config
    save_config
    success "Configuration saved securely to $CONFIG_FILE"
}

init_runtime() {
    RUN_ID="$(date '+%Y%m%d-%H%M%S')-$$"
    local local_log_dir="$PROJECT_ROOT/.deploy/logs"
    mkdir -p "$local_log_dir"
    LOG_FILE="$local_log_dir/deploy-$RUN_ID.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    local lock_key
    lock_key="$(printf '%s' "$PROJECT_ROOT" | cksum | awk '{print $1}')"
    LOCK_DIR="${TMPDIR:-/tmp}/smart-cpanel-deployer-${lock_key}.lockdir"
    mkdir "$LOCK_DIR" 2>/dev/null || fatal "Another deployment for this project is already running." 13

    START_EPOCH="$(date +%s)"
}

print_banner() {
    printf '\n%b' "$C_BOLD$C_CYAN"
    cat <<'BANNER'
    ____       _                                      
   |  _ \ __ _| |__  ___  ___ _ __   __ _ _ __       
   | |_) / _` | '_ \/ __|/ _ \ '_ \ / _` | '__|      
   |  _ < (_| | | | \__ \  __/ |_) | (_| | |         
   |_| \_\\__,_|_| |_|___/\___| .__/ \__,_|_|         
                               |_|                    
                  رهسپار · Rahsepar                     
            deploy softly · ship clearly                
BANNER
    printf '%b\n' "$C_RESET"
}

print_config() {
    section "Configuration"
    kv "Project root" "$PROJECT_ROOT"
    kv "Build folder" "$BUILD_FOLDER"
    kv "Archive" "$ZIP_FILE_NAME"
    kv "FTP endpoint" "ftp://$FTP_HOST"
    kv "FTP user" "$REMOTE_USER"
    kv "Remote path" "$REMOTE_PATH"
    kv "Deploy endpoint" "$EXTRACT_SCRIPT_URL"
    kv "Health URL" "${HEALTH_URL:-<disabled>}"
    kv "Build command" "$BUILD_COMMAND"
    kv "Secrets" "•••••••• (masked)"
}

ensure_lock_loaded() { :; }

build_dir_path() {
    if [[ "$BUILD_FOLDER" = /* ]]; then printf '%s\n' "$BUILD_FOLDER"; else printf '%s/%s\n' "$PROJECT_ROOT" "$BUILD_FOLDER"; fi
}

zip_path() {
    if [[ "$ZIP_FILE_NAME" = /* ]]; then printf '%s\n' "$ZIP_FILE_NAME"; else printf '%s/%s\n' "$PROJECT_ROOT" "$ZIP_FILE_NAME"; fi
}

sha256_file() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | awk '{print $1}'
    else fatal "sha256sum or shasum is required for archive verification." 10
    fi
}

run_build() {
    local build_dir
    build_dir="$(build_dir_path)"
    [[ "$build_dir" != "$PROJECT_ROOT" ]] || fatal "Build folder cannot be the project root." 20

    CURRENT_STAGE="build"
    section "1/6 · Build"
    info "Cleaning previous build output…"
    rm -rf -- "$build_dir"

    local t0="$(date +%s)"
    info "Running: $BUILD_COMMAND"
    if ! (cd "$PROJECT_ROOT" && bash -lc "$BUILD_COMMAND"); then
        fatal "Build command failed." 21
    fi

    [[ -d "$build_dir" ]] || fatal "Build folder not found after build: $build_dir" 22
    [[ -n "$(find "$build_dir" -mindepth 1 -print -quit 2>/dev/null)" ]] || fatal "Build folder is empty: $build_dir" 23
    success "Build completed in $(duration_text $(( $(date +%s)-t0 )))."
}

create_archive() {
    local build_dir zip_file tmp_zip size sha
    build_dir="$(build_dir_path)"; zip_file="$(zip_path)"; tmp_zip="${zip_file}.tmp.$$"
    case "$zip_file" in "$build_dir"/*) fatal "Archive cannot be created inside the build folder." 30 ;; esac

    CURRENT_STAGE="archive"
    section "2/6 · Package"
    rm -f -- "$zip_file" "$tmp_zip"
    local t0="$(date +%s)"
    info "Creating ZIP archive…"

    local attempt
    for ((attempt=1; attempt<=3; attempt++)); do
        debug "Archive attempt $attempt/3"
        if (cd "$build_dir" && zip -rq "$tmp_zip" .); then
            mv -f -- "$tmp_zip" "$zip_file"
            size="$(wc -c < "$zip_file" | tr -d ' ')"
            sha="$(sha256_file "$zip_file")"
            success "Archive ready: $(basename "$zip_file") · $(human_bytes "$size")"
            info "SHA-256: $sha"
            ARCHIVE_SHA="$sha"
            return 0
        fi
        rm -f -- "$tmp_zip"
        (( attempt < 3 )) && { warn "Archive attempt $attempt failed; retrying…"; sleep 2; }
    done
    fatal "Unable to create archive after 3 attempts." 31
}

ftp_remote_file() {
    if [[ -z "$REMOTE_PATH" || "$REMOTE_PATH" == "." ]]; then
        printf '%s' "$ZIP_FILE_NAME"
    else
        printf '%s/%s' "${REMOTE_PATH#/}" "$ZIP_FILE_NAME"
    fi
}

upload_to_ftp() {
    local zip_file remote_file ftp_url attempt
    zip_file="$(zip_path)"; remote_file="$(ftp_remote_file)"; ftp_url="ftp://$FTP_HOST/$remote_file"
    [[ -f "$zip_file" ]] || fatal "Archive does not exist: $zip_file" 40

    CURRENT_STAGE="upload"
    section "3/6 · Upload"
    info "Uploading $(basename "$zip_file") to $FTP_HOST…"
    debug "Remote path: /$remote_file"

    for ((attempt=1; attempt<=UPLOAD_RETRIES; attempt++)); do
        info "Upload attempt $attempt/$UPLOAD_RETRIES"
        local args=(--ftp-create-dirs --progress-bar --show-error --connect-timeout 20 --user "$REMOTE_USER:$FTP_PASSWORD" -T "$zip_file")
        if curl "${args[@]}" "$ftp_url"; then
            printf '\n'
            success "Upload completed."
            return 0
        fi
        printf '\n'
        (( attempt < UPLOAD_RETRIES )) && { warn "Upload failed; retrying in $((attempt*2))s…"; sleep $((attempt*2)); }
    done
    fatal "FTP upload failed after $UPLOAD_RETRIES attempts." 41
}

http_request() {
    # Usage: http_request METHOD ACTION key=value ...
    local method="$1" action="$2"; shift 2
    local body_file err_file code curl_exit
    body_file="$(mktemp)"; err_file="$(mktemp)"

    local args=(--location --silent --show-error --connect-timeout 20 --max-time "$REQUEST_TIMEOUT_SECONDS" -H "Accept: application/json" -H "X-Deploy-Token: $TOKEN" -o "$body_file" -w '%{http_code}')
    if [[ "$method" == "GET" ]]; then
        args+=(--get --data-urlencode "action=$action")
    else
        args+=(--request "$method" --data-urlencode "action=$action")
    fi
    local item
    for item in "$@"; do args+=(--data-urlencode "$item"); done

    set +e
    code="$(curl "${args[@]}" "$EXTRACT_SCRIPT_URL" 2>"$err_file")"
    curl_exit=$?
    set -e

    HTTP_BODY="$(cat "$body_file" 2>/dev/null || true)"
    HTTP_ERROR="$(cat "$err_file" 2>/dev/null || true)"
    HTTP_CODE="${code:-000}"
    HTTP_CURL_EXIT="$curl_exit"
    rm -f "$body_file" "$err_file"

    debug "API $method $action -> HTTP=$HTTP_CODE curl=$HTTP_CURL_EXIT"
    if [[ "$DEBUG" == "1" && -n "$HTTP_BODY" ]]; then debug "API response: ${HTTP_BODY:0:1000}"; fi
    return "$curl_exit"
}

json_field() {
    local json="$1" filter="$2" default="${3:-}"
    local v
    v="$(jq -r "$filter // empty" <<<"$json" 2>/dev/null || true)"
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$default"
}

new_deploy_id() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'
    else printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM"; fi
}

poll_status() {
    local deploy_id="$1" started status message elapsed
    started="$(date +%s)"
    while true; do
        http_request GET status "deploy_id=$deploy_id" || true
        if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]] && jq -e . >/dev/null 2>&1 <<<"$HTTP_BODY"; then
            status="$(json_field "$HTTP_BODY" '.data.status' 'unknown')"
            message="$(json_field "$HTTP_BODY" '.message' '')"
            debug "Remote status=$status"
            case "$status" in
                completed) success "Remote deployment completed."; return 0 ;;
                failed|failed_rolled_back) error "Remote deployment failed${message:+: $message}"; return 1 ;;
                rolled_back) warn "Deployment is already rolled back."; return 1 ;;
            esac
        fi
        elapsed=$(( $(date +%s)-started ))
        (( elapsed >= STATUS_TIMEOUT_SECONDS )) && return 2
        sleep "$STATUS_POLL_SECONDS"
    done
}

remote_extract() {
    local sha="$1"
    DEPLOY_ID="$(new_deploy_id)"
    CURRENT_STAGE="remote_extract"
    section "4/6 · Remote deployment"
    info "Deploy ID: $DEPLOY_ID"
    info "Requesting verified server-side deployment…"

    if ! http_request POST extract "file=$ZIP_FILE_NAME" "deploy_id=$DEPLOY_ID" "sha256=$sha"; then
        warn "The initial API request was interrupted (${HTTP_ERROR:-curl exit $HTTP_CURL_EXIT}). Checking server state…"
        if poll_status "$DEPLOY_ID"; then return 0; fi
        fatal "Could not confirm the remote deployment result." 50
    fi

    if [[ ! "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        local msg="$(json_field "$HTTP_BODY" '.message' "HTTP $HTTP_CODE")"
        error "Remote API rejected deployment: $msg"
        if [[ "$HTTP_CODE" == "409" ]]; then error "Another server-side deployment is currently running."; fi
        return 1
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$HTTP_BODY"; then
        error "Server returned invalid JSON."
        debug "Raw response: $HTTP_BODY"
        return 1
    fi

    local ok status msg
    ok="$(json_field "$HTTP_BODY" '.ok' 'false')"
    status="$(json_field "$HTTP_BODY" '.data.status' '')"
    msg="$(json_field "$HTTP_BODY" '.message' '')"
    if [[ "$ok" == "true" && "$status" == "completed" ]]; then
        success "Server applied the release successfully."
        return 0
    fi
    if [[ "$HTTP_CODE" == "202" || "$status" =~ ^(starting|backing_up|extracting|deploying)$ ]]; then
        info "Server is still processing the release; polling status…"
        poll_status "$DEPLOY_ID"
        return $?
    fi
    error "Remote deployment failed${msg:+: $msg}"
    return 1
}

remote_restore() {
    CURRENT_STAGE="rollback"
    warn "Requesting rollback for Deploy ID $DEPLOY_ID…"
    http_request POST restore "deploy_id=$DEPLOY_ID" || { error "Rollback API request failed: ${HTTP_ERROR:-curl error}."; return 1; }
    [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]] || { error "Rollback failed (HTTP $HTTP_CODE): $(json_field "$HTTP_BODY" '.message' '')"; return 1; }
    [[ "$(json_field "$HTTP_BODY" '.ok' 'false')" == "true" ]] || { error "Rollback failed: $(json_field "$HTTP_BODY" '.message' 'unknown error')"; return 1; }
    success "Rollback completed."
}

health_check() {
    CURRENT_STAGE="health"
    section "5/6 · Health check"
    if [[ -z "$HEALTH_URL" ]]; then
        warn "HealthUrl is empty; application health check is skipped."
        return 0
    fi
    info "Checking application endpoint…"
    local t0="$(date +%s)"
    if curl --location --silent --show-error --fail --connect-timeout 10 --max-time "$HEALTH_TIMEOUT_SECONDS" "$HEALTH_URL" >/dev/null; then
        success "Health check passed in $(duration_text $(( $(date +%s)-t0 )))."
        return 0
    fi
    error "Health check failed: $HEALTH_URL"
    return 1
}

remote_cleanup() {
    CURRENT_STAGE="cleanup"
    section "6/6 · Cleanup"
    info "Removing uploaded archive and rotating server metadata…"
    if ! http_request POST cleanup "file=$ZIP_FILE_NAME" "deploy_id=$DEPLOY_ID"; then
        warn "Remote cleanup request failed: ${HTTP_ERROR:-curl error}."
        return 0
    fi
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then success "Remote cleanup completed."; else warn "Remote cleanup returned HTTP $HTTP_CODE."; fi

    if [[ "$(json_bool "$KEEP_LOCAL_ARCHIVE")" == "true" ]]; then
        info "Local archive retained by configuration."
    else
        rm -f -- "$(zip_path)"
        success "Local archive removed."
    fi
}

summary_success() {
    local elapsed=$(( $(date +%s)-START_EPOCH ))
    section "Deployment summary"
    printf '  %b✔ Deployment completed successfully%b\n\n' "$C_BOLD$C_GREEN" "$C_RESET"
    kv "Deploy ID" "$DEPLOY_ID"
    kv "Duration" "$(duration_text "$elapsed")"
    kv "Archive" "$ZIP_FILE_NAME"
    kv "Log" "$LOG_FILE"
    printf '\n'
}

deploy_once() {
    print_banner
    print_config
    run_build
    create_archive
    [[ "$ARCHIVE_SHA" =~ ^[a-fA-F0-9]{64}$ ]] || ARCHIVE_SHA="$(sha256_file "$(zip_path)")"
    upload_to_ftp

    if ! remote_extract "$ARCHIVE_SHA"; then
        error "Remote deployment did not complete successfully. Server state/logs should be inspected; no blind rollback is attempted."
        fatal "Deployment aborted." 51
    fi

    if ! health_check; then
        error "The new release is unhealthy; starting automatic rollback."
        if remote_restore; then
            fatal "Deployment was rolled back because the health check failed." 61
        else
            fatal "CRITICAL: health check failed and rollback also failed. Manual intervention is required." 62
        fi
    fi

    remote_cleanup
    summary_success
}

rollback_only() {
    print_banner
    print_config
    DEPLOY_ID="${DEPLOY_ID_OVERRIDE:-}"
    if [[ -z "$DEPLOY_ID" ]]; then
        read -rp "Deploy ID to rollback (leave empty for latest backup): " DEPLOY_ID
    fi
    if [[ -n "$DEPLOY_ID" ]]; then
        remote_restore
    else
        CURRENT_STAGE="rollback"
        section "Rollback"
        warn "No Deploy ID supplied; requesting latest available backup."
        http_request POST restore || fatal "Rollback API request failed." 70
        [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ && "$(json_field "$HTTP_BODY" '.ok' 'false')" == "true" ]] || fatal "Rollback failed: $(json_field "$HTTP_BODY" '.message' "HTTP $HTTP_CODE")" 70
        success "Rollback completed."
    fi
    health_check || warn "Rollback completed, but the health check did not pass."
}

watch_mode() {
    require_cmd inotifywait
    print_banner
    print_config
    section "Watch mode"
    local build_base child_args
    build_base="$(basename "$(build_dir_path)")"
    info "Watching project files. Press Ctrl+C to stop."
    while true; do
        inotifywait -r -q -e close_write,create,move,delete \
            --exclude "(^|/)(node_modules|${build_base//./\\.}|\.git|\.deploy)($|/)" \
            "$PROJECT_ROOT" >/dev/null 2>&1 || true
        sleep 1
        info "Change detected; starting isolated deployment run…"
        child_args=(--auto "--config=$CONFIG_FILE")
        [[ "$DEBUG" == "1" ]] && child_args+=(--debug)
        if "$SCRIPT_DIR/rahsepar.sh" "${child_args[@]}"; then
            success "Watch deployment completed."
        else
            error "Watch deployment failed; watcher remains active."
        fi
    done
}

main() {
    local auto_mode=false watch=false dry_run=false rollback=false
    while (($#)); do
        case "$1" in
            --auto|-Auto) auto_mode=true ;;
            --watch|-Watch) watch=true ;;
            --dry-run|-DryRun) dry_run=true ;;
            --rollback|-Rollback) rollback=true ;;
            --debug|-Debug) DEBUG=1 ;;
            --deploy-id=*) DEPLOY_ID_OVERRIDE="${1#*=}" ;;
            --config=*) CONFIG_FILE="${1#*=}" ;;
            --help|-h|-Help)
                cat <<'HELP'
Usage: ./rahsepar.sh [options]
  --auto                 Fail instead of prompting when config.json is missing
  --watch                Deploy after project file changes (requires inotifywait)
  --dry-run              Validate and print configuration without deploying
  --rollback             Roll back a Deploy ID (or latest backup)
  --deploy-id=<id>       Deploy ID used with --rollback
  --config=<path>        Use a custom config.json path
  --debug                Enable verbose diagnostics (secrets remain masked)
HELP
                exit 0 ;;
            *) fatal "Unknown argument: $1" 2 ;;
        esac
        shift
    done

    require_core_dependencies
    if ! load_config; then
        $auto_mode && fatal "Configuration file not found: $CONFIG_FILE" 11
        prompt_config
        load_config
    fi
    if $watch; then watch_mode; exit 0; fi

    init_runtime
    if $dry_run; then print_banner; print_config; success "Configuration is valid."; exit 0; fi
    if $rollback; then rollback_only; exit 0; fi
    deploy_once
}

main "$@"
