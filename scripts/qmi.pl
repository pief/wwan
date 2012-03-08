#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

use constant {
    QMI_CTL => 0x00,
    QMI_WDS => 0x01,
    QMI_DMS => 0x02,
    QMI_NAS => 0x03,
    QMI_WMS => 0x05,
};


package QMI;
use strict;
use warnings;
{
my %msg;
}
1; # eof QMI

package QMI::WDS;
use strict;
use warnings;
use Net::IP;
use vars qw(@ISA);
@ISA = qw(QMI);
{
my %msg = (
    0x0001 => {
	name => 'SET_EVENT_REPORT',
	0x16 => {
	    name => 'Channel Rate',
	    decode => sub { sprintf "tx: %u, rx: %u", unpack("VV", pack("C*", @{shift()}));  },
	},
	0x1d => {
	    name => 'Current Data Bearer Technology',
	    decode => \&tlv_data_bearer,
	},
    },
    0x0022 => {
	name => 'GET_PKT_SRVC_STATUS',
	0x01 => {
	    name => 'Packet Service Status',
	    decode => \&tlv_connstatus,
	},
	0x10 => {
	    name => 'Call End Reason',
	    decode => sub {  sprintf "%u",  unpack("v", pack("C*", @{$_[0]})); },
	},
	0x11 => {
	    name => 'Verbose Call End Reason',
	    decode => \&tlv_callendreason,
	},
	0x12 => {
	    name => 'IP Family',
	    decode => sub { sprintf "IPv%u", $_[0]->[0] },
	},
    },
    0x002b => {
	name => 'GET_PROFILE_SETTINGS',
	0x11 => {
	    name => 'PDP Type',
	    decode => \&tlv_pdptype,
	},
	0x15 => {
	    name => 'Primary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x16 => {
	    name => 'Secondary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x1e => {
	    name => 'Preferred IPv4 address',
	    decode => \&tlv_ipv4addr,
	},
    },
    0x002c => {
	name => 'GET_DEFAULT_SETTINGS',
	0x11 => {
	    name => 'PDP Type',
	    decode => \&tlv_pdptype,
	},
	0x15 => {
	    name => 'Primary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x16 => {
	    name => 'Secondary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x1e => {
	    name => 'Preferred IPv4 address',
	    decode => \&tlv_ipv4addr,
	},
    },
    0x002d => {
	name => 'GET_RUNTIME_SETTINGS',
	0x11 => {
	    name => 'PDP Type',
	    decode => \&tlv_pdptype,
	},
	0x15 => {
	    name => 'Primary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x16 => {
	    name => 'Secondary DNS Address',
	    decode => \&tlv_ipv4addr,
	},
	0x1e => {
	    name => 'Preferred IPv4 address',
	    decode => \&tlv_ipv4addr,
	},
	0x20 => {
	    name => 'Gateway address',
	    decode => \&tlv_ipv4addr,
	},
	0x21 => {
	    name => 'Subnet mask',
	    decode => \&tlv_ipv4addr,
	},
	0x25 => {
	    name => 'IPv6 Address',
	    decode => \&tlv_ipv6addr,
	},
	0x26 => {
	    name => 'IPv6 Gateway Address',
	    decode => \&tlv_ipv6addr,
	},
	0x27 => {
	    name => 'Primary IPv6 DNS Address',
	    decode => \&tlv_ipv6addr,
	},
	0x28 => {
	    name => 'Secondary IPv6 DNS Address',
	    decode => \&tlv_ipv6addr,
	},
    },
    );

my %call_end_type_map = (
    1 => 'Mobile IP',
    2 => 'Internal',
    3 => 'Call Manager deﬁned',
    6 => '3GPP speciﬁcation deﬁned',
    7 => 'PPP',
    8 => 'EHRPD',
    9 => 'IPv6',
    );

my %call_end_reason_map = (
    1 => { # Mobile IP
    },
    2 => { # Internal
	201 => 'INTERNAL_ERROR',
	202 => 'CALL_ENDED',
	203 => 'INTERNAL_UNKNOWN_CAUSE_CODE',
	204 => 'UNKNOWN_CAUSE_CODE',
	205 => 'CLOSE_IN_PROGRESS',
	206 => 'NW_INITIATED_TERMINATION',
	207 => 'APP_PREEMPTED',
    },
    3 => { # Call Manager deﬁned
    },
    6 => { #  3GPP speciﬁcation deﬁned
	8  => 'OPERATOR_DETERMINED_BARRING',
	25 => 'LLC_SNDCP_FAILURE',
	26 => 'INSUFFICIENT_RESOURCES',
	27 => 'UNKNOWN_APN',
	28 => 'UNKNOWN_PDP',
	29 => 'AUTH_FAILED',
	30  => 'GGSN_REJECT',
	31  => 'ACTIVATION_REJECT',
	32  => 'OPTION_NOT_SUPPORTED',
	33  => 'OPTION_UNSUBSCRIBED',
	34  => 'OPTION_TEMP_OOO',
	35  => 'NSAPI_ALREADY_USED',
	36  => 'REGULAR_DEACTIVATION',
	37  => 'QOS_NOT_ACCEPTED',
	38  => 'NETWORK_FAILURE',
	39  => 'UMTS_REACTIVATION_REQ',
	40  => 'FEATURE_NOT_SUPPORTED',
	41  => 'TFT_SEMANTIC_ERROR',
	42  => 'TFT_SYNTAX_ERROR',
	43  => 'UNKNOWN_PDP_CONTEXT',
	44  => 'FILTER_SEMANTIC_ERROR',
	45  => 'FILTER_SYNTAX_ERROR',
	46  => 'PDP_WITHOUT_ACTIVE_TFT',
	81  => 'INVALID_TRANSACTION_ID',
	95  => 'MESSAGE_INCORRECT_SEMANTIC',
	96  => 'INVALID_MANDATORY_INFO',
	97  => 'MESSAGE_TYPE_UNSUPPORTED',
	98  => 'MSG_TYPE_NONCOMPATIBLE_STATE',
	99  => 'UNKNOWN_INFO_ELEMENT',
	100 => 'CONDITIONAL_IE_ERROR',
	101 => 'MSG_AND_PROTOCOL_STATE_UNCOMPATIBLE',
	111 => 'PROTOCOL_ERROR',
	112 => 'APN_TYPE_CONFLICT',
	50  => 'IP_V4_ONLY_ALLOWED',
	51  => 'IP_V6_ONLY_ALLOWED',
	52  => 'SINGLE_ADDR_BEARER_ONLY',
	53  => 'ESM_INFO_NOT_RECEIVED',
	54  => 'PDN_CONN_DOES_NOT_EXIST',
	55  => 'MULTI_CONN_TO_SAME_PDN_NOT_ALLOWED',
    },
    7 => { #  PPP
    },
    8 => { #  EHRPD
    },
    9 => { #  IPv6
    },
    );

sub tlv_callendreason {
    my ($type, $reason) = unpack("v2", pack("C*",  @{$_[0]})); 
    return "$call_end_type_map{$type}: " . ($call_end_reason_map{$type}{$reason} || 'unknown') . " [type=$type, reason=$reason]";
}

my %connection_status_map = (
    1 => 'DISCONNECTED',
    2 => 'CONNECTED',
    3 => 'SUSPENDED',
    4 => 'AUTHENTICATING',
    );

sub tlv_connstatus {
    my $data = shift;
    my $ret = $connection_status_map{$data->[0]};
    $ret .= ", reconfiguration " . ($data->[1] ? "" : "not ") . "required" if exists($data->[1]);
    return $ret;
}
   
my %pdp_type_map = (
    0 => 'PDP-IP (IPv4)',
    1 => 'PDP-PPP',
    2 => 'PDP-IPV6',
    3 => 'PDP-IPV4V6',
    );
sub tlv_pdptype {
   my $data = shift;
   return $pdp_type_map{$data->[0]};
}

sub tlv_ipv4addr {
    my $data = shift;
    return join('.', reverse(@$data));
}

sub tlv_ipv6addr {
    my $data = shift;
    my $addr = join(':', map { sprintf("%04x", $_) } unpack("n*", pack("C*", @{$data}[0..15])));
    $addr .= "/$data->[16]" if exists($data->[16]);
    return Net::IP::ip_compress_address($addr, 6);
}

my %current_nw_map = (
    0 => 'UNKNOWN',
    1 => '3GPP2',
    2 => '3GPP',
    );

my %rat_mask_map = (
    0x01 => 'WCDMA',
    0x02 => 'GPRS',
    0x04 => 'HSDPA',
    0x08 => 'HSUPA',
    0x10 => 'EDGE',
    0x20 => 'LTE',
    0x40 => 'HSDPA+',
    0x80 => 'DC_HSDPA+',
    );

sub tlv_data_bearer {
    my $data = shift;
    my ($current_nw, $rat_mask, $so_mask) = unpack("CVV", pack("C*", @$data));
    my @rat;
    for (my $i = 0; $i < 32; $i++) {
	push(@rat, $rat_mask_map{1<<$i} || 'unknown') if ($rat_mask & 1<<$i);
    }

    return "$current_nw_map{$current_nw}: ".join('|', @rat);
}

sub tlv {
    my ($msgid, $tlv, $data) = @_;
    
    if (exists($msg{$msgid}) && exists($msg{$msgid}->{$tlv})) {
	return &{$msg{$msgid}->{$tlv}{decode}}($data);
    }
    return ''; # => default handling
}

}
1; # eof QMI::WDS;


