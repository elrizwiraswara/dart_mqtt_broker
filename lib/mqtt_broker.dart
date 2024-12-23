import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mqtt_broker/client.dart';

class MqttBroker {
  final String address;
  final int port;

  late ServerSocket? _serverSocket;
  final List<Client> _clients = [];
  final Map<String, List<Client>> _topicSubscribers = {};
  void Function(String topic, int count)? _onTopicSubscribedListener;
  void Function(String topic, int qos, Uint8List payload)? _onMessagePublishedListener;

  MqttBroker({
    required this.address,
    this.port = 1883,
  });

  Future<void> start() async {
    try {
      _serverSocket = await ServerSocket.bind(address, port, shared: true);
      print('[MqttBroker] MQTT Broker started on ${_serverSocket!.address} port $port');
      _serverSocket!.listen(_handleClient);
    } catch (e) {
      print('[MqttBroker] Failed to start MQTT Broker: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      for (var client in _clients) {
        await _handleDisconnect(client.socket);
      }

      await _serverSocket?.close();
      _serverSocket = null;

      _topicSubscribers.clear();
      print('[MqttBroker] MQTT Broker stopped');
    } catch (e) {
      print('[MqttBroker] Failed to stop MQTT Broker: $e');
      rethrow;
    }
  }

  void onTopicSubscribedListener(Function(String topic, int count) listener) {
    _onTopicSubscribedListener = listener;
    print('[MqttBroker] Listener for subscribe topics set.');
  }

  void onMessagePublishedListener(Function(String topic, int qos, Uint8List payload) listener) {
    _onMessagePublishedListener = listener;
    print('[MqttBroker] Listener for published messages set.');
  }

  Future<void> disconnectClient(Socket socket) async {
    await _handleDisconnect(socket);
  }

  void _handleClient(Socket client) {
    client.listen(
      (Uint8List data) => _processPacket(client, data),
      onError: (error) => print('[MqttBroker] Error from client: $error'),
      onDone: () => print('[MqttBroker] Client disconnected'),
    );
  }

