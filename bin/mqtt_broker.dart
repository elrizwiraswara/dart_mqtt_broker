import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mqtt_broker/client.dart';
import 'package:dart_mqtt_broker/mqtt_broker.dart';

void main() async {
  // Start the MQTT Broker
  final broker = MqttBroker(address: InternetAddress.anyIPv4.address, port: 1883);
  await broker.start();
  print('MQTT Broker is running...');

  List<Client> connectedClients = [];

  // Listen to connected client
  broker.onClientConnectListener((Client client) {
    connectedClients.add(client);
    print('Connected client: ${client.clientId}');
  });

  // Listen to disconnected client
  broker.onClientDisconnectListener((Client client) {
    connectedClients.remove(client);
    print('Disconnected client: ${client.clientId}');
  });

  // Listen to topic subscribed
  broker.onTopicSubscribedListener((String topic, int count) {
    print('Topic subscribed: $topic, subscriber count: $count');
  });

  // Listen to message published
  broker.onMessagePublishedListener((String topic, int qos, Uint8List payload) {
    final decodedPayload = utf8.decode(payload);
    print('Message published: topic: $topic, qos: $qos, payload: $decodedPayload');
  });

  // String text = "Hello, World!";
  // // You can also use MessagePack if needed
  // // Uint8List bytesData = serialize(text);
  // Uint8List uint8List = Uint8List.fromList(utf8.encode(text));

  // // Publish a message
  // broker.publishMessage(
  //   '/topic/mytopic', // Topic
  //   0, // QoS
  //   uint8List, // Bytes data
  // );

  // // Disconnect client
  // for (var client in connectedClients) {
  //   await broker.disconnectClient(client);
  // }

  // // Stop the broker
  // await broker.stop();
}