package QMI::NAS;
use strict;
use warnings;
#use QMI;
use vars qw(@ISA);
@ISA = qw(QMI);
{
my %msg = (
    0x0024 => {
	name => 'GET_SERVING_SYSTEM',
	0x01 => {
	    name => 'Serving System',
	    decode => \&tlv_serving_system,
	},
	0x10 => {
	    name => 'Roaming Indicator',
	    decode => sub { 'roaming: ' . ($_[0]->[0] ? 'off' : 'on') .  ($_[0]->[0] > 1 ? " operator specific: $_[0]->[0]" : '') },
	},
	0x11 => {
	    name => 'Data Service Capability',
	    decode => \&tlv_data_service_cap,
	},
	0x12 => {
	    name => 'Current PLMN',
	    decode => \&tlv_plmn,
	},
	0x15 => {
	    name => 'Roaming Indicator List',
	    decode => \&tlv_roaming_list,
	},
	0x1c => {
	    name => '3GPP Location Area Code',
	    decode => sub {  sprintf "lac=0x%04x", unpack("v", pack("C*", @{$_[0]})); },
	},
	0x1d => {
	    name => '3GPP Cell ID',
	    decode => sub { sprintf "cell_id=0x%08x", unpack("v", pack("C*", @{$_[0]})); },
	},
	0x21 => {
	    name => 'Detailed Service Information',
	    decode => \&tlv_detailed_service,
	},
	0x24 => {
	    name => 'TAC Information for LTE',
	    decode => sub {  sprintf "tac=0x%04x", unpack("v", pack("C*", @{$_[0]})); },
	},
    },
    0x0025 => {
	name => 'GET_HOME_NETWORK',
	0x01 => {
	    name => 'Home Network',
	    decode => \&tlv_plmn,
	},
    },
    0x0034 => {
	name => 'GET_SYSTEM_SELECTION_PREFERENCE',
	0x10 => {
	    name => 'Emergency Mode',
	    decode => sub { 'Emergency mode: ' . ($_[0]->[0] ? 'on' : 'off') },
	},
	0x11 => {
	    name => 'Mode Preference',
	    decode => \&tlv_mode_pref,
	},
	0x14 => {
	    name => 'Roaming Preference',
	    decode => \&tlv_roaming_pref,
	},
	0x16 => {
	    name => 'Network Selection Preference',
	    decode => sub { 'Network Selection: ' .  ($_[0]->[0] ? 'manual' : 'automatic') },
	},
	0x18 => {
	    name => 'Service Domain Preference',
	    decode => \&tlv_service_pref,
	},
	0x19 => {
	    name => 'GSM/WCDMA Acquisition Order Preference',
	    decode => \&tlv_aquis_pref,
	},

    },
    );

my %registration_map = (
    0 => 'NOT REGISTERED',
    1 => 'REGISTERED',
    2 => 'SEARCHING',
    3 => 'DENIED',
    4 => 'UNKNOWN',
    );

my %attach_map = (
    0 => 'UNKNOWN',
    1 => 'ATTACHED',
    2 => 'DETACHED',
    );
my %network_map = (
    0 => 'UNKNOWN',
    1 => '3GPP2',
    2 => '3GPP',
    );
my %radio_if_map = (
    0x00 => 'NO_SVC',
    0x01 => 'CDMA_1X',
    0x02 => 'CDMA_1XEVDO',
    0x03 => 'AMPS',
    0x04 => 'GSM',
    0x05 => 'UMTS',
    0x08 => 'LTE',
    );

sub tlv_serving_system {
    my $data = shift;
    my ($registration, $cs_attach, $ps_attach, $selected_network, $num_radio, @radio) = @$data;

    return "$registration_map{$registration}, CS_$attach_map{$cs_attach}, PS_$attach_map{$ps_attach}, $network_map{$selected_network}, " . 
	join('|', map { $radio_if_map{$_} } @radio);
}

my %data_cap_map = (
0x01 => 'GPRS',
0x02 => 'EDGE',
0x03 => 'HSDPA',
0x04 => 'HSUPA',
0x05 => 'WCDMA',
0x06 => 'CDMA',
0x07 => 'EV-DO REV 0',
0x08 => 'EV-DO REV A',
0x09 => 'GSM',
0x0A => 'EV-DO REV B',
0x0B => 'LTE',
0x0C => 'HSDPA+',
0x0D => 'DC-HSDPA+',
    );
sub tlv_data_service_cap {
    my @data = @{shift()};
    my $len = shift(@data);
    return "[$len] " . join('|', map { $data_cap_map{$_} } @data);
}


sub tlv_plmn {
    my $datastr = pack("C*", @{shift()});
    my ($mcc, $mnc, $len) = unpack("vvC", $datastr);
    return sprintf "%u%02u - %s", $mcc, $mnc, substr($datastr, 5, $len);
}

sub tlv_roaming_list {
    my @data = @{shift()};
    my $n = shift(@data);
    my %roam = @data;
    return join(', ', map { "if=$radio_if_map{$_} roam=". $roam{$_} ? 'off' : 'on' } keys %roam);
}

my %srv_status_map = (
    0x00 => 'No service',
    0x01 => 'Limited service',
    0x02 => 'Service available',
    0x03 => 'Limited regional service',
    0x04 => 'MS in power save or deep sleep',
    );
my %srv_cap_map = (
    0x00 => 'No service',
    0x01 => 'Circuit-switched only',
    0x02 => 'Packet-switched only',
    0x03 => 'Circuit-switched and-packet switched',
    0x04 => 'MS found the right system but not yet registered/attached',
    );
my %srv_hdr_status_map = (
    0x00 => 'No service',
    0x01 => 'Limited service',
    0x02 => 'Service available',
    0x03 => 'Limited regional service',
    0x04 => 'MS in power save or deep sleep',
);

sub tlv_detailed_service {
    my ($status, $capability, $hdr_status, $hdr_hybrid, $forbidden) =  @{shift()};
    return "$srv_status_map{$status}, $srv_cap_map{$capability}, HDR: $srv_hdr_status_map{$hdr_status}, " .
	($hdr_hybrid ? 'H' : 'Not h') . "ybrid, " . ($forbidden ? 'F' : 'Not f') . "orbidden";
}

my %roam_map = (
    0x01 => 'OFF',
    0x02 => 'NOT OFF',
    0x03 => 'NOT FLASHING',
    0xff => 'ANY',
    );

sub tlv_roaming_pref {
    my $roam = unpack("v", pack("C*", @{shift()}));
    return 'Roaming preference: ' . $roam_map{$roam};
}

my %mode_map = (
    1<<0 => 'cdma2000 1X',
    1<<1 => 'cdma2000 HRPD (1xEV-DO)',
    1<<2 => 'GSM',
    1<<3 => 'UMTS',
    1<<4 => 'LTE',
);

sub tlv_mode_pref {
    my $mode = unpack("v", pack("C*", @{shift()}));
    return join('|', map { $mode_map{$_} } grep { $mode & $_ } keys %mode_map);
}

my %service_domain_map = (
    0x00 => 'Circuit-switched only',
    0x01 => 'Packet-switched only',
    0x02 => 'Circuit-switched and packet-switched',
    0x03 => 'Packet-switched attach',
    0x04 => 'Packet-switched detach',
    );

sub tlv_service_pref {
    my $pref = unpack("V", pack("C*", @{shift()}));
    return $service_domain_map{$pref};
}

my %aquis_order_map = (
    0x00 => 'Automatic',
    0x01 => 'GSM then WCDMA',
    0x02 => 'WCDMA then GSM',
    );

sub tlv_aquis_pref {
    my $pref = unpack("V", pack("C*", @{shift()}));
    return $aquis_order_map{$pref};
}

sub tlv {
    my ($msgid, $tlv, $data) = @_;
    
    if (exists($msg{$msgid}) && exists($msg{$msgid}->{$tlv})) {
	return &{$msg{$msgid}->{$tlv}{decode}}($data);
    }
    return ''; # => default handling
}

}
1; # eof QMI::NAS;


