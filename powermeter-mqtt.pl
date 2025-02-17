#!/usr/bin/perl
use strict;
use warnings;
use Device::Modbus::TCP::Client;
use Net::MQTT::Simple;
use Systemd::Daemon qw( -hard notify );
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Getopt::Long;
use Config::IniFiles;
use JSON;
use File::Slurp;

$| = 1;    # piping hot!

$SIG{'INT'}  = 'STOP_LOOP';
$SIG{'TERM'} = 'STOP_LOOP';
$SIG{'PIPE'} = 'IGNORE';


my $config = "powermeter.ini";
my ( $verbose, $help ) = ( 0, 0 );
my $options = GetOptions(
	"config=s"  => \$config,
	"verbose"   => \$verbose,
	"help"      => \$help
);
help() if( $help );

my $settings = Config::IniFiles->new( -file => $config ) or die( "Cannot open '$config': $!\n" );

# Initialize MQTT connection
my $mqtt;
if( $settings->val( "MQTT", "use_ssl" ) ) {
	$mqtt = Net::MQTT::Simple->new( $settings->val( "MQTT", "host" ).":".$settings->val( "MQTT", "port" ),
		{
			SSL_ca_file => $settings->val( "MQTT", "broker_ca" ),
			SSL_ca_path => "/etc/ssl/certs"
		}
	);
} else {
	$mqtt = Net::MQTT::Simple->new( $settings->val( "MQTT", "host" ).":".$settings->val( "MQTT", "port" ) );
}
if( $settings->exists( "MQTT", "username" ) ) {
	$mqtt->login(
		$settings->val( "MQTT", "username" ),
		$settings->val( "MQTT", "password" )
	);
}

my $topic = "homie/".$settings->val( "MQTT", "devicename" )."/";

# Initialize the Modbus RTU client
my $client = Device::Modbus::TCP::Client->new(
    host => $settings->val( "Modbus", "host" ),
    port => $settings->val( "Modbus", "port" ),
    debug => 0
);


# Registers and their meaning
my $valuemap = {
	"Voltage" => {
		"r" => 0x0048,		# voltage register start
		"u" => "V",		# unit of register
		"d" => 100,		# division factor
		"c" => 3,		# mumber of registers to read
		"n" => {		# node configuration:
			"L1" => 0,	# L1 is on 1st register read
			"L2" => 1	# L2 is on second register
		}
	},
	"Current" => {
		"r" => 0x004b,
		"u" => "A",
		"d" => 100,
		"c" => 3,
		"n" => {
			"L1" => 0,
			"L2" => 1
		}
	},
	"Power" => {
		"r" => 0x004f,
		"u" => "kW",
		"d" => 100,
		"c" => 4,
		"n" => {
			"L1" => 0,
			"L2" => 1,
			"total" => 3
		}
	},
	"Reactive" => {
		"r" => 0x0053,
		"u" => "kVar",
		"d" => 100,
		"c" => 4,
		"n" => {
			"L1" => 0,
			"L2" => 1,
			"total" => 3
		}
	},
	"Apparent" => {
		"r" => 0x0057,
		"u" => "kVA",
		"d" => 100,
		"c" => 4,
		"n" => {
			"L1" => 0,
			"L2" => 1,
			"total" => 3
		}
	},
	"Powerfactor" => {
		"r" => 0x005b,
		"u" => "",
		"d" => 1000,
		"c" => 4,
		"n" => {
			"L1" => 0,
			"L2" => 1,
			"total" => 3
		}
	},
	"Total_Power" => {
		"r" => 0x005f,
		"u" => "kWh",
		"d" => 100,
		"c" => 8,
		"n" => {
			"L1" => 0,
			"L2" => 2,
			"total" => 6
		},
		"4b" => 1
	},
	"Total_Reactive" => {
		"r" => 0x0067,
		"u" => "kvarh",
		"d" => 100,
		"c" => 8,
		"n" => {
			"L1" => 0,
			"L2" => 2,
			"total" => 6
		},
		"4b" => 1
	},
	"Total_Apparent" => {
		"r" => 0x006f,
		"u" => "kVAh",
		"d" => 100,
		"c" => 8,
		"n" => {
			"L1" => 0,
			"L2" => 2,
			"total" => 6
		},
		"4b" => 1
	},
	"Frequency" => {
		"r" => 0x0077,
		"u" => "Hz",
		"d" => 100,
		"c" => 1,
		"n" => {
			"total" => 0
		}
	}
};

