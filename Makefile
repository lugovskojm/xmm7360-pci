obj-m := xmm7360.o

KVERSION ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVERSION)/build
PWD := $(shell pwd)
ccflags-y := -Wno-multichar -Wno-declaration-after-statement

# PCI slot of the modem. Auto-detected from lspci (Intel XMM7360, 8086:7360).
# Override on the CLI if autodetect fails, e.g. `make reset PCI_SLOT=0000:02:00.0`.
PCI_SLOT ?= $(shell lspci -D -d 8086:7360 | awk '{print $$1}' | head -n1)

# ACPI path used to toggle the device power (_RST). Differs per laptop:
#   - ThinkPad X1 Carbon G6/G7: \_SB.PCI0.RP07.PXSX._RST
#   - ThinkPad X280:            \_SB.PCI0.RP09.PXSX._RST
#   - ThinkPad T480/T480s:      \_SB.PCI0.RP01.PXSX._RST
# Override on the CLI, e.g. `make reset ACPI_PATH='\_SB.PCI0.RP09.PXSX._RST'`.
ACPI_PATH ?= \_SB.PCI0.RP09.PXSX._RST

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

load:
	-sudo /sbin/rmmod iosm
	-sudo /sbin/rmmod xmm7360
	sudo /sbin/insmod xmm7360.ko

unload:
	sudo /sbin/rmmod xmm7360

# Soft reset: just reload the kernel module. This is the ONLY reset path
# proven safe on ThinkPad X280. Do NOT touch the PCI slot or ACPI _RST on
# X280 — the root port (RP09) shares a power rail with the Thunderbolt
# controller and any reset propagates, freezing the machine hard.
reset:
	-sudo /sbin/rmmod xmm7360
	sleep 1
	sudo /sbin/modprobe xmm7360
	sleep 2

# PCI sysfs remove/rescan. Works on most laptops, but on ThinkPad X280
# this has also been observed to freeze the machine (same RP09 power
# rail issue). If `make reset` is not enough, try this — but save your
# work first.
reset-pci:
	@if [ -z "$(PCI_SLOT)" ]; then echo "PCI_SLOT is empty: no Intel XMM7360 found via lspci. Set PCI_SLOT=0000:xx:yy.z manually."; exit 1; fi
	@echo "WARNING: PCI remove/rescan on RP09 has frozen ThinkPad X280 in the past. Ctrl+C now to abort. Sleeping 5s..."
	@sleep 5
	-sudo /sbin/rmmod xmm7360
	echo 1 | sudo tee /sys/bus/pci/devices/$(PCI_SLOT)/remove
	sleep 2
	echo 1 | sudo tee /sys/bus/pci/rescan
	sleep 3

# Hard reset via ACPI _RST.
#
# !!! DO NOT USE ON THINKPAD X280 !!!
#
# On X280 (and some X1 Carbon G6 revisions) the RP09 ACPI _RST propagates
# to the Thunderbolt controller and freezes the entire system. The user
# must hard-power-off the laptop. Only use on hardware where you know the
# modem root port is on its own power rail.
reset-acpi:
	@if [ -z "$(PCI_SLOT)" ]; then echo "PCI_SLOT is empty"; exit 1; fi
	@echo "DANGER: ACPI _RST on RP09 freezes ThinkPad X280. Abort with Ctrl+C. Sleeping 10s..."
	@sleep 10
	-sudo /sbin/rmmod xmm7360
	sudo dd if=/sys/bus/pci/devices/$(PCI_SLOT)/config of=/tmp/xmm_cfg bs=256 count=1 status=none
	sudo modprobe acpi_call
	echo '$(ACPI_PATH)' | sudo tee /proc/acpi/call
	sleep 5
	sudo dd of=/sys/bus/pci/devices/$(PCI_SLOT)/config if=/tmp/xmm_cfg bs=256 count=1 status=none
