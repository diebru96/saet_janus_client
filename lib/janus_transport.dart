part of janus_client;

abstract class JanusTransport {
  String? url;
  int? sessionId;

  JanusTransport({this.url});

  Future<dynamic> getInfo();

  /// this is called internally whenever [JanusSession] or [JanusPlugin] is disposed for cleaning up of active connections either polling or websocket connection.
  void dispose();
}

///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use Rest as a transport mechanism for communicating with Janus Server.<br>
/// therefore for events sent by Janus server is received with the help of polling.
class RestJanusTransport extends JanusTransport {
  RestJanusTransport({String? url}) : super(url: url);

  /*
  * method for posting data to janus by using http client
  * */
  Future<dynamic> post(body, {int? handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    try {
      final res = (await http.post(Uri.parse(url! + suffixUrl), body: stringify(body)));
      if (res.statusCode < 300) {
        var response = res.body;
        return parse(response);
      } else {
        throw Exception(res.statusCode);
      }
    } on JsonCyclicError {
      return null;
    } on JsonUnsupportedObjectError {
      return null;
    } catch (e) {
      return null;
    }
  }

  /*
  * private method for get data to janus by using http client
  * */
  Future<dynamic> get({handleId}) async {
    var suffixUrl = '';
    if (sessionId != null && handleId == null) {
      suffixUrl = suffixUrl + "/$sessionId";
    } else if (sessionId != null && handleId != null) {
      suffixUrl = suffixUrl + "/$sessionId/$handleId";
    }
    return parse((await http.get(Uri.parse(url! + suffixUrl))).body);
  }

  @override
  void dispose() {}

  @override
  Future<dynamic> getInfo() async {
    return parse((await http.get(Uri.parse(url! + "/info"))).body);
  }
}

///
/// This transport class is provided to [JanusClient] instances in transport property in order to <br>
/// inform the plugin that we need to use WebSockets as a transport mechanism for communicating with Janus Server.<br>
/// sendCompleterTimeout is used to set timeout duration for each send request to Janus server resolving against transaction.
class WebSocketJanusTransport extends JanusTransport {
  WebSocketJanusTransport({
    String? url,
    this.sendCompleterTimeout = const Duration(seconds: 20),
    this.autoReconnect = true,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.maxMessageMissedRetries = 3,
    this.maxReconnectAttempts = 5,
  }) : super(url: url);

  WebSocketChannel? channel;
  WebSocketSink? sink;
  late Stream stream;
  bool isConnected = false;

  Duration sendCompleterTimeout;
  bool autoReconnect;
  Duration heartbeatInterval;
  int maxReconnectAttempts;
  int maxMessageMissedRetries;

  final Map<String, Completer<dynamic>> _pendingTransactions = {};
  Timer? _heartbeatTimer;
  int _reconnectAttempts = 0;

  /// Dispose WebSocket connection
  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    sink?.close();
    channel = null;
    isConnected = false;
  }

  /// Establish WebSocket connection
  void connect() {
    try {
      channel = WebSocketChannel.connect(
        Uri.parse(url!),
        protocols: ['janus-protocol'],
      );

      sink = channel!.sink;
      stream = channel!.stream.asBroadcastStream();
      isConnected = true;
      _reconnectAttempts = 0;

      // Start heartbeat
      _startHeartbeat();

      // Listen to incoming messages
      stream.listen(
        (event) {
          final msg = parse(event);
          final transaction = msg['transaction'];
          if (transaction != null && _pendingTransactions.containsKey(transaction)) {
            _pendingTransactions[transaction]!.complete(msg);
            _pendingTransactions.remove(transaction);
          }
        },
        onDone: _handleDisconnect,
        onError: (_) => _handleDisconnect(),
      );
    } catch (e) {
      print('WebSocket connect failed: $e');
      _handleDisconnect();
    }
  }

  /// Heartbeat to keep connection alive
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (isConnected) {
        final ping = {
          'janus': 'ping',
          'transaction': getUuid().v4(),
        };
        sink!.add(stringify(ping));
      }
    });
  }

  /// Handle disconnect and auto-reconnect
  void _handleDisconnect() async {
    isConnected = false;
    sink = null;
    channel = null;
    _heartbeatTimer?.cancel();

    if (autoReconnect && _reconnectAttempts < maxReconnectAttempts) {
      _reconnectAttempts++;
      final delay = Duration(seconds: 2 * _reconnectAttempts); // exponential backoff
      print('Reconnecting in ${delay.inSeconds}s...');
      await Future.delayed(delay);
      connect();
    } else if (_reconnectAttempts >= maxReconnectAttempts) {
      print('Max reconnect attempts reached.');
    }
  }

  /// Send JSON to Janus safely with 3 retries
  Future<dynamic> send(Map<String, dynamic> data, {int? handleId}) async {
    if (!isConnected || sink == null) {
      throw StateError("WebSocket is not connected");
    }

    final original = Map<String, dynamic>.from(data);

    for (int attempt = 1; attempt <= maxMessageMissedRetries; attempt++) {
      final Map<String, dynamic> payload = Map<String, dynamic>.from(original);
      final String transaction = getUuid().v4();
      payload['transaction'] = transaction;
      payload['session_id'] = sessionId;
      if (handleId != null) payload['handle_id'] = handleId;

      final completer = Completer<dynamic>();
      _pendingTransactions[transaction] = completer;

      sink!.add(stringify(payload));

      try {
        final response = await completer.future.timeout(sendCompleterTimeout);
        _pendingTransactions.remove(transaction);
        return response;
      } on TimeoutException {
        _pendingTransactions.remove(transaction);
        if (attempt == maxMessageMissedRetries) {
          throw TimeoutException("Janus transaction timed out after $maxMessageMissedRetries attempts");
        }
      }
    }

    throw TimeoutException("Unexpected send() failure");
  }

  @override
  Future<dynamic> getInfo() async {
    if (!isConnected) connect();
    final payload = {
      'janus': 'info',
    };
    return send(payload);
  }
}
