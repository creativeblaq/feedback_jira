import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// This is an extension to make it easier to call
/// [showAndUploadToJira].
extension BetterFeedbackX on FeedbackController {
  /// Example usage:
  /// ```dart
  /// import 'package:feedback_jira/feedback_jira.dart';
  ///
  /// RaisedButton(
  ///   child: Text('Click me'),
  ///   onPressed: (){
  ///     BetterFeedback.of(context).showAndUploadToJira
  ///       domainName: 'jira-project',
  ///       apiToken: 'jira-api-token',
  ///     );
  ///   }
  /// )
  /// ```
  /// The API token needs access to:
  ///   - read_api
  ///   - write_repository
  /// See https://docs.gitlab.com/ee/user/project/settings/project_access_tokens.html#limiting-scopes-of-a-project-access-token
  void showAndUploadToJira({
    required String domainName,
    required String apiToken,
    required String jiraEmail,
    bool includeDeviceDetails = true,
    bool includeScreenshot = true,
    http.Client? client,
    Function(bool isShowing)? onShow,
  }) {
    show(uploadToJira(
      domainName: domainName,
      apiToken: apiToken,
      jiraEmail: jiraEmail,
      includeDeviceDetails: includeDeviceDetails,
      includeScreenshot: includeScreenshot,
      client: client,
    ));
    onShow?.call(isVisible);
  }

  bool get visible => isVisible;
}

Map<String, dynamic> _createParagraph(String label, String value) {
  List<Map<String, dynamic>> content = [];
  if (label.isNotEmpty) {
    content.add({
      "text": "$label: ",
      "type": "text",
      "marks": [
        {"type": "strong"}
      ]
    });
  }

  content.add({"text": " $value", "type": "text"});

  return {
    "type": "paragraph",
    "content": content,
  };
}

/// See [BetterFeedbackX.showAndUploadToJira].
/// This is just [visibleForTesting].
@visibleForTesting
OnFeedbackCallback uploadToJira({
  required String domainName,
  required String apiToken,
  required String jiraEmail,
  bool includeDeviceDetails = true,
  bool includeScreenshot = true,
  Map<String, dynamic>? customBody,
  http.Client? client,
}) {
  final httpClient = client ?? http.Client();
  final baseUrl = '$domainName.atlassian.net';

  return (UserFeedback feedback) async {
    final deviceDetailsMap = includeDeviceDetails ? await getDeviceDetails() : <String, dynamic>{};

    var contentMap = <Map<String, dynamic>>[];
    contentMap.add({
      "type": "paragraph",
      "content": [
        {
          "text": '${feedback.text}\n\n',
          "type": "text",
        }
      ]
    });

    if (includeDeviceDetails && deviceDetailsMap.isNotEmpty) {
      contentMap.add({"type": "rule"});
      contentMap.add({
        "type": "heading",
        "attrs": {"level": 3},
        "content": [
          {"type": "text", "text": "Device details"}
        ]
      });

      deviceDetailsMap.forEach((key, value) {
        contentMap.add(_createParagraph(key, value));
      });
    }

    Map<String, dynamic> descriptionMap = {
      "type": "doc",
      "version": 1,
      "content": contentMap,
    };

    final body = customBody ??
        {
          "fields": {
            "summary": feedback.text.split('.')[0],
            "issuetype": {"id": "10002"},
            "project": {"id": "10000"},
            "description": descriptionMap
          }
        };
    //final issueUri = Uri.https(baseUrl.replaceAll('https://', ''), '/rest/api/2/issue');
    final issueUri = Uri.https(baseUrl, '/rest/api/3/issue');
    final String basicAuth =
        'Basic ${base64Encode(utf8.encode('$jiraEmail:$apiToken'))}';

    try {
      final response = await httpClient.post(
        issueUri,
        body: jsonEncode(body),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.authorizationHeader: basicAuth
        },
      );
      final int statusCode = response.statusCode;
      if (kDebugMode) {
        debugPrint('Jira issue create response status: $statusCode');
      }

      if (statusCode >= 200 && statusCode < 400) {
        final resp =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final ticketId = resp['id'] as String;
        try {
          final attachmentsUri =
              Uri.https(baseUrl, '/rest/api/3/issue/$ticketId/attachments');
          if (includeScreenshot && feedback.screenshot.isNotEmpty) {
            await uploadAttachmentFromUint8List(
                attachmentsUri, basicAuth, feedback.screenshot, 'screenshot.png');
          }
        } catch (e) {
          rethrow;
        }
      } else {
        throw HttpException('Jira issue creation failed with status $statusCode');
      }
    } catch (e) {
      rethrow;
    }
  };
}

Future<String> uploadAttachmentFromUint8List(
    Uri uri, String authHeader, Uint8List fileData, String fileName) async {
  var request = http.MultipartRequest('POST', uri);

  var file = http.MultipartFile.fromBytes('file', fileData, filename: fileName);
  request.files.add(file);

  request.headers['Authorization'] = authHeader;
  request.headers['Content-Type'] = 'application/json';
  request.headers['X-Atlassian-Token'] = 'no-check';

  if (kDebugMode) {
    final redactedHeaders = Map<String, String>.from(request.headers);
    if (redactedHeaders.containsKey('Authorization')) {
      redactedHeaders['Authorization'] = 'REDACTED';
    }
    debugPrint('Attachment request headers: $redactedHeaders');
  }

  var response = await request.send();
  if (kDebugMode) {
    debugPrint('Attachment response: ${response.statusCode} ${response.reasonPhrase}');
  }

  if (response.statusCode >= 200 && response.statusCode < 400) {
    String responseBody = await response.stream.transform(utf8.decoder).join();
    return responseBody;
  } else {
    throw Exception(
        'Failed to upload attachment: ${response.statusCode} ${response.reasonPhrase}');
  }
}

Future<Map<String, dynamic>> getDeviceDetails() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  String version = '${packageInfo.version}-${packageInfo.buildNumber}';

  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  final platform = Platform.operatingSystem;

  //String deviceData = '';

  String makeData = '';

  if (Platform.isAndroid) {
    final info = await deviceInfo.androidInfo;
    makeData =
        '$platform, ${info.brand}, ${info.model}, ${info.version.release}';
    Map<String, dynamic> data = {
      'brand': info.brand,
      'model': info.model,
      'androidVersion': info.version.release,
      'make': makeData,
      'appVersion': version
    };
    // makeData = deviceData = jsonEncode(data);
    return data;
  } else if (Platform.isIOS) {
    final info = await deviceInfo.iosInfo;
    makeData = '$platform, ${info.utsname.machine}, ${info.systemVersion}';
    Map<String, dynamic> data = {
      'brand': 'Apple',
      'model': info.utsname.machine,
      'iosVersion': info.systemVersion,
      'make': makeData,
      'version': version
    };
    //deviceData = jsonEncode(data);
    return data;
  }

  return {};
}
