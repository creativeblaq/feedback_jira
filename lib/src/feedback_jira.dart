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

/// Converts an arbitrary [raw] string into a list of ADF inline nodes that are
/// safe for Jira's strict ADF validator.
///
/// ADF `text` nodes MUST NOT contain newline characters and MUST NOT be empty.
/// This helper:
///  - normalizes `\r\n` and `\r` to `\n`,
///  - splits on `\n`,
///  - emits a `{"type":"text","text": <line>}` node for each non-blank line,
///  - inserts a `{"type":"hardBreak"}` between consecutive emitted lines, and
///  - returns `[]` for an all-empty/whitespace input so callers can skip
///    emitting an empty paragraph/bullet item.
///
/// When [bold] is true each text node carries a `strong` mark.
List<Map<String, dynamic>> _inlineTextNodes(String raw, {bool bold = false}) {
  final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final nodes = <Map<String, dynamic>>[];
  for (final line in normalized.split('\n')) {
    if (line.trim().isEmpty) continue;
    if (nodes.isNotEmpty) {
      nodes.add({"type": "hardBreak"});
    }
    final Map<String, dynamic> node = {"type": "text", "text": line};
    if (bold) {
      node["marks"] = [
        {"type": "strong"}
      ];
    }
    nodes.add(node);
  }
  return nodes;
}

/// Build an ADF paragraph node with a bold `label` prefix and a text `value`.
///
/// Returns `null` when both label and value are empty/whitespace so callers can
/// avoid emitting an empty paragraph (which strict ADF validation rejects).
Map<String, dynamic>? _createParagraph(String label, String value) {
  final content = <Map<String, dynamic>>[];
  if (label.isNotEmpty) {
    content.addAll(_inlineTextNodes("$label: ", bold: true));
  }
  content.addAll(_inlineTextNodes(value));

  if (content.isEmpty) return null;
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
    final header = _inlineTextNodes("$indent$key", bold: true);
    if (header.isNotEmpty) {
      out.add({"type": "paragraph", "content": header});
    }
    value.forEach((k, v) {
      _appendCustomParagraphs(k.toString(), v, out, depth + 1);
    });
  } else if (value is List) {
    final header = _inlineTextNodes("$indent$key", bold: true);
    if (header.isNotEmpty) {
      out.add({"type": "paragraph", "content": header});
    }
    for (int i = 0; i < value.length; i++) {
      _appendCustomParagraphs('[$i]', value[i], out, depth + 1);
    }
  } else {
    final paragraph =
        _createParagraph("$indent$key", value?.toString() ?? 'null');
    if (paragraph != null) out.add(paragraph);
  }
}

/// Helper to create a single-paragraph node whose text is split into
/// ADF-safe inline nodes (see [_inlineTextNodes]).
///
/// Returns `null` when [text] is empty/whitespace so callers can skip emitting
/// an empty paragraph.
Map<String, dynamic>? _paragraphNode(String text, {bool bold = false}) {
  final content = _inlineTextNodes(text, bold: bold);
  if (content.isEmpty) return null;
  return {
    "type": "paragraph",
    "content": content,
  };
}

/// Builds a hierarchical bullet list ADF node from a Map.
/// Returns `null` when the list would have no items (an empty `bulletList` is
/// invalid ADF).
Map<String, dynamic>? _buildBulletListFromMap(Map map) {
  final List<Map<String, dynamic>> items = [];
  map.forEach((k, v) {
    final content = <Map<String, dynamic>>[];
    if (v is Map) {
      final header = _paragraphNode(k.toString(), bold: true);
      if (header != null) content.add(header);
      final nested = _buildBulletListFromMap(v);
      if (nested != null) content.add(nested);
    } else if (v is List) {
      final header = _paragraphNode(k.toString(), bold: true);
      if (header != null) content.add(header);
      final nested = _buildBulletListFromList(v);
      if (nested != null) content.add(nested);
    } else {
      final leaf =
          _paragraphNode("${k.toString()}: ${v?.toString() ?? 'null'}");
      if (leaf != null) content.add(leaf);
    }
    if (content.isNotEmpty) {
      items.add({"type": "listItem", "content": content});
    }
  });
  if (items.isEmpty) return null;
  return {"type": "bulletList", "content": items};
}

