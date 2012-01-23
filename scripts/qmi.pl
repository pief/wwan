#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

use constant {
    QMI_CTL => 0,
    QMI_WDS => 1,
    QMI_DMS => 2,
};

sub usage {
    warn "Usage: $0 start|stop|status [iface]\n";
    exit;
}

### global variables ###

# interface
my $netdev = $ENV{'IFACE'};		# netdevice
$netdev = $ARGV[1] if ($ARGV[1]);	# let command line override interface (e.g for status command)
&usage unless $netdev;
my $state = "/etc/network/run/qmistate.$netdev"; # state keeping file

# per interface config
my %pin; $pin{1} = $ENV{'WWAN_PIN'} if $ENV{'WWAN_PIN'};
my $apn = $ENV{'WWAN_APN'};
my $user = $ENV{'WWAN_USER'};
my $pw = $ENV{'WWAN_PW'};

# output levels
my $verbose = 1;
my $debug = 0;

# internal state
my $dev;		# management device
my @cid;		# array of allocated CIDs
my $tid = 1;		# transaction id
my $wds_handle;		# connection handle

# translation tables
my %err = (
    0x0000 => "QMI_ERR_NONE",
    0x0001 => "QMI_ERR_MALFORMED_MSG",
    0x0002 => "QMI_ERR_NO_MEMORY",
    0x0003 => "QMI_ERR_INTERNAL",
    0x0004 => "QMI_ERR_ABORTED",
    0x0005 => "QMI_ERR_CLIENT_IDS_EXHAUSTED",
    0x0006 => "QMI_ERR_UNABORTABLE_TRANSACTION",
    0x0007 => "QMI_ERR_INVALID_CLIENT_ID",
    0x0008 => "QMI_ERR_NO_THRESHOLDS",
    0x0009 => "QMI_ERR_INVALID_HANDLE",
    0x000A => "QMI_ERR_INVALID_PROFILE",
    0x000B => "QMI_ERR_INVALID_PINID",
    0x000C => "QMI_ERR_INCORRECT_PIN",
    0x000D => "QMI_ERR_NO_NETWORK_FOUND",
    0x000E => "QMI_ERR_CALL_FAILED",
    0x000F => "QMI_ERR_OUT_OF_CALL",
    0x0010 => "QMI_ERR_NOT_PROVISIONED",
    0x0011 => "QMI_ERR_MISSING_ARG",
    0x0013 => "QMI_ERR_ARG_TOO_LONG",
    0x0016 => "QMI_ERR_INVALID_TX_ID",
    0x0017 => "QMI_ERR_DEVICE_IN_USE",
    0x0018 => "QMI_ERR_OP_NETWORK_UNSUPPORTED",
    0x0019 => "QMI_ERR_OP_DEVICE_UNSUPPORTED",
    0x001A => "QMI_ERR_NO_EFFECT",
    0x001B => "QMI_ERR_NO_FREE_PROFILE",
    0x001C => "QMI_ERR_INVALID_PDP_TYPE",
    0x001D => "QMI_ERR_INVALID_TECH_PREF",
    0x001E => "QMI_ERR_INVALID_PROFILE_TYPE",
    0x001F => "QMI_ERR_INVALID_SERVICE_TYPE",
    0x0020 => "QMI_ERR_INVALID_REGISTER_ACTION",
    0x0021 => "QMI_ERR_INVALID_PS_ATTACH_ACTION",
    0x0022 => "QMI_ERR_AUTHENTICATION_FAILED",
    0x0023 => "QMI_ERR_PIN_BLOCKED",
    0x0024 => "QMI_ERR_PIN_PERM_BLOCKED",
    0x0025 => "QMI_ERR_UIM_NOT_INITIALIZED",
    0x0026 => "QMI_ERR_MAX_QOS_REQUESTS_IN_USE",
    0x0027 => "QMI_ERR_INCORRECT_FLOW_FILTER",
    0x0028 => "QMI_ERR_NETWORK_QOS_UNAWARE",
    0x0029 => "QMI_ERR_INVALID_QOS_ID/QMI_ERR_INVALID_ID",
    0x002A => "QMI_ERR_REQUESTED_NUM_UNSUPPORTED",
    0x002B => "QMI_ERR_INTERFACE_NOT_FOUND",
    0x002C => "QMI_ERR_FLOW_SUSPENDED",
    0x002D => "QMI_ERR_INVALID_DATA_FORMAT",
    0x002E => "QMI_ERR_GENERAL",
    0x002F => "QMI_ERR_UNKNOWN",
    0x0030 => "QMI_ERR_INVALID_ARG",
    0x0031 => "QMI_ERR_INVALID_INDEX",
    0x0032 => "QMI_ERR_NO_ENTRY",
    0x0033 => "QMI_ERR_DEVICE_STORAGE_FULL",
    0x0034 => "QMI_ERR_DEVICE_NOT_READY",
    0x0035 => "QMI_ERR_NETWORK_NOT_READY",
    0x0036 => "QMI_ERR_CAUSE_CODE",
    0x0037 => "QMI_ERR_MESSAGE_NOT_SENT",
    0x0038 => "QMI_ERR_MESSAGE_DELIVERY_FAILURE",
    0x0039 => "QMI_ERR_INVALID_MESSAGE_ID",
    0x003A => "QMI_ERR_ENCODING",
    0x003B => "QMI_ERR_AUTHENTICATION_LOCK",
    0x003C => "QMI_ERR_INVALID_TRANSITION",
    0x0041 => "QMI_ERR_SESSION_INACTIVE",
    0x0042 => "QMI_ERR_SESSION_INVALID",
    0x0043 => "QMI_ERR_SESSION_OWNERSHIP",
    0x0044 => "QMI_ERR_INSUFFICIENT_RESOURCES",
    0x0045 => "QMI_ERR_DISABLED",
    0x0046 => "QMI_ERR_INVALID_OPERATION",
    0x0047 => "QMI_ERR_INVALID_QMI_CMD",
    0x0048 => "QMI_ERR_TPDU_TYPE",
    0x0049 => "QMI_ERR_SMSC_ADDR",
    0x004A => "QMI_ERR_INFO_UNAVAILABLE",
    0x004B => "QMI_ERR_SEGMENT_TOO_LONG",
    0x004C => "QMI_ERR_SEGMENT_ORDER",
    0x004D => "QMI_ERR_BUNDLING_NOT_SUPPORTED",
    0x004F => "QMI_ERR_POLICY_MISMATCH",
    0x0050 => "QMI_ERR_SIM_FILE_NOT_FOUND",
    0x0051 => "QMI_ERR_EXTENDED_INTERNAL",
    0x0052 => "QMI_ERR_ACCESS_DENIED",
    0x0053 => "QMI_ERR_HARDWARE_RESTRICTED",
    0x0054 => "QMI_ERR_ACK_NOT_SENT",
    0x0055 => "QMI_ERR_INJECT_TIMEOUT",
    0x005A => "QMI_ERR_INCOMPATIBLE_STATE",
    0x005B => "QMI_ERR_FDN_RESTRICT",
    0x005C => "QMI_ERR_SUPS_FAILURE_CAUSE",
    0x005D => "QMI_ERR_NO_RADIO",
    0x005E => "QMI_ERR_NOT_SUPPORTED",
    0x005F => "QMI_ERR_NO_SUBSCRIPTION",
    0x0060 => "QMI_ERR_CARD_CALL_CONTROL_FAILED",
    0x0061 => "QMI_ERR_NETWORK_ABORTED",
    0x0062 => "QMI_ERR_MSG_BLOCKED",
    0x0064 => "QMI_ERR_INVALID_SESSION_TYPE",
    0x0065 => "QMI_ERR_INVALID_PB_TYPE",
    0x0066 => "QMI_ERR_NO_SIM",
    0x0067 => "QMI_ERR_PB_NOT_READY",
    0x0068 => "QMI_ERR_PIN_RESTRICTION",
    0x0069 => "QMI_ERR_PIN2_RESTRICTION",
    0x006A => "QMI_ERR_PUK_RESTRICTION",
    0x006B => "QMI_ERR_PUK2_RESTRICTION",
    0x006C => "QMI_ERR_PB_ACCESS_RESTRICTED",
    0x006D => "QMI_ERR_PB_DELETE_IN_PROG",
    0x006E => "QMI_ERR_MESSAGE_DELIVERY_FAILURE_IMS/QMI_ERR_PB_TEXT_TOO_LONG",
    0x006F => "QMI_ERR_PB_NUMBER_TOO_LONG",
    0x0070 => "QMI_ERR_PB_HIDDEN_KEY_RESTRICTION",
    );

