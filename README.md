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
import 'dart:typed_data';
import 'package:dart_mqtt_broker/mqtt_broker.dart';


void main() async {
  // Start the MQTT Broker
  final broker = MqttBroker(address: '0.0.0.0', port: 1883);
  await broker.start();
  print('MQTT Broker is running...');
  
  // Listen to topic subscribed
  broker.onTopicSubscribedListener((String topic, int count) {
    print('Topic subscribed: $topic, subscriber count: $count');
  });
  
  // Listen to message published
  broker.onMessagePublishedListener((String topic, int qos, Uint8List payload) {
    final decodedPayload = utf8.decode(payload);
    print('Message published: topic: $topic, qos: $qos, payload: $decodedPayload');
  });
  
  // Publish a message
  String text = "Hello, World!";
  Uint8List uint8List = Uint8List.fromList(utf8.encode(text));

  broker.publishMessage(
    '/topic/mytopic', // Topic
    0, // QoS
    uint8List, // Bytes data
  );
  
  // Stop the broker
  await broker.stop();
}
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

This project is licensed under the MIT License.