/// Builds a hierarchical bullet list ADF node from a List.
/// Returns `null` when the list would have no items (an empty `bulletList` is
/// invalid ADF).
Map<String, dynamic>? _buildBulletListFromList(List list) {
  final List<Map<String, dynamic>> items = [];
  for (int i = 0; i < list.length; i++) {
    final v = list[i];
    final content = <Map<String, dynamic>>[];
    if (v is Map) {
      final header = _paragraphNode("[$i]", bold: true);
      if (header != null) content.add(header);
      final nested = _buildBulletListFromMap(v);
      if (nested != null) content.add(nested);
    } else if (v is List) {
      final header = _paragraphNode("[$i]", bold: true);
      if (header != null) content.add(header);
      final nested = _buildBulletListFromList(v);
      if (nested != null) content.add(nested);
    } else {
      final leaf = _paragraphNode("[$i]: ${v?.toString() ?? 'null'}");
      if (leaf != null) content.add(leaf);
    }
    if (content.isNotEmpty) {
      items.add({"type": "listItem", "content": content});
    }
  }
  if (items.isEmpty) return null;
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
    final String basicAuth =
        'Basic ${base64Encode(utf8.encode('${jiraDetails.jiraEmail}:${jiraDetails.apiToken}'))}';

    // Resolve assignee email to account ID if needed
    String? resolvedAssigneeId = jiraDetails.assigneeAccountId;
    if (resolvedAssigneeId != null && resolvedAssigneeId.contains('@')) {
      final lookup = await _lookupAccountIdFromEmail(
          resolvedAssigneeId, baseUrl, basicAuth, httpClient);
      resolvedAssigneeId = lookup?.accountId;
      if (resolvedAssigneeId == null && kDebugMode) {
        debugPrint(
            'Could not resolve assignee email: ${jiraDetails.assigneeAccountId}');
      }
    }

    // Resolve watcher emails to account IDs if needed
    List<String>? resolvedWatcherIds = jiraDetails.watcherAccountIds;
    if (resolvedWatcherIds != null && resolvedWatcherIds.isNotEmpty) {
      final resolved = <String>[];
      for (final id in resolvedWatcherIds) {
        if (id.contains('@')) {
          final lookup = await _lookupAccountIdFromEmail(
              id, baseUrl, basicAuth, httpClient);
          if (lookup != null) {
            resolved.add(lookup.accountId);
          } else if (kDebugMode) {
            debugPrint('Could not resolve watcher email: $id');
          }
        } else {
          resolved.add(id);
        }
      }
      resolvedWatcherIds = resolved;
    }

    // Resolve mention emails to account IDs if needed. Track any resolved
    // display names so mention nodes can carry a friendly `text` attr.
    final mentionDisplayNames = <String, String>{};
    List<String>? resolvedMentionIds = jiraDetails.mentionAccountIds;
    if (resolvedMentionIds != null && resolvedMentionIds.isNotEmpty) {
      final resolved = <String>[];
      for (final id in resolvedMentionIds) {
        if (id.contains('@')) {
          final lookup = await _lookupAccountIdFromEmail(
              id, baseUrl, basicAuth, httpClient);
          if (lookup != null) {
            resolved.add(lookup.accountId);
            final name = lookup.displayName;
            if (name != null && name.trim().isNotEmpty) {
              mentionDisplayNames[lookup.accountId] = name.trim();
            }
          } else if (kDebugMode) {
            debugPrint('Could not resolve mention email: $id');
          }
        } else {
          resolved.add(id);
        }
      }
      resolvedMentionIds = resolved;
    }
    final deviceDetailsMap =
        includeDeviceDetails ? await getDeviceDetails() : <String, dynamic>{};

    var contentMap = <Map<String, dynamic>>[];
    final feedbackNodes = _inlineTextNodes(feedback.text);
    if (feedbackNodes.isNotEmpty) {
      contentMap.add({
        "type": "paragraph",
        "content": feedbackNodes,
      });
    }

    // Add user mentions if specified
    if (resolvedMentionIds != null && resolvedMentionIds.isNotEmpty) {
      final mentionContent = <Map<String, dynamic>>[];
      for (final accountId in resolvedMentionIds.toSet()) {
        final name = mentionDisplayNames[accountId];
        final mentionText =
            (name != null && name.isNotEmpty) ? '@$name' : '@user';
        mentionContent.add({
          "type": "mention",
          "attrs": {"id": accountId, "text": mentionText}
        });
        mentionContent.add({"type": "text", "text": " "});
      }
      contentMap.add({
        "type": "paragraph",
        "content": mentionContent,
      });
    }

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
        final paragraph = _createParagraph(key, value?.toString() ?? 'null');
        if (paragraph != null) contentMap.add(paragraph);
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
        final bulletList = _buildBulletListFromMap(customBody);
        if (bulletList != null) contentMap.add(bulletList);
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
        final bulletList = _buildBulletListFromMap(customBody);
        if (bulletList != null) contentMap.add(bulletList);
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

    // A `doc` with an empty content array is invalid ADF; ensure at least one
    // block node is present (e.g. empty feedback with no device/custom data).
    if (contentMap.isEmpty) {
      contentMap.add({
        "type": "paragraph",
        "content": [
          {"type": "text", "text": "No description provided."}
        ]
      });
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
        if (resolvedAssigneeId != null) "assignee": {"id": resolvedAssigneeId},
      }
    };
    final issueUri = Uri.https(baseUrl, '/rest/api/3/issue');

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
          if (resolvedWatcherIds != null && resolvedWatcherIds.isNotEmpty) {
            final watchersUri =
                Uri.https(baseUrl, '/rest/api/3/issue/$ticketId/watchers');
            for (final accountId in resolvedWatcherIds.toSet()) {
              try {
                final watcherResponse = await httpClient.post(
                  watchersUri,
                  body: jsonEncode(accountId),
                  headers: {
                    HttpHeaders.contentTypeHeader: 'application/json',
                    HttpHeaders.acceptHeader: 'application/json',
                    HttpHeaders.authorizationHeader: basicAuth,
                  },
                );
                if (watcherResponse.statusCode < 200 ||
                    watcherResponse.statusCode >= 400) {
                  final errorBody = utf8.decode(watcherResponse.bodyBytes);
                  if (kDebugMode) {
                    debugPrint(
                        'Failed to add watcher $accountId: ${watcherResponse.statusCode}');
                    debugPrint('Error details: $errorBody');
                  }
                  // Continue with other watchers instead of failing completely
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('Exception adding watcher $accountId: $e');
                }
                // Continue with remaining watchers
              }
            }
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

/// Looks up a Jira user from their email address.
/// Returns the account ID and (when present) display name if found, or null if
/// not found or on error.
Future<({String accountId, String? displayName})?> _lookupAccountIdFromEmail(
    String email, String baseUrl, String basicAuth, http.Client client) async {
  try {
    final userSearchUri =
        Uri.https(baseUrl, '/rest/api/3/user/search', {'query': email.trim()});
    final response = await client.get(
      userSearchUri,
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.authorizationHeader: basicAuth,
      },
    );

    if (response.statusCode >= 200 && response.statusCode < 400) {
      final users = jsonDecode(utf8.decode(response.bodyBytes)) as List;
      if (users.isNotEmpty) {
        final user = users.first as Map<String, dynamic>;
        final accountId = user['accountId'] as String?;
        if (accountId != null) {
          return (
            accountId: accountId,
            displayName: user['displayName'] as String?,
          );
        }
      }
    }
    if (kDebugMode) {
      debugPrint('Failed to lookup account ID for email: $email');
    }
    return null;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error looking up account ID for $email: $e');
    }
    return null;
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
/// - `assigneeAccountId`: Account ID or email of the assignee (optional).
///   If an email is provided, it will be automatically resolved to an account ID.
/// - `watcherAccountIds`: Account IDs or emails to add as watchers (optional).
///   If emails are provided, they will be automatically resolved to account IDs.
/// - `mentionAccountIds`: Account IDs or emails to mention in the description (optional).
///   Users will be @mentioned and receive notifications. If emails are provided,
///   they will be automatically resolved to account IDs.
class JiraDetails {
  final String domainName;
  final String apiToken;
  final String jiraEmail;
  final String projectKey;
  final String issueType;
  final String? parentKey;
  final List<String>? labels;
  final String? assigneeAccountId;
  final List<String>? watcherAccountIds;
  final List<String>? mentionAccountIds;

  JiraDetails(
      {required this.domainName,
      required this.apiToken,
      required this.jiraEmail,
      required this.projectKey,
      this.issueType = 'Bug',
      this.parentKey,
      this.labels,
      this.assigneeAccountId,
      this.watcherAccountIds,
      this.mentionAccountIds});
}