package main;
use strict;
use warnings;
use Getopt::Long;

my %sysname = (
    0 => "QMI_CTL",
    1 => "QMI_WDS",
    2 => "QMI_DMS",
    3 => "QMI_NAS",
    5 => "QMI_WMS",
    );

### functions used during enviroment variable parsing ###
sub usage {
    print STDERR <<EOH
Usage: $0 [options] --device=<iface> command tlv

Where [options] are

  --family=<4|6>
  --pin=<code>
  --apn=<apn>
  --user=<user>
  --pw=<pw>
  --[no]verbose
  --[no]debug
  --system=<sysname|number>

Command is either a hex command number or an alias

TLV depend on command and is on the format
  0x00 d a t a

EOH
    ;
    &release_cids;
    exit;
}

sub strip_quotes {
    my $x = shift;
    $x =~ s/"([^"]*)"/$1/ if $x;
    return $x;
}

### global variables ###

## set defaults based on environment
my $netdev = $ENV{'IFACE'};   	   # netdevice
my $family = $ENV{'ADDRFAM'} || 4; # default to IPv4

# per interface config
my %pin; $pin{1} = &strip_quotes($ENV{'IF_WWAN_PIN'}) if $ENV{'IF_WWAN_PIN'};
my $apn =  &strip_quotes($ENV{'IF_WWAN_APN'});
my $user = &strip_quotes($ENV{'IF_WWAN_USER'});
my $pw = &strip_quotes($ENV{'IF_WWAN_PW'});

