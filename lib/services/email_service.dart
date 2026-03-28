import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class EmailService {
  // ─────────────────────────────────────────────────────────────────────────
  // EmailJS credentials — using same as AuthService
  // ─────────────────────────────────────────────────────────────────────────
  static const String _serviceId = 'service_smuxq4m';
  static const String _publicKey = 'tmxqqbH_JgwNFONgt';

  // Template IDs
  static const String _sosTemplateId = 'df7mqq5';
  // If user has other templates, they can be added here.
  // For now we'll use a generic approach or default to the verified SOS one if needed.
  // ─────────────────────────────────────────────────────────────────────────

  Future<bool> _sendViaEmailJS({
    required String toEmail,
    required String templateId,
    required Map<String, dynamic> templateParams,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'service_id': _serviceId,
          'template_id': templateId,
          'user_id': _publicKey,
          'template_params': {'email': toEmail, ...templateParams},
        }),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        debugPrint('EmailJS Error ${response.statusCode}: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('EmailJS Exception: $e');
      return false;
    }
  }

  /// Send a welcome email to a new user
  Future<bool> sendWelcomeEmail(String userEmail, String userName) async {
    return _sendViaEmailJS(
      toEmail: userEmail,
      templateId:
          'template_welcome', // Placeholder - user should verify this ID
      templateParams: {'user_name': userName},
    );
  }

  /// Send SOS alert to emergency contacts
  Future<bool> sendSOSAlert({
    required List<String> emergencyEmails,
    required String userName,
    required String location,
  }) async {
    bool allSent = true;
    for (var email in emergencyEmails) {
      final success = await _sendViaEmailJS(
        toEmail: email,
        templateId: _sosTemplateId,
        templateParams: {
          'user_name': userName,
          'location_link': location,
          'timestamp': DateTime.now().toString(),
        },
      );
      if (!success) allSent = false;
    }
    return allSent;
  }

  /// Send SOS premium alert with detailed template
  Future<bool> sendSOSPremiumAlert({
    required String emergencyEmail,
    required String fullName,
    required String locationName,
    required String latitude,
    required String longitude,
    required String dateTime,
    required String link,
  }) async {
    return _sendViaEmailJS(
      toEmail: emergencyEmail,
      templateId: 'template_gzuk13l',
      templateParams: {
        'FULL_NAME': fullName,
        'LOCATION_NAME': locationName,
        'LINK': link,
        'LATITUDE': latitude,
        'LONGITUDE': longitude,
        'DATE_TIME': dateTime,
      },
    );
  }

  /// Send journey notification
  Future<bool> sendJourneyNotification({
    required String userEmail,
    required String userName,
    required String startLocation,
    required String destination,
    required bool isStarting,
  }) async {
    return _sendViaEmailJS(
      toEmail: userEmail,
      templateId: 'template_journey', // Placeholder
      templateParams: {
        'user_name': userName,
        'start_location': startLocation,
        'destination': destination,
        'status': isStarting ? 'Started' : 'Completed',
        'timestamp': DateTime.now().toString(),
      },
    );
  }

  /// Send custom email
  Future<bool> sendCustomEmail({
    required String to,
    required String subject,
    required String htmlBody,
  }) async {
    // Note: EmailJS usually requires templates, so "custom email" with raw HTML
    // might require a special template with a catch-all variable like {{message}}.
    return _sendViaEmailJS(
      toEmail: to,
      templateId: 'template_custom', // Placeholder
      templateParams: {'subject': subject, 'message': htmlBody},
    );
  }
}
