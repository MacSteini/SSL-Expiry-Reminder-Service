#!/bin/bash
#
# Let’s Encrypt SSL Certificate Expiry Reminder Service 1.0
#
# Author:
# Name: Marco Steinbrecher
# Email: lesslscript@steinbrecher.co
# GitHub: https://github.com/macsteini/SSL-Expiry-Reminder-Service
#
# Description:
# This script checks all Let’s Encrypt SSL certificates on the server
# and sends email reminders when a certificate is nearing expiry.
# It also schedules follow-up reminders if necessary.
#
# Features:
# - Sends reminders to a master admin email for all domains.
# - Supports additional email recipients per domain.
# - Uses a default expiry warning threshold, but allows per-domain
# settings.
# - Configurable follow-up intervals to send repeated reminders.
# - Uses the systemd-run command to schedule follow-up reminders.
#
# How to Use:
# - Update MASTER_EMAIL with your admin email.
# - Set MASTER_WARNING_DAYS to the default threshold (in days).
# - Define per-domain custom settings (optional).
# - Ensure sendmail (or another MTA) is configured to send emails.
#
# Follow-up intervals use systemd time spans, for example "24h", "11h",
# or "1h30m". An empty master interval disables follow-ups by default;
# an explicitly empty domain override disables them for that domain.
# A daily scan discovers expiring certificates and reconciles timers.
# Each enabled domain has its own transient follow-up timer and a saved
# certificate fingerprint, so unrelated scans do not resend its warning.
# See the README for installation, state, upgrade, and recovery details.
#
# MIT Licence:
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
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
# Define specific recipients, warning thresholds, and follow-up
# intervals for individual domains. If a domain is not explicitly
# listed, it will fall back to the master settings.

declare -A EMAILS # Stores additional email recipients per domain.
declare -A WARNING_DAYS # Stores custom warning thresholds per domain.
declare -A FOLLOW_UP_INTERVALS # Stores custom follow-up intervals per domain.

# Configurations for individual domains (add as many as required):
EMAILS["yourdomain1.com"]="Domain Admin <user1@example.com>"
WARNING_DAYS["yourdomain1.com"]=10
FOLLOW_UP_INTERVALS["yourdomain1.com"]="11h"

EMAILS["yourdomain2.com"]="Domain Admin <user2@example.com>"
WARNING_DAYS["yourdomain2.com"]=2
FOLLOW_UP_INTERVALS["yourdomain2.com"]="24h"

# ⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️
# FROM THIS POINT ONWARDS, DO NOT MODIFY ANYTHING
# UNLESS YOU KNOW WHAT YOU ARE DOING!
# ⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️⚠️
#
# The following section is part of the script's internal logic.
# - DO NOT change any variables here unless you fully understand the
# implications.
# - Modifying these values incorrectly may break the script or cause
# incorrect behaviour.
# - The script will handle follow-ups and expiry checks automatically.
#
# If you need to change settings, do so in the CONFIGURATION section at
# the top of the script.

# A root-only state directory and a single lock coordinate the daily scan,
# manual runs, and transient follow-up services.
STATE_DIR=/var/lib/ssl-expiry-reminder
CERT_DIR=/etc/letsencrypt/live
SCRIPT_PATH=/usr/local/bin/SSL_Expiry_Reminder.sh
umask 077
mkdir -p "$STATE_DIR" || exit 1
exec 9>"$STATE_DIR/lock" || exit 1
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