# output levels
my $verbose = 1;
my $debug = 0;

# defaulting to QMI_WDS operations
my $system = QMI_WDS;

## let command line override defaults
GetOptions(
    'device=s' => \$netdev,
    'family=s' => \$family,
    'pin=s' => \$pin{1},
    'apn=s' => \$apn,
    'user=s' => \$user,
    'pw=s' => \$pw,
    'verbose!' => \$verbose,
    'debug!' => \$debug,
    'system=s' => \$system,
    ) || &usage;

# the rest of the command line is left for the actual command to run

# network device is required
&usage unless $netdev;

# postprocess family
$family =~ s/^inet//;
$family =~ s/^ipv//i;

# postprocess system
if ($system =~ s/^0x//) {
    $system = hex($system);
}
if ($system !~ /^\d+$/) {
    $system = uc($system);
    $system = "QMI_$system" unless ($system =~ /^QMI_/);
    ($system) = grep { $sysname{$_} eq $system } keys %sysname;
}

# state keeping file
my $state = "/etc/network/run/qmistate.$netdev";
if ($family != 4) {
    $state .= ".ipv$family";
}

# internal state
my $dev = $ENV{MGMT} || '';		# management device
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

    my $ret = {};
    @$ret{'tf','len','ctrl','sys','cid'} = unpack("CvCCC", $packet);
    return {} unless ($ret->{tf} == 1);

    # tid is 1 byte for QMI_CTL and 2 bytes for the others...
    @$ret{'flags','tid','msgid','tlvlen'} = unpack($ret->{sys} == QMI_CTL ? "CCvv" : "Cvvv" , substr($packet, 6));
    my $tlvlen = $ret->{'tlvlen'};
    my $tlvs = substr($packet, $ret->{'sys'} == QMI_CTL ? 12 : 13 );

    # add the tlvs
     while ($tlvlen > 0) {
	my ($tlv, $len) = unpack("Cv", $tlvs);
	$ret->{'tlvs'}{$tlv} = [ unpack("C*", substr($tlvs, 3, $len)) ];
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
	} elsif ($qmi->{sys} == QMI_WDS) {
	    $txt = QMI::WDS::tlv($qmi->{msgid}, $k, $v);
	} elsif ($qmi->{sys} == QMI_NAS) {
	    $txt = QMI::NAS::tlv($qmi->{msgid}, $k, $v);
	}
	$txt ||= mk_ascii($v);

	printf "${pfx}[0x%02x] (%2d) " . "%02x " x $tlvlen . "\t%s\n", $k, $tlvlen, @$v, $txt;
    }
}

