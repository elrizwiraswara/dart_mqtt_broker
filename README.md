# Dart MQTT Broker

A MQTT Broker written in Dart.

## Overview

`dart_mqtt_broker` is a MQTT server implementation written entirely in Dart. Designed for lightweight applications, it supports MQTT versions 3.1.1 and 5.0 and is optimized for ease of integration. This project is under active development, with new features and improvements being added regularly.


## Getting Started

### Prerequisites

- Dart SDK version 3.5.3 or higher

### Installation

1. Clone the repository:
    ```sh
    git clone https://github.com/elrizwiraswara/dart_mqtt_broker.git
    cd dart_mqtt_broker
    ```

2. Install as dependency in `pubspec.yaml`
    ```yaml
    dart_mqtt_broker: 
      git:
        url: https://github.com/elrizwiraswara/dart_mqtt_broker
    ```

## Basic Example Usage

Here is a basic example of how to use the MQTT broker:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mqtt_broker/mqtt_broker.dart';
import 'package:dart_mqtt_broker/client.dart';
// import 'package:msgpack_dart/msgpack_dart.dart';

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
    // final decodedPayload = deserialize(payload); // MessagePack
    print('Message published: topic: $topic, qos: $qos, payload: $decodedPayload');
  });
  
  String text = "Hello, World!";
  Uint8List bytesData = Uint8List.fromList(utf8.encode(text));
  // You can also use MessagePack if needed
  // Uint8List bytesData = serialize(text);

  // Publish a message
  broker.publishMessage(
    '/topic/mytopic', // Topic
    0, // QoS
    bytesData, // Payload
  );

  // Disconnect client
  for (var client in connectedClients) {
    await broker.disconnectClient(client);
  }
  
  // Stop the broker
  await broker.stop();
}
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

This project is licensed under the MIT License.

