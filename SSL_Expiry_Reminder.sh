#!/bin/bash

# Let’s Encrypt SSL Certificate Expiry Reminder Service 1.0

# Author:
# Name: Marco Steinbrecher
# Email: lesslscript@steinbrecher.co
# GitHub: https://github.com/macsteini/SSL-Expiry-Reminder-Service

# Description:
# This script checks all Let’s Encrypt SSL certificates on the server
# and sends email reminders when a certificate is nearing expiry.
# It also schedules follow-up reminders if necessary.

# Features:
# - Sends reminders to a master admin email for all domains.
# - Supports additional email recipients per domain.
# - Uses a default expiry warning threshold, but allows per-domain
# settings.
# - Configurable follow-up intervals to send repeated reminders.
# - Uses the systemd-run command to schedule follow-up reminders.

# How to Use:
# - Update MASTER_EMAIL with your admin email.
# - Set MASTER_WARNING_DAYS to the default threshold (in days).
# - Define per-domain custom settings (optional).
# - Ensure sendmail (or another MTA) is configured to send emails.

# Follow-up intervals use systemd time spans, for example "30min", "11h",
# "1d", "2w", "1y", or "1h30m". Warning thresholds are always in days.
# An empty master interval disables follow-ups by default;
# an explicitly empty domain override disables them for that domain.
# A daily scan discovers expiring certificates and reconciles timers.
# Each enabled domain has its own transient follow-up timer and a saved
# certificate fingerprint, so unrelated scans do not resend its warning.
# See the README for installation, state, upgrade, and recovery details.

# MIT Licence:
# Copyright (c) 2025 MacSteini
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Global Configuration
MASTER_EMAIL="Domain Admin <admin@example.com>" # Primary email to receive all expiry reminders
MASTER_WARNING_DAYS=14 # Default number of days before expiry to trigger a reminder
MASTER_FOLLOW_UP_INTERVAL="24h" # Default interval for follow-up reminders (e. g., "24h" for daily)
SENDER_EMAIL="Let’s Encrypt SSL Expiry Service <noreply@example.com>" # Sender email address for reminders

# ----------------------------------------------------------------------
# Per-Domain Custom Settings (Optional)
# ----------------------------------------------------------------------
# Use configure_domains to apply the same settings to one or more domains.
# Arguments: additional email, warning days, follow-up interval, then domains.
# Warning days is a number of days; interval examples include "30min", "11h",
# "1d", "2w", "1y", and "1h30m". Quote intervals containing spaces.
# Intervals must be positive and shorter than one billion seconds (~31.7 years).
# Use "" for no additional recipient, or for the default warning days.
# An empty follow-up interval disables follow-ups for those domains.
# Domains without a configuration use the master settings. If a domain is
# listed more than once, the last configuration takes precedence.

declare -A EMAILS # Stores additional email recipients per domain.
declare -A WARNING_DAYS # Stores custom warning thresholds per domain.
declare -A FOLLOW_UP_INTERVALS # Stores custom follow-up intervals per domain.

configure_domains() {
    if [ "$#" -lt 4 ]; then
        echo "configure_domains requires an email, warning days, interval and at least one domain" >&2
        exit 1
    fi
    local email=$1 warning_days=$2 interval=$3 domain
    shift 3
    for domain in "$@"; do
        EMAILS["$domain"]=$email
        WARNING_DAYS["$domain"]=$warning_days
        FOLLOW_UP_INTERVALS["$domain"]=$interval
    done
}

# Add as many groups as needed. Each domain in a group gets the same settings.
configure_domains "Domain Admin <user1@example.com>" 10 "11h" \
    yourdomain1.com
configure_domains "Domain Admin <user2@example.com>" 2 "24h" \
    yourdomain2.com

# ⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️
# FROM THIS POINT ONWARDS, DO NOT MODIFY ANYTHING
# UNLESS YOU KNOW WHAT YOU ARE DOING!
# ⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️

# The following section is part of the script's internal logic.
# - DO NOT change any variables here unless you fully understand the
# implications.
# - Modifying these values incorrectly may break the script or cause
# incorrect behaviour.
# - The script will handle follow-ups and expiry checks automatically.

# If you need to change settings, do so in the CONFIGURATION section at
# the top of the script.

