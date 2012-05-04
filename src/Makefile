CC=gcc
CFLAGS_FUSE=$(shell pkg-config fuse --cflags)
LDLIBS_FUSE=$(shell pkg-config fuse --libs)
LDFLAGS=-Wall
BINARIES=wwan_ctl qcqmifs

all: $(BINARIES)

clean:
	rm -rf *.o *.so *.lo *~ $(BINARIES) .libs

wwan_ctl: wwan_ctl.c
	gcc -o wwan_ctl wwan_ctl.c

qmi-prober: qmi-prober.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

qcqmifs: qcqmifs.c
	$(CC) $(CFLAGS) $(CFLAGS_FUSE) $(LDFLAGS) -o $@ $^ $(LDLIBS) $(LDLIBS_FUSE)

