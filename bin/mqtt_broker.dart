import 'dart:io';

import 'package:mqtt_broker/mqtt_broker.dart';

void main() {
  final mqttBroker = MqttBroker(address: InternetAddress.anyIPv4.address);
  mqttBroker.start();
}
