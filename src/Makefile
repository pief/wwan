all: wwan_ctl qmi-prober

wwan_ctl: wwan_ctl.c
	gcc -o wwan_ctl wwan_ctl.c

qmi-prober: qmi-prober.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

