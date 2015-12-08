CC=gcc
CFLAGS_FUSE=$(shell pkg-config fuse --cflags)
LDLIBS_FUSE=$(shell pkg-config fuse --libs)
LDFLAGS=-Wall
BINARIES=wwan_ctl qcqmifs flush-wdm
CFLAGS_USB=$(shell pkg-config libusb-1.0 --cflags)
LDLIBS_USB=$(shell pkg-config libusb-1.0 --libs)

# Sierra Linux QMI SDK - partly from /usr/local/src/git/swi-slqs/pkgs/slqscompile.mak 
SDKPATH=/usr/local/src/git/swi-slqs
SDKCPU=hosti686
CFLAGS_SDK=-m32 -Wall -Werror -Wextra -DSDK_EXE='$(SDKPATH)/build/bin/$(SDKCPU)/slqssdk'
LDLIBS_SDK=-Wl,--start-group -lrt -lpthread -lslqsapi -lslqscore -lslqsqmi -Wl,--end-group
LDFLAGS_SDK=-L/usr/lib32 -L$(SDKPATH)/build/lib/$(SDKCPU) -static
inc_paths=$(shell echo $(SDKPATH)/api/*/inc)
INCLUDE_SDK=-I$(SDKPATH)/api -I$(SDKPATH)/api/inc $(inc_paths:%=-I%)

all: $(BINARIES)

clean:
	rm -rf *.o *.so *.lo *~ $(BINARIES) .libs

wwan_ctl: wwan_ctl.c
	gcc -o wwan_ctl wwan_ctl.c

qmi-prober: qmi-prober.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

libusbopen: libusbopen.c
	$(CC) $(CFLAGS_USB) $(LDFLAGS) -o $@ $^ $(LDLIBS_USB)

qcqmifs: qcqmifs.c
	$(CC) $(CFLAGS) $(CFLAGS_FUSE) $(LDFLAGS) -o $@ $^ $(LDLIBS) $(LDLIBS_FUSE)

cuseqmi: cuseqmi.c
	$(CC) $(CFLAGS) $(CFLAGS_FUSE) $(LDFLAGS) -lpthread -o $@ $^ $(LDLIBS) $(LDLIBS_FUSE)

swi-firmware: swi-firmware.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

swi-sdk-firmware: swi-sdk-firmware.c
	$(CC) $(CFLAGS_SDK) $(INCLUDE_SDK) $(LDFLAGS_SDK) -static -lrt -lpthread -o $@ $^ $(LDLIBS_SDK)

flush-wdm: flush-wdm.c
	$(CC) $(CFLAGS_USB) $(LDFLAGS) -o $@ $^ $(LDLIBS_USB)