# A root-only state directory and a single lock coordinate the daily scan,
# manual runs, and transient follow-up services.
STATE_DIR=/var/lib/ssl-expiry-reminder
CERT_DIR=/etc/letsencrypt/live
# Follow-ups must execute the same file, even when invoked through a relative
# path or a symbolic link. Resolve it before creating any timer.
SCRIPT_PATH=$(realpath -e -- "${BASH_SOURCE[0]}") || {
    echo "Cannot determine the script path" >&2
    exit 1
}
umask 077
mkdir -p "$STATE_DIR" || exit 1
# The lock is opened with elevated privileges. Never follow links or trust a
# directory that another user could alter between the checks and the open.
if [ -L "$STATE_DIR" ] || [ ! -d "$STATE_DIR" ]; then
    echo "Unsafe state directory: $STATE_DIR" >&2
    exit 1
fi
STATE_METADATA=$(stat -c '%u %a' -- "$STATE_DIR") || exit 1
read -r STATE_OWNER STATE_MODE <<< "$STATE_METADATA"
case "$STATE_MODE" in ''|*[!0-7]*|?????*) echo "Invalid state directory permissions: $STATE_DIR" >&2; exit 1 ;; esac
if [ "$STATE_OWNER" != "$EUID" ] || (( (8#$STATE_MODE & 077) != 0 )); then
    echo "Unsafe state directory owner or permissions: $STATE_DIR" >&2
    exit 1
fi
if [ -L "$STATE_DIR/lock" ] || { [ -e "$STATE_DIR/lock" ] && [ ! -f "$STATE_DIR/lock" ]; }; then
    echo "Unsafe lock file: $STATE_DIR/lock" >&2
    exit 1
fi
exec 9>>"$STATE_DIR/lock" || exit 1
flock -x 9 || exit 1

MODE=scan
if [ "$#" -ne 0 ]; then
    if [ "$#" -ne 3 ] || [ "$1" != "--follow-up" ]; then
        echo "Usage: $0 [--follow-up DOMAIN UNIT]" >&2
        exit 2
    fi
    MODE=follow-up
    REQUEST_DOMAIN=$2
    REQUEST_UNIT=$3
fi

# Do not interpret an inaccessible certificate store as removed certificates.
# In particular, preserve reminder state and timers until the store is back.
if [ ! -d "$CERT_DIR" ] || [ ! -r "$CERT_DIR" ] || [ ! -x "$CERT_DIR" ]; then
    echo "Certificate directory is missing or inaccessible: $CERT_DIR" >&2
    exit 1
fi

# State: fingerprint, interval, pending unit, domain, due epoch, retry stage.
# The unit name is a token as well: stale timer invocations cannot send mail.
write_state() {
    local tmp
    tmp=$(mktemp "$STATE_DIR/state.XXXXXXXXXX") || return 1
    if ! printf '%s\n' "$FINGERPRINT" "$INTERVAL" "$UNIT" "$DOMAIN" "$DUE" "$RETRY" > "$tmp" || ! mv -f "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

cancel_timer() {
    if [ -n "$UNIT" ] && systemctl is-active --quiet "$UNIT.timer"; then
        systemctl stop "$UNIT.timer" || return 1
    fi
    UNIT=
}

# Convert a systemd time span to whole seconds, rounding up. Reject zero,
# infinity and values too large for safe arithmetic.
interval_seconds() {
    local output microseconds
    output=$(LC_ALL=C systemd-analyze timespan "$1") || {
        echo "Cannot parse interval: check systemd-analyze timespan support and configuration" >&2
        return 1
    }
    microseconds=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*.*s:[[:space:]]*\([0-9][0-9]*\)$/\1/p')
    case "$microseconds" in ''|*[!0-9]*|????????????????*) return 1 ;; esac
    [ "$microseconds" -gt 0 ] || return 1
    SECONDS_INTERVAL=$(((microseconds + 999999) / 1000000))
}

schedule_timer() {
    local token_file token delay
    [ -n "$DUE" ] || return 0
    delay=$((DUE - CURRENT_TIMESTAMP))
    [ "$delay" -gt 0 ] || delay=1
    token_file=$(mktemp "$STATE_DIR/timer.XXXXXXXXXX") || return 1
    token=${token_file##*.}
    rm -f "$token_file" || return 1
    UNIT="ssl-expiry-followup-$DOMAIN_HASH-$token"
    # Save before creating the timer so obsolete callbacks cannot match.
    write_state || return 1
    if ! systemd-run --on-active="${delay}s" --unit="$UNIT" "$SCRIPT_PATH" --follow-up "$DOMAIN" "$UNIT"; then
        echo "Failed to schedule reminder for $DOMAIN" >&2
        UNIT=
        write_state || return 1
        return 1
    fi
}

set_followup_due() {
    DUE=
    [ -n "$INTERVAL" ] || return 0
    if ! interval_seconds "$INTERVAL"; then
        echo "Cannot calculate follow-up interval for $DOMAIN: $INTERVAL" >&2
        return 1
    fi
    DUE=$((CURRENT_TIMESTAMP + SECONDS_INTERVAL))
}

process_domain() {
    local DOMAIN=$1 DOMAIN_HASH STATE_FILE CERT_INFO EXPIRY_DATE EXPIRY_TIMESTAMP
    local CURRENT_TIMESTAMP DAYS_LEFT DOMAIN_WARNING_DAYS NEW_FINGERPRINT
    local FINGERPRINT='' INTERVAL='' UNIT='' SAVED_DOMAIN='' OLD_INTERVAL='' EMAIL
    local DUE='' RETRY=0 SECONDS_INTERVAL=0 MAIL_FAILED=0
    local -a RECIPIENTS
    case "$DOMAIN" in
        ''|*[!a-zA-Z0-9._-]*|.|..) echo "Invalid domain directory: $DOMAIN" >&2; return 1 ;;
    esac
    DOMAIN_HASH=$(printf '%s' "$DOMAIN" | sha256sum) || return 1
    DOMAIN_HASH=${DOMAIN_HASH%% *}
    STATE_FILE="$STATE_DIR/$DOMAIN_HASH"
    if [ -f "$STATE_FILE" ]; then
        {
            if ! { IFS= read -r FINGERPRINT && IFS= read -r OLD_INTERVAL &&
                IFS= read -r UNIT && IFS= read -r SAVED_DOMAIN &&
                IFS= read -r DUE && IFS= read -r RETRY; }; then
                echo "Invalid state for $DOMAIN" >&2; return 1;
            fi
        } < "$STATE_FILE"
        [ "$SAVED_DOMAIN" = "$DOMAIN" ] || { echo "State mismatch for $DOMAIN" >&2; return 1; }
        if [ -n "$UNIT" ]; then
            case "$UNIT" in
                "ssl-expiry-followup-$DOMAIN_HASH-"*)
                    local unit_token=${UNIT#"ssl-expiry-followup-$DOMAIN_HASH-"}
                    case "$unit_token" in ''|*[!a-zA-Z0-9]*) echo "Invalid timer for $DOMAIN" >&2; return 1 ;; esac
                    ;;
                *) echo "Invalid timer for $DOMAIN" >&2; return 1 ;;
            esac
        fi
        case "$DUE" in ''|*[!0-9]*) [ -z "$DUE" ] || { echo "Invalid due time for $DOMAIN" >&2; return 1; } ;; esac
        case "$RETRY" in 0|1|2|3|4|5) ;; *) echo "Invalid retry stage for $DOMAIN" >&2; return 1 ;; esac

    fi
    # An explicitly empty override differs from an absent array entry.
    INTERVAL=${FOLLOW_UP_INTERVALS[$DOMAIN]-$MASTER_FOLLOW_UP_INTERVAL}
    if [ "$MODE" = follow-up ] && [ "$REQUEST_UNIT" != "$UNIT" ]; then
        return 0
    fi
    if [ ! -f "$CERT_DIR/$DOMAIN/fullchain.pem" ]; then
        if [ -e "$CERT_DIR/$DOMAIN" ] || [ -L "$CERT_DIR/$DOMAIN" ]; then
            echo "Certificate file is missing or inaccessible for $DOMAIN" >&2
            return 1
        fi
        cancel_timer || return 1
        [ ! -f "$STATE_FILE" ] || rm -f "$STATE_FILE" || return 1
        return 0
    fi
    CERT_INFO=$(openssl x509 -enddate -fingerprint -sha256 -noout -in "$CERT_DIR/$DOMAIN/fullchain.pem") || {
        echo "Cannot read certificate for $DOMAIN" >&2; return 1;
    }
    EXPIRY_DATE=$(printf '%s\n' "$CERT_INFO" | sed -n 's/^notAfter=//p')
    NEW_FINGERPRINT=$(printf '%s\n' "$CERT_INFO" | sed -n 's/^[^=]*[Ff]ingerprint=//p')
    if [ -z "$EXPIRY_DATE" ] || [ -z "$NEW_FINGERPRINT" ]; then
        echo "Incomplete certificate information for $DOMAIN" >&2; return 1
    fi
    EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s) || return 1
    CURRENT_TIMESTAMP=$(date +%s) || return 1
    DAYS_LEFT=$(((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400))
    DOMAIN_WARNING_DAYS=${WARNING_DAYS[$DOMAIN]:-$MASTER_WARNING_DAYS}
    case "$DOMAIN_WARNING_DAYS" in
        ''|*[!0-9]*|??????????*) echo "Invalid warning threshold for $DOMAIN: $DOMAIN_WARNING_DAYS" >&2; return 1 ;;
    esac
    DOMAIN_WARNING_DAYS=$((10#$DOMAIN_WARNING_DAYS))
    if [ "$((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP))" -gt "$((DOMAIN_WARNING_DAYS * 86400))" ]; then
        cancel_timer || return 1
        [ ! -f "$STATE_FILE" ] || rm -f "$STATE_FILE" || return 1
        return 0
    fi
    if [ "$FINGERPRINT" != "$NEW_FINGERPRINT" ]; then
        cancel_timer || return 1
        FINGERPRINT=
        DUE=
        RETRY=0
    elif [ "$OLD_INTERVAL" != "$INTERVAL" ]; then
        # A pending retry is independent of the normal follow-up interval.
        if [ "$RETRY" -eq 0 ]; then
            cancel_timer || return 1
            set_followup_due || { write_state; return 1; }
        fi
        write_state || return 1
    fi

    if [ -z "$FINGERPRINT" ] || { [ -n "$DUE" ] && [ "$CURRENT_TIMESTAMP" -ge "$DUE" ]; }; then
        cancel_timer || return 1
        RECIPIENTS=("$MASTER_EMAIL")
        if [ -n "${EMAILS[$DOMAIN]}" ] && [ "${EMAILS[$DOMAIN]}" != "$MASTER_EMAIL" ]; then
            RECIPIENTS+=("${EMAILS[$DOMAIN]}")
        fi
        for EMAIL in "${RECIPIENTS[@]}"; do
            if ! printf 'From: %s\nTo: %s\nSubject: SSL Certificate Expiry Warning for %s\n\nThe SSL certificate for %s expires in %s days.\n\nConsider renewing it soon to avoid downtime.\n' "$SENDER_EMAIL" "$EMAIL" "$DOMAIN" "$DOMAIN" "$DAYS_LEFT" | sendmail -t; then
                echo "Failed to send warning for $DOMAIN" >&2
                MAIL_FAILED=1
                break
            fi
        done
        CURRENT_TIMESTAMP=$(date +%s) || return 1
        FINGERPRINT=$NEW_FINGERPRINT
        if [ "$MAIL_FAILED" -eq 1 ]; then
            [ "$RETRY" -ge 5 ] || RETRY=$((RETRY + 1))
            case "$RETRY" in
                1) SECONDS_INTERVAL=900 ;;
                2) SECONDS_INTERVAL=1800 ;;
                3) SECONDS_INTERVAL=3600 ;;
                4) SECONDS_INTERVAL=7200 ;;
                5) SECONDS_INTERVAL=14400 ;;
            esac
            DUE=$((CURRENT_TIMESTAMP + SECONDS_INTERVAL))
            write_state || return 1
            schedule_timer || return 1
            return 1
        fi
        RETRY=0
        # Record successful delivery before parsing/scheduling the next timer.
        DUE=
        write_state || return 1
        set_followup_due || return 1
        write_state || return 1
    elif [ "$MODE" = follow-up ]; then
        # An early timer must be replaced for the remaining duration.
        UNIT=
    fi

    if [ -n "$DUE" ] && { [ -z "$UNIT" ] || ! systemctl is-active --quiet "$UNIT.timer"; }; then
        schedule_timer || return 1
    elif [ -z "$DUE" ] && [ -n "$INTERVAL" ] && [ "$RETRY" -eq 0 ]; then
        # Recover from an interval parsing or scheduling failure after mail.
        set_followup_due || return 1
        write_state || return 1
        schedule_timer || return 1
    fi

}

STATUS=0
if [ "$MODE" = follow-up ]; then
    process_domain "$REQUEST_DOMAIN" || STATUS=1
else
    # Also reconcile stored domains whose certificate has been removed.
    for STATE_FILE in "$STATE_DIR"/[0-9a-f]*; do
        [ -f "$STATE_FILE" ] || continue
        { IFS= read -r _ && IFS= read -r _ && IFS= read -r _ && IFS= read -r DOMAIN; } < "$STATE_FILE" || { echo "Invalid state: $STATE_FILE" >&2; STATUS=1; continue; }
        if [ ! -e "$CERT_DIR/$DOMAIN" ] && [ ! -L "$CERT_DIR/$DOMAIN" ]; then
            process_domain "$DOMAIN" || STATUS=1
        fi
    done
    for DOMAIN_PATH in "$CERT_DIR"/*; do
        [ -d "$DOMAIN_PATH" ] || [ -L "$DOMAIN_PATH" ] || continue
        process_domain "${DOMAIN_PATH##*/}" || STATUS=1
    done
fi
exit "$STATUS"