# If this meter is connected to 3 phases
# add register definitions for L3
if( $settings->val( "Powermeter", "is_three_phase" ) ) {
	$valuemap->{"Voltage"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Current"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Power"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Reactive"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Apparent"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Powerfactor"}->{"n"}->{"L3"} = 2;
	$valuemap->{"Total_power"}->{"n"}->{"L3"} = 4;
	$valuemap->{"Total_reactive"}->{"n"}->{"L3"} = 4;
	$valuemap->{"Total_apparent"}->{"n"}->{"L3"} = 4;
}


# Build homie registration
$mqtt->last_will( $topic.'$state', "lost" );
$mqtt->retain( $topic.'$homie', "4.0.0" );
$mqtt->retain( $topic.'$name', "JSY-MK-339" );
$mqtt->retain( $topic.'$state', "init" );
$mqtt->retain( $topic.'$nodes', lc( join( ",", sort keys %{$valuemap} ) ) );
foreach my $mqtt_node ( sort keys %{$valuemap} ) {
	my $node_name = $mqtt_node;
	$node_name =~ s/_/ /;
	$mqtt->retain( $topic.lc( $mqtt_node ).'/$name', $node_name );
	$mqtt->retain( $topic.lc( $mqtt_node ).'/$type', $node_name." Sensor" );
	$mqtt->retain( $topic.lc( $mqtt_node ).'/$properties', lc( join( ",", sort keys %{$valuemap->{$mqtt_node}->{"n"}} ) ) );
	foreach my $mqtt_prop ( sort keys %{$valuemap->{$mqtt_node}->{"n"}} ) {
		$mqtt->retain( $topic.lc( $mqtt_node )."/".lc( $mqtt_prop ).'/$name', $mqtt_prop );
		$mqtt->retain( $topic.lc( $mqtt_node )."/".lc( $mqtt_prop ).'/$datatype', "float" );
		$mqtt->retain( $topic.lc( $mqtt_node )."/".lc( $mqtt_prop ).'/$settable', "false" );
		$mqtt->retain( $topic.lc( $mqtt_node )."/".lc( $mqtt_prop ).'/$unit', $valuemap->{$mqtt_node}->{"u"} );
	}
}
$mqtt->retain( $topic.'$state', "ready" );

my $loop = IO::Async::Loop->new;
my $publish = IO::Async::Timer::Periodic->new(
	interval => 10,
	on_tick => sub {
		foreach my $measure ( sort keys %{$valuemap} ) {
			# Build the request
			my $request = $client->read_holding_registers(
				unit     => $settings->val( "Powermeter", "device_address" ),
				address  => $valuemap->{$measure}->{"r"},
				quantity => $valuemap->{$measure}->{"c"}
			);

			# Send the request
			$client->send_request($request);

			# Receive the response
			my $response = $client->receive_response();

			if( $response->success ) {
				print "$measure:\n" if( $verbose );
				foreach my $node ( sort keys %{$valuemap->{$measure}->{"n"}} ) {
					my $reg_value;

					# If register is 4 byte long we have to shift first register by 16 bit (MSB) and add second register
                                        if( defined( $valuemap->{$measure}->{"4b"} ) && $valuemap->{$measure}->{"4b"} ) {
						$reg_value = ( @{$response->values}[ $valuemap->{$measure}->{"n"}->{$node} ] << 16 ) | @{$response->values}[ $valuemap->{$measure}->{"n"}->{$node} + 1 ];
                                        } else {
					# Otherwise we can just use the 2 byte value
						$reg_value = @{$response->values}[ $valuemap->{$measure}->{"n"}->{$node} ];
					}

					# Finally divide by register divisor.
					$reg_value /= $valuemap->{$measure}->{"d"};

                                        print "\t$node: $reg_value ".$valuemap->{$measure}->{"u"}."\n" if( $verbose );;
                                        $mqtt->publish( $topic.lc( $measure )."/".lc( $node ), $reg_value );

				}
				print "\n" if( $verbose );
			} else {
				warn "Failed to get value for $measure";
			}

			print "\n" if( $verbose );
		}
	}
);
$loop->add( $publish );

my $watchdog = IO::Async::Timer::Periodic->new(
	interval => 60,
	on_tick => sub {
		# tell systemd we're still alive.
		notify( WATCHDOG => 1 );
	},
);
$loop->add( $watchdog );

$publish->start;
$watchdog->start;

notify( READY => 1 );
$loop->run;

sub STOP_LOOP {
	$mqtt->retain( $topic.'$state', "disconnected" );
	$mqtt->disconnect();

	$publish->stop;
	$watchdog->stop;
	$loop->stop;
	exit( 0 );
}

sub help {
	print 'powermeter-mqtt.pl
	config	config file to use (default: powermeter.ini)
	verbose	show what\'s going on.
	help	print this help message.
';
	exit( 0 );
}
