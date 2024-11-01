# JSY-MK-339
Make your JSY-MK-339 Powermeter available on MQTT via homie convention.

This project assumes you have connected the Powermeter to an Modbus/RS485 to TCP gateway to query the device over network.
It is Possible to switch the Device::Modbus::TCP::Client with Device::Modbus::RTU::Client and directly access the powermeter over a serial connection.

# Install
First create a user under which the service will run:
```
sudo adduser --system --no-create-home --group powermeter
```

Install files:
```
cp powermeter-mqtt.pl /usr/local/bin/
cp powermeter.ini /usr/local/etc/
cp powermeter.service /etc/systemd/system/
```

Edit config file to your likings.

Install Perl dependencies:
```
cpan install Device::Modbus::TCP::Client Net::MQTT::Simple Systemd::Daemon IO::Async::Loop IO::Async::Timer::Periodic Getopt::Long Config::IniFiles
```

Reload systemd and enable service
```
systemctl daemon-reload
systemctl enable powermeter
systemctl start powermeter
```

# Configuration
All relevant settings can be done through the ini file. 

There are three sections, one for MQTT config, one for Modbus over TCP and the last one for selecting the grid type: 3 Phase or 2 Phase (default).
