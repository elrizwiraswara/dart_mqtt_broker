import 'dart:io';
import 'dart:typed_data';

class MqttBroker {
  final String address;
  final int port;

  late ServerSocket? _serverSocket;
  final Map<String, List<Socket>> _topicSubscribers = {};
  void Function(String topic, int qos, Uint8List payload)? _onMessagePublished;

  MqttBroker({
    required this.address,
    this.port = 1883,
  });

  Future<void> start() async {
    try {
      _serverSocket = await ServerSocket.bind(address, port);
      print('[MqttBroker] MQTT Broker started on ${_serverSocket!.address} port $port');
      _serverSocket!.listen(_handleClient);
    } catch (e) {
      print('[MqttBroker] Failed to start MQTT Broker: $e');
    }
  }

  Future<void> stop() async {
    try {
      _serverSocket?.close();
      _serverSocket = null;
      _topicSubscribers.clear();
      print('[MqttBroker] MQTT Broker stopped');
    } catch (e) {
      print('[MqttBroker] Failed to stop MQTT Broker: $e');
    }
  }

  void onMessagePublishedListener(Function(String topic, int qos, Uint8List payload) listener) {
    _onMessagePublished = listener;
    print('[MqttBroker] Listener for published messages set.');
  }

  void _handleClient(Socket client) {
    print('[MqttBroker] Client connected: ${client.remoteAddress.address}:${client.remotePort}');
    client.listen(
      cancelOnError: true,
      (Uint8List data) => _processPacket(client, data),
      onError: (error) => print('[MqttBroker] Error from client: $error'),
      onDone: () => print('[MqttBroker] Client disconnected'),
    );
  }

  void _processPacket(Socket client, Uint8List data) {
    try {
      if (data.isEmpty) {
        print('[MqttBroker] Received empty packet, ignoring.');
        return;
      }

      // Fixed Header
      final packetType = data[0].toRadixString(16);

      // Parse Remaining Length
      final remainingLengthResult = _parseRemainingLength(data, 1);
      if (remainingLengthResult == null) {
        print('[MqttBroker] Invalid remaining length field, ignoring packet.');
        return;
      }
      final remainingLength = remainingLengthResult['length'] ?? 0;
      final variableHeaderIndex = remainingLengthResult['index'] ?? 0;

      if (data.length < variableHeaderIndex + remainingLength) {
        print(
            '[MqttBroker] Incomplete packet: Expected length = ${variableHeaderIndex + remainingLength}, Actual length = ${data.length}');
        return;
      }

      // Process Packet by Type
      switch (packetType) {
        case '10': // CONNECT
          print('[MqttBroker] CONNECT received');
          _handleConnect(client);
          break;

        case '82': // SUBSCRIBE
          print('[MqttBroker] SUBSCRIBE received');
          _handleSubscribe(client, data, variableHeaderIndex, remainingLength);
          break;

        case '30': // PUBLISH
          print('[MqttBroker] PUBLISH received');
          _handlePublish(client, data, variableHeaderIndex, remainingLength);
          break;

        case 'c0': // PINGREQ (Handled by client)
          print('[MqttBroker] PINGREQ received');
          _handlerPingReq(client);
          break;

        case 'e0': // DISCONNECT (Handled by client)
          print('[MqttBroker] DISCONNECT received');
          _handleDisconnect(client);
          break;

        default:
          print('[MqttBroker] Unknown packet type: $packetType');
      }
    } catch (e) {
      print('[MqttBroker] Error while writing to client: $e');
      _handleDisconnect(client);
    }
  }

  Map<String, int>? _parseRemainingLength(Uint8List data, int startIndex) {
    int multiplier = 1;
    int value = 0;
    int index = startIndex;

    while (index < data.length) {
      final byte = data[index];
      value += (byte & 0x7F) * multiplier;
      multiplier *= 128;

      if (multiplier > 128 * 128 * 128) {
        print('[MqttBroker] Remaining length too large, ignoring packet.');
        return null;
      }

      index++;

      if ((byte & 0x80) == 0) {
        break;
      }
    }

    return {'length': value, 'index': index};
  }

