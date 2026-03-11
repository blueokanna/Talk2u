import 'dart:async';
import 'package:flutter/material.dart';
import 'package:talk2u/src/rust/api/chat_api.dart' as rust_api;
import 'package:talk2u/src/rust/api/data_models.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  List<LogEntry> _logs = [];
  LogLevel? _currentFilter;
  Timer? _refreshTimer;
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
    // 自动刷新：每 2 秒拉取最新日志
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadLogs();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    try {
      final logs = await rust_api.getLogs(
        levelFilter: _currentFilter,
        limit: BigInt.from(200),
      );
      if (!mounted) return;
      setState(() {
        _logs = logs;
      });
      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to load logs: $e');
    }
  }

  Future<void> _clearLogs() async {
    await rust_api.clearLogs();
    _loadLogs();
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
    }
  }

  String _levelLabel(LogLevel level) {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  String _formatTimestamp(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('请求日志'),
        actions: [
          // 级别过滤
          PopupMenuButton<LogLevel?>(
            icon: Icon(
              Icons.filter_list,
              color: _currentFilter != null
                  ? _levelColor(_currentFilter!)
                  : null,
            ),
            tooltip: '按级别过滤',
            onSelected: (value) {
              setState(() {
                _currentFilter = value;
              });
              _loadLogs();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('全部')),
              PopupMenuItem(
                value: LogLevel.info,
                child: Text('INFO', style: TextStyle(color: Colors.blue)),
              ),
              PopupMenuItem(
                value: LogLevel.warning,
                child: Text('WARNING+', style: TextStyle(color: Colors.orange)),
              ),
              PopupMenuItem(
                value: LogLevel.error,
                child: Text('ERROR', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
          // 自动滚动
          IconButton(
            icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.pause),
            tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
              });
            },
          ),
          // 清空
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: _clearLogs,
          ),
        ],
      ),
      body: _logs.isEmpty
          ? const Center(
              child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
            )
          : ListView.builder(
              controller: _scrollController,
              itemCount: _logs.length,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemBuilder: (context, index) {
                final log = _logs[index];
                final color = _levelColor(log.level);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 时间戳
                      Text(
                        _formatTimestamp(log.timestamp),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: Colors.grey,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 级别标签
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          _levelLabel(log.level),
                          style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 消息内容
                      Expanded(
                        child: Text(
                          log.message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: log.level == LogLevel.error
                                ? Colors.red[300]
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
