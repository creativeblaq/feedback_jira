import 'dart:convert';
import 'dart:io';

import 'package:feedback/feedback.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:http_parser/http_parser.dart';

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
    http.Client? client,
  }) {
    show(uploadToJira(
      domainName: domainName,
      apiToken: apiToken,
      client: client,
    ));
  }
}

/// See [BetterFeedbackX.showAndUploadToJira].
/// This is just [visibleForTesting].
@visibleForTesting
OnFeedbackCallback uploadToJira({
  required String domainName,
  required String apiToken,
  String? gitlabUrl,
  Map<String, dynamic>? customBody,
  http.Client? client,
}) {
  final httpClient = client ?? http.Client();
  final baseUrl = 'https://$domainName.atlassian.net';

  return (UserFeedback feedback) async {
    final body = customBody ??
        {
          'fields': {
            'description': feedback.text,
            'issuetype': {
              'id': '10001',
            },
            'parent': {},
            'project': {
              'id': '10000',
            },
            'summary': feedback.text,
          },
          'update': {},
        };
    final issueUri = Uri.https(baseUrl, '/rest/api/2/issue');

    try {
      final response = await httpClient.post(
        issueUri,
        body: body,
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.authorizationHeader: 'Basic $apiToken',
        },
      );
      final int statusCode = response.statusCode;
      if (statusCode >= 200 && statusCode < 400) {
        final resp = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final ticketId = resp['key'] as String;
        try {
          final attachmentsUri = Uri.https(baseUrl, '/rest/api/2/issue/$ticketId/attachments');
          final request = MultipartRequest('POST', attachmentsUri);
          request.headers['X-Atlassian-Token'] = 'no-check';
          request.headers['Accept'] = 'application/json';
          request.headers['Authorization'] = 'Basic $apiToken';
          final httpImage = MultipartFile.fromBytes(
            'file',
            feedback.screenshot,
            filename: 'screenshot.png',
            contentType: MediaType('image', 'png'),
          );
          request.files.add(httpImage);
          await request.send();
        } catch (e) {
          rethrow;
        }
      } else {
        throw HttpException('Erreur $statusCode');
      }
    } catch (e) {
      rethrow;
    }
  };
}