my %sysname = (
    0 => "QMI_CTL",
    1 => "QMI_WDS",
    2 => "QMI_DMS",
    );

### 1. find the associated QMI interface  ###
#
#  bjorn@nemi:~$ ls -l /sys/class/net/wwan1/device
#  lrwxrwxrwx 1 root root 0 Jan 20 04:43 /sys/class/net/wwan1/device -> ../../../2-1:1.4
#  bjorn@nemi:~$ ls -l /sys/class/net/wwan1/device/../2-1:1.3/usb/
#  total 0
#  drwxr-xr-x 3 root root 0 Jan 21 22:18 cdc-wdm0


sub get_mgmt_dev {
    my $ret = '';

    # no IFACE environment variable?
    return $ret if (!$netdev);

    my $usbif = readlink("/sys/class/net/$netdev/device"); # ../../../2-1:1.4
    return $ret if (!$usbif);
    $usbif =~ s!.*/!!;                                  # 2-1:1.4
    my ($usbdev) = split(/:/, $usbif, 2);               # 2-1
    return $ret if (!$usbdev);

    opendir(D, "/sys/class/usb") || return $ret;
    while (my $f = readdir(D)) { # cdc-wdm0 -> ../../devices/pci0000:00/0000:00:1d.7/usb2/2-1/2-1:1.3/usb/cdc-wdm0
	next unless ($f =~ /^cdc-wdm/);
	if (readlink("/sys/class/usb/$f") =~ m!/$usbdev/$usbdev:.*/usb/cdc-wdm!) { # found it!
	    $ret = "/dev/$f";
	    last;
	}
    }
    closedir(D);
    warn "$netdev: will use $ret for management\n" if ($ret && $verbose);
    return $ret;
}

