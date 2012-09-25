#!/usr/bin/perl
# Copyright 2012 Bjørn Mork <bjorn@mork.no>
# License: GPLv2

use strict;
use warnings;
use Getopt::Long;
use Device::USB;
use Data::Dumper;

# defaults
my %opt = (
    'debug' => 0, 
    'cfg' => 1,
);

GetOptions(\%opt,
	   'device=s',
	   'debug|d+',
	   'cfg=i',
	   'help|h|?',
    );

&usage if ($opt{'help'} || !$opt{'device'});

my $usb = Device::USB->new();
$usb->debug_mode($opt{'debug'});

my ($vid, $pid) = map { hex } split(/:/, $opt{'device'});

my $dev = $usb->find_device($vid, $pid);
die "Cannot find any such device: $opt{'device'} - $!\n" unless $dev;

warn "Device: ", sprintf("%04x:%04x", $dev->idVendor(), $dev->idProduct()), "\n";

$dev->open();
my ($ret, $descr) = &set_config($dev, $opt{cfg});

sub set_config {
    my ($dev, $cfg) = @_;
    my $reqtype = 0x00;   # USB_DIR_OUT | USB_TYPE_STANDARD | USB_RECIP_DEVICE
    my $req = 0x09;       # USB_REQ_SET_CONFIGURATION
    my $wValue = 0x0;
    
    return (-1, undef) unless $cfg;

    my $buf = 0 x 512; # pre-allocate buffer - libusb is not perl!
    my $ret = $dev->control_msg($reqtype,
				$req,
				$cfg, # bConfigurationValue
				0, # wIndex
				$buf,
				0, # wLength
				1000);  # timeout in ms

    printf "usb_control_msg(0x%02x, 0x%02x, 0x%02x, 0x%04x, 0x%04x) returned $ret\n", $reqtype, $req, $cfg, 0, 0;
    return ($ret, $buf);
}


sub usage {
    warn <<EOT
      Usage:
	$0 [--debug] --device=<idVendor:idProduct> --cfg=<num>

      Options:
	--debug
	    debug output
	--device
	    USB device ID to test - required
        --cfg
            new configuration value

      Example:
	$0 --device=1199:68a2 --cfg=2

EOT
;
    exit 0;
}
