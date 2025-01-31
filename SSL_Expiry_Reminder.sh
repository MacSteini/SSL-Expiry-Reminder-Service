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
#   settings.
# - Configurable follow-up intervals to send repeated reminders.
# - Uses the systemd-run command to schedule follow-up reminders.
#
# How to Use:
# - Update MASTER_EMAIL with your admin email.
# - Set MASTER_WARNING_DAYS to the default threshold (in days).
# - Define per-domain custom settings (optional).
# - Ensure sendmail (or another MTA) is configured to send emails.
#
# ======================================================================
# Follow-up Reminder Interval Configuration
# ======================================================================
# This setting defines how often follow-up emails should be sent after
# the first warning. If a certificate is near expiry, the script sends a
# warning email and schedules itself to run again after the defined time
# interval (using systemd-run).
#
# The follow-up process will continue indefinitely (at the specified
# interval) until:
# 1. The SSL certificate is renewed (the script detects a new expiry
#    date).
# 2. The server admin manually disables follow-ups (by setting this
#    value to "").
#
# Affected Variables:
# -------------------
# - MASTER_FOLLOW_UP_INTERVAL: Controls the global follow-up schedule
#   (default for all domains).
# - FOLLOW_UP_INTERVALS["yourdomain.com"]: Overrides the global setting
#   for a specific domain.
# - FOLLOW_UP_REQUIRED: DO NOT MODIFY! This flag determines whether a
#   follow-up is needed.
# - systemd-run --on-active=$FOLLOW_UP_INTERVAL: Used to schedule the
#   next execution.
#   - If FOLLOW_UP_INTERVALS["yourdomain.com"] exists, it will replace
#     MASTER_FOLLOW_UP_INTERVAL when scheduling follow-ups for that
#     domain.
#
# How Follow-Ups are Scheduled:
# -----------------------------
# - If a domain has no custom interval, follow-ups use
#   MASTER_FOLLOW_UP_INTERVAL.
# - If FOLLOW_UP_INTERVALS["yourdomain.com"] is set, that domain follows
#   its own schedule.
# - If MASTER_FOLLOW_UP_INTERVAL="", and a domain has no override, no
#   follow-ups are scheduled.
#
# Accepted Formats:
# -----------------
# - "24h"   Every 24 hours (daily follow-ups, recommended default).
# - "12h"   Every 12 hours (twice a day).
# - "48h"   Every 48 hours (every 2 days).
# - "7d"    Every 7 days (weekly follow-ups).
# - "1h30m" Every 1 hour and 30 minutes.
# - "2d3h"  Every 2 days and 3 hours.
# - "10m"   Every 10 minutes.
# - ""      Disables follow-ups (only one initial warning is sent).
#
# Usage Scenarios:
# -----------------
# - If you want daily reminders for all domains, use:
#   MASTER_FOLLOW_UP_INTERVAL="24h"
# - If you want different schedules per domain, define:
#   FOLLOW_UP_INTERVALS["yourdomain1.com"]="11h"
#   FOLLOW_UP_INTERVALS["yourdomain2.com"]="48h"
#   FOLLOW_UP_INTERVALS["yourdomain3.com"]="8h"
#   …and so on
# - If you want to test the script without waiting too long, use:
#   MASTER_FOLLOW_UP_INTERVAL="5m"
# - If you do not want follow-up emails globally, use
#   MASTER_FOLLOW_UP_INTERVAL=""
#   Disables follow-ups unless overridden per domain.
# - If you want to disable follow-ups for only one domain, use:
#   FOLLOW_UP_INTERVALS["yourdomain.com"]=""
#   This domain gets only one email.
#
# ⚠️ Warning ⚠️
# -----------
# - Setting a very short interval (e. g., "10m") may cause excessive
#   emails.
# - Systemd will continue rescheduling the script until the certificate
#   is renewed.
# - If emails become too frequent, either increase the interval or
#   disable follow-ups.
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
#   implications.
# - Modifying these values incorrectly may break the script or cause
#   incorrect behaviour.
# - The script will handle follow-ups and expiry checks automatically.
#
# If you need to change settings, do so in the CONFIGURATION section at
# the top of the script.

# Flag to determine if any follow-up reminders should be scheduled
FOLLOW_UP_REQUIRED=0

for DOMAIN_PATH in /etc/letsencrypt/live/*; do
DOMAIN=$(basename "$DOMAIN_PATH") # Extract the domain name from the directory path

# Skip domains that do not have a certificate file
if [ ! -f "$DOMAIN_PATH/fullchain.pem" ]; then
continue
fi

# Retrieve the certificate expiry date
EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$DOMAIN_PATH/fullchain.pem" | cut -d= -f2)
EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s) # Convert expiry date to a timestamp
CURRENT_TIMESTAMP=$(date +%s) # Get the current timestamp
DAYS_LEFT=$(((EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400)) # Calculate days until expiry

# Determine the warning threshold (use domain-specific setting if
# available, otherwise use the master setting)
DOMAIN_WARNING_DAYS=${WARNING_DAYS[$DOMAIN]:-$MASTER_WARNING_DAYS}

# If the certificate is expiring within the warning period,
# send a reminder
if [ "$DAYS_LEFT" -le "$DOMAIN_WARNING_DAYS" ]; then

# Always include the master email recipient first…
RECIPIENTS=("$MASTER_EMAIL")

# …and add domain-specific recipients if specified
if [ -n "${EMAILS[$DOMAIN]}" ]; then
RECIPIENTS+=("${EMAILS[$DOMAIN]}")
fi

# Construct the email subject and body
SUBJECT="SSL Certificate Expiry Warning for $DOMAIN"
MESSAGE="The SSL certificate for $DOMAIN expires in $DAYS_LEFT days.\n\nConsider renewing it soon to avoid downtime…"

# Send individual emails to each recipient
for EMAIL in "${RECIPIENTS[@]}"; do
echo -e "From: $SENDER_EMAIL\nTo: $EMAIL\nSubject: $SUBJECT\n\n$MESSAGE" | sendmail -t
done

# Indicate that follow-up reminders should be scheduled
FOLLOW_UP_REQUIRED=1
fi
done

# If any certificates are due for renewal, reschedule the script to run again
# after the defined follow-up interval
if [ "$FOLLOW_UP_REQUIRED" -eq 1 ]; then
systemd-run --on-active="$MASTER_FOLLOW_UP_INTERVAL" --unit=ssl-expiry-followup /usr/local/bin/SSL_Expiry_Reminder.sh
fi