### QMI helpers ###

# $tlvs = { type1 => packdata, type2 => packdata, .. 
sub mk_qmi {
    my ($sys, $cid, $msgid, $tlvs) = @_;

    # create tlvbytes
    my $tlvbytes = '';
    foreach my $tlv (keys %$tlvs) {
	$tlvbytes .= pack("Cv", $tlv, length($tlvs->{$tlv})) . $tlvs->{$tlv};
    }
    my $tlvlen = length($tlvbytes);
    if ($sys != QMI_CTL) {
	return pack("CvCCCCvvv", 1, 12 + $tlvlen, 0, $sys, $cid, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    } else {
	return pack("CvCCCCCvv", 1, 11 + $tlvlen, 0, QMI_CTL, 0, 0, $tid++, $msgid, $tlvlen) . $tlvbytes;
    }
}
    
sub decode_qmi {
    my $packet = shift;

    return {} unless $packet;

    printf "%02x " x length($packet) . "\n", unpack("C*", $packet) if $debug;

    my ($tf, $len, $ctrl, $sys, $cid) = unpack("CvCCC", $packet);
    return {} unless ($tf == 1);

    my ($flags, $tid, $msgid, $tlvlen, $tlvs);
    if ($sys != 0) {
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

sub mk_ascii {
    my $bytearray = shift;
    return pack("C*", map { $_ < 32 || $_ > 127 ? ord('.') : $_ } @$bytearray);
}

sub pretty_print_qmi {
    my $qmi = shift;

    return unless exists($qmi->{tf});

    my $pfx = '';
    if ($qmi->{ctrl}) {
	$pfx = "<= ";
    } else {
	$pfx = "=> ";
    }	

    print "${pfx}QMUX Header:\n";
    printf "$pfx  len:    0x%04x\n", $qmi->{len};
    printf "$pfx  sender: 0x%02x\n", $qmi->{ctrl}; # (service)
    printf "$pfx  svc:    0x%02x\n", $qmi->{sys}; # (wds)
    printf "$pfx  cid:    0x%02x\n", $qmi->{cid}; 
    print "\n${pfx}QMI Header:\n";
    printf "$pfx  Flags:  0x%02x\n", $qmi->{flags}; # (response)
    printf "$pfx  TXN:    ". ($qmi->{sys} != QMI_CTL ? "0x%04x\n" : "0x%02x\n"), $qmi->{tid};
    printf "$pfx  Cmd:    0x%04x\n", $qmi->{msgid}; # (GET_PKT_STATUS)
    printf "$pfx  Size:   0x%04x\n", $qmi->{tlvlen};

    foreach my $k (sort { $a <=> $b } keys %{$qmi->{tlvs}}) {
	my $v = $qmi->{tlvs}{$k};
	my $tlvlen = scalar(@$v);
	my $txt;
	
	# special casing status
	if ($k == 0x02) {
	    $txt = ($v->[0] ? "FAILURE" : "SUCCESS") . " - " . $err{unpack("v", pack("C*", @$v[2..3]))};
	} else {
	    $txt = mk_ascii($v);
	}

	printf "${pfx}[0x%02x] (%2d) " . "%02x " x $tlvlen . "\t$txt\n", $k, $tlvlen, @$v;
#	printf "\n  TLV:    0x%02x\n", $k; # (WDS/Get Packet Service Status Response/Result Code)
#	printf "  Size:   0x%04x\n", $tlvlen;
#	printf "  Data:   ". "%02x " x $tlvlen . "\n", @$v;
    }
}

# check if two messages are part of the same transaction
sub qmi_match {
    my ($q1, $q2) = @_;

    for my $f (qw(tf sys cid msgid)) {
	return undef unless (exists($q1->{$f}) && exists($q2->{$f}) && $q1->{$f} == $q2->{$f});
    }
    return 1;
}

# FIXME: needs to verify that the received packet is the answer
# FIXME: needs timeout
sub send_and_recv {
    my $cmd = shift;
    my $timeout = shift || 5;

    return {} if (!$cmd);

    # get cached device, or lookup and cache
    $dev ||= get_mgmt_dev($netdev);
    return {} unless $dev;

    warn("sending to $dev:\n") if $debug;

    my $qmi_out = decode_qmi($cmd);
    pretty_print_qmi($qmi_out) if $debug;

    my $qmi_in = {};
    open(F, "+<", $dev) || die "open $dev: $!\n";
    autoflush F 1;
    print F $cmd;
    warn("reading from $dev\n") if $debug;

    eval {
	local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
	my $raw;
	my $found;
	alarm $timeout;
	do {
	    if (!$raw) {
		my $len = sysread(F, $raw, 256);
		warn("read $len bytes from $dev\n") if $debug;
	    } else {
		warn "$netdev: last read return multiple packets\n" if $verbose;
	    }

	    $qmi_in = decode_qmi($raw);

	    # a single read may return more than one packet!
	    if ($qmi_in->{tf}) {
		$raw = substr($raw, $qmi_in->{len} + 1);
	    } else {
		$raw = '';
	    }

	    # matching reply?
	    $found = &qmi_match($qmi_out, $qmi_in);
	    if (!$found && $debug) {
		warn "skipping unrelated message\n";
		pretty_print_qmi($qmi_in) if $debug;
 	    }

	} while (!$found);
	alarm 0;
    };
    if ($@) {
	die unless $@ eq "alarm\n";   # propagate unexpected errors
    }
    close(F);

    pretty_print_qmi($qmi_in) if $debug;
    return $qmi_in;
}


sub verify_status {
    my $qmi = shift;
    return 1 if ((ref($qmi) ne "HASH") || !exists($qmi->{tf}));
    return 0 if (!exists($qmi->{tlvs}) || !exists($qmi->{tlvs}{0x02}));
    return unpack("v", pack("C*", @{$qmi->{tlvs}{0x02}}[2..3]));
}

sub get_cid {
    my $sys = shift;

    return $cid[$sys] if $cid[$sys];

    my $req = mk_qmi(0, 0, 0x0022, {0x01 => pack("C*", $sys)});
    my $ret = send_and_recv($req);

    my $status = verify_status($ret);
    if (!$status && $ret->{tlvs}{0x01}[0] == $sys) {
	$cid[$sys] = $ret->{tlvs}{0x01}[1];
    } else {
	warn "$netdev: CID request for $sysname{$sys} failed: $err{$status}\n";
    }
    
    return $cid[$sys];
}

# release all CIDs with the possible exception of QMI_WDS if we started a connection
sub release_cids {
    for (my $sys = 0; $sys < scalar @cid; $sys++) {
	if ($cid[$sys]) {
	    if ($wds_handle && $sys == QMI_WDS) {
		warn "$netdev: not releasing QMI_WDS cid=$cid[$sys] while connected\n" if $verbose;
		next;
	    }
	    my $req = mk_qmi(0, 0, 0x0023, {0x01 => pack("C*", $sys, $cid[$sys])});
 	    my $ret = send_and_recv($req);
	    warn "$netdev: released $sysname{$sys} cid=$cid[$sys] with status=" . verify_status($ret) . "\n" if $verbose;
	    $cid[$sys] = 0;
	}
    }
}

sub mk_wds {
    my $cid = get_cid(QMI_WDS);
    return undef if (!$cid);
    return mk_qmi(QMI_WDS, $cid, @_);
}

sub mk_dms {
    my $cid = get_cid(QMI_DMS);
    return undef if (!$cid);
    return mk_qmi(QMI_DMS, $cid, @_);
}

sub wds_get_runtime_settings {
    my $req = mk_wds(0x002d); # QMI_WDS_GET_RUNTIME_SETTINGS
    my $ret = send_and_recv($req);
    pretty_print_qmi($ret);
}

my %srvc_status = (
    1 => "DISCONNECTED",
    2 => "CONNECTED",
    3 => "SUSPENDED",
    4 => "AUTHENTICATING",
);
sub wds_get_pkt_srvc_status {
    my $req = mk_wds(0x0022); # QMI_WDS_GET_PKT_SRVC_STATUS
    my $ret = send_and_recv($req, 2); # short timeout
    my $status = verify_status($ret);
    if ($status) {
	warn "wds_get_pkt_srvc_status: $err{$status}\n";
	return undef;
    }
    my $v = $ret->{tlvs}{0x01};
    return $srvc_status{$v->[0]};
}

sub wds_stop_network_interface {
    if (!$wds_handle) {
	warn "$netdev: unable to disconnect without a valid handle\n";
	return 'FAILED';
    }
    my $req = mk_wds(0x0021, { 0x01 => pack("V", $wds_handle) } ); # QMI_WDS_STOP_NETWORK_INTERFACE
    my $ret = send_and_recv($req);
    $wds_handle = 0; # reset handle to allow releasing the CID
    return $err{&verify_status($ret)};
}

sub wds_start_network_interface {
    my %tlv;
    $tlv{0x14} = $apn if $apn;
    $tlv{0x17} = $user if $user;
    $tlv{0x18} = $pw if $pw;

    my $req = mk_wds(0x0020, \%tlv); # QMI_WDS_START_NETWORK_INTERFACE

    # need to save handle (and WMS CID!!!) for disconnect
    my $ret = send_and_recv($req, 60);
    my $status = verify_status($ret);
    if ($status) {
	warn "Connection failed: $err{$status}\n";
	pretty_print_qmi($ret);
	return $status;
    }

    my $v = $ret->{tlvs}{0x01};
    $wds_handle = unpack("V*", pack("C*", @$v)); # save as a 32bit integer
    printf STDERR "$netdev: got QMI_WDS handle 0x%08x\n", $wds_handle;

    return $status;
}


### 2. verify and optionally enter PIN code ###

sub dms_enter_pin {
    my $pinnumber = shift;

    unless ($pin{$pinnumber}) {
	warn "$netdev: No PIN$pinnumber configured\n" if $verbose;
	return undef;
    }
    my $pin = $pin{$pinnumber};
    my $req = &mk_dms(0x0028,  # QMI_DMS_UIM_VERIFY_PIN
		      { 0x01 => pack("C*", $pinnumber, length($pin)) . $pin});
    
    my $ret = &send_and_recv($req);
    my $status = &verify_status($ret);
    if ($status) {
	warn "$netdev: PIN$pinnumber verification failed: $err{$status}\n";
	return undef;
    }
    return 1;
}

my %pinstatus = (
    0 => "not initialized",
    1 => "enabled, not veriﬁed",
    2 => "enabled, veriﬁed",
    3 => "disabled",
    4 => "blocked",
    5 => "permanently blocked",
    6 => "unblocked",
    7 => "changed",
    );
sub dms_verify_pin {
    my $req = mk_dms(0x002b); # QMI_DMS_UIM_GET_PIN_STATUS
    my %pinok;

    if ($req) {
	my $ret = send_and_recv($req);
	return undef if (verify_status($ret));

	for (my $pin = 1; $pin <=2; $pin++) {
	    my $tlv = $ret->{tlvs}{0x10 + $pin};
	    next unless $tlv;
	    warn "PIN$pin status: $pinstatus{$tlv->[0]}, verify_left: $tlv->[1], unblock_left: $tlv->[2]\n" if $verbose;
	    $pinok{$pin} = 1 if ($tlv->[0] == 2 || $tlv->[0] == 3);
	    if ($tlv->[0] == 1) { # enabled, not veriﬁed
		if ($tlv->[1] >= 3) {
		     $pinok{$pin} = &dms_enter_pin($pin);
		} else {
		    warn "$netdev: less than 3 verification attempts left for PIN$pin - must be entered manually!\n" if ($pin == 1 || $verbose);
		}
	    }
	}
    }
    return $pinok{1};  # we only really care about PIN1
}

sub dms_dump_msg {
    my $msgid = shift;
    my $req = mk_dms($msgid);
    if ($req) {
	my $ret = send_and_recv($req);
	pretty_print_qmi($ret);
    }
}

sub wds_get_current_channel_rate {
    my $req = mk_wds(0x0023); # QMI_WDS_GET_CURRENT_CHANNEL_RATE
    my $ret = send_and_recv($req);

    return [ ('unknown') x 4 ] if (verify_status($ret));

    my $v = $ret->{tlvs}{0x01};
    return [ map { $_ == 0xffffffff ? 'unknown' : $_ } unpack("V*", pack("C*", @$v)) ];
}

sub format_ms {
    my $ms = shift;

    my $rest = $ms % 1000; 
    my $s = $ms / 1000 % 60;
    my $m = $ms /60000 % 60;
    my $h = $ms /3600000;
    return sprintf "%u:%02u:%02u.%03u", $h, $m, $s, $rest;
}

sub wds_get_call_duration {
    my $req = mk_wds(0x0035); # QMI_WDS_GET_CALL_DURATION
    if ($req) {
	my $ret = send_and_recv($req);
#	pretty_print_qmi($ret);

	my %r;
	return  \%r if (verify_status($ret));

	my %calltypes = (
	    0x01 => 'call',
	    0x10 => 'last call',
	    0x11 => 'call active', 
	    0x12 => 'last call active',
	    );
	for my $tlv (keys %calltypes) {
	    my $v = $ret->{tlvs}{$tlv};
	    if ($v) {
		$r{$calltypes{$tlv}} = format_ms(unpack("Q<", pack("C*", @$v)));
	    }
	}
	return \%r;
    }
}

my %data_bearer = (
0x01 => "cdma2000 1X",
0x02 => "cdma2000 HRPD (1xEV-DO)",
0x03 => "GSM",
0x04 => "UMTS",
0x05 => "cdma200 HRPD (1xEV-DO RevA)",
0x06 => "EDGE",
0x07 => "HSDPA and WCDMA",
0x08 => "WCDMA and HSUPA",
0x09 => "HSDPA and HSUPA",
0x0A => "LTE",
0x0B => "cdma2000 EHRPD",
0x0C => "HSDPA+ and WCDMA",
0x0D => "HSDPA+ and HSUPA",
0x0E => "DC_HSDPA+ and WCDMA",
0x0F => "DC_HSDAP+ and HSUPA",
0xFF => "Unknown",
);

sub wds_get_data_bearer_technology {
    my $req = mk_wds(0x0037); # QMI_WDS_GET_DATA_BEARER_TECHNOLOGY
    my $ret = send_and_recv($req);
	
    return $data_bearer{0xff} if (verify_status($ret));

    my $v = $ret->{tlvs}{0x01} if exists($ret->{tlvs}{0x01}); # Data Bearer Technology
    $v = $ret->{tlvs}{0x10} if exists($ret->{tlvs}{0x10}); # Last Call Data Bearer Technology
    return $data_bearer{$v->[0]};
}

sub tlv01_ascii {
    my $qmi = shift;
    return '' if (!$qmi);
    my $v = $qmi->{tlvs}{0x01};
    return '' if (!$v);
    return pack("C*", @$v);
}

sub wds_reset {
    my $ret = send_and_recv(mk_wds(0x0000));
    pretty_print_qmi($ret);
}

sub save_wds_state {
    if (open(X, ">$state")) {
	if ($wds_handle) {
	    printf X "%u %u\n", $cid[QMI_WDS], $wds_handle;
	}
	close X;
    } else {
	warn "$netdev: FATAL: cannot open \"$state\": $!\n";
	$wds_handle = 0; # will cause disconnect when CID is released
    }
}

sub get_wds_state {
    if ($cid[QMI_WDS]) {
	warn "cannot update state after QMI_WDS commands\n";
	return;
    }
    if (!open(X, $state)) {
	warn "unable to open $state: $!\n" if $debug;
	return;
    }
    my $x = <X>;
    close X;
    ($cid[QMI_WDS], $wds_handle) = split(/ /, $x) if $x;

    # verify that the state is valid
    my $conn = &wds_get_pkt_srvc_status;
    if (!$conn || $conn ne 'CONNECTED') { # handle is invalid
	$wds_handle = 0;
    }
    if (!$conn) { # CID is invalid
	$cid[QMI_WDS] = 0;
    }
    $tid ||= 1;
    printf STDERR "$netdev: QMI_WDS cid=%u, wds_handle=0x%08x\n", $cid[QMI_WDS], $wds_handle if $verbose;
}

sub device_info {
    warn "$netdev: Manufacturer: ", &tlv01_ascii(&send_and_recv(&mk_dms(0x0021))), "\n"; # QMI_DMS_GET_DEVICE_MFR
    warn "$netdev: Revision: ",  &tlv01_ascii(&send_and_recv(&mk_dms(0x0023))), "\n"; # QMI_DMS_GET_DEVICE_REV_ID
}

# detect whether device management interface talks QMI
sub is_qmi {
   my $req = mk_dms(0x0020);	# QMI_DMS_GET_DEVICE_CAP
   my $ret = send_and_recv($req, 1);	# 1 second timeout
   return undef if !exists($ret->{tf});

   # report capabilities
   my $v = $ret->{tlvs}{0x01};
   my ($max_tx, $max_rx, $data, $sim, $nradio, @radio) = unpack("VVCCCC*", pack("C*", @$v));
   my %data_cap_map = ( 
       0 => 'none',
       1 => 'CS',
       2 => 'PS',
       3 => 'CS & PS',
       4 => 'CS | PS',
       );
   my %radio_cap_map = (
       1 => "CDMA2000 1X",
       2 => "CDMA2000 HRPD (1xEV-DO)",
       4 => "GSM",
       5 => "UMTS",
       8 => "LTE",
       );

   # return capability string
   return "max tx/rx=$max_tx/$max_rx, service=$data_cap_map{$data}, SIM is " .
       ($sim ? '' : 'not ') . "supported, radios=" . join(',', map { $radio_cap_map{$_} } @radio);

}

# detect whether device management interface talks AT
sub is_at {
    open(F, "+<", $dev) || die "open $dev: $!\n";
    autoflush F 1;
    print F "ATI\r\n";
    warn("reading from $dev\n") if $debug;
    my $r = '';

    eval {
	local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
	my $raw;
	my $found;
	alarm 1;
	do {
	    my $len = sysread(F, $raw, 256);
	    warn("read $len bytes from $dev\n") if $debug;
	    $r .= $raw;
	} while ($raw !~ /OK/);
	alarm 0;
    };
    if ($@) {
	die unless $@ eq "alarm\n";   # propagate unexpected errors
    }
    close(F);
    return ($r =~ /OK/);
}


sub status {
    warn "$netdev: capabilities: ", &is_qmi, "\n";

    my $conn = &wds_get_pkt_srvc_status || 'unknown';
    warn "$netdev: $conn\n";
    return unless ($conn eq 'CONNECTED');

    warn "$netdev: current data bearer: ", &wds_get_data_bearer_technology, "\n";
    my $rate = &wds_get_current_channel_rate;
    warn "$netdev: current tx/rx = $rate->[0]/$rate->[1]\n";
    warn "$netdev: max tx/rx = $rate->[2]/$rate->[3]\n";
    
    my $call = &wds_get_call_duration;
    map { warn "$netdev: $_: $call->{$_}\n" } keys %$call;
}

### main ###

# look up management character device
$dev = &get_mgmt_dev($netdev);
if (!$dev) {
    warn "$netdev: Cannot find a QMI management interface!\n" if $verbose;
    exit;
}

if (&is_at) {
    die "$netdev: no support for AT command $dev yet\n";
}

# sanity
if (!&is_qmi) {
    die "$netdev: unable to detect $dev protocol\n";
}

# get and verify cached data, so we can reuse the QMI_WDS CID at least
&get_wds_state;

my $cmd = $ENV{'PHASE'};
$cmd ||= $ARGV[0];
$cmd =~ s/^pre-up$/start/;
$cmd =~ s/^post-down$/stop/;

# start interface?
if ($cmd eq 'start') {
    if (&dms_verify_pin) {
	# FIXME: must wait for network registration before continuing
	&wds_start_network_interface;
    } else {
	warn "$netdev: cannot start with PIN verification\n";
    }

# stop interface?
} elsif ($cmd eq 'stop') {
    &wds_stop_network_interface;

# or just print status?
} elsif ($cmd eq 'status') {
    &status;
} else {
    &usage;
}

# save state for next run
&save_wds_state;

# release all releasable CIDs
&release_cids;

__END__


## freeing all possible CIDs
for (my $i = 2; $i < 50; $i++) {
    $cid[QMI_WDS] = $i;
    $cid[QMI_DMS] = $i;
    &release_cids;
}


## another option:
## QMI_CTL SYNC (0x0027) seems to clear everything...


__END__



# 3. connect using specific APM
# 4. save handle to net/run
# 5. disconnect using saved handle


Insufficient resources:

[0x14] (13) 70 69 6c 6f 74 2e 74 65 6c 65 6e 6f 72      pilot.telenor
QMUX Header:
  len:    0x001f
  sender: 0x80
  svc:    0x01
  cid:    0x49

QMI Header:
  Flags:  0x02
  TXN:    0x0002
  Cmd:    0x0020
  Size:   0x0013
[0x02] ( 4) 01 00 0e 00         FAILURE - QMI_ERR_CALL_FAILED
[0x10] ( 2) ed 03       ..
[0x11] ( 4) 06 00 1a 00         ....


wds_reset hjelper...
