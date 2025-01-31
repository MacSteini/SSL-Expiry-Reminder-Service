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
	- `systemd`
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

> Ensure that the `sendmail` service is correctly configured to send emails from your server.

## Usage
Once installed and configured, the script will automatically run daily (as scheduled by the `systemd` timer) to check SSL certificate expiry dates and send notifications as configured. Follow-up reminders will be sent based on the defined intervals until the certificates are renewed.

To manually run the script:
```bash
sudo /usr/local/bin/SSL_Expiry_Reminder.sh
```
To check the status of the `systemd` timer:
```bash
systemctl status SSL-Expiry.timer
```
## Troubleshooting
If you encounter issues with the script not executing properly, or `systemd` indicates that the follow-up service is already running, follow these steps to resolve them.
### How to Completely Stop the Running Script & Follow-Ups
#### Cancel Any Running Instances
Run the following command to stop any active instances of the script:
```bash
sudo systemctl stop ssl-expiry-followup.service
```
Then, check if it is still running:
```bash
systemctl list-units --type=service | grep ssl-expiry
```
#### Reset `Systemd` Failed States
Sometimes, `systemd` marks a service as “failed” even if it is not actively running. Reset this status with:
```bash
sudo systemctl reset-failed ssl-expiry-followup.service
```
#### Remove Any Stuck Timer Units
If the error persists, remove the fragment file that may be stuck in `/run/systemd/transient/`:
```bash
sudo systemctl reset-failed && sudo systemctl daemon-reexec
```
This clears any transient `systemd` jobs, including orphaned ones that might be blocking execution.
#### Check for Other Running Instances
If you are still seeing errors, check if the `systemd` timer (`SSL-Expiry.timer`) is active:
```bash
systemctl list-timers --all | grep ssl-expiry
```
If it is, disable it:
```bash
sudo systemctl stop ssl-expiry.timer && sudo systemctl disable ssl-expiry.timer
```
#### (Optional) Completely Remove the Follow-Up Service
If you no longer require follow-ups, you can delete the transient follow-up unit:
```bash
sudo rm -f /run/systemd/transient/ssl-expiry-followup.service && sudo systemctl daemon-reload
```
### What Happens Next?
After these steps, your system will no longer have any running instances of the script or follow-ups. You can now safely run the script again manually using:
```bash
sudo /usr/local/bin/SSL_Expiry_Reminder.sh
```
If you want to re-enable scheduled checks, restart the timer:
```bash
sudo systemctl enable --now SSL-Expiry.timer
```
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