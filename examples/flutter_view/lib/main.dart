import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(new FlutterView());
}

class FlutterView extends StatelessWidget {

  @override
  Widget build(BuildContext context) {
    return new MaterialApp(
      title: 'Flutter View',
      theme: new ThemeData(
        primarySwatch: Colors.grey,
      ),
      home: new MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => new _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _channel = "increment";
  static const String _pong = "pong";
  static const String _emptyMessage = "";
  static const PlatformMessageChannel<String> platform =
      const PlatformMessageChannel<String>(_channel, const StringCodec());

  int _counter = 0;

  @override
  void initState() {
    super.initState();
    platform.setMessageHandler(_handlePlatformIncrement);
  }

  Future<String> _handlePlatformIncrement(String message) async {
    setState(() {
      _counter++;
    });
    return _emptyMessage;
  }

  void _sendFlutterIncrement() {
    platform.send(_pong);
  }

  @override
  Widget build(BuildContext context) {
    return new Scaffold(
      body: new Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          new Expanded(
            child: new Center(
              child: new Text(
                'Platform button tapped $_counter time${ _counter == 1 ? '' : 's' }.',
                style: new TextStyle(fontSize: 17.0))
            ),
          ),
          new Container(
            padding: const EdgeInsets.only(bottom: 15.0, left: 5.0),
            child: new Row(
              children: <Widget>[
                new Image.asset('assets/flutter-mark-square-64.png', scale: 1.5),
                new Text('Flutter', style: new TextStyle(fontSize: 30.0)),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: new FloatingActionButton(
        onPressed: _sendFlutterIncrement,
        child: new Icon(Icons.add),
      ),
    );
  }
}
