import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/constants.dart';
import '../auth/login_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _online = false;
  bool _busy = false;
  String? _error;
  final List<String> _orders = [];

  Future<void> _goOnline() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final token = await ref.read(authProvider.notifier).getIdToken();
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _busy = false;
        _error = 'Session expired. Please log in again.';
      });
      return;
    }
    try {
      final ch = WebSocketChannel.connect(
        Uri.parse('${AppConstants.webSocketUrl}?token=$token'),
      );
      await ch.ready;
      if (!mounted) {
        ch.sink.close();
        return;
      }
      _channel = ch;
      _sub = ch.stream.listen(
        (m) {
          if (mounted) setState(() => _orders.insert(0, m.toString()));
        },
        onError: (_) => _goOffline(error: 'Connection lost.'),
        onDone: () {
          if (_online) _goOffline(error: 'Connection closed.');
        },
      );
      setState(() {
        _online = true;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _online = false;
        _error = 'Could not connect. Please try again.';
      });
    }
  }

  void _goOffline({String? error}) {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    if (!mounted) return;
    setState(() {
      _online = false;
      _busy = false;
      _error = error;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () {
              _goOffline();
              ref.read(authProvider.notifier).logout();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Card(
                child: SwitchListTile(
                  title: Text(_online ? 'Receiving orders' : 'Not receiving orders'),
                  subtitle: Text(_busy
                      ? 'Connecting...'
                      : (_online ? 'Switch off to stop' : 'Switch on to receive orders')),
                  value: _online,
                  onChanged: _busy
                      ? null
                      : (on) => on ? _goOnline() : _goOffline(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: _orders.isEmpty
                    ? Center(
                        child: Text(_online
                            ? 'Waiting for new orders...'
                            : 'You are offline'),
                      )
                    : ListView.builder(
                        itemCount: _orders.length,
                        itemBuilder: (_, i) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.receipt_long),
                            title: Text('New order'),
                            subtitle: Text(_orders[i]),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
