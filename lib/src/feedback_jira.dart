import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Rendering formats for the `customBody` section in the Jira description.
/// - `paragraphs`: nested paragraphs (default), good general readability.
/// - `bullets`: hierarchical bullet lists for quick scanning.
/// - `codeBlock`: pretty-printed JSON for exact structure.
/// - `hybrid`: bullets followed by a JSON code block.
enum JiraCustomBodyFormat { paragraphs, bullets, codeBlock, hybrid }

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
  /// Shows the feedback UI and, upon submit, creates a Jira issue.
  /// Parameters:
  /// - `jiraDetails`: Jira project/domain/auth configuration.
  /// - `includeDeviceDetails`: Append device/app details to the description.
  /// - `includeScreenshot`: Upload the user's screenshot as an attachment.
  /// - `metadata`: Arbitrary nested map rendered using `customBodyFormat`.
  /// - `customBodyFormat`: Controls how `metadata` is rendered.
  /// - `client`: Optional HTTP client for testing/DI.
  /// - `onShow`: Callback when the feedback UI visibility changes.
  /// - `onSubmit`: Callback while submission is in progress.
  void showAndUploadToJira({
    required JiraDetails jiraDetails,
    bool includeDeviceDetails = true,
    bool includeScreenshot = true,
    Map<String, dynamic> metadata = const {},
    JiraCustomBodyFormat customBodyFormat = JiraCustomBodyFormat.paragraphs,
    http.Client? client,
    Function(bool isShowing)? onShow,
    Function(bool isSubmitting)? onSubmit,
  }) {
    show(uploadToJira(
      jiraDetails: jiraDetails,
      includeDeviceDetails: includeDeviceDetails,
      includeScreenshot: includeScreenshot,
      customBody: metadata,
      customBodyFormat: customBodyFormat,
      client: client,
      onSubmit: onSubmit,
    ));
    onShow?.call(isVisible);
  }

  bool get visible => isVisible;
}

/// Build an ADF paragraph node with a bold `label` prefix and a text `value`.
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

/// Recursively appends ADF paragraph nodes for nested maps/lists in `customBody`.
/// Uses indentation to reflect depth for readability.
void _appendCustomParagraphs(
    String key, dynamic value, List<Map<String, dynamic>> out, int depth) {
  final indent = depth > 0 ? List.filled(depth, '  ').join() : '';
  if (value is Map) {
    out.add({
      "type": "paragraph",
      "content": [
        {
          "text": "$indent$key",
          "type": "text",
          "marks": [
            {"type": "strong"}
          ]
        }
      ]
    });
    value.forEach((k, v) {
      _appendCustomParagraphs(k.toString(), v, out, depth + 1);
    });
  } else if (value is List) {
    out.add({
      "type": "paragraph",
      "content": [
        {
          "text": "$indent$key",
          "type": "text",
          "marks": [
            {"type": "strong"}
          ]
        }
      ]
    });
    for (int i = 0; i < value.length; i++) {
      _appendCustomParagraphs('[${i}]', value[i], out, depth + 1);
    }
  } else {
    out.add(_createParagraph("$indent$key", value?.toString() ?? 'null'));
  }
}

/// Helper to create an ADF text node. When `bold` is true, adds strong mark.
Map<String, dynamic> _textNode(String text, {bool bold = false}) {
  final Map<String, dynamic> node = {"text": text, "type": "text"};
  if (bold)
    node["marks"] = [
      {"type": "strong"}
    ];
  return node;
}

/// Helper to create a single-paragraph node with one text child.
Map<String, dynamic> _paragraphNode(String text, {bool bold = false}) {
  return {
    "type": "paragraph",
    "content": [_textNode(text, bold: bold)]
  };
}

/// Builds a hierarchical bullet list ADF node from a Map.
Map<String, dynamic> _buildBulletListFromMap(Map map) {
  final List<Map<String, dynamic>> items = [];
  map.forEach((k, v) {
    if (v is Map) {
      items.add({
        "type": "listItem",
        "content": [
          _paragraphNode(k.toString(), bold: true),
          _buildBulletListFromMap(v)
        ]
      });
    } else if (v is List) {
      items.add({
        "type": "listItem",
        "content": [
          _paragraphNode(k.toString(), bold: true),
          _buildBulletListFromList(v)
        ]
      });
    } else {
      items.add({
        "type": "listItem",
        "content": [
          _paragraphNode("${k.toString()}: ${v?.toString() ?? 'null'}")
        ]
      });
    }
  });
  return {"type": "bulletList", "content": items};
}

/// Builds a hierarchical bullet list ADF node from a List.
Map<String, dynamic> _buildBulletListFromList(List list) {
  final List<Map<String, dynamic>> items = [];
  for (int i = 0; i < list.length; i++) {
    final v = list[i];
    if (v is Map) {
      items.add({
        "type": "listItem",
        "content": [
          _paragraphNode("[${i}]", bold: true),
          _buildBulletListFromMap(v)
        ]
      });
    } else if (v is List) {
      items.add({
        "type": "listItem",
        "content": [
          _paragraphNode("[${i}]", bold: true),
          _buildBulletListFromList(v)
        ]
      });
    } else {
      items.add({
        "type": "listItem",
        "content": [_paragraphNode("[${i}]: ${v?.toString() ?? 'null'}")]
      });
    }
  }
  return {"type": "bulletList", "content": items};
}

