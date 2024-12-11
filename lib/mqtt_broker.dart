import 'dart:io';
import 'dart:typed_data';

class MqttBroker {
  final String address;
  final int port;

  late ServerSocket? _serverSocket;
  final Map<String, List<Socket>> _topicSubscribers = {};

  MqttBroker({
    required this.address,
    this.port = 1883,
  });

  Future<void> start() async {
    try {
      _serverSocket = await ServerSocket.bind(address, port);
      print('MQTT Broker started on ${_serverSocket!.address} port $port');
      _serverSocket!.listen(_handleClient);
    } catch (e) {
      print('Failed to start MQTT Broker: $e');
    }
  }

  Future<void> stop() async {
    try {
      _serverSocket?.close();
      _serverSocket = null;
      _topicSubscribers.clear();
      print('MQTT Broker stopped');
    } catch (e) {
      print('Failed to stop MQTT Broker: $e');
    }
  }

  void _handleClient(Socket client) {
    print('Client connected: ${client.remoteAddress.address}:${client.remotePort}');
    client.listen(
      (Uint8List data) => _processPacket(client, data),
      onError: (error) => print('Error from client: $error'),
      onDone: () => _clientDisconnected(client),
    );
  }

  void _processPacket(Socket client, Uint8List data) {
    if (data.isEmpty) {
      print('Received empty packet, ignoring.');
      return;
    }

    // Fixed Header
    final packetType = data[0].toRadixString(16);

    // Parse Remaining Length
    final remainingLengthResult = _parseRemainingLength(data, 1);
    if (remainingLengthResult == null) {
      print('Invalid remaining length field, ignoring packet.');
      return;
    }
    final remainingLength = remainingLengthResult['length'] ?? 0;
    final variableHeaderIndex = remainingLengthResult['index'] ?? 0;

    if (data.length < variableHeaderIndex + remainingLength) {
      print('Incomplete packet, ignoring.');
      return;
    }

    // Process Packet by Type
    switch (packetType) {
      case '10': // CONNECT
        print('CONNECT received');
        client.add(_buildConnAckPacket());
        break;

      case '82': // SUBSCRIBE
        print('SUBSCRIBE received');
        _handleSubscribe(client, data, variableHeaderIndex, remainingLength);
        break;

      case '30': // PUBLISH
        print('PUBLISH received');
        _handlePublish(client, data, variableHeaderIndex, remainingLength);
        break;

      case 'c0': // PINGREQ (Handled by client)
        print('PINGREQ received');
        client.add(Uint8List.fromList([0xD0, 0x00]));
        break;

      case 'e0': // DISCONNECT (Handled by client)
        print('DISCONNECT received');
        _clientDisconnected(client);
        break;

      default:
        print('Unknown packet type: $packetType');
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
        return null; // Remaining length field too large
      }

      index++;

      if ((byte & 0x80) == 0) {
        break;
      }
    }

