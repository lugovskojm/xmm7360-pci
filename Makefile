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

# Soft reset: unbind + PCI rescan. Safer than ACPI _RST on ThinkPads where
# the root port shares a power rail with Thunderbolt and freezes the system.
reset:
	@if [ -z "$(PCI_SLOT)" ]; then echo "PCI_SLOT is empty: no Intel XMM7360 found via lspci. Set PCI_SLOT=0000:xx:yy.z manually."; exit 1; fi
	-sudo /sbin/rmmod xmm7360
	echo 1 | sudo tee /sys/bus/pci/devices/$(PCI_SLOT)/remove
	sleep 2
	echo 1 | sudo tee /sys/bus/pci/rescan
	sleep 3

# Hard reset via ACPI _RST. WARNING: on some ThinkPads (X280, some X1 Carbon
# revisions) this freezes the machine because the root-port reset propagates
# to the Thunderbolt controller. Only use if `make reset` is not enough and
# you have saved your work.
reset-acpi:
	@if [ -z "$(PCI_SLOT)" ]; then echo "PCI_SLOT is empty"; exit 1; fi
	-sudo /sbin/rmmod xmm7360
	sudo dd if=/sys/bus/pci/devices/$(PCI_SLOT)/config of=/tmp/xmm_cfg bs=256 count=1 status=none
	sudo modprobe acpi_call
	echo '$(ACPI_PATH)' | sudo tee /proc/acpi/call
	sleep 5
	sudo dd of=/sys/bus/pci/devices/$(PCI_SLOT)/config if=/tmp/xmm_cfg bs=256 count=1 status=none
