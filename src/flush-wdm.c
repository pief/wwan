/*
 *  Copyright 2012 Bjørn Mork <bjorn@mork.no>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License.
 */

#include <stdio.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <getopt.h>
#include <string.h>
#include <libusb.h>
#include <linux/types.h>

/* dump device info */
static void print_usb_device(libusb_device_handle *handle)
{
	libusb_device *dev;
	struct libusb_device_descriptor desc;
	int err;

	dev = libusb_get_device(handle);
	if (dev == NULL)
		return;

	err = libusb_get_device_descriptor(dev, &desc);
	if (err)
		return;

	printf("bLength=%d\nbDescriptorType=%d\nbDeviceClass=%x\nidVendor=%04x\nidProduct=%04x\n",
		desc.bLength, desc.bDescriptorType, desc.bDeviceClass, desc.idVendor, desc.idProduct);
}

/* open the given device */
static libusb_device_handle *open_device(char *device)
{
	uint16_t vendor_id = 0, product_id = 0;

	if ((sscanf(device, " %hx : %hx ", &vendor_id, &product_id) != 2) || (vendor_id == 0) || (product_id == 0))
		return NULL;

	return libusb_open_device_with_vid_pid(NULL, vendor_id, product_id);
}

static int read_reply(libusb_device_handle *handle, int interface, unsigned char *buf, int size)
{
	int ret;

        ret = libusb_control_transfer(handle, 
				LIBUSB_ENDPOINT_IN + LIBUSB_REQUEST_TYPE_CLASS + LIBUSB_RECIPIENT_INTERFACE,  /* 0xa1 */
				1, /* CDC GET_ENCAPSULATED_RESPONSE */
				0, /* zero */
				interface, /* wIndex = interface */
				buf,
				size,
				1000);

	fprintf(stderr, "%s: libusb_control_transfer() returned %d\n",  __FUNCTION__, ret);
	return ret;
}

static struct option main_options[] = {
	{ "help",	0, 0, 'h' },
	{ "device",     1, 0, 'd' },
	{ "interface",  1, 0, 'i' },
	{ 0, 0, 0, 0 }
};


void usage(char *prog)
{
	fprintf(stderr, "Usage: %s --device vid:pid [--interface N]\n\n", prog);
}

int main(int argc, char *argv[])
{
	char *prog, *device = NULL;
	int i, opt, ret, interface = 0;
	libusb_device_handle *handle;
	unsigned char buf[500];
	int size = sizeof(buf);

	prog = argv[0];
	while ((opt = getopt_long(argc, argv, "d:i:h", main_options, NULL)) != -1) {
		switch(opt) {
		case 'd':
			device = strdup(optarg);
			break;
		case 'i':
			interface = atoi(optarg);
			break;
		case 'h':
			usage(prog);
			exit(0);
		}
	}

	if (!device) {
		usage(prog);
		exit(0);
	}

	if ((ret = libusb_init(NULL))) {
		fprintf(stderr, "libusb_init() failed: %d\n", ret);
		exit(1);
	}
	
	if ((handle = open_device(device))) {
		print_usb_device(handle);
		ret = libusb_claim_interface (handle, interface);

		/* flush pending messages */
		i = 1;
		while (i > 0)
			i = read_reply(handle, interface, buf, size);
		ret = libusb_release_interface(handle, interface);
	} else {
		fprintf(stderr, "failed to open device \"%s\"\n", device);
	}
		
	libusb_exit(NULL);

	return ret;
}
