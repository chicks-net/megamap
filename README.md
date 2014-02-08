megamap
=======

MegaRAID(tm) Linux drive mapper

Usage
-----

Run the `megamap` script and it will produce a map of MegaRAID drive ID to Linux drive `sd*` and also displays the WWN from Linux.

Requirements
------------

* you need the `megacli` tool which probably needs to be run as `root`
* Readonly Perl module (debian package libreadonly-perl)

Notes
-----

* the Linux WWN is off-by-one from what megacli shows.
* thanks to http://serverfault.com/questions/381177/megacli-get-the-dev-sd-device-name-for-a-logical-drive/ for getting me to look in `/dev/disk/by-id`

Ideas
-----

* a script to use the megamap to blink a drive based on the linux drive `sd*`
