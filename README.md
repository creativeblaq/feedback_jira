<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages).
-->

# feedback_jira

## 🚀 Getting Started

### Setup

First, you will need to add `feedback_jira` to your `pubspec.yaml`.

```yaml
dependencies:
  flutter:
    sdk: flutter
  feedback_jira: x.y.z # use the latest version found on pub.dev
```

Then, run `flutter pub get` in your terminal.

### Use it

Just wrap your app in a `BetterFeedback` widget.
To show the feedback view just call `BetterFeedback.of(context).showAndUploadToJira(...);`.
The callback gets called when the user submits his feedback.

```dart
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(
    BetterFeedback(
      child: const MyApp(),
    ),
  );
}
```

Provide a way to show the feedback panel by calling
```dart
BetterFeedback.of(context).showAndUploadToJira(
    domainName: 'domainName',
    apiToken: 'api-token',
);
```
Provide a way to hide the feedback panel by calling  `BetterFeedback.of(context).hide();` 
