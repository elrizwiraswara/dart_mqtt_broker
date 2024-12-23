import 'dart:io';

class Client {
  final String clientId;
  final Socket socket;

  Client({
    required this.clientId,
    required this.socket,
  });
}