# State is four lines: fingerprint, configured interval, pending unit, domain.
# The unit name is a token as well: stale timer invocations cannot send mail.
write_state() {
    local tmp
    tmp=$(mktemp "$STATE_DIR/state.XXXXXXXXXX") || return 1
    if ! printf '%s\n' "$FINGERPRINT" "$INTERVAL" "$UNIT" "$DOMAIN" > "$tmp" || ! mv -f "$tmp" "$STATE_FILE"; then
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

schedule_timer() {
    local token_file token new_unit
    [ -n "$INTERVAL" ] || return 0
    token_file=$(mktemp "$STATE_DIR/timer.XXXXXXXXXX") || return 1
    token=${token_file##*.}
    rm -f "$token_file" || return 1
    new_unit="ssl-expiry-followup-$DOMAIN_HASH-$token"
    # Persist the token before creating the timer. A failed creation is
    # retried by the next scan; a stale callback cannot match a new token.
    UNIT=$new_unit
    write_state || return 1
    if ! systemd-run --on-active="$INTERVAL" --unit="$UNIT" "$SCRIPT_PATH" --follow-up "$DOMAIN" "$UNIT"; then
        echo "Failed to schedule follow-up for $DOMAIN" >&2
        UNIT=
        write_state || return 1
        return 1
    fi
}

process_domain() {
    local DOMAIN=$1 DOMAIN_HASH STATE_FILE CERT_INFO EXPIRY_DATE EXPIRY_TIMESTAMP
    local CURRENT_TIMESTAMP DAYS_LEFT DOMAIN_WARNING_DAYS NEW_FINGERPRINT
    local FINGERPRINT='' INTERVAL='' UNIT='' SAVED_DOMAIN='' OLD_INTERVAL='' EMAIL
    local -a RECIPIENTS
    case "$DOMAIN" in
        ''|*[!a-zA-Z0-9._-]*|.|..) echo "Invalid domain directory: $DOMAIN" >&2; return 1 ;;
    esac
    DOMAIN_HASH=$(printf '%s' "$DOMAIN" | sha256sum) || return 1
    DOMAIN_HASH=${DOMAIN_HASH%% *}
    STATE_FILE="$STATE_DIR/$DOMAIN_HASH"
    if [ -f "$STATE_FILE" ]; then
        { IFS= read -r FINGERPRINT && IFS= read -r OLD_INTERVAL && IFS= read -r UNIT && IFS= read -r SAVED_DOMAIN; } < "$STATE_FILE" || {
            echo "Invalid state for $DOMAIN" >&2; return 1;
        }
        [ "$SAVED_DOMAIN" = "$DOMAIN" ] || { echo "State mismatch for $DOMAIN" >&2; return 1; }
    fi
    # An explicitly empty override differs from an absent array entry.
    INTERVAL=${FOLLOW_UP_INTERVALS[$DOMAIN]-$MASTER_FOLLOW_UP_INTERVAL}
    if [ "$MODE" = follow-up ] && [ "$REQUEST_UNIT" != "$UNIT" ]; then
        return 0
    fi
    if [ ! -f "$CERT_DIR/$DOMAIN/fullchain.pem" ]; then
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
    if [ "$DAYS_LEFT" -gt "$DOMAIN_WARNING_DAYS" ]; then
        cancel_timer || return 1
        [ ! -f "$STATE_FILE" ] || rm -f "$STATE_FILE" || return 1
        return 0
    fi
    if [ "$FINGERPRINT" != "$NEW_FINGERPRINT" ]; then
        cancel_timer || return 1
        FINGERPRINT=
    elif [ "$OLD_INTERVAL" != "$INTERVAL" ]; then
        cancel_timer || return 1
        write_state || return 1
        # A callback for a newly disabled or changed interval is stale.
        [ "$MODE" != follow-up ] || { schedule_timer; return $?; }
    fi
    if [ -z "$FINGERPRINT" ] || [ "$MODE" = follow-up ]; then
        RECIPIENTS=("$MASTER_EMAIL")
        if [ -n "${EMAILS[$DOMAIN]}" ] && [ "${EMAILS[$DOMAIN]}" != "$MASTER_EMAIL" ]; then
            RECIPIENTS+=("${EMAILS[$DOMAIN]}")
        fi
        for EMAIL in "${RECIPIENTS[@]}"; do
            if ! printf 'From: %s\nTo: %s\nSubject: SSL Certificate Expiry Warning for %s\n\nThe SSL certificate for %s expires in %s days.\n\nConsider renewing it soon to avoid downtime.\n' "$SENDER_EMAIL" "$EMAIL" "$DOMAIN" "$DOMAIN" "$DAYS_LEFT" | sendmail -t; then
                echo "Failed to send warning for $DOMAIN" >&2
                return 1
            fi
        done
        FINGERPRINT=$NEW_FINGERPRINT
        UNIT=
        write_state || return 1
    fi
    if [ -n "$INTERVAL" ]; then
        if [ -z "$UNIT" ] || ! systemctl is-active --quiet "$UNIT.timer"; then
            schedule_timer || return 1
        fi
    elif [ -n "$UNIT" ]; then
        cancel_timer || return 1
        write_state || return 1
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
        if [ ! -f "$CERT_DIR/$DOMAIN/fullchain.pem" ]; then
            process_domain "$DOMAIN" || STATUS=1
        fi
    done
    for DOMAIN_PATH in "$CERT_DIR"/*; do
        [ -f "$DOMAIN_PATH/fullchain.pem" ] || continue
        process_domain "${DOMAIN_PATH##*/}" || STATUS=1
    done
fi
exit "$STATUS"
