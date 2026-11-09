# Let’s Encrypt SSL Certificate Expiry Reminder Service
A Bash script that checks local SSL certificate expiry dates and emails reminders to designated recipients.
## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Licence](#licence)

## Overview
My main motivation for publishing these few lines of code was the [announcement by Let’s Encrypt](https://letsencrypt.org/2025/01/22/ending-expiration-emails/ "Ending Support for Expiration Notification Emails (Let’s Encrypt)") about ending notification emails for domain expiry.

I don’t expect an uproar, but if there is one – this repo is here to ease your pain… ;-)

This script automates the monitoring of SSL certificates by checking their expiry dates and sending email alerts to specified recipients when certificates are nearing expiry. It supports both global and per-domain configurations, allowing for flexible management across multiple domains.
## Features

- **Automated Monitoring**: Periodically checks certificate files under `/etc/letsencrypt/live/`.
- **Email Notifications**: Sends alerts to a master email address and optional domain-specific recipients when certificates are approaching expiry.
- **Customisable Settings**: Allows global and per-domain configurations for warning thresholds and follow-up intervals.
- **`Systemd` Integration**: Utilises `systemd` timers to schedule regular checks and follow-up reminders.

## Requirements

- Operating System: Linux-based system with `systemd` support.
- Dependencies:
	- Bash 4 or later
	- `openssl`
	- `sendmail`
	- `systemd` (`systemd-run`, `systemctl`, and `systemd-analyze`)
	- `flock` (util-linux), GNU coreutils (`sha256sum`, `stat`, `realpath`, `date`, and `mktemp`), and `sed`

`systemd-analyze timespan` is required for regular follow-up intervals. It is available in upstream systemd 240 and later, or in older distribution versions that backport it. Check with `systemd-analyze timespan 24h` before upgrading; without it, regular follow-ups cannot be scheduled.

## Installation

The paths below use `/usr/local/bin/SSL_Expiry_Reminder.sh` as an example. If you choose another location, use its absolute path throughout the installation and in the systemd service's `ExecStart`.

The service runs with administrator privileges. Anyone who can modify or replace the script can therefore execute code with those privileges. For a more secure installation, consider a root-owned script in a location where untrusted users cannot modify the file or its parent directories, including paths reached through symbolic links. For example, a user-writable home directory allows its owner to replace the script even if the file itself is owned by root. Choose a location appropriate for your server and who can access it.

1. Download the Script:
	- Save the script as `/usr/local/bin/SSL_Expiry_Reminder.sh`
1. Make the Script Executable:
	```sh
	sudo chmod +x /usr/local/bin/SSL_Expiry_Reminder.sh
	```
