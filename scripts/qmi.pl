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
    QMI_PDS => 0x06,
    QMI_LOC => 0x10,
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
    0x0026 => {
	name => 'GET_PREFERRED_NETWORKS',
	0x10 => {
	    name => '3GPP Preferred Networks',
	    decode => \&tlv_pref_nets,
	},
 	0x11 => {
	    name => 'Static 3GPP Preferred Networks',
	    decode => \&tlv_pref_nets,
	},
   },
    0x0031 => {
	name => 'GET_RF_BAND_INFO',
	0x01 => {
	    name => 'RF Band Information List',
	    decode => \&tlv_rf_band_info,
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
	0x12 => {
	    name => 'Band Preference',
	    decode => \&tlv_band_pref,
	},
	0x14 => {
	    name => 'Roaming Preference',
	    decode => \&tlv_roaming_pref,
	},
	0x15 => {
	    name => 'LTE Band Preference',
	    decode => \&tlv_lte_band_pref,
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
    0x0043 => {
	name => 'GET_CELL_LOCATION_INFO',
	0x10 => {
	    name => 'GERAN Info',
	    decode => sub { return '' }, # => default handling
	},
	0x11 => {
	    name => 'UMTS Info',
	    decode => sub { return '' }, # => default handling
	},
	0x12 => {
	    name => 'CDMA Info',
	    decode => sub { return '' }, # => default handling
	},
	0x13 => {
	    name => 'LTE Info - Intrafrequency',
	    decode => \&tlv_lte_intrafreq,
	},
	0x14 => {
	    name => 'LTE Info - Interfrequency',
	    decode => \&tlv_lte_interfreq,
	},
	0x15 => {
	    name => 'LTE Info - Neighboring GSM',
	    decode => \&tlv_lte_neigh_gsm,
	},
	0x16 => {
	    name => 'LTE Info - Neighboring WCDMA',
	    decode => \&tlv_lte_neigh_wcdma,
	},
	0x17 => {
	    name => 'UMTS Cell ID',
	    decode => sub { return '' }, # => default handling
	},
	0x18 => {
	    name => 'WCDMA Info - LTE Neighbor Cell Info Set',
	    decode => sub { return '' }, # => default handling
	},
    },
    0x004d => {
	name => 'GET_SYS_INFO',
	0x12 => {
	    name => 'GSM Service Status Info',
	    decode => sub { &tlv_service_status('GSM', @_) },
	},
	0x13 => {
	    name => 'WCDMA Service Status Info',
	    decode => sub { &tlv_service_status('WCDMA', @_) },
	},
	0x14 => {
	    name => 'LTE Service Status Info',
	    decode => sub { &tlv_service_status('LTE', @_) },
	},
	0x17 => {
	    name => 'GSM System Info',
	    decode => \&tlv_lte_system_info,
	},
	0x18 => {
	    name => 'WDCMA System Info',
	    decode => \&tlv_lte_system_info,
	},
	0x19 => {
	    name => 'LTE System Info',
	    decode => \&tlv_lte_system_info,
	},
	0x1e => {
	    name => 'Additional LTE System Info',
	    decode => sub { sprintf "Geo sys index: 0x%04x", unpack("v", pack("C*", @{$_[0]})) },
	},
	0x21 => {
	    name => 'LTE Voice Support',
	    decode => sub { 'Voice is '. ($_[0]->[0] ? '' : 'not ') .'supported' },
	},
    },
    0x0066 => {
	name => 'RF_BAND_INFO_IND',
	0x01 => {
	    name => 'RF Band Information',
	    decode => \&tlv_rf_band_info,
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
    0x09 => 'TD-SCDMA',
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

my %rat_map = (
    1<<15 => 'UMTS',
    1<<14 => 'LTE',
    1<<7  => 'GSM',
    1<<6  => 'GSM compat',
    );

sub decode_rat {
    my $rat = shift;
    my @rat;
    for (my $i = 0; $i < 16; $i++) {
	push(@rat, $rat_map{1<<$i} || 'unknown') if ($rat & 1<<$i);
    }
    return @rat ? join('|', @rat) : 'any';
}

sub tlv_pref_nets {
    my $datastr = pack("C*", @{shift()});
    my $count = unpack("v", $datastr);
    my $ret = '';
    for (my $i = 0; $i < $count; $i++) {
	my ($mcc, $mnc, $rat) = unpack("vvv", substr($datastr, 2 + $i*6, 6));
	$ret .= sprintf "\n\t%u%02u (%s)", $mcc, $mnc, &decode_rat($rat);
    }
    return $ret;
}


# Note that this is different enough from the band preference bitmap to make sharing difficult...
my %active_band_map = (
    #  0 to 19 => CDMA BC_x
    # 20 to 39 => Reserved
    40 => 'GSM 450',
    41 => 'GSM 480',
    42 => 'GSM 750',
    43 => 'GSM 850',
    44 => 'GSM 900 (Extended)',
    45 => 'GSM 900 (Primary)',
    46 => 'GSM 900 (Railways)',
    47 => 'GSM 1800',
    48 => 'GSM 1900',
    # 49 to 79 => Reserved
    80 => 'WCDMA 2100',
    81 => 'WCDMA PCS 1900',
    82 => 'WCDMA DCS 1800',
    83 => 'WCDMA 1700 (U.S.)',
    84 => 'WCDMA 850',
    85 => 'WCDMA 800',
    86 => 'WCDMA 2600',
    87 => 'WCDMA 900',
    88 => 'WCDMA 1700 (Japan)',
    89 => 'reserved',
    90 => 'WCDMA 1500 (Japan)',
    91 => 'WCDMA 850 (Japan)',
    );

sub map_active_band {
    my $band = shift;
    if ($band <= 19) {
	return "BC_$band"; # CDMA
    }
    if (($band <= 39) || (($band > 48) && ($band <= 79))) {
	return "reserved";
    }
    if (($band > 119) && ($band <= 151)) {
	my $x = $band - 119;
	$x += 2 if ($band > 133);  # there's a hole for band 15 and 16...
	$x += 15 if ($band > 134); # and one between 17 and 33
	$x -= 23 if ($band > 142); # then we go back to 18 after 40...
	$x += 2 if ($band > 146); # and have a whole for band  22 and 23
	$x += 15 if ($band > 148); # and up to 41 again after 25..
	return "E-UTRA Operating Band $x";
    }
    if (($band > 199) && ($band <= 205)) {
	my $x = chr(ord('A') + $band - 200);
	return "TD-SCDMA Band $x";
    }
    return exists($active_band_map{$band}) ? $active_band_map{$band} : "unknown";
}

sub tlv_rf_band_info {
    my @data = @{shift()};
    my $count = shift(@data);
    my $datastr = pack("C*", @data);
    my $ret = '';
    for (my $i = 0; $i < $count; $i++) {
	my ($radio_if, $band, $channel) = unpack("Cvv", substr($datastr, $i*5, 5));
	$ret .= "$radio_if_map{$radio_if} => \"" . &map_active_band($band) . "\" ch $channel, ";
    }
    return $ret;
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

sub tlv_service_status {
    my $system = shift;
    my ($status, $true_status, $preferred) = @{shift()};
    return "$system: $srv_status_map{$status}, True $srv_status_map{$true_status}, " . ($preferred ? "" : "Not ") . "preferred";
}

sub tlv_lte_system_info {
    my ($servdom_valid, $srvdom, $srvcap_valid, $srvcap, $roam_valid, $roam, $forbidden_valid, $forbidden, $lac_valid, $lac, $cellid_valid, $cellid, $rej_valid, $rej_srv_domain, $rej_cause, $netid_valid, @mcc, @mnc, $tac_valid, $tac );
    ($servdom_valid, $srvdom, $srvcap_valid, $srvcap, $roam_valid, $roam, $forbidden_valid, $forbidden, $lac_valid, $lac, $cellid_valid, $cellid, $rej_valid, $rej_srv_domain, $rej_cause, $netid_valid, @mcc[0..2], @mnc[0..2], $tac_valid, $tac ) = unpack("C9vCVC4C6Cv", pack("C*", @{shift()}));

    my $mcc = pack("C3", @mcc);
    my $mnc = pack( $mnc[2] > ord('9') ? "C2" : "C3", @mnc);
    
    return "dom: $srv_status_map{$srvdom}, cap: $srv_status_map{$srvcap}, roam: $roam, ". ($forbidden ? 'Not ' : '') .", lac: $lac, cellid: $cellid, reject: $srv_status_map{$rej_srv_domain}, mcc: $mcc, mnc: $mnc, tac: $tac";
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

my %band_map = (
    0 => 'Class 0, A-System',
    1 => 'Class 0, B-System, Class 0 AB, GSM 850',
    2 => 'Class 1, all blocks',
    3 => 'Class 2 placeholder',
    4 => 'Class 3, A-System',
    5 => 'Class 4, all blocks',
    6 => 'Class 5, all blocks',
    7 => 'GSM DCS 1800',
    8 => 'GSM Extended GSM (E-GSM) 900',
    9 => 'GSM Primary GSM (P-GSM) 900',
    10 => 'Class 6',
    11 => 'Class 7',
    12 => 'Class 8',
    13 => 'Class 9',
    14 => 'Class 10',
    15 => 'Class 11',
    16 => 'GSM 450',
    17 => 'GSM 480',
    18 => 'GSM 750',
    19 => 'GSM 850',
    20 => 'GSM Railways GSM 900',
    21 => 'GSM PCS 1900',
    22 => 'WCDMA Europe, Japan, and China IMT 2100',
    23 => 'WCDMA U.S. PCS 1900',
    24 => 'WCDMA Europe and China DCS 1800',
    25 => 'WCDMA U.S. 1700',
    26 => 'WCDMA U.S. 850',
    27 => 'WCDMA Japan 800',
    28 => 'Class 12',
    29 => 'Class 14',
# Bit 30 => 'Reserved',
    31 => 'Class 15',
# Bits 32 to 47 => 'Reserved',
    48 => 'WCDMA Europe 2600',
    49 => 'WCDMA Europe and Japan 900',
    50 => 'WCDMA Japan 1700',
# Bits 51 to 55 => 'Reserved',
    56 => 'Class 16',
    57 => 'Class 17',
    58 => 'Class 18',
    59 => 'Class 19',
# Bits 60 to 64 => 'Reserved',
    );

sub tlv_band_pref {
    my $bands =  unpack("Q<", pack("C*", @{shift()}));
    my @res;

    for (my $i = 0; $i < 64; $i++) {
	push(@res, "\"$band_map{$i}\"" || '"reserved"') if ($bands & 1<<$i);
    }
    return join(' + ', @res);
}

sub tlv_lte_band_pref {
    my $bands =  unpack("Q<", pack("C*", @{shift()}));
    my @res;

    for (my $i = 0; $i < 40; $i++) {
	push(@res, sprintf("%u", $i + 1)) if ($bands & 1<<$i);
    }
    return "E-UTRA Operating Bands ". join(', ', @res);
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

sub _decode_lte_pci_data {
    my @data = @_;
    my ($pci, $rsrq, $rsrp, $rssi, $srxlev) = unpack("vs<s<s<s<", pack("C*", @data));
    return sprintf("%4u: rsrq=%d dB, rsrp=%d dBm, rssi=%d dBm srxlev=%d", $pci, $rsrq/10, $rsrp/10, $rssi/10, $srxlev);
}

sub tlv_lte_intrafreq {
    my ($ue_in_idle, $plmn1, $plmn2, $plmn3, $tac, $global_cell_id, $earfcn, $serving_cell_id,
	$cell_resel_priority, $s_non_intra_search, $thresh_serving_low, $s_intra_search, $cells_len, @r) 
	= unpack("CC3vVvvCCCCCC*", pack("C*", @{shift()}));
    my $ret = "\n\t" . ($ue_in_idle ? '' : '!') . sprintf("idle, tac=0x%04x, global_cell=0x%08x, earfcn=%d, serving_cell=%d, %d/%d/%d/%d", $tac, $global_cell_id, $earfcn, $serving_cell_id,
	$cell_resel_priority, $s_non_intra_search, $thresh_serving_low, $s_intra_search);
    for (my $i = 0; $i < $cells_len; $i++) {
	$ret .= "\n\t\t" . &_decode_lte_pci_data(@r[$i*10..$i*10+9]);
    }
    return $ret;
}

sub tlv_lte_interfreq {
    my @data = @{shift()};
    my $ue_in_idle = shift(@data);
    my $freqs_len = shift(@data);
    my $ret = '';
    for (my $i = 0; $i < $freqs_len; $i++) {
	my $earfcn = unpack("v", pack("C2", shift(@data), shift(@data)));
	my $threshX_low = shift(@data);
	my $threshX_high = shift(@data);
	my $cell_resel_priority = shift(@data);
	my $cells_len = shift(@data);
	$ret .= "\n\t" . ($ue_in_idle ? '' : '!') . sprintf("idle, earfcn=%d, %d/%d/%d", $earfcn, $threshX_low, $threshX_high, $cell_resel_priority);
	for (my $i = 0; $i < $cells_len; $i++) {
	    $ret .= "\n\t\t" . &_decode_lte_pci_data(@data[$i*10..$i*10+9]);
	}
	@data = @data[$cells_len*10..$#data];
    }
    return $ret;
}

sub _decode_lte_gsm_data {
    my @data = @_;
    my ($arfcn, $band_1900, $cell_id_valid, $bsic_id, $rssi, $srxlev) = unpack("vCCCs<s<", pack("C*", @data));
    return sprintf("arfcn=%d, %s, cell id %svalid, bsic=0x%02x, rssi=%d dB srxlev=%d", $arfcn, $band_1900 ? '1900' : '1800', $cell_id_valid ? '' : 'in', $rssi/10, $srxlev);
}

sub tlv_lte_neigh_gsm {
    my @data = @{shift()};
    my $ue_in_idle = shift(@data);
    my $freqs_len = shift(@data);
    my $ret = '';
    for (my $i = 0; $i < $freqs_len; $i++) {
	my $cell_resel_priority = shift(@data);
	my $thresh_gsm_high = shift(@data);
	my $thresh_gsm_low = shift(@data);
	my $ncc_permitted = shift(@data);
	my $cells_len = shift(@data);
	$ret .= "\n\t" . ($ue_in_idle ? '' : '!') . sprintf("idle, %d/%d/%d, ncc=0x%02x", $thresh_gsm_low, $thresh_gsm_high, $cell_resel_priority, $ncc_permitted);
	for (my $i = 0; $i < $cells_len; $i++) {
	    $ret .= "\n\t\t" . &_decode_lte_gsm_data(@data[$i*9..$i*9+8]);
	}
	@data = @data[$cells_len*9..$#data];
     }
    return $ret;
}

sub _decode_lte_wcdma_data {
    my @data = @_;
    my ($psc, $cpich_rscp, $cpich_ecno, $srxlev) = unpack("vs<s<s<", pack("C*", @data));
    return sprintf("psc=%d, RSCP=%d dBm, Ec/No=%d dB, srxlev=%d", $psc, $cpich_rscp/10, $cpich_ecno/10, $srxlev);
}

sub tlv_lte_neigh_wcdma {
    my @data = @{shift()};
    my $ue_in_idle = shift(@data);
    my $freqs_len = shift(@data);
    my $ret = '';
    for (my $i = 0; $i < $freqs_len; $i++) {
	my $uarfcn = unpack("v", pack("C2", shift(@data), shift(@data)));
	my $cell_resel_priority = shift(@data);
	my $threshX_high = unpack("v", pack("C2", shift(@data), shift(@data)));
	my $threshX_low = unpack("v", pack("C2", shift(@data), shift(@data)));
	my $cells_len = shift(@data);
	$ret .= "\n\t" . ($ue_in_idle ? '' : '!') . sprintf("idle, uarfcn=%d, %d/%d/%d", $uarfcn, $threshX_low, $threshX_high, $cell_resel_priority);
	for (my $i = 0; $i < $cells_len; $i++) {
	    $ret .= "\n\t\t" . &_decode_lte_wcdma_data(@data[$i*8..$i*8+7]);
	}
	@data = @data[$cells_len*8..$#data];
    }
    return $ret;
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


package QMI::PDS;
use strict;
use warnings;
#use QMI;
use vars qw(@ISA);
@ISA = qw(QMI);
{
my %msg = (
    0x002b => {
	name => 'GET_XTRA_PARAMETERS',
	0x10 => {
	    name => 'XTRA Database Autodownload',
	    decode => sub { sprintf "auto: %u, interval %u hours", unpack("Cv", pack("C*", @{shift()}));  },
	},
	0x13 => {
	    name => 'XTRA Database Validity',
	    decode => sub { sprintf "gps_week: %u, start_offset: %u, valid: %u", unpack("vvv", pack("C*", @{shift()}));  },
	},
    },
    0x0044 => {
	name => 'GET_GPS_STATE_INFO',
	0x10 => {
	    name => 'GPS State Info',
	    decode => \&tlv_gps_state_info,
	},
    },
    );

sub tlv_gps_state_info {
    my ($state, $valid, $lat, $long, $hor, $alt, $ver, $tow_ms, $gps_week, $time_unc, $iono_valid, $mask1, $mask2, $mask3, $mask4, $mask5, $mask6, $mask7, $mask8, $mask9, $mask10, $mask11, $mask12, $xtra_gps_week, $xtra_gps_minutes, $xtra_valid_hours ) = unpack("CVQ<Q<VVVVvVCVVVVVVVVVVVVvvv", pack("C*", @{shift()}));

    return "engine=$state, gps_week=$gps_week, xtra_gps_week=$xtra_gps_week, xtra_gps_minutes=$xtra_gps_minutes, xtra_valid_hours=$xtra_valid_hours" ;
}

sub tlv {
    my ($msgid, $tlv, $data) = @_;
    
    if (exists($msg{$msgid}) && exists($msg{$msgid}->{$tlv})) {
	return &{$msg{$msgid}->{$tlv}{decode}}($data);
    }
    return ''; # => default handling
}

}
1; # eof QMI::PDS;

package main;
use strict;
use warnings;
use Getopt::Long;
use LWP::Simple;
use Socket;

my %sysname = (
    0 => "QMI_CTL",
    1 => "QMI_WDS",
    2 => "QMI_DMS",
    3 => "QMI_NAS",
    5 => "QMI_WMS",
    6 => "QMI_PDS",
    0x10 => "QMI_LOC",
    );

### functions used during enviroment variable parsing ###
sub usage {
    print STDERR <<EOH
Usage: $0 [options] --device=<iface> command tlv

Where [options] are

  --proxy
  --family=<4|6>
  --pin=<code>
  --apn=<apn>
  --user=<user>
  --pw=<pw>
  --[no]verbose
  --[no]debug
  --system=<sysname|number>
  --monitor

Command is either a hex command number or an alias

TLV depend on command and is on the format
  0x00 01 02 0x10 00 00 00 00
i.e a stream of TLVs starting with 0x followed by the raw contents, all encoded as hex bytes

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

# sleep and read all rcvd messages?
my $monitor = 0;

# use qmi-proxy
my $proxy = 0;

## let command line override defaults
GetOptions(
    'proxy!' => \$proxy,
    'device=s' => \$netdev,
    'family=s' => \$family,
    'pin=s' => \$pin{1},
    'apn=s' => \$apn,
    'user=s' => \$user,
    'pw=s' => \$pw,
    'verbose!' => \$verbose,
    'debug!' => \$debug,
    'system=s' => \$system,
    'monitor!' => \$monitor,
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

    # class name changed from "usb" to "usbmisc" in 3.5!
    # first look for a cdc-wdm device attached to the same interface
    my $d;
    foreach ("/sys/class/net/$netdev/device/usb",
	     "/sys/class/usb",
	     "/sys/class/net/$netdev/device/usbmisc",
	     "/sys/class/usbmisc",
	) {
	$d = $_;
	last if (-d $d);
    }
    opendir(D, $d) || return $ret;
    $d =~ s!.*/!!; # save class name for matching

    while (my $f = readdir(D)) { # cdc-wdm0 -> ../../devices/pci0000:00/0000:00:1d.7/usb2/2-1/2-1:1.3/usb/cdc-wdm0
	next unless ($f =~ /^cdc-wdm/);
	if (readlink("/sys/class/$d/$f") =~ m!/$usbdev/$usbdev:.*/$d/cdc-wdm!) { # found it!
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
	} elsif ($qmi->{sys} == QMI_PDS) {
	    $txt = QMI::PDS::tlv($qmi->{msgid}, $k, $v);
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
		if ($proxy) {
		    recv(F, $raw, 512, 0);
		    $len = length($raw);
		} else {
		    $len = sysread(F, $raw, 512);
		}
		warn("[" . localtime . "] read $len bytes from $dev\n") if ($debug && $len);
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

    if ($proxy) {
	send(F, $cmd, 0);
    } else {
	print F $cmd;
    }
    
    # set up for matching
    $qmi_out->{flags} = $qmi_out->{sys} ? 0x02 : 0x01; # response
    $qmi_out->{ctrl} = 0x80;  # service

    # work around bug in libqmi qmi-proxy implementation
    if ($proxy && $qmi_out->{'cid'} == 0 && $qmi_out->{'msgid'} == 0xff00) {
	$qmi_out->{ctrl} = 0x00;
    }

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

# a QMI_CTL SET_INSTANCE_ID message might be required before using a QMI_WDS connection?
sub ctl_set_instance {
    my $id = shift;

    my $old_debug = $debug;
    $debug = 1;
    my $ret = &send_and_recv(&mk_qmi(0, 0, 0x0020, {0x01 => pack("C*", $id)}));
    $debug = $old_debug;
    return &verify_status($ret);
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

    # set instance id
    if ($sys == QMI_WDS) {
	&ctl_set_instance(0);
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

# QMI Position Determination Service (QMI_PDS)
sub mk_pds {
    my $cid = &get_cid(QMI_PDS);
    return undef if (!$cid);
    return &mk_qmi(QMI_PDS, $cid, @_);
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
    my $handle = shift;

    my %tlv;
    if ($handle) {
	$handle =~ s/^0x//;
	$tlv{0x1} = pack("V", hex($handle));
    }
    $tlv{0x14} = $apn if $apn;
    $tlv{0x17} = $user if $user;
    $tlv{0x18} = $pw if $pw;
## TEST: Set default family pref instead
##    $tlv{0x19} = pack("C", $family) if $family;
    printf STDERR "Setting default family to $family: %s\n", &verify_status(&send_and_recv(&mk_wds(0x004d, {0x01 => pack("C", $family)}))) if $family;

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

# configure some default profile settings
sub wds_modify_profile {
    my $profile = shift;
    my $req = &mk_wds(0x0028, # QMI_WDS_MODIFY_PROFILE_SETTINGS
		      { 0x01 =>  pack("CC", 0, $profile),
		        0x10 => "profile$profile", 
			0x18 => \0 x 33,
			0x29 => \0 x 34,
		      });
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
    warn "$netdev: Model: ", &tlv01_ascii(&send_and_recv(&mk_dms(0x0022))), "\n"; # QMI_DMS_GET_DEVICE_MODEL_ID
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
		      { 0x01 => pack("C*", 2), # 1 => auto, 2 => manual?
			0x10 => pack("vvC", 242, 1, 8), # telenor LTE
			});
    $debug = 1;
    my $ret = &send_and_recv($req);
    $debug = 0;
    return &verify_status($ret);
}


sub nas_set_system_selection_preference  {
    my $sel = shift || (
	  1<<4 # LTE
	| 1<<3 # UMTS
	| 1<<2 # GSM
	);
    my $req = &mk_nas(0x0033, # QMI_NAS_SET_SYSTEM_SELECTION_PREFERENCE
		      { 0x11 => pack("v",$sel),
#			0x1b => pack("V",2),
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
if ($proxy) {
    my $addr = sockaddr_un("\x{0}qmi-proxy");
    socket(F, PF_UNIX, SOCK_STREAM, 0) || die "socket: $!\n";
    connect(F, $addr) || die "connect: $!\n";

    my $req = mk_qmi(0, 0, 0xff00, {0x01 => $dev});
    my $ret = send_and_recv($req);
    warn "$netdev: qmi-proxy open status=" . verify_status($ret) . "\n" if $verbose;
    die "$netdev: qmi-proxy for $dev failed\n" if (verify_status($ret) != 0);
} else {
    open(F, "+<", $dev) || die "open $dev: $!\n";
    autoflush F 1;
}

#if (&is_at) {
#    die "$netdev: no support for AT command $dev yet\n";
#}

# sanity
#if (!&is_qmi) {
#    die "$netdev: unable to detect $dev protocol\n";
#}

# at this point we'd like to ensure that CIDs are released
$SIG{TERM} = \&release_cids;
$SIG{INT} = \&release_cids;

##&device_info if $verbose;

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
    # get and verify cached data, so we can reuse the QMI_WDS CID at least
    &get_wds_state;

    # start interface?
    if ($cmd eq 'start') {
#	if (&dms_verify_pin) {
	    my $handle = shift;
	    &wds_start_network_interface($handle);
#	} else {
#	    warn "$netdev: cannot start without PIN verification\n";
#	}

    # stop interface?
    } elsif ($cmd eq 'stop') {
	&wds_stop_network_interface;
 
    # or just print status?
    } elsif ($cmd eq 'status') {
	&status;
    } elsif ($cmd eq 'profile') {
	my $profile = shift;
	warn "Modifying profile #$profile: ", $err{&wds_modify_profile($profile)}, "\n";
    } elsif ($cmd eq 'monitor') {
	&send_and_recv(&mk_wds(0x0001, {0x10 => pack("C", 1), # Current Channel Rate Indicator
					0x15 => pack("C", 1), # Current Data Bearer Technology Indicator
					0x17 => pack("C", 1), # Data Call Status Change Indicator
			       }));

	# monitor QMI_NAS changes as well, regisering interest in band notifications
	&send_and_recv(&mk_nas(0x0003, {0x13 => pack("C", 1), # Serving System Events
					0x20 => pack("C", 1), # RF Band Information
			       }));
	$monitor = 1;
    }
} elsif ($system == QMI_NAS) {
    if (!$cmd) {
	&nas_set_system_selection_preference; # force new scan
    } elsif ($cmd eq 'lte') {
	&nas_set_system_selection_preference(1<<4); # force LTE only
    } elsif ($cmd eq 'register') {
	&nas_initiate_network_register;
    } elsif ($cmd eq 'scan') {
	&nas_perform_network_scan;
    }
} elsif ($system == QMI_WMS) {
    unless ($cmd) {
	&wms_list_messages;
	&wms_raw_read(0,0);
    }
} elsif ($system == QMI_CTL) {
    if ($cmd eq 'sync') {
	warn "Resetting device state: ", $err{&ctl_sync}, "\n";
    } elsif ($cmd eq 'mode') {
	my $mode = shift;
	if ($mode == 1 || $mode == 2 || $mode == 3 ) {
	    &ctl_set_data_format($mode, shift);
	}
    }
} elsif ($system == QMI_PDS) {
    if ($cmd eq 'xtra') {
	my $old = $debug;
	$debug = 1;

	# 1. setup event report
	&send_and_recv(&mk_pds(0x0001, {
#	    0x10 => pack("C", 1), # Report NMEA data
	    0x23 => pack("C", 1), # Report *extended* external XTRA data requests
			       }));

	# 2. wait with infinite timeout and matching on PDS Event Report indications
	my @urls = ();
	my $maxsize = 0;

	my $match = {
	    tf => 1,
	    sys => QMI_PDS,
	    cid => &get_cid(QMI_PDS),
	    flags => 0x04,
	    ctrl => 0x80,
	    msgid => 0x0001,
	};

	my $qmi_in;
	do {
	    $qmi_in = &read_match($match, 0);

	    # TLV 0x14 is "External XTRA Database Request" - too small max file size!
	    # TLV 0x26 is "Extended External XTRA Database Request"
	    if ($qmi_in->{tlvs}{0x26}) {
		my $data = pack("C*", @{$qmi_in->{tlvs}{0x26}});
		my $num;
		($maxsize, $num) = unpack("VC", $data);
		warn "xtra: got $num urls and max file size = $maxsize\n";
		$data = substr($data, 5);
		for (my $i = 0; $i < $num; $i++) {
		    last unless $data; # failsafe
		    my $len = unpack("C", $data);
		    push(@urls, substr($data, 1, $len));
		    $data = substr($data, $len + 1);
		} 

	    }
	} while (!@urls && exists($qmi_in->{tf}));

	# 3. download file
	print Dumper(\@urls);

	my $content;
	foreach my $url (@urls) {
	    $content = get($url);
	    last if $content;
	}

	# 4. upload file in pieces within 90 seconds from event
	my $seq = 0;
	my $total = $content ? length($content) : 0;
	warn "will upload $total bytes\n";
	while (($total < $maxsize) && $content) {
	    my $chunk = substr($content, 0, 1536 );
	    $content = substr($content, 1536);

	    # QMI_PDS_INJECT_XTRA_DATA
	    my $ret = &send_and_recv(&mk_pds(0x0037,
					     {0x01 => pack("Cvv", $seq, $total, length($chunk)) . $chunk
					     }), 30); # need longer read timeout than default?
	    my $status = verify_status($ret);
	    if ($status) {
		warn "seq=$seq returned $err{$status} ($status)\n";
		last;
	    }
	    $seq++;
	}

	$debug = $old;

    }
}

# default common command number handling
if ($cmd && $cmd =~ s/^0x//) {
    my $msgid = hex($cmd);
    my $cid = $system == QMI_CTL ? 0 : &get_cid($system);

    # need to temporarily override debug output to force any useful output at all
    my $olddebug = $debug;
    $debug = 1;
    if (defined($cid)) {
	# anything else is considered TLV contents
	#  e.g:  0x01 00 0x10 01 0f => { 0x01 => 0, 0x10 => 0x0f01 }
	my $tlv;
	my @data;
	my %msg = ();
	foreach my $arg (@ARGV) {
	    # anything starting with 0x is considered a new TLV number
	    if ($arg =~ s/^0x([0-9a-f]{1,2})$/$1/i) {
		if ($tlv) {
		    # all TLVs need some data
		    &usage unless @data;
		    $msg{$tlv} = pack("C*", @data);
		    @data = ();
		}
		$tlv = hex($arg);
	    } elsif ($tlv && $arg =~ /^[0-9a-f]{1,2}$/i) {
		push(@data, hex($arg));
	    } else {
		&usage;
	    }
	}
	if ($tlv) {
	    # all TLVs need some data
	    &usage unless @data;
	    $msg{$tlv} = pack("C*", @data);
	}
	&send_and_recv(&mk_qmi($system, $cid, $msgid, \%msg));
    }
    $debug = $olddebug;
}

# save state for next run
&save_wds_state;

# monitoring?
if ($monitor) {
    my $old = $debug;
    $debug = 1;
    &monitor;
    $debug = $old;
}

# release all releasable CIDs
&release_cids;

# close device
close(F);

