#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

# 1. find the associated QMI interface
#
#  bjorn@nemi:~$ ls -l /sys/class/net/wwan1/device
#  lrwxrwxrwx 1 root root 0 Jan 20 04:43 /sys/class/net/wwan1/device -> ../../../2-1:1.4
#  bjorn@nemi:~$ ls -l /sys/class/net/wwan1/device/../2-1:1.3/usb/
#  total 0
#  drwxr-xr-x 3 root root 0 Jan 21 22:18 cdc-wdm0

my $dev;
my $netdev = "wwan1";
my @cid;

sub get_mgmt_dev {
    my $net = shift;
    my $ret = '';

    my $usbif = readlink("/sys/class/net/$net/device"); # ../../../2-1:1.4
    $usbif =~ s!.*/!!;                                  # 2-1:1.4
    my ($usbdev) = split(/:/, $usbif, 2);               # 2-1
    opendir(D, "/sys/class/usb");
    while (my $f = readdir(D)) { # cdc-wdm0 -> ../../devices/pci0000:00/0000:00:1d.7/usb2/2-1/2-1:1.3/usb/cdc-wdm0
	if (readlink("/sys/class/usb/$f") =~ m!/$usbdev/$usbdev:.*/usb/cdc-wdm!) {
	    $ret = "/dev/$f";
	    last;
	}
    }
    closedir(D);
    return $ret;
}
my $tid = 1;

# $tlvs = { type1 => packdata, type2 => packdata, .. 
sub mk_qmi {
    my ($sys, $cid, $msgid, $tlvs) = @_;

    # create tlvbytes
    my $tlvbytes = '';
    foreach my $tlv (keys %$tlvs) {
	$tlvbytes .= pack("Cv", $tlv, length($tlvs->{$tlv})) . $tlvs->{$tlv};
    }
    my $tlvlen = length($tlvbytes);
    if ($sys != 0) {
	return pack("CvCCCCvvv", 1, 12 + $tlvlen, 0, $sys, $cid, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    } else {
	return pack("CvCCCCCvv", 1, 11 + $tlvlen, 0, 0, 0, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    }
}
    
sub decode_qmi {
    my $packet = shift;

    printf "%02x " x length($packet) . "\n", unpack("C*", $packet);


    my ($tf, $len, $ctrl, $sys, $cid) = unpack("CvCCC", $packet);
    my ($flags, $tid, $msgid, $tlvlen, $tlvs);
    if ($cid != 0) {
	($flags, $tid, $msgid, $tlvlen) = unpack("Cvvv", substr($packet, 6));
	$tlvs = substr($packet, 13);
    } else {
	($flags, $tid, $msgid, $tlvlen) = unpack("CCvv", substr($packet, 6));
	$tlvs = substr($packet, 12);
    }

    my $ret = { tf => $tf,
		len => $len,
		ctrl => $ctrl,
		sys => $sys,
		cid => $cid,
		flags => $flags,
		tid => $tid,
		msgid => $msgid,
		tlvlen => $tlvlen,};

    # add the tlvs
     while ($tlvlen > 0) {
	my ($tlv, $len) = unpack("Cv", $tlvs);
	$ret->{tlvs}{$tlv} = [ unpack("C*", substr($tlvs, 3, $len)) ];
	$tlvlen -= $len + 3;
	$tlvs = substr($tlvs, $len + 3);
     }
    return $ret;
}


sub pretty_print_qmi {
    my $qmi = shift;

    print "QMUX Header:\n";
    printf "  len:    0x%04x\n", $qmi->{len};
    printf "  sender: 0x%02x\n", $qmi->{ctrl}; # (service)
    printf "  svc:    0x%02x\n", $qmi->{sys}; # (wds)
    printf "  cid:    0x%02x\n", $qmi->{cid}; 
    print "\nQMI Header:\n";
    printf "  Flags:  0x%02x\n", $qmi->{flags}; # (response)
    printf "  TXN:    ". ($qmi->{sys} ? "0x%04x\n" : "0x%02x\n"), $qmi->{tid};
    printf "  Cmd:    0x%04x\n", $qmi->{msgid}; # (GET_PKT_STATUS)
    printf "  Size:   0x%04x\n", $qmi->{tlvlen};

    while (my ($k, $v) = each %{$qmi->{tlvs}}) {
	my $tlvlen = scalar(@$v);
	printf "[0x%02x] (%2d) " . "%02x " x $tlvlen . "\t". pack("C*", @$v) ."\n", $k, $tlvlen, @$v;
#	printf "\n  TLV:    0x%02x\n", $k; # (WDS/Get Packet Service Status Response/Result Code)
#	printf "  Size:   0x%04x\n", $tlvlen;
#	printf "  Data:   ". "%02x " x $tlvlen . "\n", @$v;
    }
}


sub send_and_recv {
    my $cmd = shift;

    # get cached device, or lookup and cache
    $dev ||= get_mgmt_dev($netdev);

    warn("sending to $dev:\n");
    pretty_print_qmi(decode_qmi($cmd));

    my $raw;
    open(F, "+<", $dev) || die "open $dev: $!\n";
    autoflush F 1;
    print F $cmd;
    warn("reading from $dev\n");
    my $len = sysread(F, $raw, 256);
    close(F);

    warn("read $len bytes from $dev\n");
    return decode_qmi($raw);
}

sub verify_status {
    my $qmi = shift;

    return 0 if (ref($qmi) ne "HASH" || !exists($qmi->{tlvs}) || !exists($qmi->{tlvs}{0x02}));
    return unpack("v", pack("C*", @{$qmi->{tlvs}{0x02}}[2..3]));
}

sub get_cid {
    my $sys = shift;

    return $cid[$sys] if $cid[$sys];

    my $req = mk_qmi(0, 0, 0x0022, {0x01 => pack("C*", $sys)});
    my $ret = send_and_recv($req);
    
    if (!verify_status($ret) && $ret->{tlvs}{0x01}[0] == $sys) {
	$cid[$sys] = $ret->{tlvs}{0x01}[1];
    } else {
	warn "status not OK: " . Dumper($ret);
    }
    
    return $cid[$sys];
}

sub release_cids {
    for (my $sys = 0; $sys < scalar @cid; $sys++) {
	if ($cid[$sys]) {
	    my $req = mk_qmi(0, 0, 0x0023, {0x01 => pack("C*", $sys, $cid[$sys])});
 	    my $ret = send_and_recv($req);
	    warn "released cid=$cid[$sys] for sys=$sys with status=" . verify_status($ret) . "\n";
	    $cid[$sys] = 0;
	}
    }
}

sub mk_wms {
    my $cid = get_cid(1);
    return undef if (!$cid);
    return mk_qmi(1, $cid, @_);
}

sub print_settings {
    my $req = mk_wms(0x002d);
    if ($req) {
	my $ret = send_and_recv($req);
	pretty_print_qmi($ret);
    }
}

&print_settings;
&release_cids;



__END__

# 2. verify and optionally enter PIN code
sub dms_verify_pin {
    my $dev = shift;

    open(F, "+<", $def) || die "Cannot open $dev: $!\n";
    print F pack
}


# 3. connect using specific APM
# 4. save handle to net/run
# 5. disconnect using saved handle