1. Configure the Script:
	- Set your email addresses and any desired warning and follow-up settings as described in [Configuration](#configuration). Replace or remove the example domain groups.
1. Create `Systemd` Service File:
	- Path: `/usr/lib/systemd/system/SSL-Expiry.service`
	- Content:
		```ini
		[Unit]
		Description=SSL Expiry Reminder Service
		After=network.target

		[Service]
		Type=oneshot
		ExecStart=/usr/local/bin/SSL_Expiry_Reminder.sh
		```
1. Create Systemd Timer File:
	- Path: `/usr/lib/systemd/system/SSL-Expiry.timer`
	- Content:
		```ini
		[Unit]
		Description=Runs the SSL Expiry Reminder Script Daily

		[Timer]
		# Runs daily at midnight
		OnCalendar=*-*-* 00:00:00
		Persistent=true

		[Install]
		WantedBy=timers.target
		```
1. Enable and Start the Timer:
	```sh
	sudo systemctl daemon-reload && sudo systemctl enable SSL-Expiry.timer && sudo systemctl start SSL-Expiry.timer
	```

## Configuration
Edit the `/usr/local/bin/SSL_Expiry_Reminder.sh` script to customise the following settings:

- Global Settings:
	- `MASTER_EMAIL`: Primary email to receive all expiry reminders.
	- `MASTER_WARNING_DAYS`: Default number of days before expiry to trigger a reminder.
	- `MASTER_FOLLOW_UP_INTERVAL`: Default interval for follow-up reminders (e. g., “24h” for daily).
	- `SENDER_EMAIL`: Sender email address for reminders.

For optional per-domain settings, add a `configure_domains` line for one or more certificate names. Each name is the directory name under `/etc/letsencrypt/live/`:

```sh
sudo ls -1 /etc/letsencrypt/live/
```

```sh
configure_domains "Domain Admin <team@example.com>" 10 "11h" \
    example.com www.example.com shop.example.com
```

The arguments are the additional recipient, the warning threshold in **days**, the follow-up interval, and one or more certificate names. Each name refers to a certificate directory, not necessarily every domain covered by that certificate. All names in the group share those settings. The master recipient still receives the warning. Use `""` for no additional recipient, or for the default warning threshold. Domains not listed use the master settings. If a domain appears in multiple groups, the last group takes precedence.

Follow-up intervals use systemd time spans: for example, `"30min"`, `"11h"`, `"1d"`, `"2w"`, `"1y"`, or `"1h30m"`. A year is a fixed duration of 365.25 days, not a calendar anniversary. Intervals must be positive and less than one billion seconds (about 31.7 years); fractions of a second are rounded up. An empty interval disables follow-ups for that group, even if the master interval is set. If the master interval is empty, groups with a non-empty interval still receive follow-ups. Failed initial warnings are retried even when follow-ups are disabled.

Ensure that `sendmail` is correctly configured. Run all scheduled and manual invocations as the same privileged user, with access to the certificates and system systemd manager.

## Usage

The daily `SSL-Expiry.timer` discovers certificates entering their warning period. When a certificate is first found within its warning period, the scan sends a warning and, when enabled, schedules a separate transient follow-up timer for it. Follow-ups check and notify only their own certificate. A daily or manual scan does not send the same warning again merely because another timer ran. A renewed certificate is treated as a new certificate; a certificate outside its warning period has its pending timer cancelled.

The script keeps reminder history under `/var/lib/ssl-expiry-reminder/`. Keep this directory private and persistent: removing it may cause another initial warning. The directory must belong to the user running the script and must not grant group or other users access; the script refuses to run if it is unsafe. After a reboot, the next daily or manual scan attempts to send one overdue reminder or schedules it for its original due time. Multiple missed reminders are not sent. Reminders may be delayed by systemd or by the time the script takes to run. Changes to follow-up intervals take effect at the next scan or follow-up; a pending retry keeps its existing schedule.

If a message cannot be submitted to the local mail system, the script retries after 15 minutes, then 30 minutes, one hour, two hours and, thereafter, every four hours. It continues after expiry while the certificate remains present and within the warning period. Once the message is accepted, the normal follow-up schedule resumes. Acceptance by the local mail system does not guarantee delivery to the recipient.

Run a scan manually or inspect the daily timer:

```sh
sudo /usr/local/bin/SSL_Expiry_Reminder.sh
systemctl status SSL-Expiry.timer
```

Inspect follow-up timers and their logs with:

```sh
systemctl list-timers --all 'ssl-expiry-followup-*'
sudo journalctl -u 'ssl-expiry-followup-*'
```

### Upgrade and stopping reminders

Before replacing the script, save your email addresses, warning thresholds and follow-up intervals. Copy them into the new script after upgrading. Check its ownership and permissions as described under Installation.

If you choose to move the script, install the new copy at the chosen location and update the service's `ExecStart` path. Follow-up timers use the resolved path of the script at the time they are created, even if it was started through a symbolic link. Existing timers therefore still point to the old file if you move it or change the link. Keep the old copy in place until you have recreated them:

```sh
sudo systemctl daemon-reload
sudo systemctl stop 'ssl-expiry-followup-*.timer'
sudo systemctl start SSL-Expiry.service
sudo systemctl list-timers --all 'ssl-expiry-followup-*'
```

After checking that the scan succeeded and any expected follow-up timers have been recreated, you can remove the old copy. A reminder that was already due may be sent during the scan.

To disable follow-ups, set the master interval and any group intervals to empty strings, then run a scan so pending regular follow-up timers are cancelled. Retries of failed mail submissions remain active. The daily timer continues to detect newly expiring or renewed certificates. To stop automatic discovery too, run `sudo systemctl disable --now SSL-Expiry.timer`.

## Troubleshooting

If scheduling or mail submission fails, the script exits unsuccessfully and reports the affected domain. Check the service journal and correct the problem. A later daily or manual scan recovers missing timers or processes overdue reminders. If submission succeeds for some recipients but fails for others, a retry may repeat mail to the successful recipients. A crash after mail is accepted but before the state is saved can also lead to a repeated warning.

## Contributing
Contributions are welcome! Please follow these steps:

1. Fork this repository
2. Create a feature branch: `git checkout -b feature-branch`
3. Commit your changes: `git commit -m "Add feature"`
4. Push the branch: `git push origin feature-branch`
5. Submit a pull request

Please ensure all changes are well-documented and tested.

**Suggestions for improvements are highly encouraged!** Please ensure that your contributions adhere to the project’s coding standards and include appropriate documentation.
## Licence
This project is licenced under the [MIT Licence](https://opensource.org/license/mit "MIT Licence"). You are free to use, modify, and distribute this project in compliance with the licence terms.