    return {'length': value, 'index': index};
  }

  void _handlePublish(Socket client, Uint8List data, int variableHeaderIndex, int remainingLength) {
    // Extract Topic Name
    final topicLength = (data[variableHeaderIndex] << 8) + data[variableHeaderIndex + 1];
    final topicStart = variableHeaderIndex + 2;
    final topicEnd = topicStart + topicLength;

    if (topicEnd > data.length) {
      print('Invalid topic length in PUBLISH packet.');
      return;
    }
    final topic = String.fromCharCodes(data.sublist(topicStart, topicEnd));

    // Extract Payload
    final payloadStart = topicEnd;
    final payloadEnd = variableHeaderIndex + remainingLength;
    if (payloadEnd > data.length) {
      print('Invalid payload length in PUBLISH packet.');
      return;
    }
    final payload = String.fromCharCodes(data.sublist(payloadStart, payloadEnd));

    print('Received PUBLISH: Topic = "$topic", Payload = "$payload"');
    _publishMessage(topic, payload);
  }

  void _handleSubscribe(Socket client, Uint8List data, int variableHeaderIndex, int remainingLength) {
    int index = variableHeaderIndex;
    final packetIdentifier = (data[index] << 8) + data[index + 1]; // 2 bytes for Packet Identifier
    index += 2;
    print('Packet Identifier: $packetIdentifier');

    // Check if the remaining length makes sense for the topics in the packet
    int expectedLength = remainingLength - 2; // excluding Packet Identifier
    print('Expected remaining length for topics: $expectedLength');

    while (index < data.length && expectedLength > 0) {
      // Extract Topic Length (2 bytes)
      final topicLength = (data[index] << 8) + data[index + 1]; // 2 bytes for topic length
      index += 2;

      // Sanity check for topic length
      if (topicLength <= 0 || topicLength + index > data.length) {
        print('Invalid topic length, ignoring packet.');
        return;
      }

      final topic = String.fromCharCodes(data.sublist(index, index + topicLength)); // Extract topic name
      index += topicLength;

      // Extract QoS level (1 byte)
      final qos = data[index];
      index++;

      print('Subscribed to topic: "$topic" with QoS: $qos');

      // Subscribe client to the topic
      _subscribeToTopic(client, topic);

      expectedLength -= (2 + topicLength + 1); // reduce expected length (Topic Length + Topic Name + QoS)
    }
  }

  // String? _extractString(Uint8List data, int startIndex) {
  //   if (startIndex + 2 > data.length) {
  //     return null;
  //   }
  //   final length = (data[startIndex] << 8) + data[startIndex + 1];
  //   final endIndex = startIndex + 2 + length;
  //   if (endIndex > data.length) {
  //     return null;
  //   }
  //   return String.fromCharCodes(data.sublist(startIndex + 2, endIndex));
  // }

  void _subscribeToTopic(Socket client, String topic) {
    if (!_topicSubscribers.containsKey(topic)) {
      _topicSubscribers[topic] = [];
    }
    _topicSubscribers[topic]!.add(client);
    print('[_subscribeToTopic] Client subscribed to topic: $topic length ${_topicSubscribers.length}');
    print('[_subscribeToTopic] Client subscriber: ${_topicSubscribers.toString()}');

    // Send SUBACK packet (optional, depending on MQTT version)
    client.add(_buildSubAckPacket());
  }

  Uint8List _buildSubAckPacket() {
    return Uint8List.fromList([0x90, 0x02, 0x00, 0x00]); // Example SUBACK packet
  }

  void _publishMessage(String topic, String message) {
    print('[_publishMessage] Client subscriber: ${_topicSubscribers.toString()}');
    print('[_publishMessage] is contains subscribe key $topic: ${_topicSubscribers.containsKey(topic)}');
    if (_topicSubscribers.containsKey(topic)) {
      final subscribers = _topicSubscribers[topic]!;
      for (final client in subscribers) {
        final publishPacket = _buildPublishPacket(topic, message);
        client.add(publishPacket);
        print('Message sent to client: Topic = $topic, Message = $message');
      }
    } else {
      print('No subscribers for topic: $topic');
    }
  }

  Uint8List _buildPublishPacket(String topic, String message) {
    final topicBytes = topic.codeUnits;
    final messageBytes = message.codeUnits;

    // Fixed header
    final header = [0x30]; // PUBLISH with QoS 0

    // Remaining length
    final remainingLength = topicBytes.length + 2 + messageBytes.length;
    final remainingLengthBytes = _encodeRemainingLength(remainingLength);

    // Variable header + payload
    final payload = [
      (topicBytes.length >> 8) & 0xFF,
      topicBytes.length & 0xFF,
      ...topicBytes,
      ...messageBytes,
    ];

    return Uint8List.fromList([...header, ...remainingLengthBytes, ...payload]);
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

  void _clientDisconnected(Socket client) {
    print('Client disconnected: ${client.remoteAddress.address}:${client.remotePort}');
    _topicSubscribers.forEach((topic, clients) {
      client.close();
      clients.remove(client);
    });
  }

  Uint8List _buildConnAckPacket() {
    // MQTT CONNACK Packet: Fixed header (0x20) + Remaining length (0x02) + Flags (0x00) + Return Code (0x00)
    return Uint8List.fromList([0x20, 0x02, 0x00, 0x00]);
  }
}