  void _processPacket(Socket socket, Uint8List data) async {
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
          _handleConnect(socket, data);
          break;

        case '82': // SUBSCRIBE
          print('[MqttBroker] SUBSCRIBE received');
          _handleSubscribe(socket, data, variableHeaderIndex, remainingLength);
          break;

        case '30': // PUBLISH
          print('[MqttBroker] PUBLISH received');
          _handlePublish(socket, data, variableHeaderIndex, remainingLength);
          break;

        case 'c0': // PINGREQ (Handled by client)
          print('[MqttBroker] PINGREQ received');
          _handlerPingReq(socket);
          break;

        case 'e0': // DISCONNECT (Handled by client)
          print('[MqttBroker] DISCONNECT received');
          _handleDisconnect(socket);
          break;

        default:
          print('[MqttBroker] Unknown packet type: $packetType');
      }
    } catch (e) {
      print('[MqttBroker] Error while writing to client: $e');
      await _handleDisconnect(socket);
      rethrow;
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

  void _handleConnect(Socket socket, Uint8List data) {
    final isSessionPresent = _isSessionPresent(data);
    final clientId = _parseClientId(data);

    _clients.add(Client(clientId: clientId, socket: socket));

    socket.add(_buildConnAckPacket(isSessionPresent));

    print('[MqttBroker] CONNECT received from $clientId address: ${socket.remoteAddress.address}:${socket.remotePort}');
  }

  bool _isSessionPresent(Uint8List data) {
    // The clean session flag is the first bit of the Connect Flags byte (byte 9)
    return (data[9] & 0x02) != 0;
  }

  String _parseClientId(Uint8List data) {
    // Skip the fixed header (2 bytes)
    int index = 2;

    // Skip the variable header (10 bytes for protocol name, version, flags, keep alive)
    index += 10;

    // Ensure there are enough bytes to read the client ID length
    if (index + 2 > data.length) {
      throw RangeError('Not enough data to read client ID length');
    }

    // Read the length of the client ID (2 bytes)
    int clientIdLength = (data[index] << 8) + data[index + 1];
    index += 2;

    // Ensure there are enough bytes to read the client ID
    if (index + clientIdLength > data.length) {
      throw RangeError('Not enough data to read client ID');
    }

    // Extract the client ID
    return String.fromCharCodes(data.sublist(index, index + clientIdLength));
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
      client.add(_buildPubAckPacket(packetIdentifier));
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

  void _handleSubscribe(Socket socket, Uint8List data, int variableHeaderIndex, int remainingLength) {
    int index = variableHeaderIndex;

    // Extract Packet Identifier
    final packetIdentifier = (data[index] << 8) + data[index + 1];
    index += 2;

    // Check if the remaining length makes sense for the topics in the packet
    int expectedLength = remainingLength - 2; // excluding Packet Identifier
    print('[MqttBroker] Expected remaining length for topics: $expectedLength');

    final grantedQoS = <int>[];

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
      _subscribeToTopic(socket, topic);

      // Add granted QoS to the list (for simplicity, grant the requested QoS)
      grantedQoS.add(qos);

      expectedLength -= (2 + topicLength + 1); // reduce expected length (Topic Length + Topic Name + QoS)
    }

    // Build and send SUBACK packet
    final subAckPacket = _buildSubAckPacket(packetIdentifier, grantedQoS);
    socket.add(subAckPacket);
  }

  void _subscribeToTopic(Socket socket, String topic) {
    if (!_topicSubscribers.containsKey(topic)) {
      _topicSubscribers[topic] = [];
    }

    List<Client> subscribedClients = [];

    _topicSubscribers.forEach((currTopic, clients) async {
      if (currTopic != topic) return;
      subscribedClients = clients;
    });

    final currClient = _clients.where((x) => x.socket == socket).firstOrNull;
    if (currClient == null) {
      print('[MqttBroker] Client not found or not connected yet for subscription');
      return;
    }

    final isAlreadySubscribed = subscribedClients.any((x) => x.clientId == currClient.clientId);

    if (isAlreadySubscribed) {
      print('[MqttBroker] Client subscribe ignored: Client ${currClient.clientId} is already subscribed.');
      return;
    }

    _topicSubscribers[topic]!.add(currClient);
    print('[MqttBroker] Client subscribed to topic: $topic length ${_topicSubscribers[topic]!.length}');
    print('[MqttBroker] Client subscriber: ${_topicSubscribers.toString()}');

    // Notify the listener
    if (_onTopicSubscribedListener != null) {
      _onTopicSubscribedListener!(topic, _topicSubscribers[topic]!.length);
    }
  }

  Uint8List _buildSubAckPacket(int packetIdentifier, List<int> grantedQoS) {
    // Fixed header for SUBACK packet
    final fixedHeader = 0x90;

    // Remaining length: 2 bytes for Packet Identifier + 1 byte for each granted QoS
    final remainingLength = 2 + grantedQoS.length;

    // Packet Identifier (2 bytes)
    final packetIdentifierBytes = Uint8List(2);
    packetIdentifierBytes[0] = (packetIdentifier >> 8) & 0xFF;
    packetIdentifierBytes[1] = packetIdentifier & 0xFF;

    // Combine all parts
    return Uint8List.fromList([
      fixedHeader,
      remainingLength,
      ...packetIdentifierBytes,
      ...grantedQoS,
    ]);
  }

  void publishMessage(String topic, int qos, Uint8List payload) {
    if (_topicSubscribers.containsKey(topic)) {
      final subscribers = _topicSubscribers[topic]!;
      for (final client in subscribers) {
        final publishPacket = _buildPublishPacket(topic, qos, payload);

        // Send SUBACK packet (optional, depending on MQTT version)
        final currClient = _clients.where((e) => e.clientId == client.clientId).firstOrNull;
        if (currClient == null) return;
        currClient.socket.add(publishPacket);
        print('[MqttBroker] Message sent to client: ID: ${currClient.clientId}, Topic: $topic, Payload: $payload');
      }
    } else {
      print('[MqttBroker] No subscribers for topic: $topic');
    }

    // Notify the listener
    if (_onMessagePublishedListener != null) {
      _onMessagePublishedListener!(topic, qos, payload);
    }
  }

  Uint8List _buildPublishPacket(String topic, int qos, Uint8List payload, {int packetIdentifier = 0}) {
    // Fixed Header
    final fixedHeader = 0x30 | (qos << 1); // PUBLISH packet with QoS bits

    // Variable Header: Topic Name
    final topicBytes = Uint8List.fromList(topic.codeUnits);
    final topicLength = Uint8List(2);
    topicLength[0] = (topicBytes.length >> 8) & 0xFF;
    topicLength[1] = topicBytes.length & 0xFF;

    // Variable Header: Packet Identifier (if QoS > 0)
    Uint8List packetIdentifierBytes = Uint8List(0);
    if (qos > 0) {
      packetIdentifierBytes = Uint8List(2);
      packetIdentifierBytes[0] = (packetIdentifier >> 8) & 0xFF;
      packetIdentifierBytes[1] = packetIdentifier & 0xFF;
    }

    // Remaining Length: Topic Length + Packet Identifier (if QoS > 0) + Payload Length
    final remainingLength = topicBytes.length + 2 + packetIdentifierBytes.length + payload.length;
    final remainingLengthBytes = _encodeRemainingLength(remainingLength);

    // Combine all parts
    return Uint8List.fromList([
      fixedHeader,
      ...remainingLengthBytes,
      ...topicLength,
      ...topicBytes,
      ...packetIdentifierBytes,
      ...payload,
    ]);
  }

// Helper function to encode the remaining length
  Uint8List _encodeRemainingLength(int length) {
    final encodedBytes = <int>[];
    do {
      var byte = length % 128;
      length = length ~/ 128;
      // if there are more digits to encode, set the top bit of this digit
      if (length > 0) {
        byte = byte | 0x80;
      }
      encodedBytes.add(byte);
    } while (length > 0);
    return Uint8List.fromList(encodedBytes);
  }

  void _handlerPingReq(Socket client) {
    client.add(Uint8List.fromList([0xD0, 0x00]));
  }

  Future<void> _handleDisconnect(Socket socket) async {
    final client = _clients.where((e) => e.socket == socket).firstOrNull;
    if (client == null) {
      print('[MqttBroker] Client not found or already disconnected');
      return;
    }

    _topicSubscribers.forEach((topic, clientIds) {
      clientIds.removeWhere((e) => e == client.clientId);
    });
    await client.socket.close();
    _clients.removeWhere((e) => e.clientId == client.clientId);
    print('[MqttBroker] Client disconnected: ${client.clientId}');
  }

  Uint8List _buildConnAckPacket(bool isSessionPresent) {
    // MQTT CONNACK Packet: Fixed header (0x20) + Remaining length (0x02) + Flags (0x00) + Return Code (0x00)
    int flags = isSessionPresent ? 0x01 : 0x00;
    return Uint8List.fromList([0x20, 0x02, flags, 0x00]);
  }
}
