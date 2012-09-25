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
);

GetOptions(\%opt,
	   'device=s',
	   'debug|d+',
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

my $mscode = 0;
foreach my $idx (@ARGV) {
    if ($idx =~ s/^0x// || $idx =~ /[a-f]/i) {
	$idx = hex($idx);
    }
    my $result = $dev->get_string_simple($idx);
    printf "%#04x: %s", $idx, $result || '(none)';

    # MS special thingy - string is converted from utf16le to single bytes,so ignore padding byte
    if ($idx = 0xee && $result && $result =~ /^MSFT100(.)$/) {
	$mscode = unpack("C", $1);
	printf ", code=%#04x (%d)", $mscode, $mscode;
    }
    map { printf " %02x", $_ } unpack("C*", $result) if ($opt{debug} && $result);

    print "\n";
    
}

my ($ret, $descr) = &get_ms_descriptor($dev, $mscode, 0x0001);

($ret, $descr) = &get_ms_descriptor($dev, $mscode, 0x0004);
if ($ret > 0) {
    print "MS descriptor:\n";
    map { printf " %02x", $_ } unpack("C*", $descr);
    print "\n";


    # decoding header:
    my ($dwLength, $bcdVersion, $wIndex, $bCount) = unpack("VvvC", $descr);
    printf "dwLength=$dwLength, bcdVersion=%04x, wIndex=$wIndex, bCount=$bCount\n", $bcdVersion;
    $descr = substr($descr, 16);

    # decode each function
    for (my $i = 0; $i < $bCount; $i++) {
	my ($bFirstInterfaceNumber, $bInterfaceCount, $compatibleID, $subCompatibleID) = unpack("CCQQ", $descr);

	printf "bFirstInterfaceNumber=$bFirstInterfaceNumber, bInterfaceCount=$bInterfaceCount, compatibleID=%#010x, subCompatibleID=%#010x\n", $compatibleID, $subCompatibleID;
	print "compatibleID: ", substr($descr, 2, 8), ", subCompatibleID: ", substr($descr, 10, 8), "\n";
	$descr = substr($descr, 24);

    }
}

# try to get the extended properties as well
($ret, $descr) = &get_ms_descriptor($dev, $mscode, 0x0005);
if ($ret > 0) {
    print "MS extended properties:\n";
    map { printf " %02x", $_ } unpack("C*", $descr);
    print "\n";

    # decoding header:
    my ($dwLength, $bcdVersion, $wIndex, $wCount) = unpack("Vvvv", $descr);
    printf "dwLength=$dwLength, bcdVersion=%04x, wIndex=$wIndex, wCount=$wCount\n", $bcdVersion;
    $descr = substr($descr, 10);

}


# retrieve the first MS descriptor page, referencing interface 0
sub get_ms_descriptor {
    my ($dev, $mscode, $feature) = @_;
    my $reqtype = 0xc0;   # USB_DIR_IN | USB_TYPE_VENDOR | USB_RECIP_DEVICE
    my $wValue = 0x0;
    
    return (-1, undef) unless $mscode;

    # some requests got to the interface... 
    if ($feature > 0x0004) {
	$reqtype = 0xc1;   # USB_DIR_IN | USB_TYPE_VENDOR | USB_RECIP_INTERFACE
	$wValue = 1;
    }
 
    my $buf = 0 x 512; # pre-allocate buffer - libusb is not perl!
    my $ret = $dev->control_msg($reqtype,
				$mscode,
				$wValue,      # wValue = if #0 << 8 | page #0 
				$feature, # wIndex = feature
				$buf,
				512,
				1000);  # timeout in ms

    printf "usb_control_msg(%#04x, %#04x, %#06x, %#06x) returned $ret\n", $reqtype, $mscode, $wValue, $feature;
    return ($ret, $buf);
}


sub usage {
    warn <<EOT
      Usage:
	$0 [--debug] --device=<idVendor:idProduct> <list of string descriptor indexes>

      Options:
	--debug
	    debug output
	--device
	    USB device ID to test - required

      Example:
	$0 --device=1199:68a2 1 2 3 0xee

EOT
;
    exit 0;
}
