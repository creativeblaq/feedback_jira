import 'dart:convert';
import 'dart:typed_data';

import 'package:feedback_jira/feedback_jira.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Recursively collect every ADF node of a given [type] from a doc tree.
///
/// When a node's type is in [stopAt], its subtree is not descended into. This
/// lets us exclude the (legitimately newline-bearing) text inside `codeBlock`
/// nodes when asserting on inline text.
List<Map<String, dynamic>> _collectByType(
  dynamic node,
  String type, {
  Set<String> stopAt = const {},
}) {
  final results = <Map<String, dynamic>>[];
  if (node is Map) {
    final nodeType = node['type'];
    if (nodeType == type) results.add(Map<String, dynamic>.from(node));
    if (stopAt.contains(nodeType)) return results;
    for (final v in node.values) {
      results.addAll(_collectByType(v, type, stopAt: stopAt));
    }
  } else if (node is List) {
    for (final v in node) {
      results.addAll(_collectByType(v, type, stopAt: stopAt));
    }
  }
  return results;
}

/// Runs the [uploadToJira] callback and returns the ADF `description` map that
/// would be POSTed to Jira, captured from the intercepted HTTP request.
Future<Map<String, dynamic>> _captureDescription(
  UserFeedback feedback, {
  Map<String, dynamic>? customBody,
  JiraCustomBodyFormat customBodyFormat = JiraCustomBodyFormat.paragraphs,
  List<String>? mentionAccountIds,
}) async {
  Map<String, dynamic>? captured;
  final mockClient = MockClient((request) async {
    if (request.url.path == '/rest/api/3/issue') {
      captured = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'id': '10001'}), 201);
    }
    return http.Response('{}', 200);
  });

  final callback = uploadToJira(
    jiraDetails: JiraDetails(
      domainName: 'example',
      apiToken: 'token',
      jiraEmail: 'me@example.com',
      projectKey: 'ENG',
      mentionAccountIds: mentionAccountIds,
    ),
    includeDeviceDetails: false,
    includeScreenshot: false,
    customBody: customBody,
    customBodyFormat: customBodyFormat,
    client: mockClient,
  );

  await callback(feedback);
  expect(captured, isNotNull, reason: 'issue create request was not captured');
  return (captured!['fields'] as Map<String, dynamic>)['description']
      as Map<String, dynamic>;
}

void main() {
  final screenshot = Uint8List(0);

  /// Asserts that every inline `text` node (outside code blocks) is a non-empty
  /// string that contains neither `\n` nor `\r`.
  void assertInlineTextNodesValid(Map<String, dynamic> description) {
    final textNodes =
        _collectByType(description, 'text', stopAt: {'codeBlock'});
    for (final node in textNodes) {
      final text = node['text'];
      expect(text, isA<String>(),
          reason: 'every ADF text node must have a String text: $node');
      expect((text as String).isNotEmpty, isTrue,
          reason: 'ADF text nodes must not be empty: ${jsonEncode(node)}');
      expect(text.contains('\n'), isFalse,
          reason: 'ADF text node must not contain \\n: ${jsonEncode(node)}');
      expect(text.contains('\r'), isFalse,
          reason: 'ADF text node must not contain \\r: ${jsonEncode(node)}');
    }
  }

  group('ADF description hardening', () {
    test('multi-line feedback + multi-line metadata emits no newline/empty text',
        () async {
      final description = await _captureDescription(
        UserFeedback(
          text: 'Line one\nLine two\r\nLine three',
          screenshot: screenshot,
        ),
        customBody: {
          'note': 'first line\nsecond line',
          'nested': {'deep': 'a\nb'},
        },
      );

      assertInlineTextNodesValid(description);
      expect(_collectByType(description, 'text', stopAt: {'codeBlock'}),
          isNotEmpty);
    });

    test('multi-line metadata in bullets format is clean', () async {
      final description = await _captureDescription(
        UserFeedback(text: 'hello', screenshot: screenshot),
        customBody: {
          'multi': 'x\ny\nz',
          'group': {'a': '1\n2'},
        },
        customBodyFormat: JiraCustomBodyFormat.bullets,
      );
      assertInlineTextNodesValid(description);
    });

    test('empty feedback text produces no empty text nodes', () async {
      final description = await _captureDescription(
        UserFeedback(text: '', screenshot: screenshot),
        customBody: {'k': 'v'},
      );
      assertInlineTextNodesValid(description);
    });

    test('whitespace-only feedback text produces no empty/newline text nodes',
        () async {
      final description = await _captureDescription(
        UserFeedback(text: '   \n\n  ', screenshot: screenshot),
        customBody: {'k': 'v'},
      );
      assertInlineTextNodesValid(description);
    });

    test('mention nodes include both id and text attrs', () async {
      final description = await _captureDescription(
        UserFeedback(text: 'ping', screenshot: screenshot),
        mentionAccountIds: ['acc-123'],
      );
      final mentions = _collectByType(description, 'mention');
      expect(mentions, isNotEmpty);
      for (final m in mentions) {
        final attrs = m['attrs'] as Map<String, dynamic>;
        expect(attrs['id'], isNotNull, reason: 'mention needs an id: $m');
        expect(attrs['text'], isA<String>(),
            reason: 'mention needs a text attr: $m');
        expect((attrs['text'] as String).isNotEmpty, isTrue,
            reason: 'mention text must be non-empty: $m');
      }
      assertInlineTextNodesValid(description);
    });
  });
}
