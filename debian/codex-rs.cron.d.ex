#
# Regular cron jobs for the codex-rs package
# See dh_installcron(1) and crontab(5).
#
#0 4	* * *	root	[ -x /usr/bin/codex-rs_maintenance ] && /usr/bin/codex-rs_maintenance
