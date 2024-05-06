import 'package:feedback_jira/feedback_jira.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const BetterFeedback(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            ElevatedButton(
              onPressed: () {
                BetterFeedback.of(context).showAndUploadToJira(
                  domainName: 'enzo-calvino',
                  apiToken:
                      'ZW56b2NhbHZpbm8zQGdtYWlsLmNvbTpBVEFUVDN4RmZHRjBIVEZGNUxwanY4WGp3dF8zb0FPTmhMWDNJSElSTFkzTTB1a2VYT0RPYmdtT2RKNThwS2dKZm1BeUdEbFFfTWV2R2xJa3E5V3pxWF96TWo0NnZIdnhLSFAtWjVjcjluNVRBX2dDYzNvUEZsaFlpTzVTMGVHZDdOdHJyVWRnUDNXQ0o3SjNUZjdxVnRwQy1Bc2ZiVXlob1EtYncwcUlWenBSMlFYQS11YjFmZVU9ODhGNzg2QzI=',
                );
              },
              child: const Text('Show Feedback view'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