# check if two messages are part of the same transaction
sub qmi_match {
    my ($q1, $q2) = @_;

    for my $f (qw(tf ctrl flags sys cid msgid)) {
	return undef unless (exists($q1->{$f}) && exists($q2->{$f}) && $q1->{$f} == $q2->{$f});
    }
    return 1;
}

# read from F until match or timeout
sub read_match {
    my $match = shift;
    my $timeout = shift;

    my $qmi_in = {};
    warn("reading from $dev\n") if $debug;
    eval {
	local $SIG{ALRM} = sub { die "alarm\n" }; # NB: \n required
	my $raw;
	my $found;
	alarm $timeout;
	do {
	    my $len = 0;
	    if (!$raw) {
		$len = sysread(F, $raw, 512);
		warn("read $len bytes from $dev\n") if ($debug && $len);
	    } else {
		$len = length($raw);
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
	    $found = !$len || &qmi_match($match, $qmi_in);
	    if (!$found && $debug) {
		warn "skipping unrelated message\n";
 	    }
	    pretty_print_qmi($qmi_in) if $debug;
	} while (!$found);
	alarm 0;
	warn "got match!\n" if ($found && $debug);
    };
    if ($@) {
	die unless $@ eq "alarm\n";   # propagate unexpected errors
    }
    return  $qmi_in;
}

# infinite timeout and impossible match => read forever
sub monitor {
    &read_match({}, 0);
}

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

    print F $cmd;

    # set up for matching
    $qmi_out->{flags} = $qmi_out->{sys} ? 0x02 : 0x01; # response
    $qmi_out->{ctrl} = 0x80;  # service
    my $qmi_in = read_match($qmi_out, $timeout);
 
    return $qmi_in;
}