/// See [BetterFeedbackX.showAndUploadToJira].
/// This is just [visibleForTesting].
@visibleForTesting
/// Creates the callback that posts a Jira issue and optional attachments.
/// Uses Jira Cloud REST v3 and ADF for description content.
OnFeedbackCallback uploadToJira({
  required JiraDetails jiraDetails,
  bool includeDeviceDetails = true,
  bool includeScreenshot = true,
  Map<String, dynamic>? customBody,
  JiraCustomBodyFormat customBodyFormat = JiraCustomBodyFormat.paragraphs,
  http.Client? client,
  Function(bool isSubmitting)? onSubmit,
}) {
  final httpClient = client ?? http.Client();
  final baseUrl = '${jiraDetails.domainName}.atlassian.net';

  return (UserFeedback feedback) async {
    final deviceDetailsMap =
        includeDeviceDetails ? await getDeviceDetails() : <String, dynamic>{};

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

    if (customBody != null) {
      contentMap.add({"type": "rule"});
      contentMap.add({
        "type": "heading",
        "attrs": {"level": 3},
        "content": [
          {"type": "text", "text": "Custom data"}
        ]
      });

      if (customBodyFormat == JiraCustomBodyFormat.paragraphs) {
        customBody.forEach((key, value) {
          _appendCustomParagraphs(key, value, contentMap, 0);
        });
      } else if (customBodyFormat == JiraCustomBodyFormat.bullets) {
        contentMap.add(_buildBulletListFromMap(customBody));
      } else if (customBodyFormat == JiraCustomBodyFormat.codeBlock) {
        final encoder = const JsonEncoder.withIndent('  ');
        final jsonStr = encoder.convert(customBody);
        contentMap.add({
          "type": "codeBlock",
          "attrs": {"language": "json"},
          "content": [
            {"type": "text", "text": jsonStr}
          ]
        });
      } else if (customBodyFormat == JiraCustomBodyFormat.hybrid) {
        // Bullets for quick scan
        contentMap.add(_buildBulletListFromMap(customBody));
        // Divider and full JSON for exact fidelity
        contentMap.add({"type": "rule"});
        final encoder = const JsonEncoder.withIndent('  ');
        final jsonStr = encoder.convert(customBody);
        contentMap.add({
          "type": "codeBlock",
          "attrs": {"language": "json"},
          "content": [
            {"type": "text", "text": jsonStr}
          ]
        });
      }
    }

    Map<String, dynamic> descriptionMap = {
      "type": "doc",
      "version": 1,
      "content": contentMap,
    };

    final body = {
      "fields": {
        "summary": (feedback.text.trim().isEmpty
            ? 'Feedback'
            : feedback.text.split('.').first.trim()),
        "issuetype": {"name": jiraDetails.issueType},
        "project": {"key": jiraDetails.projectKey},
        "description": descriptionMap,
        if (jiraDetails.parentKey != null)
          "parent": {"key": jiraDetails.parentKey},
        if (jiraDetails.labels != null) "labels": jiraDetails.labels,
      }
    };
    final issueUri = Uri.https(baseUrl, '/rest/api/3/issue');
    final String basicAuth =
        'Basic ${base64Encode(utf8.encode('${jiraDetails.jiraEmail}:${jiraDetails.apiToken}'))}';

    try {
      onSubmit?.call(true);
      final response = await httpClient.post(
        issueUri,
        body: jsonEncode(body),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.authorizationHeader: basicAuth
        },
      );
      print(response);

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
                attachmentsUri,
                basicAuth,
                feedback.screenshot,
                'screenshot-${DateTime.now().millisecondsSinceEpoch}.png');
          }
        } catch (e) {
          rethrow;
        }
      } else {
        if (kDebugMode) {
          debugPrint(
              'Jira issue create error body: ${utf8.decode(response.bodyBytes)}');
        }
        throw HttpException(
            'Jira issue creation failed with status $statusCode');
      }
      onSubmit?.call(false);
    } catch (e) {
      onSubmit?.call(false);
      rethrow;
    }
  };
}

/// Uploads a binary attachment to the Jira issue `attachments` endpoint.
/// Returns the response body on success; throws on non-2xx.
Future<String> uploadAttachmentFromUint8List(
    Uri uri, String authHeader, Uint8List fileData, String fileName) async {
  var request = http.MultipartRequest('POST', uri);

  var file = http.MultipartFile.fromBytes('file', fileData, filename: fileName);
  request.files.add(file);

  request.headers['Authorization'] = authHeader;
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
    debugPrint(
        'Attachment response: ${response.statusCode} ${response.reasonPhrase}');
  }

  if (response.statusCode >= 200 && response.statusCode < 400) {
    String responseBody = await response.stream.transform(utf8.decoder).join();
    return responseBody;
  } else {
    throw Exception(
        'Failed to upload attachment: ${response.statusCode} ${response.reasonPhrase}');
  }
}

/// Collects app and device details to include in the Jira description.
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
      'appVersion': version
    };
    //deviceData = jsonEncode(data);
    return data;
  }

  return {};
}

/// Jira connection and issue configuration.
/// - `domainName`: e.g., 'yourcompany' for yourcompany.atlassian.net
/// - `apiToken`: Atlassian API token for the given `jiraEmail`.
/// - `jiraEmail`: Atlassian account email used for API token.
/// - `projectKey`: Jira project key (e.g., 'ENG').
/// - `issueType`: Issue type name (e.g., 'Bug', 'Task').
/// - `parentKey`: Parent issue key for sub-tasks (optional).
/// - `labels`: Labels to apply (optional).
class JiraDetails {
  final String domainName;
  final String apiToken;
  final String jiraEmail;
  final String projectKey;
  final String issueType;
  final String? parentKey;
  final List<String>? labels;

  JiraDetails(
      {required this.domainName,
      required this.apiToken,
      required this.jiraEmail,
      required this.projectKey,
      this.issueType = 'Bug',
      this.parentKey,
      this.labels});
}