  void _handleConnect(Socket client) {
    try {
      final clientAddress = client.remoteAddress.address;

      List<String> connectedClientAdresses = [];

      _topicSubscribers.forEach((topic, clients) async {
        connectedClientAdresses = clients.map((e) => e.remoteAddress.address).toList();
      });

      if (connectedClientAdresses.contains(clientAddress)) {
        print('[MqttBroker] CONNECT ignored: Client $clientAddress is already connected.');
        return;
      }

      print('[MqttBroker] CONNECT received from $clientAddress');

      client.add(_buildConnAckPacket());
    } catch (e) {
      print('[MqttBroker] Error while writing to client: $e');
      _handleDisconnect(client);
    }
  }

  void _handlePublish(Socket client, Uint8List data, int variableHeaderIndex, int remainingLength) {
    // Extract Fixed Header Flags
    final fixedHeader = data[0];
    final qos = (fixedHeader >> 1) & 0x03; // QoS level (2 bits)
    final retain = (fixedHeader & 0x01) == 1; // Retain flag

    // Extract Topic Name
    final topicLength = (data[variableHeaderIndex] << 8) + data[variableHeaderIndex + 1];
    final topicStart = variableHeaderIndex + 2;
    final topicEnd = topicStart + topicLength;

    if (topicEnd > data.length) {
      print('[MqttBroker] Invalid topic length in PUBLISH packet.');
      return;
    }
    final topic = String.fromCharCodes(data.sublist(topicStart, topicEnd));

    // QoS-specific Handling: Extract Packet Identifier for QoS 1 or 2
    int payloadStart = topicEnd;
    int? packetIdentifier;
    if (qos > 0) {
      if (payloadStart + 2 > data.length) {
        print('[MqttBroker] Invalid packet identifier length in PUBLISH packet.');
        return;
      }
      packetIdentifier = (data[payloadStart] << 8) + data[payloadStart + 1];
      payloadStart += 2;
      print('[MqttBroker] PUBLISH packet with QoS $qos, Packet Identifier: $packetIdentifier');
    }

    final payloadEnd = variableHeaderIndex + remainingLength;
    if (payloadEnd > data.length) {
      print('[MqttBroker] Invalid payload length in PUBLISH packet.');
      return;
    }

    final payload = data.sublist(payloadStart, payloadEnd);

    print('[MqttBroker] Received PUBLISH: Topic = "$topic", Payload (bytes) = $payload, QoS = $qos, Retain = $retain');

    publishMessage(topic, qos, payload);

    // Acknowledge if QoS 1
    if (qos == 1 && packetIdentifier != null) {
      try {
        client.add(_buildPubAckPacket(packetIdentifier));
      } catch (e) {
        print('[MqttBroker] Error while writing to client: $e');
        _handleDisconnect(client);
      }
    }

    // For QoS 2, additional handling (PUBREC, PUBREL, PUBCOMP) would be needed.
  }

  Uint8List _buildPubAckPacket(int packetIdentifier) {
    return Uint8List.fromList([
      0x40, // PUBACK packet type and flags
      0x02, // Remaining length
      (packetIdentifier >> 8) & 0xFF, // Packet Identifier MSB
      packetIdentifier & 0xFF, // Packet Identifier LSB
    ]);
  }

  void _handleSubscribe(Socket client, Uint8List data, int variableHeaderIndex, int remainingLength) {
    int index = variableHeaderIndex;
    final packetIdentifier = (data[index] << 8) + data[index + 1]; // 2 bytes for Packet Identifier
    index += 2;
    print('[MqttBroker] Packet Identifier: $packetIdentifier');

    // Check if the remaining length makes sense for the topics in the packet
    int expectedLength = remainingLength - 2; // excluding Packet Identifier
    print('[MqttBroker] Expected remaining length for topics: $expectedLength');

    while (index < data.length && expectedLength > 0) {
      // Extract Topic Length (2 bytes)
      final topicLength = (data[index] << 8) + data[index + 1]; // 2 bytes for topic length
      index += 2;

      // Sanity check for topic length
      if (topicLength <= 0 || topicLength + index > data.length) {
        print('[MqttBroker] Invalid topic length, ignoring packet.');
        return;
      }

      final topic = String.fromCharCodes(data.sublist(index, index + topicLength)); // Extract topic name
      index += topicLength;

      // Extract QoS level (1 byte)
      final qos = data[index];
      index++;

      print('[MqttBroker] Subscribed to topic: "$topic" with QoS: $qos');

      // Subscribe client to the topic
      _subscribeToTopic(client, topic);

      expectedLength -= (2 + topicLength + 1); // reduce expected length (Topic Length + Topic Name + QoS)
    }
  }