sub verify_status {
    my $qmi = shift;
    return 1 if ((ref($qmi) ne "HASH") || !exists($qmi->{tf}));
    return 0 if (!exists($qmi->{tlvs}) || !exists($qmi->{tlvs}{0x02}));
    return unpack("v", pack("C*", @{$qmi->{tlvs}{0x02}}[2..3]));
}

# sending a QMI_CTL SYNC message will release all allocated CIDs and
# therefore also disconnect device!
sub ctl_sync {
    my $req = mk_qmi(0, 0, 0x0027);
    my $ret = send_and_recv($req);
    my $status = &verify_status($ret);
    if (!$status) {
	# reset all cached state as it is now invalid
	@cid = ();
	$wds_handle = 0;
    }
    return $status;
}

# will receive a QMI_CTL sync notification when device is ready after
# PIN verification
sub wait_for_sync_ind {
    my $timeout = shift || 5;

    # set up for matching
    my $match = {
	tf => 1,
	sys => 0,
	cid => 0,
	flags => 0x02,
	ctrl => 0x80,
	msgid => 0x0027,
    };
    my $qmi_in = read_match($match, $timeout);

    return exists($qmi_in->{tf});
}

sub get_cid {
    my $sys = shift;

    return $cid[$sys] if $cid[$sys];

    my $req = mk_qmi(0, 0, 0x0022, {0x01 => pack("C*", $sys)});

restart:
    my $ret = send_and_recv($req);
    my $status = verify_status($ret);
    if (!$status && $ret->{tlvs}{0x01}[0] == $sys) {
	$cid[$sys] = $ret->{tlvs}{0x01}[1];
    } else {
	if ($status == 0x0005) { # QMI_ERR_CLIENT_IDS_EXHAUSTED
	    if (!&ctl_sync) { # reset to clean state
		goto restart;
	    }
	}
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
    my $cid = &get_cid(QMI_WDS);
    return undef if (!$cid);
    return &mk_qmi(QMI_WDS, $cid, @_);
}

sub mk_dms {
    my $cid = &get_cid(QMI_DMS);
    return undef if (!$cid);
    return &mk_qmi(QMI_DMS, $cid, @_);
}

# QMI Network Access Service (QMI_NAS)
sub mk_nas {
    my $cid = &get_cid(QMI_NAS);
    return undef if (!$cid);
    return &mk_qmi(QMI_NAS, $cid, @_);
}

# QMI Wireless Message Service (QMI_WMS)
sub mk_wms {
    my $cid = &get_cid(QMI_WMS);
    return undef if (!$cid);
    return &mk_qmi(QMI_WMS, $cid, @_);
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

sub call_end_reason {
    my $qmi = shift;
    my $v = $qmi->{tlvs}{0x11}; # Verbose Call End Reason
    return 'unknown' unless $v;

    return &QMI::WDS::tlv_callendreason($v);
} 

sub wds_start_network_interface {
    my %tlv;
    $tlv{0x14} = $apn if $apn;
    $tlv{0x17} = $user if $user;
    $tlv{0x18} = $pw if $pw;
    $tlv{0x19} = pack("C", $family) if $family;
    my $req = mk_wds(0x0020, \%tlv); # QMI_WDS_START_NETWORK_INTERFACE

    warn "$netdev: connecting...\n" if $verbose;
    # need to save handle (and WMS CID!!!) for disconnect
    my $ret = send_and_recv($req, 60);
    my $status = verify_status($ret);
    if ($status) {
	warn "Connection failed: status=$err{$status}, reason=", call_end_reason($ret), "\n";
#	pretty_print_qmi($ret);
	return $status;
    }

    my $v = $ret->{tlvs}{0x01};
    $wds_handle = unpack("V*", pack("C*", @$v)); # save as a 32bit integer
    printf STDERR "$netdev: got QMI_WDS handle 0x%08x\n", $wds_handle;

    return $status;
}

sub wds_set_client_ip_family_pref {
    my $family = shift;
    my $req = &mk_wds(0x004d, # QMI_WDS_SET_CLIENT_IP_FAMILY_PREF
		      { 0x01 =>  pack("C", $family) });
    my $ret = &send_and_recv($req);
    return &verify_status($ret);
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

    # wait for status to be updated
    &wait_for_sync_ind(20);

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
    my $req = &mk_dms(0x002b); # QMI_DMS_UIM_GET_PIN_STATUS
    my %pinok;

    my $ret = &send_and_recv($req);
    my $status = &verify_status($ret);
    if ($status) {
	warn "$netdev: PIN verfication failed: $err{$status}\n";
	if ($status == 0x0003) { # QMI_ERR_INTERNAL
	    warn "$netdev: SIM card missing?\n";
	}
	return undef;
    }

    for (my $pin = 1; $pin <=2; $pin++) {
	my $tlv = $ret->{tlvs}{0x10 + $pin};
	next unless $tlv;
	warn "$netdev: PIN$pin status: $pinstatus{$tlv->[0]}, verify_left: $tlv->[1], unblock_left: $tlv->[2]\n" if $verbose;
	$pinok{$pin} = ($tlv->[0] == 2 || $tlv->[0] == 3);
	if ($tlv->[0] == 1) { # enabled, not veriﬁed
	    if ($tlv->[1] >= 3) {
		$pinok{$pin} = &dms_enter_pin($pin);
	    } else {
		warn "$netdev: less than 3 verification attempts left for PIN$pin - must be entered manually!\n" if ($pin == 1 || $verbose);
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
);

sub wds_get_data_bearer_technology {
    my $req = mk_wds(0x0037); # QMI_WDS_GET_DATA_BEARER_TECHNOLOGY
    my $ret = send_and_recv($req);
	
    return $data_bearer{0xff} if (verify_status($ret));

    my $v = $ret->{tlvs}{0x01} if exists($ret->{tlvs}{0x01}); # Data Bearer Technology
    $v = $ret->{tlvs}{0x10} if exists($ret->{tlvs}{0x10}); # Last Call Data Bearer Technology
    return $data_bearer{$v->[0]} || sprintf ' unknown [0x%02x]', $v->[0];
}

sub tlv01_ascii {
    my $qmi = shift;
    return '' if (!$qmi);
    my $v = $qmi->{tlvs}{0x01};
    return '' if (!$v);
    return pack("C*", @$v);
}

sub wds_reset {
    my $ret = &send_and_recv(&mk_wds(0x0000)); # QMI_WDS_RESET
    $wds_handle = 0; # all WDS variables will be reset, but client IDs are still valid
    return &verify_status($ret);
}


sub save_wds_state {
    printf STDERR "$netdev: saving state to \"$state\"\n" if $verbose;
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
    printf STDERR "$netdev: reading state from \"$state\"\n" if $verbose;
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


## NAS
# This is deprecated - use QMI_NAS_SET_SYSTEM_SELECTION_PREFERENCE instead
sub nas_initiate_network_register  {
    my $req = &mk_nas(0x0022, # QMI_NAS_INITIATE_NETWORK_REGISTER
		      { 0x01 => pack("C*", 1), # 1 => auto, 2 => manual?
#			0x10 => pack("vvC", 242, 1, 8), # telenor LTE
			});
    $debug = 1;
    my $ret = &send_and_recv($req);
    $debug = 0;
    return &verify_status($ret);
}


sub nas_set_system_selection_preference  {
    my $req = &mk_nas(0x0033, # QMI_NAS_SET_SYSTEM_SELECTION_PREFERENCE
		      { 0x11 => pack("v", 1<<4 # LTE
				        | 1<<3 # UMTS
				        | 1<<2 # GSM
			    ),
		      });
    my $ret = &send_and_recv($req);
    return &verify_status($ret);
}

sub nas_perform_network_scan  {
    my $req = &mk_nas(0x0021); # QMI_NAS_PERFORM_NETWORK_SCAN
    $debug = 1;
    my $ret = &send_and_recv($req, 180);
    $debug = 0;
    return &verify_status($ret);
}

## WMS

sub wms_raw_read  {
    my ($storage, $index) = @_;
    my $req = &mk_wms(0x0022,  # QMI_WMS_RAW_READ
		      { 0x01 => pack("CV", $storage, $index),
			0x10 => pack("C", 1),
		      });
    $debug = 1;
    my $ret = &send_and_recv($req);
    $debug = 0;
    return &verify_status($ret);
}

sub wms_list_messages  {
    my $req = &mk_wms(0x0031,  # QMI_WMS_LIST_MESSAGES
		      { 0x01 => pack("C", 0),
#			0x10 => pack("C", 1),
			0x11 => pack("C", 1),
		      });
    $debug = 1;
    my $ret = &send_and_recv($req);
    $debug = 0;
    return &verify_status($ret);
}

sub ctl_set_data_format {
    my $mode = shift;
    my $qos = (shift) ? 1 : 0;
    my $req = &mk_qmi(0, 0, 0x0026, {
	0x01 => pack("C", $qos), # (0 = no QoS Header, 1 = include QoS header)
	0x10 => pack("CC", $mode, #(1 = 802.3, 2 = raw IP mode)
		     0) # ???
		      });
    $debug = 1;
    my $ret = &send_and_recv($req);
    $debug = 0;
    return &verify_status($ret);
}

### main ###

# look up management character device
$dev ||= &get_mgmt_dev($netdev);
if (!$dev) {
    warn "$netdev: Cannot find a QMI management interface!\n" if $debug;
    exit;
}

# open it now and keep it open until exit
open(F, "+<", $dev) || die "open $dev: $!\n";
autoflush F 1;

if (&is_at) {
    die "$netdev: no support for AT command $dev yet\n";
}

# sanity
if (!&is_qmi) {
    die "$netdev: unable to detect $dev protocol\n";
}

# at this point we'd like to ensure that CIDs are released
$SIG{TERM} = \&release_cids;
$SIG{INT} = \&release_cids;

&device_info if $verbose;

# get and verify cached data, so we can reuse the QMI_WDS CID at least
&get_wds_state;

# get the command
my $cmd = shift;

# let network scripts override everything
if (exists $ENV{'PHASE'}) {
    $cmd = $ENV{'PHASE'};
    $cmd =~ s/^pre-up$/start/;
    $cmd =~ s/^post-down$/stop/;
    $system = QMI_WDS;
}

# special command alias handling per system
if ($system == QMI_WDS) {
    # start interface?
    if ($cmd eq 'start') {
	if (&dms_verify_pin) {
	    &wds_start_network_interface;
	} else {
	    warn "$netdev: cannot start without PIN verification\n";
	}

    # stop interface?
    } elsif ($cmd eq 'stop') {
	&wds_stop_network_interface;
 
    # or just print status?
    } elsif ($cmd eq 'status') {
	&status;
    } elsif ($cmd eq 'reset') {
	warn "Resetting device state: ", $err{&ctl_sync}, "\n";
    } elsif ($cmd eq 'monitor') {
	$debug = 1;
	&send_and_recv(&mk_wds(0x0001, {0x10 => pack("C", 1), # Current Channel Rate Indicator
					0x15 => pack("C", 1), # Current Data Bearer Technology Indicator
					0x17 => pack("C", 1), # Data Call Status Change Indicator
			       }));
	&monitor;
	$debug = 0;
    }
} elsif ($system == QMI_NAS) {
    &nas_set_system_selection_preference unless $cmd; # force new scan
} elsif ($system == QMI_WMS) {
    unless ($cmd) {
	&wms_list_messages;
	&wms_raw_read(0,0);
    }
} elsif ($system == QMI_CTL) {
    my $mode = shift;
    if ($mode == 1 || $mode == 2) {
	&ctl_set_data_format($mode, shift);
    }
}

# default common command number handling
if ($cmd && $cmd =~ s/^0x//) {
    my $msgid = hex($cmd);
    my $cid = &get_cid($system);

    # need to temporarily override debug output to force any useful output at all
    my $olddebug = $debug;
    $debug = 1;
    if ($cid) {
	my $tlv = shift;
	if ($tlv && $tlv =~ s/^0x//) {
	    $tlv = hex($tlv);
	    my $data = pack("C*", map { hex } @ARGV);
	    &send_and_recv(&mk_qmi($system, $cid, $msgid, { $tlv => $data }));
	} else {
	    &send_and_recv(&mk_qmi($system, $cid, $msgid));
	}
    }
    $debug = $olddebug;
}

# save state for next run
&save_wds_state;

# release all releasable CIDs
&release_cids;

# close device
close(F);

