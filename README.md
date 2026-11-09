# Let’s Encrypt SSL Certificate Expiry Reminder Service
A Bash script that monitors SSL certificate expiry dates and sends email notifications to designated recipients, ensuring timely renewals and uninterrupted secure connections.
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
My main motivation for publishing these few lines of code was the recent [announcement by Let’s Encrypt](https://letsencrypt.org/2025/01/22/ending-expiration-emails/ "Ending Support for Expiration Notification Emails (Let’s Encrypt)") about ending notification emails for domain expiry.

I don’t expect an uproar, but if there is one – this repo is here to ease your pain… ;-)

This script automates the monitoring of SSL certificates by checking their expiry dates and sending email alerts to specified recipients when certificates are nearing expiry. It supports both global and per-domain configurations, allowing for flexible management across multiple domains.
## Features

- **Automated Monitoring**: Periodically checks SSL certificate expiry dates for all domains managed by Let’s Encrypt on the server.
- **Email Notifications**: Sends alerts to a master email address and optional domain-specific recipients when certificates are approaching expiry.
- **Customisable Settings**: Allows global and per-domain configurations for warning thresholds and follow-up intervals.
- **`Systemd` Integration**: Utilises `systemd` timers to schedule regular checks and follow-up reminders.

## Requirements

- Operating System: Linux-based system with `systemd` support.
- Dependencies:
	- `bash`
	- `openssl`
	- `sendmail`
	- `systemd` (`systemd-run` and `systemctl`)
	- `flock` (util-linux), `sha256sum`, `date`, `mktemp`, and `sed`

## Installation

1. Download the Script:
	- Save the script as `/usr/local/bin/SSL_Expiry_Reminder.sh`
1. Make the Script Executable:
	```bash
	sudo chmod +x /usr/local/bin/SSL_Expiry_Reminder.sh
	```
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
		```bash
		[Unit]
		Description=Runs the SSL Expiry Reminder Script Daily

		[Timer]
		OnCalendar=*-*-* 00:00:00 # Runs daily at midnight
		Persistent=true

		[Install]
		WantedBy=timers.target
		```
1. Enable and Start the Timer:
	```bash
	sudo systemctl daemon-reload && sudo systemctl enable SSL-Expiry.timer && sudo systemctl start SSL-Expiry.timer
	```

## Configuration
Edit the `/usr/local/bin/SSL_Expiry_Reminder.sh` script to customise the following settings:

- Global Settings:
	- `MASTER_EMAIL`: Primary email to receive all expiry reminders.
	- `MASTER_WARNING_DAYS`: Default number of days before expiry to trigger a reminder.
	- `MASTER_FOLLOW_UP_INTERVAL`: Default interval for follow-up reminders (e. g., “24h” for daily).
	- `SENDER_EMAIL`: Sender email address for reminders.
- Per-Domain Custom Settings (Optional):
	- `EMAILS["yourdomain.com"]`: Additional email recipients for specific domains.
	- `WARNING_DAYS["yourdomain.com"]`: Custom warning thresholds for specific domains.
	- `FOLLOW_UP_INTERVALS["yourdomain.com"]`: Custom follow-up intervals for specific domains.

Set an interval to an empty string to disable follow-ups. An explicitly empty `FOLLOW_UP_INTERVALS["domain"]` disables them for that domain, even when the master interval is set. If the master interval is empty, domains with a non-empty override still receive follow-ups. Non-empty intervals are systemd time spans such as `11h` or `1h30m`.

Ensure that `sendmail` is correctly configured. Run all scheduled and manual invocations as the same privileged user, with access to the certificates and system systemd manager.

## Usage

The daily `SSL-Expiry.timer` discovers certificates entering their warning period. The first scan sends a warning and, when enabled, schedules a separate transient follow-up timer for each domain. Follow-ups check and notify only their own domain. A daily or manual scan does not send the same warning again merely because another timer ran. A renewed certificate is treated as a new certificate; a certificate outside its warning period has its pending timer cancelled.

The script stores fingerprints and pending timer identifiers under `/var/lib/ssl-expiry-reminder/` and uses `flock` to serialise scans and follow-ups. Keep this directory private and persistent. Removing it loses the reminder history and may cause another initial warning. After a reboot, transient timers are recreated by the next daily or manual scan, starting a fresh interval; missed follow-ups are not replayed. Changed intervals are applied on the next scan or follow-up. Systemd timer accuracy and service execution time may delay a reminder.

Run a scan manually or inspect the daily timer:

```sh
sudo /usr/local/bin/SSL_Expiry_Reminder.sh
systemctl status SSL-Expiry.timer
```

Inspect follow-up timers and their logs with:

```sh
systemctl list-timers --all 'ssl-expiry-followup-*'
journalctl -u 'ssl-expiry-followup-*'
```

### Upgrade and stopping reminders

After upgrading from the original version, stop the old shared follow-up timer once, then run a scan to establish the new per-domain timers:

```sh
sudo systemctl stop ssl-expiry-followup.timer
sudo /usr/local/bin/SSL_Expiry_Reminder.sh
```

If the old timer is absent, systemd may report that it could not be found. The new scan does not require the old timer to exist. To disable follow-ups, set the master interval and any domain overrides to empty strings, then run a scan so pending timers are cancelled. The daily timer continues to detect newly expiring or renewed certificates. To stop automatic discovery too, run `sudo systemctl disable --now SSL-Expiry.timer`.

## Troubleshooting

If scheduling or mail delivery fails, the script exits unsuccessfully and reports the affected domain. Check the service journal and correct the problem. A later daily or manual scan retries missing timers; failed mail delivery may need another scan. If delivery succeeds for some recipients but fails for others, a retry may repeat mail to the successful recipients. A crash after mail is accepted but before the state is saved can also lead to a repeated warning.

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