  void _subscribeToTopic(Socket client, String topic) {
    if (!_topicSubscribers.containsKey(topic)) {
      _topicSubscribers[topic] = [];
    }
    _topicSubscribers[topic]!.add(client);
    print('[MqttBroker] Client subscribed to topic: $topic length ${_topicSubscribers.length}');
    print('[MqttBroker] Client subscriber: ${_topicSubscribers.toString()}');

    try {
      // Send SUBACK packet (optional, depending on MQTT version)
      client.add(_buildSubAckPacket());
    } catch (e) {
      print('[MqttBroker] Error while writing to client: $e');
      _handleDisconnect(client);
    }

    // Notify the listener
    if (_onMessagePublished != null) {
      print('[MqttBroker] Message publised listener added');
      _onMessagePublished!(topic, 0, Uint8List.fromList([0]));
    }
  }

  Uint8List _buildSubAckPacket() {
    return Uint8List.fromList([0x90, 0x02, 0x00, 0x00]); // Example SUBACK packet
  }

  void publishMessage(String topic, int qos, Uint8List payload) {
    if (_topicSubscribers.containsKey(topic)) {
      final subscribers = _topicSubscribers[topic]!;
      for (final client in subscribers) {
        final publishPacket = _buildPublishPacket(topic, qos, payload);
        print('[MqttBroker] Message sent to client: Topic = $topic, Payload = $payload');

        try {
          // Send SUBACK packet (optional, depending on MQTT version)
          client.add(publishPacket);
        } catch (e) {
          print('[MqttBroker] Error while writing to client: $e');
          _handleDisconnect(client);
        }
      }
    } else {
      print('[MqttBroker] No subscribers for topic: $topic');
    }

    // Notify the listener
    if (_onMessagePublished != null) {
      print('[MqttBroker] Message publised listener added');
      _onMessagePublished!(topic, qos, payload);
    }
  }

  Uint8List _buildPublishPacket(String topic, int qos, Uint8List payload) {
    // Fixed Header
    final fixedHeader = 0x30 | (qos << 1); // PUBLISH packet with QoS bits

    // Variable Header: Topic Name
    final topicBytes = Uint8List.fromList(topic.codeUnits);
    final topicLength = Uint8List(2);
    topicLength[0] = (topicBytes.length >> 8) & 0xFF;
    topicLength[1] = topicBytes.length & 0xFF;

    // Remaining Length: Topic Length + Payload Length
    final remainingLength = topicBytes.length + 2 + payload.length;
    final remainingLengthBytes = _encodeRemainingLength(remainingLength);

    // Combine all parts
    return Uint8List.fromList([
      fixedHeader,
      ...remainingLengthBytes,
      ...topicLength,
      ...topicBytes,
      ...payload,
    ]);
  }

  List<int> _encodeRemainingLength(int length) {
    final result = <int>[];
    do {
      var encodedByte = length % 128;
      length = length ~/ 128;
      if (length > 0) {
        encodedByte |= 0x80;
      }
      result.add(encodedByte);
    } while (length > 0);
    return result;
  }

  void _handlerPingReq(Socket client) {
    try {
      client.add(Uint8List.fromList([0xD0, 0x00]));
    } catch (e) {
      print('[MqttBroker] Error while writing to client: $e');
      _handleDisconnect(client);
    }
  }

  void _handleDisconnect(Socket client) async {
    print('[MqttBroker] Client disconnected: ${client.remoteAddress.address}:${client.remotePort}');
    await client.flush();
    await client.close();
  }

  Uint8List _buildConnAckPacket() {
    // MQTT CONNACK Packet: Fixed header (0x20) + Remaining length (0x02) + Flags (0x00) + Return Code (0x00)
    return Uint8List.fromList([0x20, 0x02, 0x00, 0x00]);
  }
}
