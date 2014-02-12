megamap
=======

MegaRAID(tm) Linux drive mapper

Usage
-----

Run the `megamap` script and it will produce a map of MegaRAID drive ID to Linux drive `sd*` and also displays the WWN from Linux.

Requirements
------------

* you need the `megacli` tool which needs to be run as `root`
* Readonly Perl module (debian package libreadonly-perl)

Usage
-----

`megamap` takes no arguments and outputs a table of drive mappings such as:

	$ sudo megamap
	0       sdc     0x5000cca02ab9e1a0
	1       sdf     0x5000cca02ab9b548
	2       sde     0x5000cca02ab9bad0
	3       sdd     0x5000cca02ab9b928
	4       sdh     0x5000cca02ab9b5e8
	5       sdg     0x5000cca02ab9b86c
	6       sdj     0x5000cca02ab9b8c0
	7       sdi     0x5000cca02ab9dde8
	8       sdn     0x5000cca02ab9b34c
	9       sdk     0x5000cca02ab9e7d8
	10      sdl     0x5000cca02ab9e0c0
	11      sdm     0x5000cca02ab9b350

`megablink` takes arguments of linux drives like `/dev/sda` or without the full path such as `sdb` and starts that drive blinking.  Unblinking happens when the drive is replaced automatically, so there is no reversal script at this point.

	$ sudo ./megablink /dev/sdn
	blinking drive 8 (sdn), running megacli -PdLocate -start -physdrv[0:8] -a0
                                     
	Adapter: 0: Device at EnclId-0 SlotId-8  -- PD Locate Start Command was successfully sent to Firmware 

	Exit Code: 0x00

Notes
-----

* the Linux WWN is off-by-one from what megacli shows.
* thanks to http://serverfault.com/questions/381177/megacli-get-the-dev-sd-device-name-for-a-logical-drive/ for getting me to look in `/dev/disk/by-id`

Ideas
-----

* try to make perlcritic happier
* verify that it works on a system with more than 26 attached drives (the author does not currently have accesss tosuch a system)
* support multiple adapters through command line arguments or environment variables
